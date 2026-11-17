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
import 'package:xveil/state/mailbox_service.dart';
import 'package:xveil/state/messaging.dart';

NodeId _id(int value) => NodeId(Uint8List(32)..fillRange(0, 32, value));

class _HeldStore extends HiddenVolumeStorage {
  _HeldStore(super.open) : super.async();
  bool holdContact = false;
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<Contact?> getContact(NodeId peer) async {
    final contact = await super.getContact(peer);
    if (holdContact && peer == _id(2)) {
      holdContact = false;
      entered.complete();
      await release.future;
    }
    return contact;
  }
}

class _Wire extends LoopbackTransport {
  _Wire() : super(localNodeId: _id(1));
  final sent = <WireEnvelope>[];
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<void> send(
    NodeId peer,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    final frame = WireEnvelope.decode(payload);
    sent.add(frame);
    if (frame.frameId == 'edit:first' && !entered.isCompleted) {
      entered.complete();
      await release.future;
    }
  }
}

class _Sink implements MailboxSink {
  final sent = <WireEnvelope>[];
  @override
  bool get isRegistered => true;
  @override
  bool backgroundDrainPaused = false;
  @override
  Future<void> stash({
    required NodeId recipient,
    required Uint8List payload,
    required Uint8List contentId,
  }) async => sent.add(WireEnvelope.decode(payload));
  @override
  void nudgeDrain() {}
  @override
  void noteActivity() {}
}

void main() {
  for (final native in [false, true]) {
    for (final stage in ['contact', 'worker']) {
      for (final change in [
        'block',
        'block-unblock',
        'ack',
        'other-peer',
        'none',
      ]) {
        test(
          'Outbox consent native=$native stage=$stage change=$change',
          () async {
            Directory? dir;
            late AsyncSpaceOpener open;
            if (native) {
              expect(ensureHiddenVolumeLoaded(), isTrue);
              dir = await Directory.systemTemp.createTemp(
                'xveil-outbox-consent-',
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
            final storage = _HeldStore(open), wire = _Wire(), sink = _Sink();
            final service = MessagingService(wire, storage)
              ..liveLegDeadline = const Duration(days: 1)
              ..attachMailbox(sink);
            Future<void>? flushing;
            final peer = _id(2), fid = 'accept:${_id(2).hex}';
            try {
              expect(
                await storage.open(password: 'fixture', createIfMissing: true),
                isTrue,
              );
              await storage.upsertContact(
                Contact(nodeId: peer, status: ContactStatus.accepted),
              );
              if (stage == 'worker') {
                await storage.enqueueOutboxFrame(
                  'edit:first',
                  peer.hex,
                  WireEnvelope.edit(
                    'message',
                    'first',
                    seq: 1,
                  ).withFrameId('edit:first').encode(),
                );
              }
              final wireBytes = const WireEnvelope.accept()
                  .withFrameId(fid)
                  .encode();
              await storage.enqueueOutboxFrame(fid, peer.hex, wireBytes);
              storage.holdContact = stage == 'contact';
              flushing = service.debugFlushOutboxFrames();
              await (stage == 'contact'
                  ? storage.entered.future
                  : wire.entered.future);
              if (change.startsWith('block')) {
                await service.blockContact(peer);
                if (change == 'block-unblock') {
                  await service.unblockContact(peer);
                }
              } else if (change == 'other-peer') {
                await service.blockContact(_id(3));
              } else if (change == 'ack') {
                await service.deliverInbound(
                  InboundMessage(
                    src: peer,
                    payload: WireEnvelope.ack(fid).encode(),
                    provenance: SenderProvenance.sessionPeer,
                  ),
                );
              }
              if (!storage.release.isCompleted) storage.release.complete();
              if (!wire.release.isCompleted) wire.release.complete();
              await flushing;
              final stale = change.startsWith('block') || change == 'ack';
              // The worker-stage deposit was already admitted before the block
              // or ACK. A later change cannot recall that earlier transport leg.
              final stashes = stage == 'worker'
                  ? 1
                  : stale
                  ? 0
                  : 1;
              expect(
                {
                  'live': wire.sent.where((f) => f.frameId == fid).length,
                  'mailbox': sink.sent.where((f) => f.frameId == fid).length,
                },
                {'live': stale ? 0 : 1, 'mailbox': stashes},
              );
              if (change == 'block-unblock') {
                await service.debugFlushOutboxFrames();
                expect(
                  wire.sent.where((f) => f.frameId == fid),
                  hasLength(1),
                  reason: 'cancelled candidates must not spend retry backoff',
                );
              }
              final expected = change == 'block'
                  ? ContactStatus.blocked
                  : ContactStatus.accepted;
              expect((await storage.getContact(peer))?.status, expected);
              expect(
                (await storage.pendingOutboxFrames()).any(
                  (f) => f.frameId == fid,
                ),
                change != 'ack',
              );
              await service.dispose();
              await storage.close();
              expect(await storage.open(password: 'fixture'), isTrue);
              expect((await storage.getContact(peer))?.status, expected);
              expect(
                (await storage.pendingOutboxFrames()).any(
                  (f) => f.frameId == fid,
                ),
                change != 'ack',
              );
            } finally {
              if (!storage.release.isCompleted) storage.release.complete();
              if (!wire.release.isCompleted) wire.release.complete();
              await flushing;
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
