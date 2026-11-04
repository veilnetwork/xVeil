@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:io';
import 'dart:convert';
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
const _frame = 'edit:concurrent-expiry', _target = 'concurrent-target';
const _body = 'PRIVATE_CONCURRENT_EDIT';

class _Store extends HiddenVolumeStorage {
  _Store(super.opener);
  _Store.async(super.opener) : super.async();
  int lookups = 0;
  int? pauseLookup;
  int tombstoneReads = 0;
  int? pauseTombstone;
  bool holdLoaded = false;
  Message? loadedAtGate;
  bool pauseReplacement = false, failReplacement = false, failFinish = false;
  final lookupEntered = Completer<void>(), lookupRelease = Completer<void>();
  final replaceEntered = Completer<void>(), replaceRelease = Completer<void>();
  final tombstoneEntered = Completer<void>();
  final tombstoneRelease = Completer<void>();
  @override
  Future<bool> isMessageDeleted(String conversation, String id) async {
    final deleted = await super.isMessageDeleted(conversation, id);
    if (id == _target && ++tombstoneReads == pauseTombstone) {
      tombstoneEntered.complete();
      await tombstoneRelease.future;
    }
    return deleted;
  }

  @override
  Future<Message?> loadMessageById(String conversation, String id) async {
    if (id == _target && ++lookups == pauseLookup) {
      if (holdLoaded) {
        loadedAtGate = await super.loadMessageById(conversation, id);
      }
      lookupEntered.complete();
      await lookupRelease.future;
      if (holdLoaded) return loadedAtGate;
    }
    return super.loadMessageById(conversation, id);
  }

  @override
  Future<bool> replaceOutboxFrames(
    List<OutboxFrame> old,
    List<OutboxFrame> fresh,
  ) async {
    if (pauseReplacement) {
      pauseReplacement = false;
      replaceEntered.complete();
      await replaceRelease.future;
    }
    if (failReplacement) {
      throw StateError('fixture shared cleanup refused');
    }
    return super.replaceOutboxFrames(old, fresh);
  }

  @override
  Future<void> finishOutboxCleanup() {
    if (failFinish) throw StateError('fixture shared vacuum refused');
    return super.finishOutboxCleanup();
  }
}

class _Link extends LoopbackTransport {
  _Link() : super(localNodeId: _id(1));
  final sent = <WireEnvelope>[];
  @override
  Future<void> send(
    NodeId peer,
    Uint8List wire, {
    bool anonymous = false,
  }) async => sent.add(WireEnvelope.decode(wire));
}

