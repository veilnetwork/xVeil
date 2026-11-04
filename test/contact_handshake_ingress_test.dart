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
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

NodeId _id(int n) => NodeId(Uint8List(32)..fillRange(0, 32, n));

class _HeldAcceptance extends LoopbackTransport {
  _HeldAcceptance() : super(localNodeId: _id(1));
  final entered = Completer<void>(), release = Completer<void>();
  final sent = <WireEnvelope>[];
  final inbound = StreamController<InboundMessage>.broadcast();
  void inject(InboundMessage message) => inbound.add(message);
  @override
  Stream<InboundMessage> messages() => inbound.stream;
  @override
  Future<void> dispose() async {
    await inbound.close();
    await super.dispose();
  }

  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    final envelope = WireEnvelope.decode(payload);
    sent.add(envelope);
    if (envelope.kind == WireKind.accept && !entered.isCompleted) {
      entered.complete();
      await release.future;
    }
  }
}

void main() {
  for (final native in [false, true]) {
    for (final reconnect in [false, true]) {
      test(
        'contact acceptance network wait releases ingress native=$native reconnect=$reconnect',
        () async {
          Directory? dir;
          late HiddenVolumeStorage storage;
          if (native) {
            expect(ensureHiddenVolumeLoaded(), isTrue);
            dir = await Directory.systemTemp.createTemp(
              'xveil-contact-ingress-',
            );
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
              ({required password, required bool create}) => kv,
            );
          }
          final transport = _HeldAcceptance();
          final peer = _id(2);
          final messaging = MessagingService(transport, storage)
            // The oracle is the unreleased gate, never a timeout winning a race.
            ..liveLegDeadline = const Duration(days: 1);
          try {
            expect(
              await storage.open(password: 'fixture', createIfMissing: true),
              isTrue,
            );
            await storage.upsertContact(
              Contact(nodeId: peer, status: ContactStatus.accepted),
            );
            messaging.start();
            var calls = 0;
            messaging.onCallSignal = (_, signal) {
              expect(signal.type, CallSignalType.offer);
              calls++;
            };
            final request = reconnect
                ? const WireEnvelope.reconnect('')
                : const WireEnvelope.request('', id: 'intro');
            final handling = messaging.deliverInbound(
              InboundMessage(
                src: peer,
                payload: request.withFrameId('intro-frame').encode(),
                provenance: SenderProvenance.sessionPeer,
              ),
            );
            var requestSettled = false;
            final settled = handling.then((_) => requestSettled = true);
            await transport.entered.future;
            transport.inject(
              InboundMessage(
                src: peer,
                payload: WireEnvelope.callSignal(
                  const CallSignal(
                    callId: 'test-call',
                    type: CallSignalType.offer,
                  ).encode(),
                ).encode(),
                provenance: SenderProvenance.sessionPeer,
              ),
            );
            // Await actual durable worker round trips, not a guessed sleep.
            for (var i = 0; i < 30; i++) {
              await storage.getContact(peer);
              await pumpEventQueue(times: 3);
            }
            expect(transport.release.isCompleted, isFalse);
            expect(
              calls,
              1,
              reason: 'ordinary call offer was held behind acceptance egress',
            );
            expect(
              requestSettled,
              isTrue,
              reason: 'ingress must wait for durable admission only',
            );
            // Fresh wire IDs must not create an unbounded detached send per
            // request while the same logical acceptance is already in flight.
            for (var i = 0; i < 8; i++) {
              await messaging.deliverInbound(
                InboundMessage(
                  src: peer,
                  payload: request.withFrameId('intro-frame/$i').encode(),
                  provenance: SenderProvenance.sessionPeer,
                ),
              );
            }
            expect(
              transport.sent.where((e) => e.kind == WireKind.accept),
              hasLength(1),
            );
            final queued = await storage.pendingOutboxFrames();
            final accept = queued
                .where(
                  (f) =>
                      f.peerHex == peer.hex &&
                      WireEnvelope.decode(f.wire).kind == WireKind.accept,
                )
                .single;
            expect(accept.frameId, 'accept:${peer.hex}');
            expect(
              (await storage.getContact(peer))?.status,
              ContactStatus.accepted,
            );
            var closed = false;
            final close = messaging.dispose().then((_) => closed = true);
            await pumpEventQueue();
            expect(
              closed,
              isFalse,
              reason: 'dispose must join the actual active response',
            );
            transport.release.complete();
            await settled;
            await close;
            expect(closed, isTrue);
            await storage.close();
            expect(await storage.open(password: 'fixture'), isTrue);
            expect(
              (await storage.pendingOutboxFrames()).any(
                (f) => f.frameId == accept.frameId,
              ),
              isTrue,
            );
          } finally {
            if (!transport.release.isCompleted) transport.release.complete();
            await messaging.dispose();
            await transport.dispose();
            await storage.close();
            await dir?.delete(recursive: true);
          }
        },
        skip: native && Platform.environment['XVEIL_HV_DYLIB'] == null,
      );
    }
  }
}
