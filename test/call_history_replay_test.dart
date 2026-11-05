import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/core/ids.dart';
import 'package:xveil/core/diagnostic_journal.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/call.dart';
import 'package:xveil/domain/call_log.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/call_log.dart';
import 'package:xveil/state/call_service.dart';
import 'package:xveil/state/group_service_providers.dart';
import 'package:xveil/state/messaging.dart';
import 'package:xveil/state/p2p_endpoint_service.dart';
import 'package:xveil/state/providers.dart';

import 'e2e/e2e_env.dart' show waitUntil;

NodeId _id(int n) => NodeId(Uint8List(32)..fillRange(0, 32, n));

class _LiveTransport extends LoopbackTransport {
  _LiveTransport() : super(localNodeId: _id(1));
  final frames = StreamController<InboundMessage>.broadcast();
  final acknowledgements = <String, Completer<void>>{};
  @override
  Stream<InboundMessage> messages() => frames.stream;
  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    final wire = WireEnvelope.decode(payload);
    if (wire.kind == WireKind.ack) {
      final ack = acknowledgements[wire.id];
      if (ack != null && !ack.isCompleted) ack.complete();
    }
  }

  @override
  Future<void> dispose() async {
    await frames.close();
    await super.dispose();
  }
}

void main() {
  for (final native in [false, true]) {
    for (final mode in ['local-ended', 'sibling-ended', 'other-peer']) {
      test(
        'cold call history refuses replay native=$native mode=$mode',
        () async {
          diagnosticJournal.clear();
          Directory? dir;
          late AsyncSpaceOpener open;
          const password = 'call-replay-fixture';
          if (native) {
            expect(
              ensureHiddenVolumeLoaded(
                dylibPath: Platform.environment['XVEIL_HV_DYLIB'],
              ),
              true,
            );
            dir = await Directory.systemTemp.createTemp('xveil-call-replay-');
            final path = '${dir.path}/store.hv';
            HvKvLogStore(
              hv.HvSpace.create(
                path: path,
                password: Uint8List.fromList(utf8.encode(password)),
                argon: hv.ArgonPreset.min,
              ),
            ).close();
            open = workerSpaceOpener(path);
          } else {
            final raw = FakeKvLogStore();
            open = ({required password, required bool create}) async =>
                SyncWrappedAsyncKvLogStore(raw);
          }
          var storage = HiddenVolumeStorage.async(open);
          addTearDown(() async {
            await storage.close();
            await dir?.delete(recursive: true);
          });
          expect(
            await storage.open(password: password, createIfMissing: true),
            true,
          );
          final peer = _id(2);
          await storage.upsertContact(
            Contact(nodeId: peer, status: ContactStatus.accepted),
          );
          final row = CallLogEntry(
            id: 'finished-before-restart',
            peerHex: mode == 'other-peer' ? _id(3).hex : peer.hex,
            outgoing: false,
            video: false,
            outcome: CallLogOutcome.missed,
            atMs: DateTime.now().millisecondsSinceEpoch,
          );
          final history = CallLogStore(storage);
          if (mode == 'sibling-ended') {
            expect(await history.addMirrored(row), true);
          } else {
            expect(await history.add(row), true);
          }
          await storage.close();
          storage = HiddenVolumeStorage.async(open);
          expect(await storage.open(password: password), true);

          final transport = _LiveTransport();
          final messaging = MessagingService(transport, storage)..start();
          final container = ProviderContainer(
            overrides: [
              storageProvider.overrideWithValue(storage),
              messagingServiceProvider.overrideWithValue(messaging),
              veilTransportProvider.overrideWithValue(transport),
              groupServiceProvider.overrideWithValue(null),
              p2pEndpointServiceProvider.overrideWithValue(null),
            ],
          );
          addTearDown(() async {
            container.dispose();
            await messaging.dispose();
            await transport.dispose();
          });
          final service = container.read(callServiceProvider);
          final ringing = <String>[];
          final sub = service.changes.listen((call) {
            if (call?.status == CallStatus.ringing) ringing.add(call!.callId);
          });
          addTearDown(sub.cancel);
          await waitUntil(
            () => messaging.onCallSignal != null,
            what: 'cold call consumer is attached',
          );
          Future<void> offer(String id) async {
            final ack = Completer<void>();
            transport.acknowledgements['offer:$id'] = ack;
            transport.frames.add(
              InboundMessage(
                src: peer,
                provenance: SenderProvenance.sessionPeer,
                payload: WireEnvelope.callSignal(
                  CallSignal(
                    callId: id,
                    type: CallSignalType.offer,
                    posture: CallPosture.anonymous,
                    sentAtMs: DateTime.now().millisecondsSinceEpoch,
                  ).encode(),
                ).withFrameId('offer:$id').encode(),
              ),
            );
            await ack.future.timeout(const Duration(seconds: 10));
          }

          await offer(row.id);
          await pumpEventQueue();
          expect(await storage.getContact(peer), isNotNull);
          if (mode == 'other-peer') {
            expect(
              service.current?.callId,
              row.id,
              reason: jsonEncode(diagnosticJournal.toJson()),
            );
            await service.reject();
          } else {
            expect(
              ringing,
              isEmpty,
              reason:
                  'a durable finished call must not ring after a cold start',
            );
            expect(service.current, isNull);
          }
          await offer('fresh-after-restart');
          await pumpEventQueue();
          expect(service.current?.callId, 'fresh-after-restart');
          expect(service.current?.status, CallStatus.ringing);
        },
        skip: native && (Platform.environment['XVEIL_HV_DYLIB'] ?? '').isEmpty
            ? 'set XVEIL_HV_DYLIB to the qualified native library'
            : false,
      );
    }
  }
}