void main() {
  for (final native in [false, true]) {
    for (final mode in [
      'empty-lookup',
      'held-lookup',
      'clock-after-tombstone',
      'shared-success',
      'shared-failure',
      'shared-vacuum-failure',
      'persisted-retry',
      'changed-payload',
      'dispose',
    ]) {
      test(
        'concurrent edit expiry $mode (native=$native)',
        () async {
          final peer = _id(2), self = _id(1);
          late _Store storage;
          String? path;
          if (native) {
            expect(
              ensureHiddenVolumeLoaded(
                dylibPath: Platform.environment['XVEIL_HV_DYLIB'],
              ),
              isTrue,
            );
            final dir = await Directory.systemTemp.createTemp(
              'xveil-concurrent-ttl-',
            );
            addTearDown(() => dir.delete(recursive: true));
            path = '${dir.path}/store.hv';
            HvKvLogStore(
              hv.HvSpace.create(
                path: path,
                password: Uint8List.fromList(utf8.encode('fixture')),
                argon: hv.ArgonPreset.light,
              ),
            ).close();
            storage = _Store.async(workerSpaceOpener(path));
          } else {
            storage = _Store(FakeHvContainer().passwordOpener);
          }
          expect(
            await storage.open(password: 'fixture', createIfMissing: true),
            isTrue,
          );
          var now = DateTime.fromMillisecondsSinceEpoch(
            DateTime.now().millisecondsSinceEpoch,
          );
          final link = _Link();
          final service = MessagingService(link, storage, now: () => now);
          addTearDown(() async {
            if (!storage.lookupRelease.isCompleted) {
              storage.lookupRelease.complete();
            }
            if (!storage.replaceRelease.isCompleted) {
              storage.replaceRelease.complete();
            }
            if (!storage.tombstoneRelease.isCompleted) {
              storage.tombstoneRelease.complete();
            }
            await service.dispose();
            await link.dispose();
            await storage.close();
          });
          await storage.upsertContact(
            Contact(
              nodeId: peer,
              status: ContactStatus.accepted,
              disappearingTtlSeconds: mode == 'held-lookup' ? null : 30,
            ),
          );
          await storage.appendMessage(
            Message(
              id: _target,
              conversationId: peer.hex,
              direction: MessageDirection.outgoing,
              author: self.hex,
              timestamp: now,
              status: MessageStatus.delivered,
              body: 'original',
            ),
          );
          final seq = await storage.editMessage(peer.hex, _target, _body);
          expect(seq, isNotNull);
          final envelope = WireEnvelope.edit(_target, _body, seq: seq);
          await storage.enqueueOutboxFrame(
            _frame,
            peer.hex,
            envelope.withFrameId(_frame).encode(),
          );
          final stamp =
              (await storage.pendingOutboxFrames()).single.enqueuedAtMs;
          storage.lookups = 0;
          storage.tombstoneReads = 0;
          if (mode == 'clock-after-tombstone') {
            // Two reads select the candidate; two more revalidate redrive.
            // Hold the last read while the ORIGINAL post crosses its TTL.
            storage.pauseTombstone = 4;
            final flushing = service.debugFlushOutboxFrames();
            try {
              await storage.tombstoneEntered.future.timeout(
                const Duration(seconds: 10),
              );
              expect(link.sent.where((e) => e.kind == WireKind.edit), isEmpty);
              expect(
                (await storage.pendingOutboxFrames()).single.frameId,
                _frame,
              );
              expect(
                (await storage.loadMessageById(peer.hex, _target))!.body,
                _body,
              );
              now = now.add(const Duration(seconds: 30));
            } finally {
              storage.tombstoneRelease.complete();
            }
            await flushing;
            expect(
              link.sent.where((e) => e.kind == WireKind.edit),
              isEmpty,
              reason: 'TTL must be evaluated after the last storage await',
            );
          } else if (mode == 'empty-lookup' || mode == 'held-lookup') {
            // First read admits the candidate, second revalidates before live
            // redrive. The preconditions below witness the queued/no-send phase.
            storage.pauseLookup = 2;
            storage.holdLoaded = mode == 'held-lookup';
            final flushing = service.debugFlushOutboxFrames();
            try {
              await storage.lookupEntered.future.timeout(
                const Duration(seconds: 10),
              );
              expect(link.sent.where((e) => e.kind == WireKind.edit), isEmpty);
              expect(
                (await storage.pendingOutboxFrames()).single.frameId,
                _frame,
              );
              if (mode == 'held-lookup') {
                expect(storage.loadedAtGate!.body, _body);
              } else {
                now = now.add(const Duration(seconds: 30));
              }
              await storage.deleteMessage(peer.hex, _target);
              expect(await storage.isMessageDeleted(peer.hex, _target), isTrue);
            } finally {
              storage.lookupRelease.complete();
            }
            await flushing;
            expect(
              link.sent.where((e) => e.kind == WireKind.edit),
              isEmpty,
              reason:
                  'a stale lookup after durable deletion cannot authorize redrive',
            );
            expect(
              (await storage.pendingOutboxFrames()).any(
                (f) => f.frameId == _frame,
              ),
              isFalse,
            );
          } else if (mode == 'persisted-retry') {
            now = now.add(const Duration(seconds: 30));
            await service.sendDurable(peer, _frame, envelope, awaitLive: false);
            expect(
              (await storage.pendingOutboxFrames()).any(
                (f) => f.frameId == _frame,
              ),
              isFalse,
              reason:
                  'pre-enqueue refusal must also retire the identical already-persisted wire',
            );
          } else {
            now = now.add(const Duration(seconds: 30));
            storage.pauseReplacement = true;
            storage.failReplacement = mode == 'shared-failure';
            storage.failFinish = mode == 'shared-vacuum-failure';
            final cleaning = service.debugFlushOutboxFrames();
            await storage.replaceEntered.future.timeout(
              const Duration(seconds: 10),
            );
            expect(
              (await storage.pendingOutboxFrames()).single.frameId,
              _frame,
            );
            bool finished = false;
            late Future<Object?> joining;
            if (mode == 'dispose') {
              joining = service.dispose().then<Object?>(
                (_) {
                  finished = true;
                  return null;
                },
                onError: (Object e, StackTrace _) {
                  finished = true;
                  return e;
                },
              );
            } else {
              var next = envelope;
              if (mode == 'changed-payload') {
                await storage.appendMessage(
                  Message(
                    id: 'other-target',
                    conversationId: peer.hex,
                    direction: MessageDirection.outgoing,
                    author: self.hex,
                    timestamp: now,
                    body: 'live-other',
                    status: MessageStatus.delivered,
                  ),
                );
                final otherSeq = await storage.editMessage(
                  peer.hex,
                  'other-target',
                  'KEEP_NEW_EDIT',
                );
                next = WireEnvelope.edit(
                  'other-target',
                  'KEEP_NEW_EDIT',
                  seq: otherSeq,
                );
              }
              joining = service
                  .sendDurable(peer, _frame, next)
                  .then<Object?>(
                    (_) {
                      finished = true;
                      return null;
                    },
                    onError: (Object e, StackTrace _) {
                      finished = true;
                      return e;
                    },
                  );
              // An unrelated key must finish while the destructive job is held.
              await service.sendDurable(
                _id(3),
                'other-control',
                const WireEnvelope.del('other-control'),
              );
              expect(
                link.sent.any(
                  (e) => e.kind == WireKind.del && e.id == 'other-control',
                ),
                isTrue,
              );
            }
            await Future<void>(
              () {},
            ); // Drain ready futures, not a timing threshold.
            final completedBeforeCleanup = finished;
            storage.replaceRelease.complete();
            await cleaning;
            final result = await joining;
            expect(
              completedBeforeCleanup,
              isFalse,
              reason:
                  'the same key and teardown must join the actual cleanup outcome',
            );
            if (mode == 'shared-failure' || mode == 'shared-vacuum-failure') {
              expect(result, isA<StateError>());
              expect(
                (await storage.pendingOutboxFrames()).any(
                  (f) => f.frameId == _frame,
                ),
                mode == 'shared-failure',
              );
              if (mode == 'shared-vacuum-failure') {
                expect(
                  await storage.settingsKeys(),
                  contains('outbox.replacement_scrub_pending'),
                );
              }
              storage.failReplacement = false;
              storage.failFinish = false;
              await service.sendDurable(
                peer,
                _frame,
                envelope,
                awaitLive: false,
              );
              expect(
                (await storage.pendingOutboxFrames()).any(
                  (f) => f.frameId == _frame,
                ),
                isFalse,
              );
              expect(
                await storage.settingsKeys(),
                isNot(contains('outbox.replacement_scrub_pending')),
              );
            } else {
              expect(result, isNull);
            }
            if (mode == 'changed-payload') {
              final wires = (await storage.pendingOutboxFrames()).map(
                (f) => WireEnvelope.decode(f.wire),
              );
              expect(
                wires.where(
                  (e) => e.kind == WireKind.edit && e.body == 'KEEP_NEW_EDIT',
                ),
                hasLength(1),
              );
              expect(
                link.sent.where(
                  (e) => e.kind == WireKind.edit && e.body == 'KEEP_NEW_EDIT',
                ),
                hasLength(1),
              );
            }
          }
          expect(
            link.sent.where((e) => e.kind == WireKind.edit && e.body == _body),
            isEmpty,
          );
          final kept = (await storage.pendingOutboxFrames())
              .where(
                (f) => WireEnvelope.decode(f.wire).kind == WireKind.voidSeq,
              )
              .toList();
          expect(kept, hasLength(1));
          expect(kept.single.enqueuedAtMs, stamp);
          expect(WireEnvelope.decode(kept.single.wire).seq, seq);
          await service.dispose();
          await storage.close();
          if (native) {
            final raw = (await workerSpaceOpener(path!)(
              password: Uint8List.fromList(utf8.encode('fixture')),
              create: false,
            ))!;
            try {
              var voids = 0;
              for (final row in await raw.iterLogRange(
                namespace: Ns.outbox,
                limit: 8192,
              )) {
                final payload = jsonDecode(utf8.decode(row.payload));
                if (payload is! Map || payload['w'] is! String) continue;
                final frame = WireEnvelope.decode(
                  base64Decode(payload['w'] as String),
                );
                expect(frame.body, isNot(contains(_body)));
                if (frame.kind == WireKind.voidSeq && frame.seq == seq) voids++;
              }
              expect(
                voids,
                1,
                reason: 'positive control for stopped native roots',
              );
            } finally {
              await raw.close();
            }
          }
          expect(await storage.open(password: 'fixture'), isTrue);
          expect(await storage.isMessageDeleted(peer.hex, _target), isTrue);
          expect(
            (await storage.pendingOutboxFrames()).any(
              (f) => WireEnvelope.decode(f.wire).body == _body,
            ),
            isFalse,
          );
        },
        skip: native && (Platform.environment['XVEIL_HV_DYLIB'] ?? '').isEmpty,
      );
    }
  }
}
