import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/diagnostic_journal.dart';
import 'package:xveil/core/error_journal.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/translation_model_store.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/group_call.dart';
import 'package:xveil/state/messaging.dart';
import 'package:xveil/state/model_exchange_service.dart';

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

class _RealtimeProbe
    implements
        VeilTransport,
        RealtimeTransport,
        DeviceRealtimeTransport,
        RelayRealtimeTransport,
        RealtimeInboundTransport {
  _RealtimeProbe(this.me);

  final NodeId me;
  final inbound = StreamController<InboundMessage>.broadcast();
  final realtimeInbound = StreamController<InboundMessage>.broadcast();
  final realtimeGate = Completer<void>();
  bool blockRealtime = false;
  final ackEntered = Completer<void>();
  final releaseAck = Completer<void>();
  bool blockAck = false;
  int normalSends = 0;
  int realtimeSends = 0;
  int relayRealtimeSends = 0;
  bool? lastRealtimeAnonymous;
  bool? lastNormalAnonymous;
  bool failSends = false;
  NodeId? lastNormalDestination;
  NodeId? lastRealtimeDestination;
  NodeId? lastRelayRealtimeDestination;
  Uint8List? lastRealtimePayload;
  NodeId? lastRealtimeDevice;
  void Function(NodeId dst, Uint8List payload)? onNormalSend;
  void Function(NodeId dst, Uint8List payload)? onRealtimeSend;

  @override
  Future<NodeId> nodeId() async => me;

  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    normalSends++;
    lastNormalAnonymous = anonymous;
    if (failSends) throw StateError('private-peer /private/model/path');
    lastNormalDestination = dst;
    if (blockAck && WireEnvelope.decode(payload).kind == WireKind.ack) {
      if (!ackEntered.isCompleted) ackEntered.complete();
      await releaseAck.future;
    }
    onNormalSend?.call(dst, payload);
  }

  @override
  Future<void> sendRealtime(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    realtimeSends++;
    if (failSends) throw StateError('private-peer /private/model/path');
    lastRealtimeDestination = dst;
    lastRealtimeAnonymous = anonymous;
    lastRealtimePayload = Uint8List.fromList(payload);
    if (blockRealtime) await realtimeGate.future;
    onRealtimeSend?.call(dst, payload);
  }

  @override
  Future<void> sendRealtimeToDevice(
    NodeId identity,
    NodeId device,
    Uint8List payload,
  ) async {
    lastRealtimeDevice = device;
    await sendRealtime(identity, payload);
  }

  @override
  Future<void> sendRelayRealtime(NodeId dst, Uint8List payload) async {
    relayRealtimeSends++;
    if (failSends) throw StateError('private-peer /private/model/path');
    lastRelayRealtimeDestination = dst;
  }

  @override
  Future<void> sendWithReply(NodeId dst, Uint8List payload) async {}

  @override
  Future<void> sendReply(int replyId, Uint8List payload) async {}

  @override
  Stream<InboundMessage> messages() => inbound.stream;

  @override
  Stream<InboundMessage> realtimeMessages() => realtimeInbound.stream;

  @override
  Stream<int> sessionCount() => Stream.value(0);

  @override
  Future<List<PeerInfo>> peers() async => const [];

  @override
  Future<void> dispose() async {
    await inbound.close();
    await realtimeInbound.close();
  }
}

/// The same ordinary channel without advertising optional realtime features.
class _OrdinaryProbe implements VeilTransport {
  _OrdinaryProbe(this.delegate);
  final _RealtimeProbe delegate;
  @override
  Future<NodeId> nodeId() => delegate.nodeId();
  @override
  Future<void> send(NodeId dst, Uint8List payload, {bool anonymous = false}) =>
      delegate.send(dst, payload, anonymous: anonymous);
  @override
  Future<void> sendWithReply(NodeId dst, Uint8List payload) =>
      delegate.sendWithReply(dst, payload);
  @override
  Future<void> sendReply(int replyId, Uint8List payload) =>
      delegate.sendReply(replyId, payload);
  @override
  Stream<InboundMessage> messages() => delegate.messages();
  @override
  Stream<int> sessionCount() => delegate.sessionCount();
  @override
  Future<List<PeerInfo>> peers() => delegate.peers();
  @override
  Future<void> dispose() => delegate.dispose();
}

SpaceOpener _memOpener() {
  final store = FakeKvLogStore();
  return ({required password, required bool create}) => store;
}

class _BlockingOutboxStorage extends HiddenVolumeStorage {
  _BlockingOutboxStorage() : super(_memOpener());

  final enqueueEntered = Completer<void>();
  final releaseEnqueue = Completer<void>();

  @override
  Future<void> enqueueOutboxFrame(
    String frameId,
    String peerHex,
    Uint8List wire,
  ) async {
    if (!enqueueEntered.isCompleted) enqueueEntered.complete();
    await releaseEnqueue.future;
    await super.enqueueOutboxFrame(frameId, peerHex, wire);
  }
}

class _BlockingContactStorage extends HiddenVolumeStorage {
  _BlockingContactStorage() : super(_memOpener());

  final readEntered = Completer<void>();
  final releaseRead = Completer<void>();
  bool blockReads = false;

  @override
  Future<Contact?> getContact(NodeId nodeId) async {
    if (blockReads) {
      if (!readEntered.isCompleted) readEntered.complete();
      await releaseRead.future;
    }
    return super.getContact(nodeId);
  }
}

class _ThrowOnceContactStorage extends HiddenVolumeStorage {
  _ThrowOnceContactStorage() : super(_memOpener());

  bool throwNextRead = false;

  @override
  Future<Contact?> getContact(NodeId nodeId) {
    if (throwNextRead) {
      throwNextRead = false;
      throw StateError('injected contact read failure');
    }
    return super.getContact(nodeId);
  }
}

