@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/core/error_journal.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/storage.dart' show MessageDeletionIntent;
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/event.dart';
import 'package:xveil/domain/inline_custom_emoji.dart';
import 'package:xveil/state/messaging.dart';

import 'support/fake_hv_container.dart';

NodeId _id(int n) => NodeId(Uint8List(32)..fillRange(0, 32, n));

class _EditStore extends HiddenVolumeStorage {
  _EditStore(super.opener);
  _EditStore.async(super.opener) : super.async();
  final entered = Completer<void>(), release = Completer<void>();
  bool armed = true, failDelete = false;
  int edits = 0;
  @override
  Future<int?> editMessage(
    String conversation,
    String id,
    String body, {
    int? seq,
    List<InlineCustomEmoji> customEmoji = const [],
    bool reflected = false,
  }) async {
    final applied = await super.editMessage(
      conversation,
      id,
      body,
      seq: seq,
      customEmoji: customEmoji,
      reflected: reflected,
    );
    edits++;
    if (armed) {
      armed = false;
      entered.complete();
      await release.future;
    }
    return applied;
  }

  @override
  Future<void> deleteMessage(
    String conversation,
    String id, {
    MessageDeletionIntent? intent,
  }) {
    if (failDelete) throw StateError('PRIVATE_EDIT_ERASURE_PATH');
    return super.deleteMessage(conversation, id, intent: intent);
  }
}

class _Link extends LoopbackTransport {
  _Link() : super(localNodeId: _id(1));
  final sent = <WireEnvelope>[];
  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    sent.add(WireEnvelope.decode(payload));
  }
}

