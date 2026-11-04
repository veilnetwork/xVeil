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
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/domain/call.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/call_service.dart';
import 'package:xveil/state/messaging.dart';

NodeId id(int n) => NodeId(Uint8List(32)..fillRange(0, 32, n));

class _Held extends HiddenVolumeStorage {
  _Held(super.open) : super.async();
  bool holdOutbox = false, holdRead = false;
  String? writeFault;
  int reads = 0;
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<List<OutboxFrame>> pendingOutboxFrames() async {
    final frames = await super.pendingOutboxFrames();
    if (holdOutbox) {
      holdOutbox = false;
      entered.complete();
      await release.future;
    }
    return frames;
  }

  @override
  Future<void> setContactStatus(NodeId peer, ContactStatus status) async {
    final mode = writeFault;
    if (mode != null && status == ContactStatus.blocked) {
      writeFault = null;
      entered.complete();
      await release.future;
      if (mode == 'before') throw StateError('injected write refusal');
      await super.setContactStatus(peer, status);
      throw StateError('injected write reply loss');
    }
    await super.setContactStatus(peer, status);
  }

  @override
  Future<Contact?> getContact(NodeId peer) async {
    reads++;
    final contact = await super.getContact(peer);
    if (holdRead && peer == id(2)) {
      holdRead = false;
      entered.complete();
      await release.future;
    }
    return contact;
  }
}

class _Wire extends LoopbackTransport implements RealtimeInboundTransport {
  _Wire() : super(localNodeId: id(1));
  final realtime = StreamController<InboundMessage>.broadcast();
  final sent = <WireEnvelope>[];
  @override
  Stream<InboundMessage> realtimeMessages() => realtime.stream;
  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    sent.add(WireEnvelope.decode(payload));
  }

  @override
  Future<void> dispose() async {
    await realtime.close();
    await super.dispose();
  }

  void offer(String call) => realtime.add(
    InboundMessage(
      src: id(2),
      payload: WireEnvelope.callSignal(
        CallSignal(callId: call, type: CallSignalType.offer).encode(),
      ).encode(),
      provenance: SenderProvenance.sessionPeer,
    ),
  );
  void barrier(String call) => realtime.add(
    InboundMessage(
      src: id(2),
      payload: WireEnvelope.callSignal(
        CallSignal(callId: call, type: CallSignalType.answer).encode(),
      ).encode(),
      provenance: SenderProvenance.sessionPeer,
    ),
  );
}

class _Fixture {
  _Fixture(this.storage, this.wire, this.service, this.dir);
  final _Held storage;
  final _Wire wire;
  final MessagingService service;
  final Directory? dir;
  Future<void> close() async {
    if (!storage.release.isCompleted) storage.release.complete();
    await service.dispose();
    await wire.dispose();
    await storage.close();
    await dir?.delete(recursive: true);
  }
}