void main() {
  late NodeId me;
  late NodeId peer;
  late _RealtimeProbe transport;
  late HiddenVolumeStorage storage;

  setUp(() async {
    diagnosticJournal.clear();
    errorJournal.clear();
    me = _id(1);
    peer = _id(2);
    transport = _RealtimeProbe(me);
    storage = HiddenVolumeStorage(_memOpener());
    await storage.open(password: 'pw', createIfMissing: true);
    await storage.upsertContact(
      Contact(nodeId: peer, status: ContactStatus.accepted),
    );
    addTearDown(transport.dispose);
    addTearDown(storage.close);
  });

  for (final realtime in [false, true]) {
    test('retry reaches a late call handler lane=$realtime', () async {
      final messaging = MessagingService(transport, storage)..start();
      addTearDown(messaging.dispose);
      const frame = 'late-call-handler-frame';
      final wire = WireEnvelope.callSignal(
        const CallSignal(
          callId: 'late-call-handler',
          type: CallSignalType.offer,
        ).encode(),
      ).withFrameId(frame).encode();
      var acks = 0, calls = 0, declines = 0;
      transport.onNormalSend = (_, payload) {
        final envelope = WireEnvelope.decode(payload);
        if (envelope.kind == WireKind.ack && envelope.id == frame) acks++;
      };
      void inject({bool? lane}) =>
          ((lane ?? realtime) ? transport.realtimeInbound : transport.inbound)
              .add(
                InboundMessage(
                  src: peer,
                  payload: wire,
                  provenance: SenderProvenance.sessionPeer,
                  onDeclined: (_) => declines++,
                ),
              );
      inject();
      await pumpEventQueue();
      final prematureAcks = acks;
      messaging.onCallSignal = (_, _) => calls++;
      inject();
      await pumpEventQueue();
      expect(calls, 1, reason: 'missing handler must not consume the retry ID');
      expect(
        prematureAcks,
        0,
        reason: 'no call handler accepted that first copy',
      );
      expect(
        declines,
        1,
        reason: 'the carrier must retain the undelivered copy',
      );
      expect(acks, greaterThan(0));
      inject(lane: !realtime);
      await pumpEventQueue();
      expect(calls, 1, reason: 'a delivered frame still deduplicates');
      messaging.onCallSignal = null;
      inject(lane: !realtime);
      await pumpEventQueue();
      expect(calls, 1);
      expect(
        declines,
        1,
        reason: 'an accepted duplicate is not a local refusal',
      );
    });
  }

  for (final realtime in [false, true]) {
    for (final outcome in [
      'dispatch',
      'missing',
      'consent',
      'provenance',
      'duplicate',
      'malformed',
    ]) {
      test(
        'anonymous call decision evidence lane=$realtime outcome=$outcome',
        () async {
          if (outcome == 'consent') {
            await storage.upsertContact(
              Contact(nodeId: peer, status: ContactStatus.pendingOutgoing),
            );
          }
          final messaging = MessagingService(transport, storage)..start();
          addTearDown(messaging.dispose);
          var callbacks = 0;
          if (outcome != 'missing') {
            messaging.onCallSignal = (_, _) => callbacks++;
          }
          final wire = WireEnvelope.callSignal(
            outcome == 'malformed'
                ? 'PRIVATE_MALFORMED'
                : const CallSignal(
                    callId: 'PRIVATE_DIAGNOSTIC_CALL',
                    type: CallSignalType.offer,
                  ).encode(),
          ).withFrameId('PRIVATE_FRAME').encode();
          void inject() {
            final message = InboundMessage(
              src: peer,
              payload: wire,
              provenance: outcome == 'provenance'
                  ? SenderProvenance.claimed
                  : SenderProvenance.sessionPeer,
            );
            (realtime ? transport.realtimeInbound : transport.inbound).add(
              message,
            );
          }

          inject();
          await pumpEventQueue();
          if (outcome == 'duplicate') {
            inject();
            await pumpEventQueue();
          }
          expect(
            callbacks,
            outcome == 'dispatch' || outcome == 'duplicate' ? 1 : 0,
          );
          final report = diagnosticJournal.toJson();
          final decisions = (report['events'] as List)
              .where((e) => e['event'] == 'callSignalDecision')
              .toList();
          final stage = switch (outcome) {
            'dispatch' => 8,
            'missing' => 7,
            'consent' => 4,
            'provenance' => 3,
            'duplicate' => 6,
            _ => 2,
          };
          if (kDiagnosticReportEnabled) {
            expect(
              decisions.map((e) => e['values']),
              contains(
                equals({
                  'code': outcome == 'malformed'
                      ? -1
                      : CallSignalType.offer.index,
                  'state': stage,
                  'transport': realtime ? 1 : 0,
                  'direction': 1,
                }),
              ),
            );
          } else {
            expect(decisions, isEmpty);
          }
          final encoded = jsonEncode(report);
          expect(encoded, isNot(contains('PRIVATE_')));
          expect(encoded, isNot(contains(peer.hex)));
        },
      );
    }
  }

  for (final accepted in [false, true]) {
    test('anonymous outgoing call decision accepted=$accepted', () async {
      if (!accepted) {
        await storage.upsertContact(
          Contact(nodeId: peer, status: ContactStatus.pendingOutgoing),
        );
      }
      final messaging = MessagingService(transport, storage);
      addTearDown(messaging.dispose);
      await messaging.sendCallSignal(
        peer,
        const CallSignal(
          callId: 'PRIVATE_OUTGOING_CALL',
          type: CallSignalType.offer,
        ),
      );
      final report = diagnosticJournal.toJson();
      final decisions = (report['events'] as List)
          .where((e) => e['event'] == 'callSignalDecision')
          .toList();
      if (kDiagnosticReportEnabled) {
        expect(
          decisions.map((e) => e['values']),
          contains(
            equals({
              'code': CallSignalType.offer.index,
              'state': 0,
              'transport': -1,
              'direction': 0,
            }),
          ),
        );
        expect(
          decisions.any((e) => (e['values'] as Map)['state'] == 4),
          !accepted,
        );
      } else {
        expect(decisions, isEmpty);
      }
      expect(jsonEncode(report), isNot(contains('PRIVATE_')));
      expect(jsonEncode(report), isNot(contains(peer.hex)));
    });
  }

  for (final anonymous in [false, true]) {
    test('model inventory reaches ordinary receiver with realtime transport '
        '(anonymous=$anonymous)', () async {
      final otherTransport = _RealtimeProbe(peer);
      final otherStorage = HiddenVolumeStorage(_memOpener());
      await otherStorage.open(password: 'pw', createIfMissing: true);
      await otherStorage.upsertContact(
        Contact(nodeId: me, status: ContactStatus.accepted),
      );
      final left = MessagingService(transport, storage, anonymous: anonymous)
        ..start();
      final right = MessagingService(
        otherTransport,
        otherStorage,
        anonymous: anonymous,
      )..start();
      // An endpoint pinned for a call is one device, whereas model discovery
      // asks the contact identity and must not inherit that device's address.
      left.routeFor = (dst) => dst == peer ? _id(3) : null;
      right.routeFor = (dst) => dst == me ? _id(4) : null;
      addTearDown(otherStorage.close);
      addTearDown(otherTransport.dispose);
      addTearDown(right.dispose);
      addTearDown(left.dispose);
      void link(_RealtimeProbe from, _RealtimeProbe to) {
        InboundMessage message(Uint8List wire) => InboundMessage(
          src: from.me,
          payload: wire,
          provenance: SenderProvenance.sessionPeer,
        );
        from.onNormalSend = (dst, wire) {
          if (dst == to.me) to.inbound.add(message(wire));
        };
        from.onRealtimeSend = (_, wire) =>
            to.realtimeInbound.add(message(wire));
      }

      link(transport, otherTransport);
      link(otherTransport, transport);
      final root = Directory.systemTemp.createTempSync('xveil-live-inventory');
      addTearDown(() => root.deleteSync(recursive: true));
      final pair = Directory('${root.path}/ru-en')..createSync();
      for (final name in kPairFiles) {
        File('${pair.path}/$name').writeAsStringSync('$name fixture');
      }
      final requester = ModelExchangeService(
        messaging: left,
        storage: storage,
        translateRoot: () async => null,
        speechRoot: () async => null,
        now: DateTime.now,
      );
      final responder = ModelExchangeService(
        messaging: right,
        storage: otherStorage,
        translateRoot: () async => root,
        speechRoot: () async => null,
        now: DateTime.now,
      );
      addTearDown(requester.dispose);
      addTearDown(responder.dispose);
      final response = requester.answers.first;
      await requester.ask([peer]);
      final answer = await response.timeout(const Duration(seconds: 2));
      expect(answer.peer, peer);
      expect(answer.offers.single.label, 'ru → en');
      expect(transport.normalSends, 1);
      expect(otherTransport.normalSends, 1);
      expect(transport.lastNormalDestination, peer);
      expect(otherTransport.lastNormalDestination, me);
      expect(transport.lastNormalAnonymous, anonymous);
      expect(otherTransport.lastNormalAnonymous, anonymous);
      expect(transport.realtimeSends + transport.relayRealtimeSends, 0);
      expect(
        otherTransport.realtimeSends + otherTransport.relayRealtimeSends,
        0,
      );
      expect(await storage.pendingOutboxFrames(), isEmpty);
      expect(await otherStorage.pendingOutboxFrames(), isEmpty);
      final counts = diagnosticJournal.toJson()['counts'] as Map;
      expect(counts['callSignalSent'] ?? 0, 0);
      expect(counts['callSignalReceived'] ?? 0, 0);
      expect(
        counts['modelInventorySent'] ?? 0,
        kDiagnosticReportEnabled ? 2 : 0,
      );
      expect(
        counts['modelInventoryReceived'] ?? 0,
        kDiagnosticReportEnabled ? 2 : 0,
      );
    });
  }

  for (final realtime in [false, true]) {
    for (final anonymous in [false, true]) {
      for (final fails in [false, true]) {
        test(
          'call health keeps its own evidence and error contract '
          '(realtime=$realtime, anonymous=$anonymous, fails=$fails)',
          () async {
            final messaging = MessagingService(
              realtime ? transport : _OrdinaryProbe(transport),
              storage,
              anonymous: anonymous,
            );
            addTearDown(messaging.dispose);
            transport.failSends = fails;
            final send = messaging.sendCallSignal(
              peer,
              const CallSignal(
                callId: 'private-call-id',
                type: CallSignalType.health,
              ),
            );
            if (anonymous && fails) {
              await expectLater(send, throwsStateError);
            } else {
              await send;
            }
            final counts = diagnosticJournal.toJson()['counts'] as Map;
            final attempts = realtime && !anonymous ? 2 : 1;
            expect(
              counts[fails ? 'callSignalFailed' : 'callSignalSent'] ?? 0,
              kDiagnosticReportEnabled ? attempts : 0,
            );
            expect(
              counts[fails ? 'callSignalSent' : 'callSignalFailed'] ?? 0,
              0,
            );
            expect(counts['p2pBootstrapSent'] ?? 0, 0);
            expect(counts['modelInventorySent'] ?? 0, 0);
            final report = diagnosticJournal.toJson().toString();
            expect(report, isNot(contains('private-call-id')));
          },
        );
      }
    }
  }

  for (final anonymous in [false, true]) {
    test('failed inventory is live-only best effort and not a call failure '
        '(anonymous=$anonymous)', () async {
      final messaging = MessagingService(
        transport,
        storage,
        anonymous: anonymous,
      );
      addTearDown(messaging.dispose);
      transport.failSends = true;
      await messaging.sendModelInventoryRequest(peer);
      final counts = diagnosticJournal.toJson()['counts'] as Map;
      expect(
        counts['modelInventoryFailed'] ?? 0,
        kDiagnosticReportEnabled ? 1 : 0,
      );
      expect(counts['callSignalFailed'] ?? 0, 0);
      expect(transport.normalSends, 1);
      expect(transport.realtimeSends + transport.relayRealtimeSends, 0);
      expect(await storage.pendingOutboxFrames(), isEmpty);
    });
  }

  for (final fails in [false, true]) {
    test(
      'P2P bootstrap ${fails ? 'failure' : 'success'} is not call evidence',
      () async {
        final messaging = MessagingService(transport, storage);
        addTearDown(messaging.dispose);
        transport.failSends = fails;
        await messaging.sendP2PEndpoints(
          peer,
          'private-endpoints',
          sentAtMs: 1,
        );
        await pumpEventQueue();
        final counts = diagnosticJournal.toJson()['counts'] as Map;
        expect(counts['callSignalSent'] ?? 0, 0);
        expect(counts['callSignalFailed'] ?? 0, 0);
        expect(
          counts[fails ? 'p2pBootstrapFailed' : 'p2pBootstrapSent'] ?? 0,
          kDiagnosticReportEnabled ? 3 : 0,
        );
        final report = errorJournal.toJson(
          platform: 'test',
          osVersion: 'test',
          appVersion: 'test',
          phase: 'ready',
          diagnostics: diagnosticJournal,
          includeTimestamps: false,
        );
        expect(report, isNot(contains('private-peer')));
        expect(report, isNot(contains('/private/model/path')));
        expect(report, isNot(contains('private-endpoints')));
        final errors = (jsonDecode(report) as Map)['errors'] as List;
        expect(errors.where((e) => e['kind'] == 'call-signal-send'), isEmpty);
        if (fails && kDiagnosticReportEnabled) {
          expect(errors.any((e) => e['kind'] == 'p2p-bootstrap-send'), isTrue);
        }
      },
    );
  }

  test('realtime endpoint arrivals are not call signal arrivals', () async {
    final messaging = MessagingService(transport, storage)..start();
    addTearDown(messaging.dispose);
    var endpoints = 0;
    messaging.onP2PEndpoints = (_, _) => endpoints++;
    transport.realtimeInbound.add(
      InboundMessage(
        src: peer,
        payload: WireEnvelope.p2pEndpoints('private-endpoints').encode(),
        provenance: SenderProvenance.sessionPeer,
      ),
    );
    await pumpEventQueue();
    expect(endpoints, 1);
    final counts = diagnosticJournal.toJson()['counts'] as Map;
    expect(counts['callSignalReceived'] ?? 0, 0);
    expect(
      counts['p2pBootstrapReceived'] ?? 0,
      kDiagnosticReportEnabled ? 1 : 0,
    );
  });

  test(
    'unrecognized realtime payloads do not manufacture call evidence',
    () async {
      final messaging = MessagingService(transport, storage)..start();
      addTearDown(messaging.dispose);
      for (final bytes in [
        Uint8List.fromList([0xff]),
        const WireEnvelope.modelInventoryRequest().encode(),
      ]) {
        transport.realtimeInbound.add(
          InboundMessage(
            src: peer,
            payload: bytes,
            provenance: SenderProvenance.sessionPeer,
          ),
        );
      }
      await pumpEventQueue();
      expect(diagnosticJournal.toJson()['counts'], isEmpty);
    },
  );

  for (final realtime in [false, true]) {
    for (final ownDevice in [false, true]) {
      test('an unproven offer cannot ring or consume its proven copy '
          '(realtime=$realtime, ownDevice=$ownDevice)', () async {
        final messaging = MessagingService(transport, storage)..start();
        addTearDown(messaging.dispose);
        messaging.isOwnDevice = (p) async => ownDevice && p == peer;
        final received = <CallSignal>[];
        messaging.onCallSignal = (_, signal) => received.add(signal);
        final wire = WireEnvelope.callSignal(
          const CallSignal(
            callId: 'unproven-offer',
            type: CallSignalType.offer,
          ).encode(),
        ).withFrameId('unproven-offer-id').encode();
        final stream = realtime ? transport.realtimeInbound : transport.inbound;
        final before = transport.normalSends;
        stream.add(InboundMessage(src: peer, payload: wire));
        await pumpEventQueue();
        expect(received, isEmpty, reason: 'a contact name is not sender proof');
        expect(transport.normalSends, before, reason: 'a claim must not ACK');
        stream.add(
          InboundMessage(
            src: peer,
            payload: wire,
            provenance: SenderProvenance.sessionPeer,
          ),
        );
        await pumpEventQueue();
        expect(received.map((s) => s.type), [CallSignalType.offer]);
      });
    }
    for (final type in [
      CallSignalType.cancel,
      CallSignalType.end,
      CallSignalType.answerSelected,
    ]) {
      test('unproven early ${type.name} cannot suppress its proven copy '
          '(realtime=$realtime)', () async {
        final messaging = MessagingService(transport, storage)..start();
        addTearDown(messaging.dispose);
        final received = <CallSignal>[];
        messaging.onCallSignal = (_, signal) => received.add(signal);
        final wire = WireEnvelope.callSignal(
          CallSignal(callId: 'early-ending', type: type).encode(),
        ).withFrameId('early-ending-${type.name}').encode();
        final stream = realtime ? transport.realtimeInbound : transport.inbound;
        final before = transport.normalSends;
        stream.add(InboundMessage(src: peer, payload: wire));
        await pumpEventQueue();
        expect(received, isEmpty);
        expect(transport.normalSends, before, reason: 'a claim must not ACK');
        stream.add(
          InboundMessage(
            src: peer,
            payload: wire,
            provenance: SenderProvenance.sessionPeer,
          ),
        );
        await pumpEventQueue();
        expect(received.map((s) => s.type), [type]);
      });
    }
    for (final relayed in [false, true]) {
      test('active call bearer still admits an unproven ending '
          '(realtime=$realtime, relayed=$relayed)', () async {
        final sibling = _id(3);
        final messaging = MessagingService(transport, storage)..start();
        addTearDown(messaging.dispose);
        messaging.isOwnDevice = (p) async => p == sibling;
        messaging.acceptsCallDeviceSignal = (p, s) =>
            p == peer && s.callId == 'live-call' && s.onBehalfOf == null;
        final received = <CallSignal>[];
        messaging.onCallSignal = (_, signal) => received.add(signal);
        final signal = CallSignal(
          callId: 'live-call',
          type: CallSignalType.cancel,
          onBehalfOf: relayed ? peer.hex : null,
        );
        (realtime ? transport.realtimeInbound : transport.inbound).add(
          InboundMessage(
            src: relayed ? sibling : peer,
            payload: WireEnvelope.callSignal(signal.encode()).encode(),
          ),
        );
        await pumpEventQueue();
        expect(received.map((s) => s.callId), ['live-call']);
        expect(received.single.onBehalfOf, signal.onBehalfOf);
      });
    }
  }

  test(
    'restored answer retries realtime and retires only after recipient ACK',
    () async {
      final sender = MessagingService(transport, storage);
      await sender.sendCallSignal(
        peer,
        const CallSignal(
          callId: 'restored-answer',
          type: CallSignalType.answer,
        ),
      );
      await sender.dispose(); // Drops the in-memory fast retry callbacks.
      final saved = (await storage.pendingOutboxFrames()).single;

      final receiverStorage = HiddenVolumeStorage(_memOpener());
      await receiverStorage.open(password: 'pw', createIfMissing: true);
      await receiverStorage.upsertContact(
        Contact(nodeId: me, status: ContactStatus.accepted),
      );
      final receiverTransport = _RealtimeProbe(peer);
      final receiver = MessagingService(receiverTransport, receiverStorage)
        ..start();
      final restored = MessagingService(transport, storage)..start();
      addTearDown(() async {
        await restored.dispose();
        await receiver.dispose();
        await receiverTransport.dispose();
        await receiverStorage.close();
      });
      final received = Completer<CallSignal>();
      var deliveries = 0;
      receiver.onCallSignal = (_, signal) {
        deliveries++;
        if (!received.isCompleted) received.complete(signal);
      };
      transport.onRealtimeSend = (dst, wire) {
        expect(dst, peer);
        expect(WireEnvelope.decode(wire).frameId, saved.frameId);
        receiverTransport.realtimeInbound.add(
          InboundMessage(
            src: me,
            payload: wire,
            provenance: SenderProvenance.sessionPeer,
          ),
        );
      };
      final realtimeBefore = transport.realtimeSends;
      final relayBefore = transport.relayRealtimeSends;
      await restored.flushOutbox(); // Ordinary sends continue to be lost.
      expect(
        (await received.future.timeout(const Duration(seconds: 1))).type,
        CallSignalType.answer,
      );
      expect(transport.realtimeSends, greaterThan(realtimeBefore));
      expect(transport.relayRealtimeSends, greaterThan(relayBefore));
      expect(await storage.pendingOutboxFrames(), hasLength(1));

      // A duplicate live copy is ACKed, but enters the call FSM only once.
      final ack = Completer<void>();
      receiverTransport.onNormalSend = (dst, wire) {
        if (WireEnvelope.decode(wire).kind != WireKind.ack) return;
        expect(dst, me);
        transport.inbound.add(
          InboundMessage(
            src: peer,
            payload: wire,
            provenance: SenderProvenance.sessionPeer,
          ),
        );
        if (!ack.isCompleted) ack.complete();
      };
      receiverTransport.realtimeInbound.add(
        InboundMessage(
          src: me,
          payload: saved.wire,
          provenance: SenderProvenance.sessionPeer,
        ),
      );
      await ack.future.timeout(const Duration(seconds: 1));
      for (var i = 0; i < 50; i++) {
        if ((await storage.pendingOutboxFrames()).isEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(await storage.pendingOutboxFrames(), isEmpty);
      expect(deliveries, 1);
    },
  );

  for (final kind in [WireKind.p2pEndpoints, WireKind.groupCallSignal]) {
    test('restored ${kind.name} retains both realtime paths', () async {
      final envelope = kind == WireKind.p2pEndpoints
          ? const WireEnvelope.p2pEndpoints('{}')
          : WireEnvelope.groupCallSignal(
              '{}',
              sentAtMs: DateTime.now().millisecondsSinceEpoch,
            );
      await storage.enqueueOutboxFrame(
        'opaque-legacy-id',
        peer.hex,
        envelope.withFrameId('opaque-legacy-id').encode(),
      );
      final restored = MessagingService(transport, storage);
      addTearDown(restored.dispose);
      await restored.flushOutbox();
      expect(transport.realtimeSends, 1);
      expect(transport.relayRealtimeSends, 1);
      expect(transport.normalSends, 1);
      expect(WireEnvelope.decode(transport.lastRealtimePayload!).kind, kind);
      expect(await storage.pendingOutboxFrames(), hasLength(1));
    });
  }

  test('group announce reaches contact while realtime cannot finish', () async {
    transport.blockRealtime = true;
    final messaging = MessagingService(transport, storage);
    addTearDown(messaging.dispose);
    messaging.routeFor = (_) => _id(3); // A cached different physical device.
    final received = <WireEnvelope>[];
    transport.onNormalSend = (_, wire) =>
        received.add(WireEnvelope.decode(wire));
    final signal = GroupCallSignal(
      groupId: _id(9),
      callId: 'group-cold',
      author: me,
      membershipEpoch: 1,
      type: GroupCallSignalType.announce,
      media: const CallMedia(audio: true),
      sentAtMs: DateTime.now().millisecondsSinceEpoch,
      nonce: '000000000000000000000001',
      signature: Uint8List(0),
      authorPubKey: Uint8List(0),
    );
    await messaging
        .sendGroupCallSignal(peer, signal, 'opaque epoch-encrypted signal')
        .timeout(const Duration(milliseconds: 500));
    await pumpEventQueue();
    expect(received.single.kind, WireKind.groupCallSignal);
    expect(transport.lastNormalDestination, peer);
    expect(transport.realtimeSends, 1);
    expect(transport.relayRealtimeSends, 1);
    expect((await storage.pendingOutboxFrames()).single.peerHex, peer.hex);
    transport.realtimeGate.complete();
  });

  test('a call frame-id cannot move chat content into realtime', () async {
    final envelope = const WireEnvelope.reconnect('ordinary');
    await storage.enqueueOutboxFrame(
      'call:misleading:answer',
      peer.hex,
      envelope.withFrameId('call:misleading:answer').encode(),
    );
    final restored = MessagingService(transport, storage);
    addTearDown(restored.dispose);
    await restored.flushOutbox();
    expect(transport.normalSends, 1);
    expect(transport.realtimeSends, 0);
    expect(transport.relayRealtimeSends, 0);
  });

  test('blocked contact cannot re-drive call control on realtime', () async {
    final sender = MessagingService(transport, storage);
    await sender.sendCallSignal(
      peer,
      const CallSignal(callId: 'blocked-retry', type: CallSignalType.answer),
    );
    await sender.dispose();
    await storage.upsertContact(
      Contact(nodeId: peer, status: ContactStatus.blocked),
    );
    final restarted = MessagingService(transport, storage);
    addTearDown(restarted.dispose);
    final before = (
      transport.normalSends,
      transport.realtimeSends,
      transport.relayRealtimeSends,
    );
    await restarted.flushOutbox();
    expect((
      transport.normalSends,
      transport.realtimeSends,
      transport.relayRealtimeSends,
    ), before);
  });

  test(
    'durable call control races contact and realtime without awaiting either',
    () async {
      transport.blockRealtime = true;
      final messaging = MessagingService(transport, storage);
      addTearDown(messaging.dispose);

      await messaging
          .sendCallSignal(
            peer,
            const CallSignal(
              callId: 'fast-answer',
              type: CallSignalType.answer,
            ),
          )
          .timeout(const Duration(milliseconds: 500));

      expect(transport.realtimeSends, 1);
      expect(transport.relayRealtimeSends, 1);
      expect(
        transport.normalSends,
        1,
        reason: 'a cold call has no direct session yet, so contact must race',
      );
      expect(transport.lastRealtimeAnonymous, isFalse);
      expect(
        (await storage.pendingOutboxFrames()).map((f) => f.frameId),
        // Destination-bound: a fan-out owes each recipient its own row.
        contains('call:fast-answer:answer:${peer.hex}'),
      );
      transport.realtimeGate.complete();
    },
  );

  test('cold call answer keeps identity for all certificate lanes', () async {
    final device = _id(3);
    final messaging = MessagingService(transport, storage);
    addTearDown(messaging.dispose);
    messaging.pinCallReplyDevice('reply-device', peer, device);

    await messaging.sendCallSignal(
      peer,
      const CallSignal(callId: 'reply-device', type: CallSignalType.answer),
    );

    expect(transport.lastNormalDestination, peer);
    expect(transport.lastRealtimeDestination, peer);
    expect(transport.lastRelayRealtimeDestination, peer);
    expect((await storage.pendingOutboxFrames()).single.peerHex, peer.hex);

    // A cached direct route to a different device cannot receive the
    // caller's answer; the identity route remains the only valid fallback.
    messaging.routeFor = (_) => _id(4);
    await messaging.sendCallSignal(
      peer,
      const CallSignal(callId: 'reply-device', type: CallSignalType.end),
    );
    expect(transport.lastNormalDestination, peer);

    messaging.routeFor = (_) => device;
    await messaging.sendCallSignal(
      peer,
      const CallSignal(callId: 'reply-device', type: CallSignalType.cancel),
    );
    expect(transport.lastNormalDestination, peer);
  });

  for (final anonymous in [false, true]) {
    test('pinned call realtime uses its verified device and identity inbox '
        '(anonymous=$anonymous)', () async {
      final device = _id(3);
      final messaging = MessagingService(
        transport,
        storage,
        anonymous: anonymous,
      );
      addTearDown(messaging.dispose);
      messaging.pinCallReplyDevice('pinned-health', peer, device);
      const health = CallSignal(
        callId: 'pinned-health',
        type: CallSignalType.health,
      );

      // A claim without an admitted route cannot redirect the frame.
      await messaging.sendCallSignal(peer, health);
      expect(transport.lastRealtimeDevice, isNull);
      messaging.routeFor = (_) => _id(4);
      await messaging.sendCallSignal(peer, health);
      expect(transport.lastRealtimeDevice, isNull);

      messaging.routeFor = (_) => device;
      await messaging.sendCallSignal(peer, health);
      expect(transport.lastRealtimeDevice, anonymous ? null : device);
      expect(transport.lastRealtimeDestination, peer);
      expect(transport.lastRealtimeAnonymous, anonymous);
      expect(transport.lastRelayRealtimeDestination, anonymous ? null : peer);
      expect(transport.normalSends, 0);
      expect(await storage.pendingOutboxFrames(), isEmpty);
      final delivered = CallSignal.tryDecode(
        WireEnvelope.decode(transport.lastRealtimePayload!).body,
      )!;
      expect(delivered.callId, 'pinned-health');
      expect(delivered.type, CallSignalType.health);
    });
  }

  test('cold offer does not seal to a cached physical route', () async {
    final messaging = MessagingService(transport, storage);
    addTearDown(messaging.dispose);
    messaging.routeFor = (_) => _id(3);

    await messaging.sendCallSignal(
      peer,
      const CallSignal(callId: 'cold-offer', type: CallSignalType.offer),
    );

    expect(transport.lastNormalDestination, peer);
    expect(transport.lastRealtimeDestination, peer);
    expect(transport.lastRelayRealtimeDestination, peer);
  });

  test('realtime call leg starts before a blocked durable enqueue', () async {
    final blockedStorage = _BlockingOutboxStorage();
    await blockedStorage.open(password: 'pw', createIfMissing: true);
    await blockedStorage.upsertContact(
      Contact(nodeId: peer, status: ContactStatus.accepted),
    );
    addTearDown(blockedStorage.close);
    final messaging = MessagingService(transport, blockedStorage);
    addTearDown(messaging.dispose);

    final send = messaging.sendCallSignal(
      peer,
      const CallSignal(callId: 'storage-hol', type: CallSignalType.offer),
    );
    await blockedStorage.enqueueEntered.future.timeout(
      const Duration(milliseconds: 500),
    );

    expect(transport.realtimeSends, 1);
    expect(transport.relayRealtimeSends, 1);
    expect(
      transport.normalSends,
      1,
      reason: 'the routable cold-start leg must precede durable storage',
    );
    blockedStorage.releaseEnqueue.complete();
    await send;
  });

  test(
    'lost call control is re-driven before the periodic outbox tick',
    () async {
      final messaging = MessagingService(transport, storage);
      addTearDown(messaging.dispose);

      await messaging.sendCallSignal(
        peer,
        const CallSignal(callId: 'fast-redrive', type: CallSignalType.offer),
      );
      expect(transport.normalSends, 1);
      expect(transport.realtimeSends, 1);
      expect(transport.relayRealtimeSends, 1);

      await Future<void>.delayed(const Duration(milliseconds: 350));

      expect(transport.normalSends, 2);
      expect(transport.realtimeSends, 2);
      expect(transport.relayRealtimeSends, 2);
    },
  );

  test(
    'realtime P2P endpoint leg starts before a blocked durable enqueue',
    () async {
      final blockedStorage = _BlockingOutboxStorage();
      await blockedStorage.open(password: 'pw', createIfMissing: true);
      await blockedStorage.upsertContact(
        Contact(nodeId: peer, status: ContactStatus.accepted),
      );
      addTearDown(() async {
        if (!blockedStorage.releaseEnqueue.isCompleted) {
          blockedStorage.releaseEnqueue.complete();
        }
        await blockedStorage.close();
      });
      final messaging = MessagingService(transport, blockedStorage);
      addTearDown(messaging.dispose);

      final send = messaging.sendP2PEndpoints(
        peer,
        '{"v":1,"ts":123,"e":["veil:bootstrap?test"]}',
        sentAtMs: 123,
      );
      await blockedStorage.enqueueEntered.future.timeout(
        const Duration(milliseconds: 500),
      );

      expect(transport.realtimeSends, 1);
      expect(transport.relayRealtimeSends, 1);
      expect(
        transport.normalSends,
        1,
        reason: 'cold bootstrap also races the routable contact lane',
      );
      blockedStorage.releaseEnqueue.complete();
      await send;
      expect(
        (await blockedStorage.pendingOutboxFrames()).map((f) => f.frameId),
        contains('p2p:ep:123'),
      );
    },
  );

  test(
    'anonymous realtime signaling never downgrades to clear direct send',
    () async {
      final messaging = MessagingService(transport, storage, anonymous: true);
      addTearDown(messaging.dispose);

      await messaging.sendCallSignal(
        peer,
        const CallSignal(callId: 'anon-health', type: CallSignalType.health),
      );

      expect(transport.realtimeSends, 1);
      expect(
        transport.relayRealtimeSends,
        0,
        reason: 'anonymous signaling must never use the non-onion relay path',
      );
      expect(transport.lastRealtimeAnonymous, isTrue);
      expect(transport.normalSends, 0);
      expect(await storage.pendingOutboxFrames(), isEmpty);
    },
  );

  for (final anonymous in [false, true]) {
    test('audio playout health uses realtime paths without durable work '
        '(anonymous=$anonymous)', () async {
      final messaging = MessagingService(
        transport,
        storage,
        anonymous: anonymous,
      );
      addTearDown(messaging.dispose);
      await messaging.sendCallSignal(
        peer,
        const CallSignal(
          callId: 'playout-wire',
          type: CallSignalType.health,
          audioPlayout: CallAudioPlayoutFeedback(sequence: 77, delayMs: 540),
        ),
      );
      expect(transport.normalSends, 0);
      expect(await storage.pendingOutboxFrames(), isEmpty);
      expect(transport.relayRealtimeSends, anonymous ? 0 : 1);
      expect(transport.lastRealtimeAnonymous, anonymous);
      final envelope = WireEnvelope.decode(transport.lastRealtimePayload!);
      final delivered = CallSignal.tryDecode(envelope.body)!;
      expect(delivered.sentAtMs, isNotNull);
      expect(delivered.audioPlayout!.sequence, 77);
      expect(delivered.audioPlayout!.delayMs, 540);
    });
  }

  test('relay route transition is realtime and durably re-driven', () async {
    final messaging = MessagingService(transport, storage);
    addTearDown(messaging.dispose);

    await messaging.sendCallSignal(
      peer,
      const CallSignal(
        callId: 'relay-transition',
        type: CallSignalType.transportInfo,
        transport: CallTransportProposal(CallTransportKind.relay),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(transport.realtimeSends, 1);
    expect(transport.relayRealtimeSends, 1);
    expect(transport.normalSends, 1);
    expect(
      (await storage.pendingOutboxFrames()).map((f) => f.frameId),
      contains(startsWith('call:relay-transition:transportInfo:')),
    );
  });

  test(
    'relay fallback and later direct readiness have distinct durable ids',
    () async {
      final messaging = MessagingService(transport, storage)..start();
      addTearDown(messaging.dispose);
      final received = <CallTransportKind?>[];
      messaging.onCallSignal = (_, signal) =>
          received.add(signal.transport?.kind);
      final wires = <Uint8List>[];
      // Even with equal millisecond timestamps, opposite transitions differ.
      for (final kind in [CallTransportKind.relay, CallTransportKind.p2p]) {
        await messaging.sendCallSignal(
          peer,
          CallSignal(
            callId: 'late-admission',
            type: CallSignalType.transportInfo,
            transport: CallTransportProposal(kind),
            sentAtMs: 1000,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        wires.add(transport.lastRealtimePayload!);
      }
      final ids = wires
          .map((wire) => WireEnvelope.decode(wire).frameId)
          .toList();
      expect(ids.toSet().length, 2);
      for (final wire in [...wires, wires.first]) {
        transport.realtimeInbound.add(
          InboundMessage(
            src: peer,
            payload: wire,
            provenance: SenderProvenance.sessionPeer,
          ),
        );
      }
      await pumpEventQueue();
      expect(
        received,
        [CallTransportKind.relay, CallTransportKind.p2p],
        reason:
            'a new readiness must pass dedup, while a replay stays suppressed',
      );
    },
  );

  test(
    'durable call dispatch and dedup progress while its device ACK is held',
    () async {
      final messaging = MessagingService(transport, storage)..start();
      final device = _id(3);
      final received = <CallSignalType>[];
      final dispatches = Completer<void>();
      messaging.onCallSignal = (source, signal) {
        expect(source, peer);
        received.add(signal.type);
        if (received.length == 2 && !dispatches.isCompleted) {
          dispatches.complete();
        }
      };
      transport.blockAck = true;
      InboundMessage incoming(CallSignalType type, String frameId) =>
          InboundMessage(
            src: peer,
            srcDevice: device,
            provenance: SenderProvenance.sessionPeer,
            payload: WireEnvelope.callSignal(
              CallSignal(callId: 'held-device-ack', type: type).encode(),
            ).withFrameId(frameId).encode(),
          );
      try {
        transport.inbound.add(incoming(CallSignalType.answer, 'answer:held'));
        await transport.ackEntered.future.timeout(const Duration(seconds: 1));
        expect(transport.lastNormalDestination, device);
        transport.inbound.add(incoming(CallSignalType.answer, 'answer:held'));
        transport.inbound.add(
          incoming(CallSignalType.transportInfo, 'route:held'),
        );
        await dispatches.future.timeout(const Duration(milliseconds: 500));
        expect(received, [CallSignalType.answer, CallSignalType.transportInfo]);
        await Future.doWhile(() async {
          if (transport.normalSends >= 3) return false;
          await Future<void>.delayed(const Duration(milliseconds: 1));
          return true;
        }).timeout(const Duration(milliseconds: 500));
        expect(
          transport.normalSends,
          3,
          reason: 'both deliveries and the duplicate still owe ACKs',
        );
      } finally {
        transport.releaseAck.complete();
        await messaging.dispose();
      }
    },
  );

  test(
    'authenticated realtime offer binds its device to the contact',
    () async {
      final messaging = MessagingService(transport, storage)..start();
      addTearDown(messaging.dispose);
      final device = _id(3);
      final received = Completer<void>();
      messaging.onCallSignal = (_, _) => received.complete();
      transport.realtimeInbound.add(
        InboundMessage(
          src: peer,
          srcDevice: device,
          provenance: SenderProvenance.sessionPeer,
          payload: WireEnvelope.callSignal(
            const CallSignal(
              callId: 'device-proof',
              type: CallSignalType.offer,
            ).encode(),
          ).encode(),
        ),
      );
      await received.future.timeout(const Duration(milliseconds: 500));
      expect(
        messaging.identityOfDevice(device),
        peer,
        reason: 'later file streams arrive under the proved device address',
      );
    },
  );

  test('a claimed realtime answer cannot bind a device', () async {
    final messaging = MessagingService(transport, storage)..start();
    addTearDown(messaging.dispose);
    final device = _id(3);
    final received = Completer<void>();
    messaging.onCallSignal = (_, _) => received.complete();
    transport.realtimeInbound.add(
      InboundMessage(
        src: peer,
        srcDevice: device,
        payload: WireEnvelope.callSignal(
          const CallSignal(
            callId: 'claimed-device',
            type: CallSignalType.answer,
          ).encode(),
        ).encode(),
      ),
    );
    await received.future.timeout(const Duration(milliseconds: 500));
    expect(messaging.identityOfDevice(device), isNull);
  });

  test(
    'dedup keeps device proof from an authenticated endpoint copy',
    () async {
      final messaging = MessagingService(transport, storage)..start();
      addTearDown(messaging.dispose);
      final device = _id(3);
      final received = Completer<void>();
      var calls = 0;
      messaging.onP2PEndpoints = (_, _) {
        calls++;
        if (!received.isCompleted) received.complete();
      };
      final wire = WireEnvelope.p2pEndpoints(
        '{"v":1,"ts":456,"e":[]}',
      ).withFrameId('p2p:ep:device-proof').encode();
      transport.realtimeInbound.add(
        InboundMessage(
          src: peer,
          payload: wire,
          provenance: SenderProvenance.sessionPeer,
        ),
      );
      await received.future.timeout(const Duration(milliseconds: 500));
      expect(messaging.identityOfDevice(device), isNull);
      transport.realtimeInbound.add(
        InboundMessage(
          src: peer,
          srcDevice: device,
          payload: wire,
          provenance: SenderProvenance.sessionPeer,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(messaging.identityOfDevice(device), peer);
      expect(
        calls,
        1,
        reason: 'proof must survive without replaying the control event',
      );
    },
  );

  test('dedicated realtime inbound stream reaches call signaling', () async {
    final messaging = MessagingService(transport, storage)..start();
    addTearDown(messaging.dispose);
    final received = Completer<CallSignal>();
    messaging.onCallSignal = (source, signal) {
      expect(source, peer);
      if (!received.isCompleted) received.complete(signal);
    };
    const answer = CallSignal(
      callId: 'direct-control-inbound',
      type: CallSignalType.answer,
    );

    transport.realtimeInbound.add(
      InboundMessage(
        src: peer,
        payload: WireEnvelope.callSignal(answer.encode()).encode(),
      ),
    );

    final actual = await received.future.timeout(
      const Duration(milliseconds: 500),
    );
    expect(actual.callId, answer.callId);
    expect(actual.type, answer.type);
  });

  test(
    'dedicated realtime inbound stream reaches P2P endpoint handler once',
    () async {
      final messaging = MessagingService(transport, storage)..start();
      addTearDown(messaging.dispose);
      const body = '{"v":1,"ts":456,"e":["veil:bootstrap?accepted-peer"]}';
      final received = Completer<String>();
      var calls = 0;
      messaging.onP2PEndpoints = (source, actualBody) {
        expect(source, peer);
        calls++;
        if (!received.isCompleted) received.complete(actualBody);
      };
      final wire = WireEnvelope.p2pEndpoints(
        body,
      ).withFrameId('p2p:ep:456').encode();
      // An honest delivery: the node checked the claimed sender against the
      // authenticated peer of the session that carried the frame.
      InboundMessage honest() => InboundMessage(
        src: peer,
        payload: wire,
        provenance: SenderProvenance.sessionPeer,
      );

      transport.realtimeInbound.add(honest());

      expect(
        await received.future.timeout(const Duration(milliseconds: 500)),
        body,
      );
      transport.realtimeInbound.add(honest());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(calls, 1, reason: 'a realtime re-drive must be deduplicated');
    },
  );

  group('a name is not an identity (X/V-01)', () {
    // veil hands the app whatever sender a frame named; since 2e5471cc it also
    // hands over how much it KNOWS about that name. Before, a frame naming an
    // accepted contact WAS that contact — any node on the network could ring
    // this phone as one, or hand it bootstrap URIs to dial.

    test(
      'an unauthenticated frame wearing a contact name does not ring',
      () async {
        final messaging = MessagingService(transport, storage)..start();
        addTearDown(messaging.dispose);
        var rings = 0;
        messaging.onCallSignal = (_, _) => rings++;

        // `peer` IS an accepted contact — that is the whole point. The only
        // thing wrong with this frame is that nothing verified who sent it.
        transport.realtimeInbound.add(
          InboundMessage(
            src: peer,
            payload: WireEnvelope.callSignal(
              const CallSignal(
                callId: 'spoofed-offer',
                type: CallSignalType.offer,
              ).encode(),
            ).encode(),
          ),
        );

        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(
          rings,
          0,
          reason: 'a stranger rang the phone as one of the user\'s contacts',
        );
      },
    );

    test(
      'an unauthenticated frame wearing a contact name is not dialled',
      () async {
        final messaging = MessagingService(transport, storage)..start();
        addTearDown(messaging.dispose);
        var calls = 0;
        messaging.onP2PEndpoints = (_, _) => calls++;

        transport.realtimeInbound.add(
          InboundMessage(
            src: peer,
            payload: WireEnvelope.p2pEndpoints(
              '{"v":1,"ts":111,"e":["veil:bootstrap?attacker"]}',
            ).withFrameId('p2p:ep:111').encode(),
          ),
        );

        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(
          calls,
          0,
          reason: 'the app would have dialled an address the attacker chose',
        );
      },
    );

    test('the session cache cannot be used to answer for the claim', () async {
      // The accepted-peer cache is primed by anything that ever looked like
      // this contact, so a check placed AFTER it would let the suspect claim
      // vouch for itself. Prime it the way production does, then spoof.
      final messaging = MessagingService(transport, storage)..start();
      addTearDown(messaging.dispose);
      await messaging.sendCallSignal(
        peer,
        const CallSignal(callId: 'warm', type: CallSignalType.health),
      );
      var rings = 0;
      messaging.onCallSignal = (_, _) => rings++;

      transport.realtimeInbound.add(
        InboundMessage(
          src: peer,
          payload: WireEnvelope.callSignal(
            const CallSignal(
              callId: 'cached-spoof',
              type: CallSignalType.offer,
            ).encode(),
          ).encode(),
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(rings, 0, reason: 'the warm cache answered for the attacker');
    });

    test('an honest delivery from the same contact still rings', () async {
      // The control. Same contact, same frame — the only difference is that
      // this one arrived over a session whose peer the node authenticated.
      final messaging = MessagingService(transport, storage)..start();
      addTearDown(messaging.dispose);
      final received = Completer<CallSignal>();
      messaging.onCallSignal = (source, signal) {
        expect(source, peer);
        if (!received.isCompleted) received.complete(signal);
      };

      transport.realtimeInbound.add(
        InboundMessage(
          src: peer,
          payload: WireEnvelope.callSignal(
            const CallSignal(
              callId: 'honest-offer',
              type: CallSignalType.offer,
            ).encode(),
          ).encode(),
          provenance: SenderProvenance.sessionPeer,
        ),
      );

      final actual = await received.future.timeout(
        const Duration(milliseconds: 500),
      );
      expect(actual.callId, 'honest-offer');
    });

    test('the anonymous path is not what was closed', () async {
      // Anonymous meta-E2E is `claimed` BY DESIGN — ML-KEM proves
      // confidentiality and never origin — and veil pins that with a test so a
      // future "fix" cannot quietly shut it. It must not be shut here either:
      // call follow-ups are matched by CallService against the exact live
      // (peer, callId) it is already in, so they never needed a contact check
      // and still do not have one.
      final messaging = MessagingService(transport, storage)..start();
      addTearDown(messaging.dispose);
      final received = Completer<CallSignal>();
      messaging.onCallSignal = (_, signal) {
        if (!received.isCompleted) received.complete(signal);
      };

      transport.realtimeInbound.add(
        InboundMessage(
          src: peer,
          payload: WireEnvelope.callSignal(
            const CallSignal(
              callId: 'anonymous-answer',
              type: CallSignalType.answer,
            ).encode(),
          ).encode(),
        ),
      );

      final actual = await received.future.timeout(
        const Duration(milliseconds: 500),
      );
      expect(
        actual.callId,
        'anonymous-answer',
        reason: 'an unauthenticated lane was closed wholesale, not the spoof',
      );
    });

    test('the mailbox drain is verified, so it speaks for the contact', () {
      // The one attribution this app proves for itself: the drained sender is
      // the orchestrator's crypto-verified one, not the relay's wire hint.
      expect(SenderProvenance.signed.isAuthenticated, isTrue);
      expect(SenderProvenance.sessionPeer.isAuthenticated, isTrue);
      expect(SenderProvenance.localIpc.isAuthenticated, isTrue);
      expect(SenderProvenance.claimed.isAuthenticated, isFalse);
    });

    test('an unknown wire byte reads as a claim, never as proof', () {
      expect(SenderProvenance.fromWire(0), SenderProvenance.claimed);
      expect(SenderProvenance.fromWire(1), SenderProvenance.localIpc);
      expect(SenderProvenance.fromWire(2), SenderProvenance.sessionPeer);
      expect(SenderProvenance.fromWire(3), SenderProvenance.signed);
      for (final byte in [4, 9, 0x7F, 0xFF, -1]) {
        expect(
          SenderProvenance.fromWire(byte),
          SenderProvenance.claimed,
          reason: 'byte $byte must fail CLOSED, down to a claim and never up',
        );
      }
    });
  });

  test('realtime P2P endpoints stay behind accepted-contact consent', () async {
    final messaging = MessagingService(transport, storage)..start();
    addTearDown(messaging.dispose);
    var calls = 0;
    messaging.onP2PEndpoints = (_, _) => calls++;

    transport.realtimeInbound.add(
      InboundMessage(
        src: _id(3),
        payload: WireEnvelope.p2pEndpoints(
          '{"v":1,"ts":789,"e":["veil:bootstrap?stranger"]}',
        ).withFrameId('p2p:ep:789').encode(),
      ),
    );

    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(calls, 0);
    expect(transport.realtimeSends, 0, reason: 'a stranger is not ACKed');
    expect(transport.normalSends, 0, reason: 'a stranger is not ACKed');
  });

  test(
    'one failed realtime contact read does not poison later frames',
    () async {
      final flakyStorage = _ThrowOnceContactStorage();
      await flakyStorage.open(password: 'pw', createIfMissing: true);
      await flakyStorage.upsertContact(
        Contact(nodeId: peer, status: ContactStatus.accepted),
      );
      final messaging = MessagingService(transport, flakyStorage)..start();
      addTearDown(messaging.dispose);
      addTearDown(flakyStorage.close);
      final received = Completer<String>();
      messaging.onP2PEndpoints = (_, body) {
        if (!received.isCompleted) received.complete(body);
      };
      flakyStorage.throwNextRead = true;

      transport.realtimeInbound.add(
        InboundMessage(
          src: peer,
          payload: WireEnvelope.p2pEndpoints(
            '{"v":1,"ts":900,"e":["veil:bootstrap?first"]}',
          ).withFrameId('p2p:ep:900').encode(),
          provenance: SenderProvenance.sessionPeer,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      const secondBody = '{"v":1,"ts":901,"e":["veil:bootstrap?second"]}';
      transport.realtimeInbound.add(
        InboundMessage(
          src: peer,
          payload: WireEnvelope.p2pEndpoints(
            secondBody,
          ).withFrameId('p2p:ep:901').encode(),
          provenance: SenderProvenance.sessionPeer,
        ),
      );

      expect(
        await received.future.timeout(const Duration(milliseconds: 500)),
        secondBody,
      );
    },
  );

  test('realtime call lane bypasses a blocked ordinary inbound', () async {
    final blockedStorage = _BlockingContactStorage();
    await blockedStorage.open(password: 'pw', createIfMissing: true);
    await blockedStorage.upsertContact(
      Contact(nodeId: peer, status: ContactStatus.accepted),
    );
    final messaging = MessagingService(transport, blockedStorage);
    addTearDown(() async {
      if (!blockedStorage.releaseRead.isCompleted) {
        blockedStorage.releaseRead.complete();
      }
      await messaging.dispose();
      await blockedStorage.close();
    });

    // The outgoing consent check warms the bounded in-session call cache.
    await messaging.sendCallSignal(
      peer,
      const CallSignal(callId: 'warm-consent', type: CallSignalType.health),
    );
    messaging.start();
    blockedStorage.blockReads = true;
    transport.inbound.add(
      InboundMessage(
        src: peer,
        payload: WireEnvelope.callSignal(
          const CallSignal(
            callId: 'ordinary-backlog',
            type: CallSignalType.offer,
          ).encode(),
        ).encode(),
      ),
    );
    await blockedStorage.readEntered.future.timeout(
      const Duration(milliseconds: 500),
    );

    final received = Completer<CallSignal>();
    messaging.onCallSignal = (_, signal) {
      if (!received.isCompleted) received.complete(signal);
    };
    transport.realtimeInbound.add(
      InboundMessage(
        src: peer,
        payload: WireEnvelope.callSignal(
          const CallSignal(
            callId: 'priority-answer',
            type: CallSignalType.answer,
          ).encode(),
        ).encode(),
      ),
    );

    final actual = await received.future.timeout(
      const Duration(milliseconds: 500),
    );
    expect(actual.callId, 'priority-answer');
    expect(actual.type, CallSignalType.answer);
    blockedStorage.releaseRead.complete();
  });

  test('realtime answer never waits for an unwarmed contact read', () async {
    final blockedStorage = _BlockingContactStorage();
    await blockedStorage.open(password: 'pw', createIfMissing: true);
    await blockedStorage.upsertContact(
      Contact(nodeId: peer, status: ContactStatus.accepted),
    );
    final messaging = MessagingService(transport, blockedStorage)..start();
    addTearDown(() async {
      if (!blockedStorage.releaseRead.isCompleted) {
        blockedStorage.releaseRead.complete();
      }
      await messaging.dispose();
      await blockedStorage.close();
    });

    blockedStorage.blockReads = true;
    final received = Completer<CallSignal>();
    messaging.onCallSignal = (_, signal) {
      if (!received.isCompleted) received.complete(signal);
    };
    transport.realtimeInbound.add(
      InboundMessage(
        src: peer,
        payload: WireEnvelope.callSignal(
          const CallSignal(
            callId: 'cold-cache-answer',
            type: CallSignalType.answer,
          ).encode(),
        ).encode(),
      ),
    );

    final actual = await received.future.timeout(
      const Duration(milliseconds: 500),
    );
    expect(actual.callId, 'cold-cache-answer');
    expect(actual.type, CallSignalType.answer);
    expect(blockedStorage.readEntered.isCompleted, isFalse);
  });

  test('realtime offer remains behind the durable consent gate', () async {
    final blockedStorage = _BlockingContactStorage();
    await blockedStorage.open(password: 'pw', createIfMissing: true);
    await blockedStorage.upsertContact(
      Contact(nodeId: peer, status: ContactStatus.accepted),
    );
    final messaging = MessagingService(transport, blockedStorage)..start();
    addTearDown(() async {
      if (!blockedStorage.releaseRead.isCompleted) {
        blockedStorage.releaseRead.complete();
      }
      await messaging.dispose();
      await blockedStorage.close();
    });

    blockedStorage.blockReads = true;
    final received = Completer<CallSignal>();
    messaging.onCallSignal = (_, signal) {
      if (!received.isCompleted) received.complete(signal);
    };
    transport.realtimeInbound.add(
      InboundMessage(
        src: peer,
        payload: WireEnvelope.callSignal(
          const CallSignal(
            callId: 'gated-offer',
            type: CallSignalType.offer,
          ).encode(),
        ).encode(),
        provenance: SenderProvenance.sessionPeer,
      ),
    );

    await blockedStorage.readEntered.future.timeout(
      const Duration(milliseconds: 500),
    );
    expect(received.isCompleted, isFalse);

    blockedStorage.releaseRead.complete();
    final actual = await received.future.timeout(
      const Duration(milliseconds: 500),
    );
    expect(actual.callId, 'gated-offer');
    expect(actual.type, CallSignalType.offer);
  });
}
