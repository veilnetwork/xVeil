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
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';
import 'package:xveil/state/ratchet_persistence.dart';

NodeId _id(int value) => NodeId(Uint8List(32)..fillRange(0, 32, value));

class _Held extends HiddenVolumeStorage {
  _Held(super.open) : super.async();
  bool holdRead = false;
  bool holdMembership = false;
  final entered = Completer<void>(), release = Completer<void>();

  @override
  Future<bool> containsOutboxFrame(OutboxFrame frame) async {
    final found = await super.containsOutboxFrame(frame);
    if (holdMembership && frame.frameId.startsWith('accept:')) {
      holdMembership = false;
      entered.complete();
      await release.future;
    }
    return found;
  }

  @override
  Future<Contact?> getContact(NodeId peer) async {
    final contact = await super.getContact(peer);
    if (holdRead && peer == _id(2)) {
      holdRead = false;
      entered.complete();
      await release.future;
    }
    return contact;
  }
}

class _Wire extends LoopbackTransport {
  _Wire() : super(localNodeId: _id(1));
  final sent = <WireEnvelope>[];

  @override
  Future<void> send(
    NodeId peer,
    Uint8List wire, {
    bool anonymous = false,
  }) async => sent.add(WireEnvelope.decode(wire));
}

class _HeldRatchet extends Fake implements RatchetPersistence {
  _HeldRatchet(this.peer);

  final NodeId peer;
  final entered = Completer<void>(), release = Completer<void>();

  @override
  bool get degraded => false;

  @override
  Future<void> reserveBeforePublish(NodeId dst) async {
    if (dst != peer || entered.isCompleted) return;
    entered.complete();
    await release.future;
  }

  @override
  Future<int> flush({String why = 'unknown', bool now = false}) async => 0;

  @override
  Future<int> close() async => 0;

  @override
  Future<int> forgetPeer(NodeId peer) async => 0;
}

