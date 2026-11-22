import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

NodeId _id(int n) => NodeId(Uint8List(32)..fillRange(0, 32, n));

class _HeldIntro extends HiddenVolumeStorage {
  _HeldIntro(super.open) : super.async();
  String? stage;
  final entered = Completer<void>(), release = Completer<void>();
  Future<void> pause(String at) async {
    if (stage != at) return;
    stage = null;
    entered.complete();
    await release.future;
  }

  @override
  Future<ContactStatus> prepareContactRequest(
    NodeId peer, {
    bool incoming = false,
    String? requestId,
  }) async {
    final status = await super.prepareContactRequest(
      peer,
      incoming: incoming,
      requestId: requestId,
    );
    if (incoming) await pause('prepare');
    return status;
  }

  @override
  Future<List<Message>> loadMessages(
    String conversationId, {
    int? limit,
  }) async {
    final messages = await super.loadMessages(conversationId, limit: limit);
    await pause('cap');
    return messages;
  }

  @override
  Future<Message?> loadMessageById(
    String conversationId,
    String messageId,
  ) async {
    final message = await super.loadMessageById(conversationId, messageId);
    if (messageId == 'new-intro') await pause('append');
    return message;
  }
}

class _Wire extends LoopbackTransport {
  _Wire() : super(localNodeId: _id(1));
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
    for (final stage in ['prepare', 'cap', 'append']) {
      for (final decision in [
        'accepted',
        'blocked',
        'pending',
        'durable-accepted',
        'durable-blocked',
        'close',
      ]) {
        test(
          'late intro at $stage preserves $decision native=$native',
          () async {
            Directory? dir;
            late AsyncSpaceOpener opener;
            if (native) {
              expect(ensureHiddenVolumeLoaded(), isTrue);
              dir = await Directory.systemTemp.createTemp(
                'xveil-intro-admission-',
              );
              final path = '${dir.path}/store.hv';
              HvKvLogStore(
                hv.HvSpace.create(
                  path: path,
                  password: Uint8List.fromList(utf8.encode('fixture')),
                  argon: hv.ArgonPreset.min,
                ),
              ).close();
              opener = workerSpaceOpener(path);
            } else {
              final kv = FakeKvLogStore();
              opener = ({required password, required bool create}) async =>
                  SyncWrappedAsyncKvLogStore(kv);
            }
            final storage = _HeldIntro(opener), peer = _id(2), wire = _Wire();
            final service = MessagingService(wire, storage);
            final published = <String>[];
            final statuses = <ContactStatus>[];
            service.onMessageStored = (_, message) => published.add(message.id);
            service.onContactStatusChanged = (_, status) =>
                statuses.add(status);
            Future<void>? handling, closing;
            try {
              expect(
                await storage.open(password: 'fixture', createIfMissing: true),
                isTrue,
              );
              await storage.upsertContact(
                Contact(
                  nodeId: peer,
                  status: stage == 'prepare'
                      ? ContactStatus.pendingOutgoing
                      : ContactStatus.pendingIncoming,
                ),
              );
              final count = stage == 'cap' ? kMaxPreConsentIntros : 2;
              for (var i = 0; i < count; i++) {
                await storage.appendMessage(
                  Message(
                    id: 'intro-$i',
                    conversationId: peer.hex,
                    direction: MessageDirection.incoming,
                    body: 'Earlier introduction $i',
                    timestamp: DateTime(2026, 11, 17).add(Duration(seconds: i)),
                    status: MessageStatus.delivered,
                    author: peer.hex,
                  ),
                );
              }
              var declined = 0;
              storage.stage = stage;
              handling = service.deliverInbound(
                InboundMessage(
                  src: peer,
                  provenance: SenderProvenance.claimed,
                  payload: const WireEnvelope.request(
                    'New introduction',
                    id: 'new-intro',
                  ).withFrameId('new-intro-frame').encode(),
                  onDeclined: (_) => declined++,
                ),
              );
              await storage.entered.future;
              if (decision == 'accepted') await service.acceptContact(peer);
              if (decision == 'blocked') await service.blockContact(peer);
              if (decision.startsWith('durable-')) {
                await storage.setContactStatus(
                  peer,
                  decision.endsWith('accepted')
                      ? ContactStatus.accepted
                      : ContactStatus.blocked,
                );
              }
              if (decision == 'close') closing = service.dispose();
              statuses.clear();
              storage.release.complete();
              await handling;
              await closing;
              if (decision != 'pending') {
                expect(
                  statuses,
                  isNot(contains(ContactStatus.pendingIncoming)),
                  reason: 'late intro cannot republish a pending decision',
                );
                expect(
                  statuses,
                  isNot(contains(ContactStatus.pendingOutgoing)),
                );
              }
              final messages = await storage.loadMessages(peer.hex);
              final ids = messages.map((m) => m.id).toSet();
              final kept = <String>{for (var i = 0; i < count; i++) 'intro-$i'};
              if (decision == 'pending') {
                if (stage == 'cap') kept.remove('intro-0');
                kept.add('new-intro');
              }
              expect(
                ids,
                kept,
                reason:
                    'pending intro work cannot modify a decided conversation',
              );
              expect(
                published,
                decision == 'pending' ? ['new-intro'] : isEmpty,
              );
              expect(
                declined,
                decision.endsWith('blocked') || decision == 'close' ? 1 : 0,
              );
              if (decision.endsWith('accepted')) {
                expect(
                  (await storage.pendingOutboxFrames()).any(
                    (frame) =>
                        frame.peerHex == peer.hex &&
                        WireEnvelope.decode(frame.wire).kind == WireKind.accept,
                  ),
                  isTrue,
                );
              }
              final expected = decision.endsWith('accepted')
                  ? ContactStatus.accepted
                  : decision.endsWith('blocked')
                  ? ContactStatus.blocked
                  : ContactStatus.pendingIncoming;
              expect((await storage.getContact(peer))?.status, expected);
              await service.dispose();
              await storage.close();
              expect(await storage.open(password: 'fixture'), isTrue);
              expect(
                (await storage.loadMessages(peer.hex)).map((m) => m.id).toSet(),
                kept,
              );
            } finally {
              if (!storage.release.isCompleted) storage.release.complete();
              await handling;
              await service.dispose();
              await wire.dispose();
              await storage.close();
              await dir?.delete(recursive: true);
            }
          },
          skip: native && Platform.environment['XVEIL_HV_DYLIB'] == null,
        );
      }
    }
  }
}