Future<_Fixture> _fixture(bool native) async {
  Directory? dir;
  late AsyncSpaceOpener open;
  if (native) {
    expect(ensureHiddenVolumeLoaded(), true);
    dir = await Directory.systemTemp.createTemp('xveil-consent-race-');
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
  final storage = _Held(open), wire = _Wire();
  expect(await storage.open(password: 'fixture', createIfMissing: true), true);
  final result = _Fixture(storage, wire, MessagingService(wire, storage), dir);
  addTearDown(result.close);
  return result;
}

Future<void> _verifyOffer(_Fixture f, {required bool allowed}) async {
  final callService = CallService(f.service)..start();
  final dispatch = f.service.onCallSignal!;
  final received = <String>[];
  final done = Completer<void>();
  f.service.onCallSignal = (peer, signal) {
    received.add(signal.callId);
    dispatch(peer, signal);
    if (signal.callId == 'barrier') done.complete();
  };
  try {
    f.service.start();
    f.wire.offer('offer-after-race');
    f.wire.barrier('barrier');
    await done.future;
    expect(
      received.contains('offer-after-race'),
      allowed,
      reason: 'realtime consent must agree with the latest durable contact',
    );
    expect(
      callService.current?.status == CallStatus.ringing,
      allowed,
      reason: 'the actual call FSM must not ring a blocked contact',
    );
  } finally {
    callService.dispose();
  }
}

void main() {
  for (final native in [false, true]) {
    for (final mode in ['before', 'after']) {
      test(
        'a read during an uncertain block cannot survive its completion native=$native mode=$mode',
        () async {
          final f = await _fixture(native);
          final p = id(2);
          await f.storage.upsertContact(
            Contact(nodeId: p, status: ContactStatus.accepted),
          );
          f.storage.writeFault = mode;
          Object? failure;
          final block = f.service.blockContact(p).catchError((Object e) {
            failure = e;
          });
          await f.storage.entered.future;
          await _verifyOffer(f, allowed: true);
          f.storage.release.complete();
          await block;
          expect(failure, isA<StateError>());
          expect(
            (await f.storage.getContact(p))?.status,
            mode == 'before' ? ContactStatus.accepted : ContactStatus.blocked,
          );
          await _verifyOffer(f, allowed: mode == 'before');
        },
        skip: native && Platform.environment['XVEIL_HV_DYLIB'] == null,
      );
    }
    test(
      'outgoing endpoint cleanup revalidates consent after its wait native=$native',
      () async {
        final f = await _fixture(native);
        final p = id(2);
        await f.storage.upsertContact(
          Contact(nodeId: p, status: ContactStatus.accepted),
        );
        f.storage.holdOutbox = true;
        final send = f.service.sendP2PEndpoints(p, '{}', sentAtMs: 3);
        await f.storage.entered.future;
        await f.service.blockContact(p);
        f.storage.release.complete();
        await send;
        expect(
          f.wire.sent.where((e) => e.kind == WireKind.p2pEndpoints),
          isEmpty,
        );
        await _verifyOffer(f, allowed: false);
      },
      skip: native && Platform.environment['XVEIL_HV_DYLIB'] == null,
    );
    test(
      'an unrelated block does not invalidate an accepted read native=$native',
      () async {
        final f = await _fixture(native);
        final p = id(2);
        await f.storage.upsertContact(
          Contact(nodeId: p, status: ContactStatus.accepted),
        );
        f.storage.holdRead = true;
        f.service.start();
        final got = Completer<void>();
        f.service.onCallSignal = (_, s) {
          if (s.callId == 'held-offer') got.complete();
        };
        f.wire.offer('held-offer');
        await f.storage.entered.future;
        await f.service.blockContact(id(3));
        f.storage.release.complete();
        await got.future;
      },
      skip: native && Platform.environment['XVEIL_HV_DYLIB'] == null,
    );
    for (final mode in ['incoming', 'outgoing', 'mirror']) {
      test(
        'closing the owner prevents late contact authorization native=$native mode=$mode',
        () async {
          final f = await _fixture(native);
          final p = id(2);
          await f.storage.upsertContact(
            Contact(
              nodeId: p,
              status: mode == 'mirror'
                  ? ContactStatus.pendingIncoming
                  : ContactStatus.accepted,
            ),
          );
          f.storage.holdRead = true;
          var received = 0;
          f.service.onCallSignal = (_, _) => received++;
          Future<dynamic>? work;
          if (mode == 'incoming') {
            f.service.start();
            f.wire.offer('held-offer');
          } else if (mode == 'mirror') {
            work = f.service.applyMirroredContactStatus(
              p,
              ContactStatus.accepted,
              atMs: DateTime.now().millisecondsSinceEpoch,
            );
          } else {
            work = f.service.sendCallSignal(
              p,
              const CallSignal(
                callId: 'held-offer',
                type: CallSignalType.offer,
              ),
            );
          }
          await f.storage.entered.future;
          final closing = f.service.dispose();
          await pumpEventQueue();
          f.storage.release.complete();
          await work;
          await closing;
          expect(received, 0);
          expect(
            f.wire.sent.where((e) => e.kind == WireKind.callSignal),
            isEmpty,
          );
          if (mode == 'mirror') {
            expect(
              (await f.storage.getContact(p))?.status,
              ContactStatus.pendingIncoming,
            );
          }
        },
        skip: native && Platform.environment['XVEIL_HV_DYLIB'] == null,
      );
    }
    test(
      'closed contact APIs do not read or mutate the active store native=$native',
      () async {
        final f = await _fixture(native);
        final p = id(2);
        await f.storage.upsertContact(
          Contact(nodeId: p, status: ContactStatus.pendingIncoming),
        );
        await f.service.dispose();
        final reads = f.storage.reads;
        await expectLater(f.service.blockContact(p), throwsStateError);
        await expectLater(f.service.acceptContact(p), throwsStateError);
        expect(
          await f.service.applyMirroredContactStatus(p, ContactStatus.accepted),
          false,
        );
        await f.service.sendCallSignal(
          p,
          const CallSignal(callId: 'closed-offer', type: CallSignalType.offer),
        );
        await f.service.sendP2PEndpoints(p, '{}', sentAtMs: 1);
        expect(f.storage.reads, reads);
        expect(f.wire.sent, isEmpty);
        expect(
          (await f.storage.getContact(p))?.status,
          ContactStatus.pendingIncoming,
        );
      },
      skip: native && Platform.environment['XVEIL_HV_DYLIB'] == null,
    );
    for (final mode in ['primary', 'mirror', 'unblock', 'other-peer']) {
      test(
        'late acceptance cannot undo a completed block native=$native mode=$mode',
        () async {
          final f = await _fixture(native);
          final s = f.storage, p = id(2);
          await s.upsertContact(
            Contact(
              nodeId: p,
              status: mode == 'unblock'
                  ? ContactStatus.blocked
                  : ContactStatus.pendingIncoming,
            ),
          );
          s.holdOutbox = true;
          final accepting = switch (mode) {
            'mirror' => f.service.applyMirroredContactStatus(
              p,
              ContactStatus.accepted,
              atMs: DateTime.now().millisecondsSinceEpoch,
            ),
            'unblock' => f.service.unblockContact(p),
            _ => f.service.acceptContact(p),
          };
          await s.entered.future;
          await f.service.blockContact(mode == 'other-peer' ? id(3) : p);
          expect(
            (await s.getContact(p))?.status,
            mode == 'other-peer'
                ? ContactStatus.accepted
                : ContactStatus.blocked,
          );
          s.release.complete();
          await accepting;
          await _verifyOffer(f, allowed: mode == 'other-peer');
        },
        skip: native && Platform.environment['XVEIL_HV_DYLIB'] == null,
      );
    }
    for (final mode in [
      'incoming-offer',
      'incoming-endpoints',
      'ordinary-endpoints',
      'outgoing-offer',
      'outgoing-endpoints',
    ]) {
      test(
        'a stale accepted read cannot authorize control native=$native mode=$mode',
        () async {
          final f = await _fixture(native);
          final s = f.storage, p = id(2);
          await s.upsertContact(
            Contact(nodeId: p, status: ContactStatus.accepted),
          );
          s.holdRead = true;
          final seen = <String>[];
          final done = Completer<void>();
          f.service.onCallSignal = (_, signal) {
            seen.add(signal.callId);
            if (signal.callId == 'barrier') done.complete();
          };
          var endpointCount = 0;
          f.service.onP2PEndpoints = (_, _) => endpointCount++;
          Future<void>? sending;
          if (mode.startsWith('incoming')) {
            f.service.start();
            if (mode == 'incoming-offer') {
              f.wire.offer('held-offer');
            } else {
              f.wire.realtime.add(
                InboundMessage(
                  src: p,
                  payload: WireEnvelope.p2pEndpoints('{}').encode(),
                  provenance: SenderProvenance.sessionPeer,
                ),
              );
            }
          } else if (mode == 'ordinary-endpoints') {
            sending = f.service.deliverInbound(
              InboundMessage(
                src: p,
                payload: const WireEnvelope.p2pEndpoints('{}').encode(),
                provenance: SenderProvenance.sessionPeer,
              ),
            );
          } else if (mode == 'outgoing-offer') {
            sending = f.service.sendCallSignal(
              p,
              const CallSignal(
                callId: 'held-offer',
                type: CallSignalType.offer,
              ),
            );
          } else {
            sending = f.service.sendP2PEndpoints(p, '{}', sentAtMs: 1);
          }
          await s.entered.future;
          await f.service.blockContact(p);
          s.release.complete();
          await sending;
          f.service.start();
          f.wire.barrier('barrier');
          await done.future;
          expect(seen.contains('held-offer'), false);
          expect(endpointCount, 0);
          expect(
            f.wire.sent.where(
              (e) =>
                  e.kind == WireKind.callSignal ||
                  e.kind == WireKind.p2pEndpoints,
            ),
            isEmpty,
          );
          await _verifyOffer(f, allowed: false);
        },
        skip: native && Platform.environment['XVEIL_HV_DYLIB'] == null,
      );
    }
  }
}
