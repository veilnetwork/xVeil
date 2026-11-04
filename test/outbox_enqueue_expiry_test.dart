@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

import 'support/fake_hv_container.dart';

NodeId _id(int n) => NodeId(Uint8List(32)..fillRange(0, 32, n));

class _EnqueueStore extends HiddenVolumeStorage {
  _EnqueueStore(super.opener);
  _EnqueueStore.async(super.opener) : super.async();
  final entered = Completer<void>(), release = Completer<void>();
  bool armed = true, failReplace = false;
  OutboxFrame? committed;
  @override
  Future<void> enqueueOutboxFrame(
    String id,
    String peer,
    Uint8List wire,
  ) async {
    await super.enqueueOutboxFrame(id, peer, wire);
    if (armed && WireEnvelope.decode(wire).kind == WireKind.edit) {
      armed = false;
      committed = (await super.pendingOutboxFrames()).singleWhere(
        (f) => f.frameId == id && f.peerHex == peer,
      );
      entered.complete();
      await release.future;
    }
  }

  @override
  Future<bool> replaceOutboxFrames(
    List<OutboxFrame> old,
    List<OutboxFrame> fresh,
  ) {
    if (failReplace) {
      throw StateError('fixture queued expiry replacement refused');
    }
    return super.replaceOutboxFrames(old, fresh);
  }
}

class _Capture extends LoopbackTransport {
  _Capture() : super(localNodeId: _id(1));
  final sent = <WireEnvelope>[];
  @override
  Future<void> send(
    NodeId dst,
    Uint8List wire, {
    bool anonymous = false,
  }) async {
    final envelope = WireEnvelope.decode(wire);
    sent.add(envelope);
  }
}