void main() {
  for (final native in [false, true]) {
    for (final decision in [
      'block',
      'unblock',
      'replacement request',
      'fresh receipt',
    ]) {
      test(
        'queued contact receipt follows current decision '
        'native=$native decision=$decision',
        () async {
          final peer = _id(2);
          final ratchet = _HeldRatchet(peer);
          final wire = _Wire();
          late final HiddenVolumeStorage storage;
          if (native) {
            expect(ensureHiddenVolumeLoaded(), isTrue);
            final dir = await Directory.systemTemp.createTemp(
              'xveil-accept-receipt-',
            );
            addTearDown(() => dir.delete(recursive: true));
            final path = '${dir.path}/store.hv';
            HvKvLogStore(
              hv.HvSpace.create(
                path: path,
                password: Uint8List.fromList(utf8.encode('fixture')),
                argon: hv.ArgonPreset.min,
              ),
            ).close();
            storage = HiddenVolumeStorage.async(workerSpaceOpener(path));
          } else {
            final kv = FakeKvLogStore();
            storage = HiddenVolumeStorage(
              ({required password, required create}) => kv,
            );
          }
          final service = MessagingService(wire, storage)..ratchet = ratchet;
          addTearDown(() async {
            if (!ratchet.release.isCompleted) ratchet.release.complete();
            await service.dispose();
            await wire.dispose();
            await storage.close();
          });
          expect(
            await storage.open(password: 'fixture', createIfMissing: true),
            isTrue,
          );
          await storage.upsertContact(
            Contact(nodeId: peer, status: ContactStatus.pendingOutgoing),
          );
          const fid = 'accept-receipt-waits';
          InboundMessage acceptance() => InboundMessage(
            src: peer,
            provenance: SenderProvenance.sessionPeer,
            payload: const WireEnvelope.accept().withFrameId(fid).encode(),
          );
          final pending = service.deliverInbound(acceptance());
          await ratchet.entered.future;
          expect(
            (await storage.getContact(peer))?.status,
            ContactStatus.accepted,
          );
          if (decision == 'replacement request') {
            await service.deleteConversation(peer);
            final request = await service.submitContactRequest(peer, '');
            expect(request.admitted, isTrue);
            expect(
              (await storage.getContact(peer))?.status,
              ContactStatus.pendingOutgoing,
            );
          } else {
            await service.blockContact(peer);
            if (decision != 'block') await service.unblockContact(peer);
          }
          if (decision == 'fresh receipt') {
            await service.deliverInbound(acceptance(), waitForReceipts: false);
          }
          Iterable<WireEnvelope> receipts() =>
              wire.sent.where((e) => e.kind == WireKind.ack && e.id == fid);
          expect(receipts(), isEmpty);
          ratchet.release.complete();
          await pending;
          await pumpEventQueue();
          expect(
            receipts(),
            hasLength(decision == 'fresh receipt' ? 1 : 0),
          );
        },
        skip: native && Platform.environment['XVEIL_HV_DYLIB'] == null,
      );
    }

    for (final stage in ['contact', 'membership', 'ratchet']) {
      for (final change in [
        'block',
        'ack',
        'foreign-ack',
        'other-peer',
        'none',
      ]) {
        test(
          'queued acceptance revalidates $change native=$native stage=$stage',
          () async {
            Directory? dir;
            late AsyncSpaceOpener open;
            if (native) {
              expect(ensureHiddenVolumeLoaded(), isTrue);
              dir = await Directory.systemTemp.createTemp(
                'xveil-accept-egress-',
              );
              final path = '${dir.path}/store.hv';
              HvKvLogStore(
                hv.HvSpace.create(
                  path: path,
                  password: Uint8List.fromList(utf8.encode('fixture')),
                  argon: hv.ArgonPreset.min,
                ),
              ).close();
              open = workerSpaceOpener(path);
            } else {
              final kv = FakeKvLogStore();
              open = ({required password, required bool create}) async =>
                  SyncWrappedAsyncKvLogStore(kv);
            }
            final storage = _Held(open), wire = _Wire(), peer = _id(2);
            final ratchet = stage == 'ratchet' ? _HeldRatchet(peer) : null;
            final service = MessagingService(wire, storage)
              ..ratchet = ratchet
              ..liveLegDeadline = const Duration(days: 1);
            final entered = ratchet?.entered ?? storage.entered;
            final release = ratchet?.release ?? storage.release;
            Future<void>? accepting;
            try {
              expect(
                await storage.open(password: 'fixture', createIfMissing: true),
                isTrue,
              );
              await storage.upsertContact(
                Contact(nodeId: peer, status: ContactStatus.pendingIncoming),
              );
              service.onContactStatusChanged = (who, status) {
                if (who == peer && status == ContactStatus.accepted) {
                  // Local publication precedes response-queue submission. Hold
                  // the worker's contact read, never the decision transaction.
                  if (stage == 'contact') {
                    storage.holdRead = true;
                  } else if (stage == 'membership') {
                    storage.holdMembership = true;
                  }
                }
              };
              accepting = service.acceptContact(peer);
              await entered.future;
              final accepted = (await storage.pendingOutboxFrames()).single;
              expect(accepted.frameId, startsWith('accept:${peer.hex}:'));
              expect(
                (await storage.getContact(peer))?.status,
                ContactStatus.accepted,
              );
              expect(wire.sent, isEmpty);
              if (change == 'block' || change == 'other-peer') {
                await service.blockContact(change == 'block' ? peer : _id(3));
              } else if (change == 'ack' || change == 'foreign-ack') {
                if (change == 'foreign-ack') {
                  await storage.upsertContact(
                    Contact(nodeId: _id(3), status: ContactStatus.accepted),
                  );
                }
                await service.deliverInbound(
                  InboundMessage(
                    src: change == 'ack' ? peer : _id(3),
                    payload: WireEnvelope.ack(accepted.frameId).encode(),
                    provenance: SenderProvenance.sessionPeer,
                  ),
                );
                expect(
                  await storage.containsOutboxFrame(accepted),
                  change != 'ack',
                );
              }
              release.complete();
              await accepting;
              expect(
                wire.sent.where((envelope) => envelope.kind == WireKind.accept),
                change == 'block' || change == 'ack' ? isEmpty : hasLength(1),
                reason:
                    'queue admission must use current consent and membership',
              );
              final expected = change == 'block'
                  ? ContactStatus.blocked
                  : ContactStatus.accepted;
              expect((await storage.getContact(peer))?.status, expected);
              expect(
                await storage.containsOutboxFrame(accepted),
                change != 'ack',
              );
              await service.dispose();
              await storage.close();
              expect(await storage.open(password: 'fixture'), isTrue);
              expect((await storage.getContact(peer))?.status, expected);
              expect(
                await storage.containsOutboxFrame(accepted),
                change != 'ack',
              );
            } finally {
              if (!release.isCompleted) release.complete();
              await accepting;
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
