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

class _IdentityGateWire extends LoopbackTransport {
  _IdentityGateWire() : super(localNodeId: _id(1));
  final identityEntered = Completer<void>();
  final identityRelease = Completer<void>();
  final sent = <WireEnvelope>[];

  @override
  Future<NodeId> nodeId() async {
    if (!identityEntered.isCompleted) {
      identityEntered.complete();
      await identityRelease.future;
    }
    return _id(1);
  }

  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    sent.add(WireEnvelope.decode(payload));
  }
}

Future<(HiddenVolumeStorage, Directory?)> _storage(bool native) async {
  if (native) {
    expect(ensureHiddenVolumeLoaded(), isTrue);
    final dir = await Directory.systemTemp.createTemp(
      'xveil-incoming-decision-',
    );
    final path = '${dir.path}/store.hv';
    HvKvLogStore(
      hv.HvSpace.create(
        path: path,
        password: Uint8List.fromList(utf8.encode('fixture')),
        argon: hv.ArgonPreset.min,
      ),
    ).close();
    return (HiddenVolumeStorage.async(workerSpaceOpener(path)), dir);
  }
  final kv = FakeKvLogStore();
  return (
    HiddenVolumeStorage(({required password, required bool create}) => kv),
    null,
  );
}

void main() {
  for (final native in [false, true]) {
    for (final reconnect in [false, true]) {
      for (final accepted in [false, true]) {
        test(
          'closing during incoming identity check retains carrier copy native=$native reconnect=$reconnect accepted=$accepted',
          () async {
            final (storage, dir) = await _storage(native);
            final wire = _IdentityGateWire(), peer = _id(2);
            final service = MessagingService(wire, storage);
            Future<void>? handling, closing;
            try {
              expect(
                await storage.open(password: 'fixture', createIfMissing: true),
                isTrue,
              );
              final status = accepted
                  ? ContactStatus.accepted
                  : ContactStatus.pendingIncoming;
              await storage.upsertContact(
                Contact(nodeId: peer, status: status),
              );
              var declined = 0;
              final request = reconnect
                  ? const WireEnvelope.reconnect('draining-intro')
                  : const WireEnvelope.request(
                      'draining-intro',
                      id: 'draining-intro',
                    );
              handling = service.deliverInbound(
                InboundMessage(
                  src: peer,
                  provenance: SenderProvenance.sessionPeer,
                  payload: request.withFrameId('draining-request').encode(),
                  onDeclined: (_) => declined++,
                ),
              );
              await wire.identityEntered.future;
              closing = service.dispose();
              wire.identityRelease.complete();
              await handling;
              await closing;
              expect(
                declined,
                1,
                reason: 'unprocessed mail must remain available to the carrier',
              );
              expect(wire.sent, isEmpty);
              expect((await storage.getContact(peer))?.status, status);
              expect(await storage.loadMessages(peer.hex), isEmpty);
              expect(await storage.pendingOutboxFrames(), isEmpty);
            } finally {
              if (!wire.identityRelease.isCompleted) {
                wire.identityRelease.complete();
              }
              await handling;
              await closing;
              await service.dispose();
              await wire.dispose();
              await storage.close();
              await dir?.delete(recursive: true);
            }
          },
          skip: native && Platform.environment['XVEIL_HV_DYLIB'] == null,
        );
      }
      for (final initial in <ContactStatus?>[
        null,
        ContactStatus.pendingOutgoing,
        ContactStatus.pendingIncoming,
        ContactStatus.accepted,
      ]) {
        for (final decision in [
          ContactStatus.accepted,
          ContactStatus.blocked,
        ]) {
          test(
            'delayed incoming request preserves $decision native=$native reconnect=$reconnect initial=$initial',
            () async {
              final (storage, dir) = await _storage(native);
              final wire = _IdentityGateWire(), peer = _id(2);
              final service = MessagingService(wire, storage);
              Future<void>? handling;
              try {
                expect(
                  await storage.open(
                    password: 'fixture',
                    createIfMissing: true,
                  ),
                  isTrue,
                );
                if (initial != null) {
                  await storage.upsertContact(
                    Contact(nodeId: peer, status: initial),
                  );
                }
                final request = reconnect
                    ? const WireEnvelope.reconnect('stale-intro')
                    : const WireEnvelope.request(
                        'stale-intro',
                        id: 'stale-intro',
                      );
                handling = service.deliverInbound(
                  InboundMessage(
                    src: peer,
                    provenance: SenderProvenance.sessionPeer,
                    payload: request.withFrameId('stale-request').encode(),
                  ),
                );
                // Dispatch has read the initial contact and is suspended in its
                // asynchronous self-address check. Complete the user's decision.
                await wire.identityEntered.future;
                if (decision == ContactStatus.accepted) {
                  await service.acceptContact(peer);
                } else {
                  await service.blockContact(peer);
                }
                expect((await storage.getContact(peer))?.status, decision);
                wire.sent.clear();
                final statuses = <ContactStatus>[];
                service.onContactStatusChanged = (_, status) =>
                    statuses.add(status);
                wire.identityRelease.complete();
                await handling;
                expect((await storage.getContact(peer))?.status, decision);
                expect(
                  statuses,
                  isNot(contains(ContactStatus.pendingIncoming)),
                );
                expect(
                  await storage.loadMessages(peer.hex),
                  isEmpty,
                  reason:
                      'a stale intro must not enter accepted or blocked history',
                );
                if (decision == ContactStatus.blocked) {
                  expect(
                    wire.sent.where((e) => e.kind == WireKind.accept),
                    isEmpty,
                  );
                  expect(await storage.pendingOutboxFrames(), isEmpty);
                }
                await service.deliverInbound(
                  InboundMessage(
                    src: peer,
                    provenance: SenderProvenance.sessionPeer,
                    payload: WireEnvelope.message(
                      'message after race',
                      id: 'post-race',
                    ).encode(),
                  ),
                );
                final accepted = decision == ContactStatus.accepted;
                expect(
                  (await storage.loadMessages(
                    peer.hex,
                  )).where((m) => m.id == 'post-race'),
                  hasLength(accepted ? 1 : 0),
                );
                expect(
                  await service.sendText(peer, 'reply after race'),
                  accepted,
                );
                if (!accepted) {
                  expect(await service.heldWhileBlocked(peer), 1);
                }
                await service.dispose();
                await storage.close();
                expect(await storage.open(password: 'fixture'), isTrue);
                expect((await storage.getContact(peer))?.status, decision);
              } finally {
                if (!wire.identityRelease.isCompleted) {
                  wire.identityRelease.complete();
                }
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
}