void main() {
  for (final native in [false, true]) {
    for (final mode in [
      'silent-expiry',
      'silent-deleted',
      'live-expiry',
      'silent-failure',
      'silent-legacy',
      'silent-fresh',
      'silent-ttl-off',
    ]) {
      test(
        'edit enqueue TTL $mode (native=$native)',
        () async {
          final peer = _id(2), self = _id(1);
          late _EnqueueStore storage;
          String? path;
          final password = Uint8List.fromList(utf8.encode('fixture'));
          if (native) {
            expect(
              ensureHiddenVolumeLoaded(
                dylibPath: Platform.environment['XVEIL_HV_DYLIB'],
              ),
              isTrue,
            );
            final dir = await Directory.systemTemp.createTemp(
              'xveil-enqueue-ttl-',
            );
            addTearDown(() => dir.delete(recursive: true));
            path = '${dir.path}/store.hv';
            HvKvLogStore(
              hv.HvSpace.create(
                path: path,
                password: password,
                argon: hv.ArgonPreset.light,
              ),
            ).close();
            storage = _EnqueueStore.async(workerSpaceOpener(path));
          } else {
            storage = _EnqueueStore(FakeHvContainer().passwordOpener);
          }
          expect(
            await storage.open(password: 'fixture', createIfMissing: true),
            isTrue,
          );
          var now = DateTime.fromMillisecondsSinceEpoch(
            DateTime.now().millisecondsSinceEpoch,
          );
          final live = mode == 'live-expiry', legacy = mode == 'silent-legacy';
          final retained = mode == 'silent-fresh' || mode == 'silent-ttl-off';
          await storage.upsertContact(
            Contact(
              nodeId: peer,
              status: ContactStatus.accepted,
              disappearingTtlSeconds:
                  mode == 'silent-deleted' || mode == 'silent-ttl-off'
                  ? null
                  : 30,
            ),
          );
          if (!live) {
            await storage.putSetting(
              'peer_seen:${peer.hex}',
              '${now.subtract(const Duration(days: 2)).millisecondsSinceEpoch}',
            );
          }
          await storage.appendMessage(
            Message(
              id: 'queue-target',
              conversationId: peer.hex,
              direction: MessageDirection.outgoing,
              author: self.hex,
              timestamp: now,
              status: MessageStatus.delivered,
              body: 'ORIGINAL_QUEUE_TARGET',
            ),
          );
          late _Capture link;
          late MessagingService service;
          final edits = <String>[], deletes = <String>[];
          void bind() {
            link = _Capture();
            service = MessagingService(link, storage, now: () => now);
            service.onMessageEdited = (_, _, body, _) => edits.add(body);
            service.onMessageDeleted = (_, id) => deletes.add(id);
          }

          bind();
          addTearDown(() async {
            if (!storage.release.isCompleted) storage.release.complete();
            await service.dispose();
            await link.dispose();
            await storage.close();
          });
          const body = 'PRIVATE_ENQUEUE_EDIT';
          final editing = legacy
              ? service.sendDurable(
                  peer,
                  'legacy-queue-edit',
                  const WireEnvelope.edit('queue-target', body),
                  awaitLive: false,
                )
              : service.editOwnMessage('queue-target', body);
          final observed = editing.then<Object?>(
            (_) => null,
            onError: (Object e, StackTrace _) => e,
          );
          try {
            await storage.entered.future.timeout(const Duration(seconds: 10));
            expect(
              WireEnvelope.decode(storage.committed!.wire).body,
              body,
              reason:
                  'positive control: the exact durable frame exists before enqueue returns',
            );
            expect(
              (await storage.pendingOutboxFrames()).any(
                (f) => f.frameId == storage.committed!.frameId,
              ),
              isTrue,
            );
            if (mode == 'silent-deleted') {
              await storage.deleteMessage(peer.hex, 'queue-target');
            }
            if (mode != 'silent-fresh') {
              now = now.add(const Duration(seconds: 30));
            }
            storage.failReplace = mode == 'silent-failure';
            // Backend queue timestamps use the real wall clock, unlike the TTL
            // test clock. Separate their values to test preservation, not speed.
            await Future<void>.delayed(const Duration(milliseconds: 5));
          } finally {
            storage.release.complete();
          }
          final error = await observed;
          if (mode == 'silent-failure') {
            expect(
              error,
              isA<StateError>(),
              reason: 'failed durable cleanup must propagate to the editor',
            );
            expect(edits, isEmpty);
            expect(
              (await storage.pendingOutboxFrames()).any(
                (f) => f.frameId == storage.committed!.frameId,
              ),
              isTrue,
              reason:
                  'the failed replacement retains the exact retry obligation',
            );
            expect(link.sent.where((e) => e.kind == WireKind.edit), isEmpty);
            storage.failReplace = false;
            await service.dispose();
            await link.dispose();
            await storage.close();
            expect(await storage.open(password: 'fixture'), isTrue);
            bind();
            await service.sweepAllDisappearing();
          } else {
            expect(error, isNull);
          }
          final frames = await storage.pendingOutboxFrames();
          final envelopes = frames
              .map((f) => WireEnvelope.decode(f.wire))
              .toList();
          if (retained) {
            expect(envelopes.single.kind, WireKind.edit);
            expect(envelopes.single.body, body);
            expect(edits, [body]);
            expect(
              await storage.loadMessageById(peer.hex, 'queue-target'),
              isNotNull,
            );
          } else {
            expect(
              envelopes.where((e) => e.kind == WireKind.edit),
              isEmpty,
              reason:
                  'enqueue completion must recheck TTL even when no live leg runs',
            );
            expect(
              edits,
              isEmpty,
              reason:
                  'expired edit must not enter sibling publication after enqueue',
            );
            expect(
              await storage.isMessageDeleted(peer.hex, 'queue-target'),
              isTrue,
            );
            if (legacy) {
              expect(frames, isEmpty);
              expect(deletes, isEmpty);
            } else {
              expect(envelopes.single.kind, WireKind.voidSeq);
              expect(
                envelopes.single.seq,
                WireEnvelope.decode(storage.committed!.wire).seq,
              );
              expect(envelopes.single.id, isNull);
              expect(envelopes.single.body, isEmpty);
              expect(deletes, ['queue-target']);
            }
          }
          if (frames.isNotEmpty) {
            expect(
              frames.single.enqueuedAtMs,
              storage.committed!.enqueuedAtMs,
              reason: 'replacement must preserve the committed frame age',
            );
          }
          expect(link.sent.where((e) => e.kind == WireKind.edit), isEmpty);
          // Normal transport must still work after this operation. A non-edit
          // control does not inherit the target's expiry or its recipient lane.
          final active = _id(3);
          await service.sendDurable(
            active,
            'healthy-control',
            const WireEnvelope.del('healthy-control'),
          );
          expect(
            link.sent.where(
              (e) => e.kind == WireKind.del && e.id == 'healthy-control',
            ),
            hasLength(1),
          );
          await service.dispose();
          await storage.close();
          if (native && !retained) {
            final raw = (await workerSpaceOpener(path!)(
              password: password,
              create: false,
            ))!;
            try {
              var controls = 0;
              for (final row in await raw.iterLogRange(
                namespace: Ns.outbox,
                limit: 8192,
              )) {
                final payload = jsonDecode(utf8.decode(row.payload));
                if (payload is! Map || payload['w'] is! String) continue;
                final frame = WireEnvelope.decode(
                  base64Decode(payload['w'] as String),
                );
                expect(frame.body, isNot(contains(body)));
                if (frame.kind == WireKind.del &&
                    frame.id == 'healthy-control') {
                  controls++;
                }
              }
              expect(
                controls,
                1,
                reason: 'positive control for native raw Outbox roots',
              );
            } finally {
              await raw.close();
            }
          }
          expect(await storage.open(password: 'fixture'), isTrue);
          final cold = (await storage.pendingOutboxFrames()).map(
            (f) => WireEnvelope.decode(f.wire),
          );
          expect(
            cold.where((e) => e.kind == WireKind.edit).length,
            retained ? 1 : 0,
          );
        },
        skip: native && (Platform.environment['XVEIL_HV_DYLIB'] ?? '').isEmpty,
      );
    }
  }
}