void main() {
  for (final native in [false, true]) {
    for (final shape in [
      'outgoing-already',
      'outgoing',
      'incoming',
      'incoming-retry',
      'mirrored',
      'reflected',
      'outgoing-deleted',
      'incoming-deleted',
      'mirrored-deleted',
    ]) {
      test(
        'edit TTL completion $shape (native=$native)',
        () async {
          errorJournal.clear();
          final peer = _id(2), self = _id(1);
          late _EditStore storage;
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
              'xveil-edit-expiry-',
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
            storage = _EditStore.async(workerSpaceOpener(path));
          } else {
            storage = _EditStore(FakeHvContainer().passwordOpener);
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
          final editsPublished = <String>[], deletesPublished = <String>[];
          service.onMessageEdited = (_, _, body, _) => editsPublished.add(body);
          service.onMessageDeleted = (_, id) => deletesPublished.add(id);
          addTearDown(() async {
            if (!storage.release.isCompleted) storage.release.complete();
            await service.dispose();
            await link.dispose();
            await storage.close();
          });
          await storage.upsertContact(
            Contact(
              nodeId: peer,
              status: ContactStatus.accepted,
              disappearingTtlSeconds: shape.endsWith('-deleted') ? null : 30,
            ),
          );
          final incoming = shape.startsWith('incoming');
          final mirrored = shape.startsWith('mirrored') || shape == 'reflected';
          const target = 'edit-target', body = 'PRIVATE_EDIT_DURING_IO';
          await storage.appendMessage(
            Message(
              id: target,
              conversationId: peer.hex,
              direction: incoming
                  ? MessageDirection.incoming
                  : MessageDirection.outgoing,
              body: 'ORIGINAL_EDIT_TARGET',
              status: MessageStatus.delivered,
              timestamp: shape == 'outgoing-already'
                  ? now.subtract(const Duration(seconds: 30))
                  : now,
              author: incoming ? peer.hex : self.hex,
              // Incoming wire numbering is remote. A local post must advance
              // the actual allocation cursor before testing its later edit.
              seq: incoming ? 1 : null,
            ),
          );
          final envelope = const WireEnvelope.edit(
            target,
            body,
            seq: 2,
          ).withFrameId('edit-io');
          Future<void> receive() => service.deliverInbound(
            InboundMessage(
              src: peer,
              provenance: SenderProvenance.sessionPeer,
              payload: envelope.encode(),
            ),
          );
          Future<void>? reflected;
          if (shape == 'reflected') {
            service.myOtherDevices = () async => [_id(3)];
            await service.flushOutbox();
            await pumpEventQueue();
            expect(
              link.sent.where(
                (e) =>
                    e.kind == WireKind.sync &&
                    (jsonDecode(e.body) as Map)['ow'] is List,
              ),
              isNotEmpty,
              reason:
                  'a reflected edit requires a real outstanding own-echo ask',
            );
            reflected = service.deliverInbound(
              InboundMessage(
                src: peer,
                provenance: SenderProvenance.sessionPeer,
                payload: WireEnvelope.sync(
                  jsonEncode({
                    'echo': {
                      'id': target,
                      'b': body,
                      'e': 2,
                      'ts': now.millisecondsSinceEpoch,
                    },
                  }),
                ).encode(),
              ),
            );
          }
          final acting =
              reflected ??
              (incoming
                  ? receive()
                  : mirrored
                  ? service.applyMirroredEdit(
                      peer: peer,
                      msgId: target,
                      body: body,
                      seq: 2,
                    )
                  : service.editOwnMessage(target, body));
          if (shape != 'outgoing-already') {
            try {
              await storage.entered.future.timeout(const Duration(seconds: 10));
              expect(
                (await storage.loadMessageById(peer.hex, target))!.body,
                body,
                reason:
                    'positive control: edit committed before its Future completed',
              );
              if (shape.endsWith('-deleted')) {
                await storage.deleteMessage(peer.hex, target);
              } else {
                now = now.add(const Duration(seconds: 30));
              }
              storage.failDelete = shape == 'incoming-retry';
            } finally {
              storage.release.complete();
            }
          } else {
            // A correct preflight must not call edit at all. Releasing the gate
            // avoids turning an old-code failure into a timeout.
            storage.armed = false;
            storage.release.complete();
          }
          await acting;
          bool acked() =>
              link.sent.any((e) => e.kind == WireKind.ack && e.id == 'edit-io');
          if (shape == 'incoming-retry') {
            expect(acked(), isFalse);
            expect(editsPublished, isEmpty);
            expect(
              errorJournal.entries.any((e) => e.kind == 'inbound-expiry'),
              isTrue,
            );
            final report = errorJournal.toJson(
              platform: 'test',
              osVersion: 'unknown',
              appVersion: 'test',
              phase: 'chat',
              includeTimestamps: false,
            );
            for (final private in [
              'PRIVATE_EDIT_ERASURE_PATH',
              body,
              peer.hex,
            ]) {
              expect(report, isNot(contains(private)));
            }
            storage.failDelete = false;
            await receive();
          }
          expect(
            editsPublished,
            isEmpty,
            reason: 'expired edit must not enter required sibling publication',
          );
          expect(await storage.loadMessageById(peer.hex, target), isNull);
          expect(await storage.isMessageDeleted(peer.hex, target), isTrue);
          expect(deletesPublished, mirrored ? isEmpty : [target]);
          expect(storage.edits, shape == 'outgoing-already' ? 0 : 1);
          expect(
            link.sent.where((e) => e.kind == WireKind.edit && e.id == target),
            isEmpty,
          );
          expect(
            (await storage.pendingOutboxFrames())
                .map((f) => WireEnvelope.decode(f.wire))
                .where((e) => e.kind == WireKind.edit && e.id == target),
            isEmpty,
          );
          if (incoming) {
            expect(acked(), isTrue);
            final slots = await storage.loadEventsSince(peer.hex, peer.hex, 0);
            final editSlot = slots.singleWhere((e) => e.seq == 2);
            expect(editSlot.kind, EventKind.void_);
            expect(editSlot.body, isNull);
          }
          if (shape == 'outgoing') {
            final slots = await storage.loadEventsSince(peer.hex, self.hex, 0);
            final editSlot = slots.singleWhere((e) => e.seq == 2);
            expect(editSlot.kind, EventKind.void_);
            expect(editSlot.body, isNull);
          } else if (shape == 'reflected') {
            expect(
              (await storage.loadEventsSince(
                peer.hex,
                self.hex,
                0,
              )).where((e) => e.seq == 2),
              isEmpty,
              reason: 'a reflected edit must never acquire an authored slot',
            );
          }
          storage.armed = false;
          await storage.appendMessage(
            Message(
              id: 'fresh-control',
              conversationId: peer.hex,
              direction: MessageDirection.outgoing,
              body: 'FRESH_EDIT_CONTROL',
              timestamp: now,
              author: self.hex,
            ),
          );
          await service.editOwnMessage(
            'fresh-control',
            'FRESH_EDIT_CONTROL_CHANGED',
          );
          expect(editsPublished, ['FRESH_EDIT_CONTROL_CHANGED']);
          expect(
            (await storage.loadMessageById(peer.hex, 'fresh-control'))!.body,
            'FRESH_EDIT_CONTROL_CHANGED',
          );
          await service.dispose();
          await storage.close();
          if (native) {
            final raw = (await workerSpaceOpener(path!)(
              password: password,
              create: false,
            ))!;
            try {
              var fresh = 0;
              for (
                var ns = Ns.messageLogShardFirst;
                ns <= Ns.messageLogShardLast;
                ns++
              ) {
                for (final row in await raw.iterLogRange(
                  namespace: ns,
                  limit: 8192,
                )) {
                  final text = utf8.decode(row.payload, allowMalformed: true);
                  expect(text, isNot(contains(body)));
                  if (text.contains('FRESH_EDIT_CONTROL_CHANGED')) fresh++;
                }
              }
              expect(fresh, 1);
            } finally {
              await raw.close();
            }
          }
          expect(await storage.open(password: 'fixture'), isTrue);
          expect(await storage.isMessageDeleted(peer.hex, target), isTrue);
          expect(
            (await storage.loadMessages(peer.hex)).single.body,
            'FRESH_EDIT_CONTROL_CHANGED',
          );
        },
        skip: native && (Platform.environment['XVEIL_HV_DYLIB'] ?? '').isEmpty,
      );
    }
  }
}
