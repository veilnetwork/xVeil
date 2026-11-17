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

void main() {
  for (final native in [false, true]) {
    for (final stage in ['contact', 'membership']) {
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
            final service = MessagingService(wire, storage)
              ..liveLegDeadline = const Duration(days: 1);
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
                  } else {
                    storage.holdMembership = true;
                  }
                }
              };
              accepting = service.acceptContact(peer);
              await storage.entered.future;
              final accepted = (await storage.pendingOutboxFrames()).single;
              expect(accepted.frameId, 'accept:${peer.hex}');
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
              storage.release.complete();
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
              if (!storage.release.isCompleted) storage.release.complete();
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
