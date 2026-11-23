import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/core/diagnostic_journal.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/domain/call.dart';
import 'package:xveil/domain/call_log.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/state/call_service.dart';
import 'package:xveil/state/call_media_route_operations.dart';
import 'package:xveil/state/call_media_receive_activity.dart';
import 'package:xveil/state/call_slot.dart';
import 'package:xveil/state/messaging.dart';
import 'package:xveil/state/veil_call_media.dart';

void main() {
  test('rejected video mount leaves no latent camera-on intent', () async {
    final wire = _FakeMessaging();
    final media = _FakeMedia()..videoOk = false;
    final service = CallService(wire, media: media)..start();
    addTearDown(service.dispose);
    wire.onCallSignal!(NodeId.fromHex('a' * 64), _diagnosticOffer());
    await service.accept();
    await pumpEventQueue();
    await service.setCameraEnabled(true);
    expect(service.current?.media.video, isFalse);
    expect(service.current?.cameraOn, isFalse);
    expect(media.cameraIntent, isNot(true));
    expect(media.log, isNot(contains('cam:true')));
  });

  test('camera off cancels an in-flight audio-to-video upgrade', () async {
    final wire = _FakeMessaging();
    final media = _FakeMedia()..videoGate = Completer<bool>();
    final service = CallService(wire, media: media)..start();
    addTearDown(service.dispose);
    wire.onCallSignal!(NodeId.fromHex('a' * 64), _diagnosticOffer());
    await service.accept();
    await pumpEventQueue();
    expect(service.current?.status, CallStatus.active);
    final enabling = service.setCameraEnabled(true);
    await pumpEventQueue();
    expect(media.log, contains('video:true'));
    await service.setCameraEnabled(false);
    media.videoGate!.complete(true);
    await enabling;
    expect(service.current?.cameraOn, isFalse);
    expect(media.log, isNot(contains('cam:true')));
    expect(
      wire.sent.where((s) => s.type == CallSignalType.renegotiate),
      isEmpty,
    );
  });

  test(
    'failed camera upgrade preserves receive and advertises camera off',
    () async {
      final wire = _FakeMessaging();
      final media = _FakeMedia()
        ..cameraOperation = (_) async => throw StateError('capture refused');
      final service = CallService(wire, media: media)..start();
      addTearDown(service.dispose);
      wire.onCallSignal!(NodeId.fromHex('a' * 64), _diagnosticOffer());
      await service.accept();
      await pumpEventQueue();
      await service.setCameraEnabled(true);
      expect(service.current?.status, CallStatus.active);
      expect(service.current?.media.video, isTrue);
      expect(service.current?.cameraOn, isFalse);
      expect(media.cameraIntent, isFalse);
      expect(wire.sent.where((s) => s.capture?.video == false), isNotEmpty);
      expect(
        wire.sent
            .where((s) => s.type == CallSignalType.renegotiate)
            .last
            .media
            ?.video,
        isTrue,
      );
    },
  );

  test('late camera failure cannot undo a newer successful retry', () async {
    final wire = _FakeMessaging();
    final gate = Completer<void>();
    var starts = 0;
    final media = _FakeMedia()
      ..cameraOperation = (on) async {
        if (on && starts++ == 0) await gate.future;
      };
    final service = CallService(wire, media: media)..start();
    addTearDown(service.dispose);
    wire.onCallSignal!(NodeId.fromHex('a' * 64), _diagnosticOffer());
    await service.accept();
    await pumpEventQueue();
    final first = service.setCameraEnabled(true);
    await pumpEventQueue();
    expect(media.log, contains('cam:true'));
    wire.sent.clear();
    await service.setCameraEnabled(false);
    await service.setCameraEnabled(true);
    gate.completeError(StateError('retired capture failed'));
    await first;
    expect(service.current?.cameraOn, isTrue);
    expect(media.cameraIntent, isTrue);
    expect(
      wire.sent.where((s) => s.capture?.video == false),
      hasLength(1),
      reason: 'only the deliberate camera-off may announce video off',
    );
  });

  test(
    'camera failure stream ignores old calls and recovered attempts',
    () async {
      final wire = _FakeMessaging();
      final media = _FakeMedia();
      final service = CallService(wire, media: media)..start();
      addTearDown(() async {
        service.dispose();
        await media.cameraFailures.close();
      });
      wire.onCallSignal!(NodeId.fromHex('a' * 64), _diagnosticOffer());
      await service.accept();
      await pumpEventQueue();
      await service.setCameraEnabled(true);
      media.startedWithoutCamera = true;
      media.cameraFailures.add('previous-call');
      await pumpEventQueue();
      expect(service.current?.cameraOn, isTrue);
      media.cameraFailures.add(service.current!.callId);
      media.startedWithoutCamera = false;
      await pumpEventQueue();
      expect(service.current?.cameraOn, isTrue);
      media.startedWithoutCamera = true;
      media.cameraFailures.add(service.current!.callId);
      await pumpEventQueue();
      expect(service.current?.cameraOn, isFalse);
      expect(service.current?.status, CallStatus.active);
      expect(wire.sent.last.capture?.video, isFalse);
      final sent = wire.sent.length;
      media.cameraFailures.add(service.current!.callId);
      await pumpEventQueue();
      expect(wire.sent, hasLength(sent));
    },
  );

  test('history bootstrap cannot reattach a disposed owner or send a queued call', () async {
    final wire = _FakeMessaging();
    final gate = Completer<List<CallLogEntry>>();
    final service = CallService(wire, loadFinishedCalls: () => gate.future)..start();
    expect(wire.onCallSignal, isNull);
    var placed = false;
    final placing = service.placeCall(NodeId.fromHex('a' * 64),
        const CallMedia(audio: true)).then((_) => placed = true);
    await pumpEventQueue();
    expect(placed, false);
    expect(wire.sent, isEmpty);
    service.dispose();
    final successor = CallService(wire)..start();
    addTearDown(successor.dispose);
    final handler = wire.onCallSignal;
    gate.complete([]);
    await placing;
    expect(wire.onCallSignal, same(handler));
    expect(wire.sent, isEmpty);
  });

  test('unavailable call history is diagnosed without silencing fresh calls', () async {
    diagnosticJournal.clear();
    final wire = _FakeMessaging();
    final service = CallService(wire, loadFinishedCalls: () async =>
        throw StateError('PRIVATE_HISTORY_PATH'))..start();
    addTearDown(service.dispose);
    await pumpEventQueue();
    expect(wire.onCallSignal, isNotNull);
    wire.onCallSignal!(NodeId.fromHex('a' * 64), _diagnosticOffer());
    expect(service.current?.status, CallStatus.ringing);
    final report = diagnosticJournal.toJson();
    if (kDiagnosticReportEnabled) {
      expect(((report['last_evidence'] as Map)['callHistoryRestore'] as Map)['values'],
          {'success': 0, 'sources': 0});
    }
    expect(jsonEncode(report), isNot(contains('PRIVATE_HISTORY_PATH')));
  });

  test('all retained journal calls restore before the wire consumer attaches', () async {
    diagnosticJournal.clear();
    final wire = _FakeMessaging(), peer = NodeId.fromHex('a' * 64);
    final rows = [
      const CallLogEntry(id: 'PRIVATE_INVALID_ROW', peerHex: 'bad-peer',
          outgoing: false, video: false, outcome: CallLogOutcome.missed, atMs: 1),
      for (var i = 0; i < 200; i++) CallLogEntry(id: 'PRIVATE_OLD_CALL_$i',
          peerHex: peer.hex, outgoing: false, video: false,
          outcome: CallLogOutcome.missed, atMs: 200 - i),
    ];
    final service = CallService(wire, loadFinishedCalls: () async => rows)..start();
    addTearDown(service.dispose);
    await pumpEventQueue();
    expect(wire.onCallSignal, isNotNull);
    for (final index in [0, 199]) {
      wire.onCallSignal!(peer, CallSignal(callId: 'PRIVATE_OLD_CALL_$index',
          type: CallSignalType.offer));
      expect(service.current, isNull);
    }
    final report = diagnosticJournal.toJson();
    if (kDiagnosticReportEnabled) {
      expect(((report['last_evidence'] as Map)['callHistoryRestore'] as Map)['values'],
          {'success': 1, 'sources': 200});
    }
    expect(jsonEncode(report), isNot(contains('PRIVATE_')));
    expect(jsonEncode(report), isNot(contains(peer.hex)));
    wire.onCallSignal!(peer, _diagnosticOffer());
    expect(service.current?.status, CallStatus.ringing);
  });

  test('finished forked call remembers its stable peer identity', () async {
    final peer = NodeId.fromHex('a' * 64), device = NodeId.fromHex('b' * 64);
    final wire = _FakeMessaging();
    final service = CallService(wire, media: _FakeMedia())..start();
    addTearDown(service.dispose);
    await service.placeCall(peer, const CallMedia(audio: true));
    final id = service.current!.callId;
    wire.onCallSignal!(device, CallSignal(callId: id, type: CallSignalType.answer,
        posture: CallPosture.anonymous,
        mediaKey: generateCallMediaKeyContribution()));
    await pumpEventQueue();
    expect(service.current?.peer, device);
    expect(service.current?.mediaIdentity, peer);
    await service.hangup();
    wire.onCallSignal!(peer, CallSignal(callId: id, type: CallSignalType.offer,
        posture: CallPosture.anonymous));
    expect(service.current, isNull,
        reason: 'a physical answer must not lose the stable finished-call key');
  });

  test(
    'late local microphone failure updates UI and peer without ending call',
    () async {
      final wire = _FakeMessaging();
      final media = _FakeMedia();
      final svc = CallService(wire, media: media)..start();
      addTearDown(() async {
        svc.dispose();
        await media.microphoneFailures.close();
      });
      wire.onCallSignal!(NodeId.fromHex('d' * 64), _diagnosticOffer());
      await pumpEventQueue();
      await svc.accept();
      await pumpEventQueue();
      expect(svc.current?.micOn, isTrue);
      media.startedWithoutMicrophone = true;
      media.microphoneFailures.add(svc.current!.callId);
      await pumpEventQueue();
      expect(svc.current?.status, CallStatus.active);
      expect(svc.current?.micOn, isFalse);
      expect(wire.sent.last.capture?.audio, isFalse);
      media.startedWithoutMicrophone = false;
      await svc.setMicEnabled(true);
      await pumpEventQueue();
      expect(svc.current?.micOn, isTrue);
      expect(wire.sent.last.capture?.audio, isTrue);
      // An already queued event from before this retry is no longer authoritative.
      final sent = wire.sent.length;
      media.microphoneFailures.add(svc.current!.callId);
      await pumpEventQueue();
      expect(svc.current?.micOn, isTrue);
      expect(wire.sent, hasLength(sent));
    },
  );

  test(
    'local microphone failure invalidates a pending optimistic mute result',
    () async {
      final wire = _FakeMessaging();
      final media = _FakeMedia();
      final svc = CallService(wire, media: media)..start();
      addTearDown(() async {
        svc.dispose();
        await media.microphoneFailures.close();
      });
      wire.onCallSignal!(NodeId.fromHex('d' * 64), _diagnosticOffer());
      await pumpEventQueue();
      await svc.accept();
      await pumpEventQueue();
      final pending = Completer<bool>();
      media.micOperation = (_) => pending.future;
      final mute = svc.setMicEnabled(false);
      media.startedWithoutMicrophone = true;
      media.microphoneFailures.add(svc.current!.callId);
      await pumpEventQueue();
      expect(svc.current?.micOn, isFalse);
      expect(wire.sent.last.capture?.audio, isFalse);
      final sent = wire.sent.length;
      pending.complete(false);
      await mute;
      await pumpEventQueue();
      expect(svc.current?.micOn, isFalse);
      expect(wire.sent, hasLength(sent));
    },
  );

  for (final phase in ['other-call', 'ended', 'disposed']) {
    test('local microphone event cannot affect $phase', () async {
      final wire = _FakeMessaging();
      final media = _FakeMedia();
      final svc = CallService(wire, media: media)..start();
      addTearDown(media.microphoneFailures.close);
      if (phase != 'disposed') addTearDown(svc.dispose);
      wire.onCallSignal!(NodeId.fromHex('d' * 64), _diagnosticOffer());
      await pumpEventQueue();
      await svc.accept();
      await pumpEventQueue();
      final id = svc.current!.callId;
      if (phase == 'ended') await svc.hangup();
      if (phase == 'disposed') svc.dispose();
      await pumpEventQueue();
      final sent = wire.sent.length;
      media.startedWithoutMicrophone = true;
      media.microphoneFailures.add(
        phase == 'other-call' ? 'different-call' : id,
      );
      await pumpEventQueue();
      expect(svc.current?.micOn, phase == 'other-call' ? isTrue : isNull);
      expect(wire.sent, hasLength(sent));
    });
  }
  for (final on in [false, true]) {
    for (final throws in [false, true]) {
      test(
        'native mic on=$on refusal preserves advertised posture (throws=$throws)',
        () async {
          final wire = _FakeMessaging();
          final media = _FakeMedia();
          final svc = CallService(wire, media: media)..start();
          addTearDown(svc.dispose);
          wire.onCallSignal!(NodeId.fromHex('d' * 64), _diagnosticOffer());
          await pumpEventQueue();
          await svc.accept();
          await pumpEventQueue();
          if (on) await svc.setMicEnabled(false);
          media.micOperation = (_) async {
            if (throws) throw StateError('private device failure');
            return false;
          };
          await svc.setMicEnabled(on);
          await pumpEventQueue();
          expect(svc.current?.status, CallStatus.active);
          expect(svc.current?.micOn, !on);
          expect(wire.sent.last.capture?.audio, !on);
          media.micOperation = (_) async => true;
          await svc.setMicEnabled(on);
          await pumpEventQueue();
          expect(svc.current?.micOn, on);
          expect(wire.sent.last.capture?.audio, on);
        },
      );
    }
  }

  test('an older mic failure cannot undo a newer failed unmute', () async {
    final wire = _FakeMessaging();
    final media = _FakeMedia();
    final svc = CallService(wire, media: media)..start();
    addTearDown(svc.dispose);
    wire.onCallSignal!(NodeId.fromHex('d' * 64), _diagnosticOffer());
    await pumpEventQueue();
    await svc.accept();
    await pumpEventQueue();
    final oldMute = Completer<bool>();
    media.micOperation = (muted) =>
        muted ? oldMute.future : Future.value(false);
    final old = svc.setMicEnabled(false);
    await svc.setMicEnabled(true);
    await pumpEventQueue();
    expect(svc.current?.micOn, isFalse);
    final sent = wire.sent.length;
    oldMute.complete(false);
    await old;
    await pumpEventQueue();
    expect(svc.current?.micOn, isFalse);
    expect(
      wire.sent,
      hasLength(sent),
      reason: 'stale result must not reannounce capture',
    );
  });

  test('a mic result after hangup cannot reannounce capture', () async {
    final wire = _FakeMessaging();
    final media = _FakeMedia();
    final svc = CallService(wire, media: media)..start();
    addTearDown(svc.dispose);
    wire.onCallSignal!(NodeId.fromHex('d' * 64), _diagnosticOffer());
    await pumpEventQueue();
    await svc.accept();
    await pumpEventQueue();
    final pending = Completer<bool>();
    media.micOperation = (_) => pending.future;
    final muted = svc.setMicEnabled(false);
    await svc.hangup();
    await pumpEventQueue();
    final sent = wire.sent.length;
    pending.complete(false);
    await muted;
    await pumpEventQueue();
    expect(svc.current, isNull);
    expect(wire.sent, hasLength(sent));
  });

  test('working receive-only startup marks mic off locally and to the peer', () async {
    final wire = _FakeMessaging();
    final media = _FakeMedia()..startedWithoutMicrophone = true;
    final svc = CallService(wire, media: media)..start();
    addTearDown(svc.dispose);
    wire.onCallSignal!(NodeId.fromHex('d' * 64), _diagnosticOffer());
    await pumpEventQueue();
    await svc.accept();
    await pumpEventQueue();
    expect(svc.current?.status, CallStatus.active);
    expect(svc.current?.micOn, isFalse);
    final captures = wire.sent.where((row) => row.capture != null);
    expect(captures, isNotEmpty);
    expect(captures.last.capture!.audio, isFalse);

      await svc.setMicEnabled(true);
      await pumpEventQueue();
      expect(
        svc.current?.micOn,
        isFalse,
        reason: 'an unavailable input cannot be advertised as transmitting',
      );
      media.startedWithoutMicrophone = false;
      await svc.setMicEnabled(true);
      await pumpEventQueue();
      expect(
        svc.current?.micOn,
        isTrue,
        reason: 'a later successful microphone retry remains available',
      );
      expect(wire.sent.last.capture?.audio, isTrue);
    },
  );

  test(
    'terminal call diagnostics retain reason after the live slot clears',
    () async {
      final wire = _FakeMessaging();
      final svc = CallService(wire, media: _FakeMedia())..start();
      addTearDown(svc.dispose);
      diagnosticJournal.clear();
      wire.onCallSignal!(
        NodeId.fromHex('d' * 64),
        CallSignal(
          callId: 'private-call-diagnostic-fixture',
          type: CallSignalType.offer,
          media: const CallMedia(audio: true),
          posture: CallPosture.direct,
          mediaKey: generateCallMediaKeyContribution(),
        ),
      );
      await pumpEventQueue();
      await svc.accept();
      await pumpEventQueue();
      expect(svc.current?.status, CallStatus.active);
      await svc.hangup();
      await pumpEventQueue();
      expect(svc.current, isNull);
      final report = diagnosticJournal.toJson();
      final terminal = (report['events'] as List).where(
        (e) => (e as Map)['event'] == 'callEnded',
      );
      if (kDiagnosticReportEnabled) {
        expect(terminal, hasLength(1));
        expect(
          (terminal.single as Map)['values'],
          containsPair('endReason', CallEndReason.hangup.index),
        );
        expect(
          (terminal.single as Map)['values'],
          containsPair('origin', CallEndOrigin.unspecified.index),
          reason: 'an unclassified hangup must not be labelled a user gesture',
        );
      } else {
        expect(terminal, isEmpty);
      }
      final encoded = jsonEncode(report);
      expect(encoded, isNot(contains('private-call-diagnostic-fixture')));
      expect(encoded, isNot(contains('d' * 64)));
    },
  );

  test('hangup diagnostics distinguish each local action source', () async {
    for (final origin in [
      CallEndOrigin.userInterface,
      CallEndOrigin.androidNotification,
      CallEndOrigin.localApi,
      CallEndOrigin.diagnosticApi,
    ]) {
      final wire = _FakeMessaging();
      final svc = CallService(wire, media: _FakeMedia())..start();
      addTearDown(svc.dispose);
      wire.onCallSignal!(NodeId.fromHex('d' * 64), _diagnosticOffer());
      await pumpEventQueue();
      await svc.accept();
      await pumpEventQueue();
      diagnosticJournal.clear();
      await svc.hangup(origin: origin);
      await pumpEventQueue();
      final events = (diagnosticJournal.toJson()['events'] as List).where(
        (e) => (e as Map)['event'] == 'callEnded',
      );
      if (kDiagnosticReportEnabled) {
        expect(events, hasLength(1));
        expect((events.single as Map)['values'], {
          'state': CallStatus.active.index,
          'transport': CallTransportKind.relay.index,
          'direction': CallDirection.incoming.index,
          'endReason': CallEndReason.hangup.index,
          'origin': origin.index,
          'video': 0,
        });
      } else {
        expect(events, isEmpty);
      }
    }
  });

  test(
    'remote error and local media failure keep distinct terminal causes',
    () async {
      for (final remote in [true, false]) {
        final wire = _FakeMessaging();
        final media = _FakeMedia();
        if (!remote) media.startGate = Completer<bool>()..complete(false);
        final svc = CallService(wire, media: media)..start();
        addTearDown(svc.dispose);
        diagnosticJournal.clear();
        wire.onCallSignal!(NodeId.fromHex('d' * 64), _diagnosticOffer());
        await pumpEventQueue();
        await svc.accept();
        await pumpEventQueue();
        if (remote) {
          expect(svc.current?.status, CallStatus.active);
          wire.onCallSignal!(
            NodeId.fromHex('d' * 64),
            CallSignal(
              callId: svc.current!.callId,
              type: CallSignalType.end,
              reason: CallEndReason.error,
            ),
          );
          await pumpEventQueue();
        }
        expect(svc.current, isNull);
        final events = (diagnosticJournal.toJson()['events'] as List).where(
          (e) => (e as Map)['event'] == 'callEnded',
        );
        if (kDiagnosticReportEnabled) {
          expect(events, hasLength(1));
          final values = (events.single as Map)['values'] as Map;
          expect(values['endReason'], CallEndReason.error.index);
          expect(
            values['origin'],
            (remote
                    ? CallEndOrigin.remoteSignal
                    : CallEndOrigin.mediaStartFailure)
                .index,
          );
        } else {
          expect(events, isEmpty);
        }
        final encoded = jsonEncode(diagnosticJournal.toJson());
        expect(encoded, isNot(contains('private-call-diagnostic-fixture')));
        expect(encoded, isNot(contains('d' * 64)));
      }
    },
  );

  test('hangup preserves origin when delegated to cancel or reject', () async {
    for (final incoming in [true, false]) {
      final wire = _FakeMessaging();
      final svc = CallService(wire, media: _FakeMedia())..start();
      addTearDown(svc.dispose);
      diagnosticJournal.clear();
      if (incoming) {
        wire.onCallSignal!(NodeId.fromHex('d' * 64), _diagnosticOffer());
        await pumpEventQueue();
      } else {
        await svc.placeCall(
          NodeId.fromHex('d' * 64),
          const CallMedia(audio: true),
        );
      }
      await svc.hangup(origin: CallEndOrigin.diagnosticApi);
      await pumpEventQueue();
      final events = (diagnosticJournal.toJson()['events'] as List).where(
        (e) => (e as Map)['event'] == 'callEnded',
      );
      if (kDiagnosticReportEnabled) {
        expect(events, hasLength(1));
        final values = (events.single as Map)['values'] as Map;
        expect(values['origin'], CallEndOrigin.diagnosticApi.index);
        expect(
          values['endReason'],
          (incoming ? CallEndReason.declined : CallEndReason.cancelled).index,
        );
      } else {
        expect(events, isEmpty);
      }
    }
  });

  test(
    'caller selection settles two already-active sibling answers without disclosing media keys',
    () async {
      final caller = NodeId.fromHex('c' * 64);
      final aId = NodeId.fromHex('a' * 64);
      final bId = NodeId.fromHex('b' * 64);
      final aWire = _FakeMessaging(), bWire = _FakeMessaging();
      final a = CallService(aWire, media: _FakeMedia())..start();
      final b = CallService(bWire, media: _FakeMedia())..start();
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      a.isOwnDevice = (peer) async => peer == bId;
      b.ownSiblingDevices = () async => [aId];
      final offer = CallSignal(
        callId: 'two-answers',
        type: CallSignalType.offer,
        media: const CallMedia(audio: true),
        posture: CallPosture.direct,
        mediaKey: generateCallMediaKeyContribution(),
      );
      aWire.onCallSignal!(caller, offer);
      bWire.onCallSignal!(caller, offer);
      await pumpEventQueue();
      await Future.wait([a.accept(), b.accept()]);
      await pumpEventQueue();
      expect(a.current?.status, CallStatus.active);
      expect(b.current?.status, CallStatus.active);
      final selected = callAnswerEndpoint(
        offer.callId,
        b.current!.localMediaKey,
      );
      final selection = CallSignal(
        callId: offer.callId,
        type: CallSignalType.answerSelected,
        selectedEndpoint: selected,
      );
      expect(selection.encode(), isNot(contains(b.current!.localMediaKey!)));
      bWire.onCallSignal!(caller, CallSignal.tryDecode(selection.encode())!);
      await pumpEventQueue();
      final forwarded = bWire.sentTo.singleWhere(
        (entry) => entry.$2.type == CallSignalType.answerSelected,
      );
      expect(forwarded.$1, aId);
      aWire.onCallSignal!(bId, forwarded.$2);
      await pumpEventQueue();
      expect(a.current, isNull);
      expect(b.current?.status, CallStatus.active);
      expect(aWire.sent.where((s) => s.type == CallSignalType.end), isEmpty);
      aWire.onCallSignal!(caller, offer);
      await pumpEventQueue();
      expect(
        a.current,
        isNull,
        reason: 'a late offer must not ring after caller election',
      );
    },
  );

  test(
    'late competing answer cannot replace the caller selected endpoint',
    () async {
      final peer = NodeId.fromHex('a' * 64), other = NodeId.fromHex('b' * 64);
      final wire = _FakeMessaging();
      final service = CallService(wire, media: _FakeMedia())..start();
      addTearDown(service.dispose);
      await service.placeCall(peer, const CallMedia(audio: true));
      final id = service.current!.callId;
      final first = generateCallMediaKeyContribution();
      wire.onCallSignal!(
        peer,
        CallSignal(
          callId: id,
          type: CallSignalType.answer,
          posture: CallPosture.direct,
          mediaKey: first,
        ),
      );
      await pumpEventQueue();
      final late = CallSignal(
        callId: id,
        type: CallSignalType.answer,
        posture: CallPosture.direct,
        mediaKey: generateCallMediaKeyContribution(),
      );
      expect(wire.acceptsCallDeviceSignal!(other, late), isTrue);
      wire.onCallSignal!(other, late);
      await pumpEventQueue();
      expect(service.current!.peerMediaKey, first);
      expect(service.current!.peer, peer);
      final selections = wire.sent.where(
        (s) => s.type == CallSignalType.answerSelected,
      );
      expect(selections, hasLength(2));
      expect(
        selections.every(
          (s) => s.selectedEndpoint == callAnswerEndpoint(id, first),
        ),
        isTrue,
      );
    },
  );

  test(
    'native screen source kinds preserve windows as a local-only choice',
    () {
      expect(screenSourceDeviceKind('screen'), CallMediaDeviceKind.screen);
      expect(screenSourceDeviceKind('window'), CallMediaDeviceKind.window);
      expect(
        screenSourceDeviceKind('unknown'),
        CallMediaDeviceKind.screen,
        reason: 'older display backends remain compatible',
      );
    },
  );

  test('initial camera capture follows camera posture, not video receive', () {
    final base = Call(
      callId: 'initial-camera-posture',
      peer: NodeId.fromHex('a' * 64),
      direction: CallDirection.incoming,
      media: const CallMedia(audio: true, video: true),
      status: CallStatus.connecting,
      localPosture: CallPosture.direct,
      startedAt: DateTime.fromMillisecondsSinceEpoch(1),
    );

    expect(shouldStartInitialCallCamera(base), isTrue);
    expect(
      shouldStartInitialCallCamera(base.copyWith(cameraOn: false)),
      isFalse,
      reason: 'receive-only video must not start physical capture',
    );
    expect(
      shouldStartInitialCallCamera(
        base.copyWith(media: const CallMedia(audio: true)),
      ),
      isFalse,
    );
  });

  test('a disposed call service answers nothing, on either lane', () async {
    // report21 XV20-L2. Detaching a handler stops the NEXT signal and does
    // nothing about one already in flight — and the relayed lane awaits
    // `isOwnDevice`, which reaches storage and can reach the network. A
    // service belonging to an identity the user has left would answer a
    // stranger's ring on that identity's pipeline, `busy` reject included.
    //
    // What this pins is the shared door, `_onSignal`, which every lane comes
    // through: remove that check and both halves below fail. The extra check
    // right after the `isOwnDevice` await is not separately pinned — the
    // shared door stops it anyway — and stands on the discipline of asking
    // after every await rather than on this test.
    final peer = NodeId.fromHex('e' * 64);
    final caller = NodeId.fromHex('f' * 64);

    // The direct lane: the handler is still held after dispose.
    final messaging = _FakeMessaging();
    final svc = CallService(messaging)..start();
    final handler = messaging.onCallSignal;
    expect(handler, isNotNull, reason: 'premise: the service is listening');
    svc.dispose();

    handler!(
      peer,
      const CallSignal(
        callId: 'after-dispose',
        type: CallSignalType.offer,
        media: CallMedia(audio: true),
        posture: CallPosture.direct,
      ),
    );
    await pumpEventQueue();
    expect(
      messaging.sent,
      isEmpty,
      reason: 'a departed identity answered a ring on its own pipeline',
    );
    expect(svc.current, isNull);

    // The relayed lane, where the dispose lands INSIDE the await.
    final messaging2 = _FakeMessaging();
    final svc2 = CallService(messaging2)..start();
    final gate = Completer<void>();
    svc2.isOwnDevice = (_) async {
      await gate.future;
      return true;
    };
    final handler2 = messaging2.onCallSignal;
    handler2!(
      peer,
      CallSignal(
        callId: 'relayed-after-dispose',
        type: CallSignalType.offer,
        media: const CallMedia(audio: true),
        posture: CallPosture.direct,
        onBehalfOf: caller.hex,
      ),
    );
    await pumpEventQueue();
    expect(
      messaging2.sent,
      isEmpty,
      reason: 'premise: the relayed signal is parked on isOwnDevice',
    );

    svc2.dispose();
    gate.complete();
    await pumpEventQueue();
    expect(
      messaging2.sent,
      isEmpty,
      reason: 'a relayed ring was answered after the identity moved on',
    );
    expect(svc2.current, isNull);
  });

  test('capture device selection is delegated for a live call', () {
    fakeAsync((async) {
      final peer = NodeId.fromHex('d' * 64);
      final messaging = _FakeMessaging();
      final media = _FakeMedia();
      final svc = CallService(messaging, media: media)..start();
      messaging.onCallSignal!(
        peer,
        const CallSignal(
          callId: 'device-selection',
          type: CallSignalType.offer,
          media: CallMedia(audio: true, video: true),
          posture: CallPosture.direct,
        ),
      );
      svc.accept();
      async.flushMicrotasks();

      var switched = false;
      svc.switchCameraFacing().then((value) => switched = value);
      async.flushMicrotasks();
      expect(switched, isTrue);
      expect(media.selectedCamera, 'back');

      var micSelected = false;
      svc.selectMicrophone('usb').then((value) => micSelected = value);
      async.flushMicrotasks();
      expect(micSelected, isTrue);
      expect(media.selectedMicrophone, 'usb');

      // The OUTPUT. It had no picker at all until 2026-08-29, and nothing in
      // the app ever called selectAudioOutput — so a desktop played a call
      // out of whatever the engine defaulted to, which on Windows is no
      // device.
      var speakerSelected = false;
      svc.selectSpeaker('hdmi').then((value) => speakerSelected = value);
      async.flushMicrotasks();
      expect(speakerSelected, isTrue);
      expect(media.selectedSpeaker, 'hdmi');

      var screenSelected = false;
      svc.selectScreen('display-2').then((value) => screenSelected = value);
      async.flushMicrotasks();
      expect(screenSelected, isTrue);
      expect(media.selectedScreen, 'display-2');
    });
  });

  test(
    'shared call slot excludes group/direct overlap and releases on end',
    () async {
      final peer = NodeId.fromHex('c' * 64);
      final fake = _FakeMessaging();
      final slot = CallSlot();
      final held = slot.acquire(CallSlotOwner.group);
      expect(held, isNotNull);
      final svc = CallService(fake, callSlot: slot)..start();
      addTearDown(svc.dispose);

      await svc.placeCall(peer, const CallMedia(audio: true));
      expect(svc.current, isNull);
      expect(fake.sent, isEmpty);

      slot.release(held);
      await svc.placeCall(peer, const CallMedia(audio: true));
      expect(slot.owner, CallSlotOwner.direct);
      expect(svc.current?.isLive, isTrue);
      await svc.cancel();
      expect(slot.owner, isNull);

      // The same exclusion applies to a later inbound offer.
      fake.sent.clear();
      final heldAgain = slot.acquire(CallSlotOwner.group);
      expect(heldAgain, isNotNull);
      fake.onCallSignal!(
        peer,
        const CallSignal(
          callId: 'incoming-after-end',
          type: CallSignalType.offer,
          media: CallMedia(audio: true),
        ),
      );
      await pumpEventQueue();
      expect(svc.current, isNull);
      expect(fake.sent.single.type, CallSignalType.busy);
      expect(slot.owner, CallSlotOwner.group);
    },
  );

  group('negotiateCallTransport — anonymity matrix', () {
    test('anon ↔ anon → full onion', () {
      expect(
        negotiateCallTransport(
          local: CallPosture.anonymous,
          peer: CallPosture.anonymous,
        ),
        CallTransportKind.onion,
      );
    });

    test('mixed (anon ↔ direct) → onion, both orderings', () {
      expect(
        negotiateCallTransport(
          local: CallPosture.anonymous,
          peer: CallPosture.direct,
        ),
        CallTransportKind.onion,
      );
      expect(
        negotiateCallTransport(
          local: CallPosture.direct,
          peer: CallPosture.anonymous,
        ),
        CallTransportKind.onion,
      );
    });

    test('direct ↔ direct with mutual consent + reachable → p2p', () {
      expect(
        negotiateCallTransport(
          local: CallPosture.direct,
          peer: CallPosture.direct,
          localConsentsP2P: true,
          peerConsentsP2P: true,
          peerReachable: true,
        ),
        CallTransportKind.p2p,
      );
    });

    test(
      'direct ↔ direct falls back to relay without consent/reachability',
      () {
        // no consent
        expect(
          negotiateCallTransport(
            local: CallPosture.direct,
            peer: CallPosture.direct,
          ),
          CallTransportKind.relay,
        );
        // one-sided consent
        expect(
          negotiateCallTransport(
            local: CallPosture.direct,
            peer: CallPosture.direct,
            localConsentsP2P: true,
            peerReachable: true,
          ),
          CallTransportKind.relay,
        );
        // both consent but unreachable
        expect(
          negotiateCallTransport(
            local: CallPosture.direct,
            peer: CallPosture.direct,
            localConsentsP2P: true,
            peerConsentsP2P: true,
          ),
          CallTransportKind.relay,
        );
      },
    );

    test('INVARIANT: an anonymous party is NEVER put on P2P, even with every '
        'consent/reachability flag set', () {
      for (final pair in [
        (CallPosture.anonymous, CallPosture.anonymous),
        (CallPosture.anonymous, CallPosture.direct),
        (CallPosture.direct, CallPosture.anonymous),
      ]) {
        final t = negotiateCallTransport(
          local: pair.$1,
          peer: pair.$2,
          localConsentsP2P: true,
          peerConsentsP2P: true,
          peerReachable: true,
        );
        expect(
          t,
          isNot(CallTransportKind.p2p),
          reason: 'anonymity must never yield a location-revealing P2P path',
        );
      }
    });
  });

  group('CallSignal encode/decode', () {
    test('v3 media contributions are strict 32-byte base64url values', () {
      final first = generateCallMediaKeyContribution();
      final second = generateCallMediaKeyContribution();
      expect(first, isNot(second));
      expect(decodeCallMediaKeyContribution(first), hasLength(32));
      expect(decodeCallMediaKeyContribution(second), hasLength(32));
      expect(decodeCallMediaKeyContribution('a2V5'), isNull);
      expect(decodeCallMediaKeyContribution('${first}x'), isNull);
    });

    test('caller TX and callee RX derive the same directional key', () {
      final callerNode = NodeId.fromHex('1' * 64);
      final calleeNode = NodeId.fromHex('2' * 64);
      final callerContribution = generateCallMediaKeyContribution();
      final calleeContribution = generateCallMediaKeyContribution();
      final started = DateTime.fromMillisecondsSinceEpoch(1);
      final caller = Call(
        callId: 'directional-keys',
        peer: calleeNode,
        direction: CallDirection.outgoing,
        media: const CallMedia(audio: true, video: true),
        status: CallStatus.connecting,
        localPosture: CallPosture.direct,
        startedAt: started,
        peerProtocolVersion: kCallRelaySealedMediaMinVersion,
        localMediaKey: callerContribution,
        peerMediaKey: calleeContribution,
      );
      final callee = Call(
        callId: 'directional-keys',
        peer: callerNode,
        direction: CallDirection.incoming,
        media: const CallMedia(audio: true, video: true),
        status: CallStatus.connecting,
        localPosture: CallPosture.direct,
        startedAt: started,
        peerProtocolVersion: kCallRelaySealedMediaMinVersion,
        localMediaKey: calleeContribution,
        peerMediaKey: callerContribution,
      );

      final callerKeys = deriveCallMediaKeys(
        call: caller,
        localNodeId: callerNode.bytes,
      );
      final calleeKeys = deriveCallMediaKeys(
        call: callee,
        localNodeId: calleeNode.bytes,
      );
      expect(callerKeys.txKey, calleeKeys.rxKey);
      expect(callerKeys.rxKey, calleeKeys.txKey);
      expect(callerKeys.txKey, isNot(callerKeys.rxKey));
      callerKeys.txKey.fillRange(0, 32, 0);
      callerKeys.rxKey.fillRange(0, 32, 0);
      calleeKeys.txKey.fillRange(0, 32, 0);
      calleeKeys.rxKey.fillRange(0, 32, 0);
    });

    test('offer round-trips through the wire body', () {
      final sig = CallSignal(
        callId: 'abc-123',
        type: CallSignalType.offer,
        media: const CallMedia(audio: true, video: true, screen: false),
        posture: CallPosture.anonymous,
        transport: const CallTransportProposal(CallTransportKind.onion),
        mediaKey: 'a2V5',
        sentAtMs: 1234567,
      );
      final back = CallSignal.tryDecode(sig.encode())!;
      expect(back.callId, 'abc-123');
      expect(back.type, CallSignalType.offer);
      expect(back.wantsAudio, isTrue);
      expect(back.wantsVideo, isTrue);
      expect(back.wantsScreen, isFalse);
      expect(back.posture, CallPosture.anonymous);
      expect(back.transport?.kind, CallTransportKind.onion);
      expect(back.mediaKey, 'a2V5');
      expect(back.sentAtMs, 1234567);
    });

    test('end carries a reason and no media', () {
      final sig = CallSignal(
        callId: 'x',
        type: CallSignalType.end,
        reason: CallEndReason.hangup,
      );
      final back = CallSignal.tryDecode(sig.encode())!;
      expect(back.type, CallSignalType.end);
      expect(back.reason, CallEndReason.hangup);
      expect(back.media, isNull);
    });

    test('health round-trips the additive media-repair request', () {
      const sig = CallSignal(
        callId: 'repair',
        type: CallSignalType.health,
        mediaRepairRequested: true,
      );
      final back = CallSignal.tryDecode(sig.encode())!;
      expect(back.mediaRepairRequested, isTrue);
      expect(
        CallSignal.tryDecode('{"c":"old","k":8}')!.mediaRepairRequested,
        isFalse,
      );
    });

    test('an out-of-range enum index decodes to the .unknown sentinel', () {
      // Simulate a newer peer's added type/posture (indices past this build).
      final body = '{"c":"id","k":9999,"p":9999,"t":{"k":9999},"v":1}';
      final back = CallSignal.tryDecode(body)!;
      expect(back.type, CallSignalType.unknown);
      expect(back.posture, CallPosture.unknown);
      expect(back.transport?.kind, CallTransportKind.unknown);
    });

    test('a malformed / non-call body decodes to null', () {
      expect(CallSignal.tryDecode('not json'), isNull);
      expect(CallSignal.tryDecode('{"no":"callId"}'), isNull);
    });
  });

  group('CallService P2P policy negotiation', () {
    final peer = NodeId.fromHex('b' * 64);

    test(
      'a lower advertised media ABI still carries a media contribution',
      () async {
        // The advertised version may still drop (an older engine binary), but
        // it must no longer be able to take the contribution with it: media on
        // every route is sealed with a key derived from BOTH contributions, so
        // omitting ours leaves the call with no media plane at all rather than
        // an unsealed one.
        final outgoingMessaging = _FakeMessaging();
        final outgoingMedia = _FakeMedia()..signalVersion = 2;
        final outgoing = CallService(outgoingMessaging, media: outgoingMedia)
          ..start();

        await outgoing.placeCall(
          peer,
          const CallMedia(audio: true, video: true),
        );
        expect(outgoingMessaging.sent.single.protocolVersion, 2);
        expect(
          decodeCallMediaKeyContribution(
            outgoingMessaging.sent.single.mediaKey,
          ),
          hasLength(32),
        );
        outgoing.dispose();

        final incomingMessaging = _FakeMessaging();
        final incomingMedia = _FakeMedia()..signalVersion = 2;
        final incoming = CallService(incomingMessaging, media: incomingMedia)
          ..start();
        incomingMessaging.onCallSignal!(
          peer,
          const CallSignal(
            callId: 'old-media-answer',
            type: CallSignalType.offer,
            media: CallMedia(audio: true, video: true),
            posture: CallPosture.direct,
            protocolVersion: 3,
          ),
        );

        await incoming.accept();
        expect(incomingMessaging.sent.single.protocolVersion, 2);
        expect(
          decodeCallMediaKeyContribution(
            incomingMessaging.sent.single.mediaKey,
          ),
          hasLength(32),
        );
        incoming.dispose();
      },
    );

    test('outgoing offer rings before an unresolved P2P probe', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        final media = _FakeMedia();
        final probe = Completer<bool>();
        final svc = CallService(
          fake,
          media: media,
          localAllowsP2P: (_) async => true,
          peerReachableForP2P: (_) => probe.future,
        )..start();

        svc.placeCall(peer, const CallMedia(audio: true));
        async.flushMicrotasks();
        expect(fake.sent.single.type, CallSignalType.offer);
        expect(fake.sent.single.transport?.kind, CallTransportKind.p2p);
        expect(
          media.startedWith,
          isEmpty,
          reason: 'intent is not media admission',
        );
        expect(probe.isCompleted, isFalse);
        async.elapse(kCallP2PSetupTimeout - const Duration(milliseconds: 1));
        expect(fake.sent, hasLength(1));
        probe.complete(true);
        async.flushMicrotasks();
        expect(fake.sent, hasLength(1));
        expect(media.startedWith, isEmpty);
        svc.dispose();
      });
    });

    test(
      'late P2P failure does not delay or change an accepted relay call',
      () {
        fakeAsync((async) {
          final fake = _FakeMessaging();
          final media = _FakeMedia()..openedTransport = CallTransportKind.relay;
          final probe = Completer<bool>();
          final svc = CallService(
            fake,
            media: media,
            localAllowsP2P: (_) async => true,
            peerReachableForP2P: (_) => probe.future,
          )..start();

          svc.placeCall(peer, const CallMedia(audio: true));
          async.flushMicrotasks();
          final id = svc.current!.callId;
          expect(fake.sent.single.type, CallSignalType.offer);
          fake.onCallSignal!(
            peer,
            CallSignal(
              callId: id,
              type: CallSignalType.answer,
              posture: CallPosture.direct,
              transport: const CallTransportProposal(CallTransportKind.relay),
              mediaKey: generateCallMediaKeyContribution(),
            ),
          );
          async.flushMicrotasks();
          expect(svc.current?.status, CallStatus.active);
          expect(media.startedWith, [CallTransportKind.relay]);
          async.elapse(kCallP2PSetupTimeout);
          async.flushMicrotasks();
          probe.complete(false);
          async.flushMicrotasks();
          expect(svc.current?.status, CallStatus.active);
          expect(svc.current?.transport, CallTransportKind.relay);
          expect(
            fake.sent.where((s) => s.type == CallSignalType.offer),
            hasLength(1),
          );
          expect(fake.sent.where((s) => s.type == CallSignalType.end), isEmpty);
          svc.dispose();
        });
      },
    );

    test(
      'outgoing direct call advertises permitted P2P and honors its answer',
      () async {
        final fake = _FakeMessaging();
        final media = _FakeMedia();
        final svc = CallService(
          fake,
          media: media,
          localAllowsP2P: (_) async => true,
          peerReachableForP2P: (_) async => true,
        )..start();

        await svc.placeCall(peer, const CallMedia(audio: true, video: true));

        expect(fake.sent.single.type, CallSignalType.offer);
        expect(fake.sent.single.transport?.kind, CallTransportKind.p2p);
        expect(fake.sent.single.protocolVersion, kCallSignalProtocolVersion);
        expect(
          decodeCallMediaKeyContribution(fake.sent.single.mediaKey),
          hasLength(32),
        );
        expect(svc.current?.localMediaKey, fake.sent.single.mediaKey);
        expect(media.startedWith, isEmpty);

        final callId = svc.current!.callId;
        fake.onCallSignal!(
          peer,
          CallSignal(
            callId: callId,
            type: CallSignalType.answer,
            posture: CallPosture.direct,
            transport: const CallTransportProposal(CallTransportKind.p2p),
            mediaKey: generateCallMediaKeyContribution(),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(media.startedWith, [CallTransportKind.p2p]);
        expect(
          decodeCallMediaKeyContribution(svc.current?.peerMediaKey),
          hasLength(32),
        );
      },
    );

    test(
      'relay fallback arriving before answer is applied after posture proof',
      () async {
        final fake = _FakeMessaging();
        final media = _FakeMedia()..openedTransport = CallTransportKind.relay;
        final svc = CallService(
          fake,
          media: media,
          localAllowsP2P: (_) async => true,
          peerReachableForP2P: (_) async => true,
        )..start();

        await svc.placeCall(peer, const CallMedia(audio: true));
        final callId = svc.current!.callId;

        // The callee's direct open failed immediately. Its fast transportInfo
        // overtakes the durable answer on the caller's receive path.
        fake.onCallSignal!(
          peer,
          CallSignal(
            callId: callId,
            type: CallSignalType.transportInfo,
            transport: const CallTransportProposal(CallTransportKind.relay),
          ),
        );
        fake.onCallSignal!(
          peer,
          CallSignal(
            callId: callId,
            type: CallSignalType.answer,
            posture: CallPosture.direct,
            transport: const CallTransportProposal(CallTransportKind.p2p),
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(media.startedWith, [CallTransportKind.relay]);
        expect(media.switches, isEmpty);
        expect(svc.current?.transport, CallTransportKind.relay);
        expect(svc.current?.status, CallStatus.active);
      },
    );

    test('answer cannot override a local P2P denial', () async {
      final fake = _FakeMessaging();
      final media = _FakeMedia()..openedTransport = CallTransportKind.relay;
      final svc = CallService(
        fake,
        media: media,
        localAllowsP2P: (_) async => false,
        peerReachableForP2P: (_) async => true,
      )..start();

      await svc.placeCall(peer, const CallMedia(audio: true));
      expect(fake.sent.single.transport?.kind, CallTransportKind.relay);
      final callId = svc.current!.callId;
      fake.onCallSignal!(
        peer,
        CallSignal(
          callId: callId,
          type: CallSignalType.answer,
          posture: CallPosture.direct,
          transport: const CallTransportProposal(CallTransportKind.p2p),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(media.startedWith, [CallTransportKind.relay]);
      expect(svc.current?.transport, CallTransportKind.relay);
      expect(svc.transportFallbackReason, isNull);
    });

    test(
      'relay badge explains an unavailable permitted direct session',
      () async {
        final fake = _FakeMessaging();
        final media = _FakeMedia()..openedTransport = CallTransportKind.relay;
        final svc = CallService(
          fake,
          media: media,
          localAllowsP2P: (_) async => true,
          peerReachableForP2P: (_) async => false,
        )..start();

        await svc.placeCall(peer, const CallMedia(audio: true));
        expect(fake.sent.single.transport?.kind, CallTransportKind.p2p);
        fake.onCallSignal!(
          peer,
          CallSignal(
            callId: svc.current!.callId,
            type: CallSignalType.answer,
            posture: CallPosture.direct,
            transport: const CallTransportProposal(CallTransportKind.relay),
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(svc.current?.transport, CallTransportKind.relay);
        expect(svc.transportFallbackReason, isNotNull);
      },
    );

    test('two direct identities never accept onion from an answer', () async {
      final fake = _FakeMessaging();
      final media = _FakeMedia()..openedTransport = CallTransportKind.relay;
      final svc = CallService(
        fake,
        media: media,
        localAllowsP2P: (_) async => true,
        peerReachableForP2P: (_) async => true,
      )..start();

      await svc.placeCall(peer, const CallMedia(audio: true));
      final callId = svc.current!.callId;
      fake.onCallSignal!(
        peer,
        CallSignal(
          callId: callId,
          type: CallSignalType.answer,
          posture: CallPosture.direct,
          transport: const CallTransportProposal(CallTransportKind.onion),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(media.startedWith, [CallTransportKind.relay]);
      expect(svc.current?.transport, CallTransportKind.relay);
    });

    test('anonymous outgoing call never proposes p2p', () async {
      final fake = _FakeMessaging()..anon = true;
      final svc = CallService(
        fake,
        localAllowsP2P: (_) async => true,
        peerReachableForP2P: (_) async => true,
      )..start();

      await svc.placeCall(peer, const CallMedia(audio: true));

      expect(fake.sent.single.transport?.kind, CallTransportKind.onion);
      expect(fake.sent.single.replyDevice, isNull);
    });

    test('incoming p2p offer is accepted as p2p only with local consent and '
        'reachability', () async {
      final fake = _FakeMessaging();
      final media = _FakeMedia();
      final svc = CallService(
        fake,
        media: media,
        localAllowsP2P: (_) async => true,
        peerReachableForP2P: (_) async => true,
      )..start();
      fake.onCallSignal!(
        peer,
        const CallSignal(
          callId: 'p2p-in',
          type: CallSignalType.offer,
          media: CallMedia(audio: true),
          posture: CallPosture.direct,
          transport: CallTransportProposal(CallTransportKind.p2p),
        ),
      );
      expect(media.startedWith, isEmpty);

      await svc.accept();
      await Future<void>.delayed(Duration.zero);

      expect(svc.current?.transport, CallTransportKind.p2p);
      expect(fake.sent.single.type, CallSignalType.answer);
      expect(fake.sent.single.replyDevice, NodeId.fromHex('f' * 64).hex);
      expect(fake.sent.single.transport?.kind, CallTransportKind.p2p);
      expect(media.startedWith, [CallTransportKind.p2p]);
    });

    for (final (posture, proposal, expected) in [
      (CallPosture.direct, CallTransportKind.relay, CallTransportKind.relay),
      (CallPosture.anonymous, CallTransportKind.p2p, CallTransportKind.onion),
    ]) {
      test('incoming ${expected.name} answer bypasses P2P policy lookup', () {
        fakeAsync((async) {
          final fake = _FakeMessaging();
          final policy = Completer<bool>();
          final svc = CallService(
            fake,
            localAllowsP2P: (_) => policy.future,
          )..start();
          try {
            fake.onCallSignal!(
              peer,
              CallSignal(
                callId: 'answer-without-p2p',
                type: CallSignalType.offer,
                posture: posture,
                transport: CallTransportProposal(proposal),
              ),
            );
            unawaited(svc.accept());
            async.flushMicrotasks();

            final answer = fake.sent.single;
            expect(answer.type, CallSignalType.answer);
            expect(answer.transport?.kind, expected);
            expect(policy.isCompleted, isFalse);
          } finally {
            svc.dispose();
            policy.complete(false);
            async.flushMicrotasks();
          }
        });
      });
    }

    test('an unresolved P2P policy cannot extend incoming ring timeout', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        final policy = Completer<bool>();
        final svc = CallService(
          fake,
          localAllowsP2P: (_) => policy.future,
        )..start();
        try {
          fake.onCallSignal!(
            peer,
            const CallSignal(
              callId: 'pending-p2p-policy',
              type: CallSignalType.offer,
              posture: CallPosture.direct,
              transport: CallTransportProposal(CallTransportKind.p2p),
            ),
          );
          unawaited(svc.accept());
          async.flushMicrotasks();
          expect(svc.current?.status, CallStatus.ringing);
          expect(fake.sent, isEmpty);

          async.elapse(kCallRingTimeout);

          expect(fake.sent.single.type, CallSignalType.reject);
          expect(fake.sent.single.reason, CallEndReason.timeout);
          expect(svc.current?.isLive, isNot(true));
          policy.complete(true);
          async.flushMicrotasks();
          expect(fake.sent, hasLength(1));
        } finally {
          svc.dispose();
          if (!policy.isCompleted) policy.complete(false);
          async.flushMicrotasks();
        }
      });
    });

    test(
      'incoming answer does not wait for NAT and announces actual relay fallback',
      () {
        fakeAsync((async) {
          final fake = _FakeMessaging();
          final media = _FakeMedia()..openedTransport = CallTransportKind.relay;
          final probe = Completer<bool>();
          final svc = CallService(
            fake,
            media: media,
            localAllowsP2P: (_) async => true,
            peerReachableForP2P: (_) => probe.future,
          )..start();
          fake.onCallSignal!(
            peer,
            const CallSignal(
              callId: 'cold-incoming',
              type: CallSignalType.offer,
              media: CallMedia(audio: true),
              posture: CallPosture.direct,
              transport: CallTransportProposal(CallTransportKind.p2p),
            ),
          );
          svc.accept();
          async.flushMicrotasks();
          expect(fake.sent.first.type, CallSignalType.answer);
          expect(fake.sent.first.transport?.kind, CallTransportKind.p2p);
          expect(media.startedWith, [CallTransportKind.p2p]);
          expect(svc.current?.status, CallStatus.active);
          expect(svc.current?.transport, CallTransportKind.relay);
          expect(fake.sent.last.type, CallSignalType.transportInfo);
          expect(fake.sent.last.transport?.kind, CallTransportKind.relay);
          probe.complete(false);
          async.flushMicrotasks();
          expect(svc.current?.status, CallStatus.active);
          expect(svc.current?.transport, CallTransportKind.relay);
          svc.dispose();
          async.flushMicrotasks();
        });
      },
    );

    test(
      'incoming p2p offer falls back to relay when local policy denies',
      () async {
        final fake = _FakeMessaging();
        final media = _FakeMedia();
        final svc = CallService(
          fake,
          media: media,
          localAllowsP2P: (_) async => false,
          peerReachableForP2P: (_) async => true,
        )..start();
        fake.onCallSignal!(
          peer,
          const CallSignal(
            callId: 'p2p-denied',
            type: CallSignalType.offer,
            media: CallMedia(audio: true),
            posture: CallPosture.direct,
            transport: CallTransportProposal(CallTransportKind.p2p),
          ),
        );

        await svc.accept();
        await Future<void>.delayed(Duration.zero);

        expect(svc.current?.transport, CallTransportKind.relay);
        expect(fake.sent.single.transport?.kind, CallTransportKind.relay);
        expect(media.startedWith, [CallTransportKind.relay]);
      },
    );
  });

  group('CallService liveness heartbeat', () {
    final peer = NodeId.fromHex('a' * 64);

    CallSignal offer(String id) => CallSignal(
      callId: id,
      type: CallSignalType.offer,
      media: const CallMedia(audio: true),
      posture: CallPosture.direct,
    );

    ({CallService svc, _FakeMessaging wire, _SnapshotMedia media}) snapshotCall(
      FakeAsync async,
      String id,
      Future<DateTime?> Function() read, {
      Stream<NetworkAttachment>? attachments,
      int Function()? readNetworkChangeGeneration,
    }) {
      final wire = _FakeMessaging();
      final media = _SnapshotMedia()
        ..openedTransport = CallTransportKind.relay
        ..rxAt = clock.now()
        ..readSnapshot = read;
      final svc = CallService(
        wire,
        now: () => clock.now(),
        media: media,
        networkAttachments: attachments,
        readNetworkChangeGeneration: readNetworkChangeGeneration,
      )..start();
      wire.onCallSignal!(peer, offer(id));
      svc.accept();
      async.flushMicrotasks();
      wire.onCallSignal!(
        peer,
        CallSignal(callId: id, type: CallSignalType.health),
      );
      expect(svc.current?.status, CallStatus.active);
      return (svc: svc, wire: wire, media: media);
    }

    test('native liveness keeps healthy media with a stale periodic cache', () {
      fakeAsync((async) {
        final t = snapshotCall(async, 'live-snapshot', () async => clock.now());
        try {
          async.elapse(const Duration(seconds: 30));
          async.flushMicrotasks();
          expect(t.svc.current?.status, CallStatus.active);
          expect(t.media.snapshotReads, greaterThan(0));
          final stopped = clock.now();
          t.media.readSnapshot = () async => stopped;
          async.elapse(const Duration(seconds: 25));
          async.flushMicrotasks();
          expect(
            t.svc.current,
            isNull,
            reason: 'old snapshots cannot renew life',
          );
        } finally {
          t.svc.dispose();
          async.flushMicrotasks();
        }
      });
    });

    for (final (admissionBeforeDispatch, offline) in [
      (false, true),
      (true, true),
      (false, false),
      (true, false),
    ]) {
      test(
        'a new network admission sends health before the peer times out '
        '(admission first=$admissionBeforeDispatch, offline=$offline)',
        () {
          fakeAsync((async) {
            const callId = 'reconnect-before-peer-timeout';
            final remote = snapshotCall(async, callId, () async => null);
            final network = StreamController<NetworkAttachment>(sync: true);
            final admissions = StreamController<void>(sync: true);
            var generation = 0;
            final wire = _FakeMessaging();
            final media = _CompactHealthMedia()
              ..openedTransport = CallTransportKind.relay;
            final local = CallService(
              wire,
              media: media,
              now: () => clock.now(),
              networkAttachments: network.stream,
              overlaySessionAdmissions: admissions.stream,
              readNetworkChangeGeneration: () => generation,
            )..start();
            try {
              wire.onCallSignal!(
                peer,
                const CallSignal(
                  callId: callId,
                  type: CallSignalType.offer,
                  media: CallMedia(audio: true),
                  posture: CallPosture.direct,
                  protocolVersion: kCallSignalProtocolVersion,
                ),
              );
              unawaited(local.accept());
              async.flushMicrotasks();
              expect(local.current?.status, CallStatus.active);
              wire.sent.clear();
              admissions.add(null);
              expect(wire.sent, isEmpty, reason: 'admission on a steady network');
              if (offline) {
                generation++;
                network.add(NetworkAttachment.offline);
              }
              async.elapse(kCallLivenessTimeout + const Duration(seconds: 4));
              wire.sent.clear();
              admissions.add(null);
              expect(wire.sent, isEmpty, reason: 'admission on the old network');

              wire.onCallSignal!(
                peer,
                const CallSignal(
                  callId: callId,
                  type: CallSignalType.health,
                  sentAtMs: 1,
                  capture: CallMedia(),
                  protocolVersion: kCallSignalProtocolVersion,
                  compactHealthReady: true,
                ),
              );
              // Native dispatch has begun. Its admission and Dart's dispatch
              // notification arrive independently.
              generation++;
              admissions.add(null);
              expect(wire.sent, isEmpty, reason: 'superseded dispatch');
              generation++;
              if (admissionBeforeDispatch) {
                admissions.add(null);
                expect(wire.sent, isEmpty, reason: 'dispatch is still pending');
              }
              final before = clock.now();
              network.add(NetworkAttachment.cellular);
              if (!admissionBeforeDispatch) {
                expect(
                  wire.sent,
                  isEmpty,
                  reason: 'new attachment before admission',
                );
                admissions.add(null);
              }
              expect(wire.sent, hasLength(1), reason: 'one live control frame');
              admissions.add(null);
              async.flushMicrotasks();
              expect(clock.now(), before);
              expect(media.compact, isEmpty, reason: 'old media can be stalled');
              expect(wire.sent, hasLength(1), reason: 'one live control frame');
              final health = wire.sent.single;
              expect(health.type, CallSignalType.health);
              expect(health.callId, callId);
              expect(health.sentAtMs, before.millisecondsSinceEpoch);
              expect(health.mediaRepairRequested, isFalse);
              remote.wire.onCallSignal!(peer, health);
              async.elapse(const Duration(seconds: 1));
              expect(remote.svc.current?.callId, callId);
              expect(remote.svc.current?.status, CallStatus.active);
            } finally {
              local.dispose();
              remote.svc.dispose();
              unawaited(network.close());
              unawaited(admissions.close());
              unawaited(media.health.close());
              async.flushMicrotasks();
            }
          });
        },
      );
    }

    test(
      'a handover admission still sends health after P2P falls back to relay',
      () {
        fakeAsync((async) {
          const callId = 'handover-relay-before-admission';
          final wire = _FakeMessaging();
          final network = StreamController<NetworkAttachment>(sync: true);
          final admissions = StreamController<void>(sync: true);
          final media = _SnapshotMedia()
            ..openedTransport = CallTransportKind.p2p
            ..liveDirectAdmission = false;
          var networkGeneration = 0;
          final svc = CallService(
            wire,
            media: media,
            now: () => clock.now(),
            localAllowsP2P: (_) async => true,
            peerReachableForP2P: (_) async => true,
            networkAttachments: network.stream,
            overlaySessionAdmissions: admissions.stream,
            readNetworkChangeGeneration: () => networkGeneration,
          )..start();
          try {
            wire.onCallSignal!(
              peer,
              const CallSignal(
                callId: callId,
                type: CallSignalType.offer,
                media: CallMedia(audio: true),
                posture: CallPosture.direct,
                transport: CallTransportProposal(CallTransportKind.p2p),
              ),
            );
            unawaited(svc.accept());
            async.flushMicrotasks();
            expect(svc.current?.transport, CallTransportKind.p2p);
            media.rxAt = clock.now();
            wire.sent.clear();

            networkGeneration++;
            network.add(NetworkAttachment.cellular);
            async.flushMicrotasks();
            expect(svc.current?.transport, CallTransportKind.relay);
            expect(media.switches, [CallTransportKind.relay]);
            expect(
              wire.sent.where(
                (signal) =>
                    signal.type == CallSignalType.transportInfo &&
                    signal.transport?.kind == CallTransportKind.relay,
              ),
              hasLength(1),
            );
            expect(
              wire.sent.where((s) => s.type == CallSignalType.health),
              isEmpty,
            );
            // The route notification above was sent before overlay admission.
            // The first admitted session should still send the live health hint.
            admissions.add(null);
            admissions.add(null);
            async.flushMicrotasks();
            final health = wire.sent.where(
              (s) => s.type == CallSignalType.health,
            );
            expect(health, hasLength(1));
            expect(health.single.callId, callId);
            expect(health.single.transport?.kind, CallTransportKind.relay);
            expect(svc.current?.status, CallStatus.active);
          } finally {
            svc.dispose();
            unawaited(network.close());
            unawaited(admissions.close());
            async.flushMicrotasks();
          }
        });
      },
    );

    for (final (admissionFirst, probeInFlight) in [
      (false, false),
      (true, false),
      (false, true),
    ]) {
      test(
        'closed direct path can prompt the peer to verify relay '
        '(admission first: $admissionFirst, existing probe: $probeInFlight)',
        () {
          fakeAsync((async) {
            const id = 'direct-loss-handover-health';
            final network = StreamController<NetworkAttachment>(sync: true);
            final admissions = StreamController<void>(sync: true);
            final senderWire = _FakeMessaging();
            final receiverWire = _FakeMessaging();
            final admission = Completer<bool?>();
            final receiverProbe = Completer<bool>();
            final previousProbe = Completer<bool>();
            final senderProbe = Completer<bool>();
            final senderMedia = _ReconnectRelayMedia()
              ..liveAdmissionGate = admission
              ..firstAttempt = senderProbe;
            final receiverMedia = _ReconnectRelayMedia()
              ..liveDirectAdmission = true
              ..firstAttempt = probeInFlight ? previousProbe : receiverProbe;
            var generation = 0;
            CallService startDirect(
              _FakeMessaging wire,
              _FakeMedia media, {
              bool changingNetwork = false,
            }) {
              final svc = CallService(
                wire,
                media: media,
                now: () => clock.now(),
                localAllowsP2P: (_) async => true,
                peerReachableForP2P: (_) async => true,
                networkAttachments: changingNetwork ? network.stream : null,
                overlaySessionAdmissions: changingNetwork
                    ? admissions.stream
                    : null,
                readNetworkChangeGeneration: changingNetwork
                    ? () => generation
                    : null,
              )..start();
              wire.onCallSignal!(
                peer,
                offer(id).copyWith(
                  transport: const CallTransportProposal(CallTransportKind.p2p),
                ),
              );
              unawaited(svc.accept());
              async.flushMicrotasks();
              expect(svc.current?.transport, CallTransportKind.p2p);
              media.rxAt = clock.now();
              wire.sent.clear();
              return svc;
            }

            final sender = startDirect(
              senderWire,
              senderMedia,
              changingNetwork: true,
            );
            final receiver = startDirect(receiverWire, receiverMedia);
            Iterable<CallSignal> health() => senderWire.sent.where(
              (signal) => signal.type == CallSignalType.health,
            );
            try {
              generation++;
              if (admissionFirst) admissions.add(null);
              network.add(NetworkAttachment.cellular);
              async.flushMicrotasks();
              if (admissionFirst) {
                final initial = health().single;
                expect(initial.toJson()['rh'], isNull);
                receiverWire.onCallSignal!(peer, initial);
              } else {
                expect(health(), isEmpty);
              }

              admission.complete(false);
              async.flushMicrotasks();
              if (!admissionFirst) {
                expect(health(), isEmpty);
                admissions.add(null);
              }
              admissions.add(null);
              async.flushMicrotasks();
              final hint = health()
                  .where((signal) => signal.toJson()['rh'] == true)
                  .single;
              final decoded = CallSignal.tryDecode(hint.encode())!;
              expect(decoded.toJson()['rh'], isTrue);
              expect(sender.current?.transport, CallTransportKind.p2p);
              final time = clock.now();
              if (!admissionFirst) {
                receiverWire.onCallSignal!(
                  peer,
                  CallSignal(
                    callId: id,
                    type: CallSignalType.health,
                    transport: const CallTransportProposal(
                      CallTransportKind.p2p,
                    ),
                    sentAtMs: decoded.sentAtMs,
                  ),
                );
              }
              final other = NodeId.fromHex('b' * 64);
              receiverWire.onCallSignal!(other, decoded);
              receiverWire.onCallSignal!(
                peer,
                decoded.copyWith(sentAtMs: decoded.sentAtMs! - 1),
              );
              expect(receiverMedia.switches, isEmpty);
              if (probeInFlight) {
                unawaited(receiver.requestRelayRecoveryForDiagnostics());
                async.flushMicrotasks();
                receiverMedia.nextAttempt = receiverProbe;
              }
              receiverWire.onCallSignal!(peer, decoded);
              receiverWire.onCallSignal!(peer, decoded);
              async.flushMicrotasks();
              expect(clock.now(), time);
              expect(receiverMedia.switches, [CallTransportKind.relay]);
              expect(receiver.current?.transport, CallTransportKind.p2p);
              if (probeInFlight) {
                previousProbe.complete(false);
                async.flushMicrotasks();
                expect(receiverMedia.switches, [
                  CallTransportKind.relay,
                  CallTransportKind.relay,
                ]);
              }
              receiverProbe.complete(true);
              async.flushMicrotasks();
              expect(receiver.current?.transport, CallTransportKind.relay);
            } finally {
              sender.dispose();
              receiver.dispose();
              if (!senderProbe.isCompleted) senderProbe.complete(false);
              if (!previousProbe.isCompleted) previousProbe.complete(false);
              if (!receiverProbe.isCompleted) receiverProbe.complete(false);
              unawaited(network.close());
              unawaited(admissions.close());
              async.flushMicrotasks();
            }
          });
        },
      );
    }

    for (final alreadyProbing in [false, true]) {
      test(
        'authenticated peer relay probe can wake recovery ($alreadyProbing)',
        () {
          fakeAsync((async) {
            final wire = _FakeMessaging();
            final first = Completer<bool>();
            final next = Completer<bool>();
            final media = _RelayObservationMedia()
              ..liveDirectAdmission = true
              ..firstAttempt = first;
            final service = CallService(
              wire,
              media: media,
              now: () => clock.now(),
              localAllowsP2P: (_) async => true,
              peerReachableForP2P: (_) async => true,
            )..start();
            try {
              wire.onCallSignal!(
                peer,
                offer('peer-probe').copyWith(
                  transport: const CallTransportProposal(CallTransportKind.p2p),
                ),
              );
              unawaited(service.accept());
              async.flushMicrotasks();
              final call = service.current!;
              expect(call.transport, CallTransportKind.p2p);
              media.rxAt = clock.now();

              media.relayProbes.add(
                call.copyWith(peerDevice: NodeId.fromHex('c' * 64)),
              );
              async.flushMicrotasks();
              expect(media.switches, isEmpty);
              if (alreadyProbing) {
                unawaited(service.requestRelayRecoveryForDiagnostics());
                async.flushMicrotasks();
                media.nextAttempt = next;
              }
              media.relayProbes.add(call);
              media.relayProbes.add(call);
              async.flushMicrotasks();
              expect(media.switches, [CallTransportKind.relay]);
              expect(service.current?.transport, CallTransportKind.p2p);
              first.complete(!alreadyProbing);
              async.flushMicrotasks();
              if (alreadyProbing) {
                expect(media.switches, [
                  CallTransportKind.relay,
                  CallTransportKind.relay,
                ]);
                expect(service.current?.transport, CallTransportKind.p2p);
                next.complete(true);
                async.flushMicrotasks();
              }
              expect(service.current?.transport, CallTransportKind.relay);
              media.relayProbes.add(call);
              async.flushMicrotasks();
              expect(media.switches, hasLength(alreadyProbing ? 2 : 1));
            } finally {
              service.dispose();
              unawaited(media.relayProbes.close());
              async.flushMicrotasks();
            }
          });
        },
      );
    }

    test('queued handover health follows a relay committed before send', () {
      fakeAsync((async) {
        const callId = 'handover-relay-before-health-send';
        final wire = _FakeMessaging();
        final network = StreamController<NetworkAttachment>(sync: true);
        final admissions = StreamController<void>(sync: true);
        final relay = Completer<bool>();
        final send = Completer<void>();
        final oldLeg = Completer<void>();
        final media = _ReconnectRelayMedia()
          ..liveDirectAdmission = false
          ..firstAttempt = relay;
        final svc = CallService(
          wire,
          media: media,
          now: () => clock.now(),
          localAllowsP2P: (_) async => true,
          peerReachableForP2P: (_) async => true,
          networkAttachments: network.stream,
          overlaySessionAdmissions: admissions.stream,
        )..start();
        try {
          wire.onCallSignal!(
            peer,
            const CallSignal(
              callId: callId,
              type: CallSignalType.offer,
              media: CallMedia(audio: true),
              posture: CallPosture.direct,
              transport: CallTransportProposal(CallTransportKind.p2p),
            ),
          );
          unawaited(svc.accept());
          async.flushMicrotasks();
          expect(svc.current?.transport, CallTransportKind.p2p);
          media.rxAt = clock.now();
          wire.sent.clear();
          wire.sendGate = send;
          wire.rejectedHealthCompletion = oldLeg;

          network.add(NetworkAttachment.cellular);
          async.flushMicrotasks();
          expect(media.switches, [CallTransportKind.relay]);
          admissions.add(null);
          async.flushMicrotasks();
          expect(svc.current?.transport, CallTransportKind.p2p);
          expect(wire.sent, isEmpty);

          relay.complete(true);
          async.flushMicrotasks();
          expect(svc.current?.transport, CallTransportKind.relay);
          send.complete();
          async.flushMicrotasks();

          final health = wire.sent.where((s) => s.type == CallSignalType.health);
          expect(health, hasLength(1));
          expect(health.single.transport?.kind, CallTransportKind.relay);
            expect(health.single.relayRecoverySuggested, isFalse);
          oldLeg.complete();
          admissions.add(null);
          async.flushMicrotasks();
          expect(health, hasLength(1));
        } finally {
          if (!relay.isCompleted) relay.complete(false);
          if (!send.isCompleted) send.complete();
          if (!oldLeg.isCompleted) oldLeg.complete();
          svc.dispose();
          unawaited(network.close());
          unawaited(admissions.close());
          async.flushMicrotasks();
        }
      });
    });

    for (final retireBy in ['nothing', 'next network', 'hangup', 'deadline']) {
      test('queued handover health checks the call and network ($retireBy)', () {
        fakeAsync((async) {
          const callId = 'queued-handover-health';
          final wire = _FakeMessaging();
          final media = _SnapshotMedia()
            ..openedTransport = CallTransportKind.relay;
          final network = StreamController<NetworkAttachment>(sync: true);
          final admissions = StreamController<void>(sync: true);
          var generation = 0;
          final svc = CallService(
            wire,
            media: media,
            now: () => clock.now(),
            networkAttachments: network.stream,
            overlaySessionAdmissions: admissions.stream,
            readNetworkChangeGeneration: () => generation,
          )..start();
          try {
            wire.onCallSignal!(peer, offer(callId));
            unawaited(svc.accept());
            async.flushMicrotasks();
            expect(svc.current?.status, CallStatus.active);
            wire.sent.clear();

            final waiting = Completer<void>();
            wire.sendGate = waiting;
            final signalTime = clock.now().millisecondsSinceEpoch;
            generation++;
            network.add(NetworkAttachment.cellular);
            admissions.add(null);
            async.flushMicrotasks();
            expect(wire.sent, isEmpty);

            if (retireBy == 'next network') generation++;
            if (retireBy == 'hangup') unawaited(svc.hangup());
            if (retireBy == 'deadline') {
              async.elapse(kCallLivenessTimeout - kCallHeartbeatInterval);
              wire.onCallSignal!(
                peer,
                const CallSignal(callId: callId, type: CallSignalType.health),
              );
              async.elapse(kCallHeartbeatInterval);
              expect(svc.current?.status, CallStatus.active);
            }
            waiting.complete();
            async.flushMicrotasks();
            expect(
              wire.sent.where(
                (signal) =>
                    signal.type == CallSignalType.health &&
                    signal.sentAtMs == signalTime,
              ),
              hasLength(retireBy == 'nothing' ? 1 : 0),
            );
            if (retireBy == 'hangup') {
              expect(
                wire.sent.where((signal) => signal.type == CallSignalType.end),
                hasLength(1),
              );
            }
          } finally {
            svc.dispose();
            unawaited(network.close());
            unawaited(admissions.close());
            async.flushMicrotasks();
          }
        });
      });
    }

    for (final (lateStamp, keepsCall) in [
      (100, false),
      (101, false),
      (102, true),
      (99, true),
    ]) {
      test('peer health renews liveness once per timestamp ($lateStamp)', () {
        fakeAsync((async) {
          const callId = 'health-arrives-on-two-lanes';
          final t = snapshotCall(async, callId, () async => null);
          void health(int stamp) => t.wire.onCallSignal!(
            peer,
            CallSignal(
              callId: callId,
              type: CallSignalType.health,
              sentAtMs: stamp,
            ),
          );

          try {
            health(100);
            health(101);
            async.elapse(kCallLivenessTimeout);
            expect(t.svc.current?.status, CallStatus.active);
            health(lateStamp);
            async.elapse(kCallHeartbeatInterval);
            if (keepsCall) {
              expect(t.svc.current?.status, CallStatus.active);
            } else {
              expect(t.svc.current, isNull);
              expect(
                t.wire.sent
                    .where((signal) => signal.type == CallSignalType.end)
                    .single
                    .reason,
                CallEndReason.timeout,
              );
            }
          } finally {
            t.svc.dispose();
            async.flushMicrotasks();
          }
        });
      });
    }

    test(
      'native liveness rechecks a signal received while its snapshot waits',
      () {
        fakeAsync((async) {
          final gate = Completer<DateTime?>();
          final t = snapshotCall(
            async,
            'signal-during-snapshot',
            () => gate.future,
          );
          try {
            async.elapse(const Duration(seconds: 25));
            async.flushMicrotasks();
            expect(t.media.snapshotReads, 1);
            expect(t.svc.current?.status, CallStatus.active);
            t.wire.onCallSignal!(
              peer,
              CallSignal(
                callId: 'signal-during-snapshot',
                type: CallSignalType.health,
              ),
            );
            gate.complete(null);
            async.flushMicrotasks();
            expect(t.svc.current?.status, CallStatus.active);
          } finally {
            t.svc.dispose();
            async.flushMicrotasks();
          }
        });
      },
    );

    test('native liveness bounds a snapshot that never completes', () {
      fakeAsync((async) {
        final gate = Completer<DateTime?>();
        final t = snapshotCall(async, 'snapshot-timeout', () => gate.future);
        try {
          async.elapse(const Duration(seconds: 25));
          async.flushMicrotasks();
          expect(t.media.snapshotReads, 1);
          expect(t.svc.current?.status, CallStatus.active);
          async.elapse(const Duration(seconds: 2));
          async.flushMicrotasks();
          expect(t.svc.current, isNull);
          gate.complete(clock.now());
          async.flushMicrotasks();
          expect(
            t.svc.current,
            isNull,
            reason: 'late reads cannot revive a call',
          );
        } finally {
          t.svc.dispose();
          async.flushMicrotasks();
        }
      });
    });

    for (final notifyNode in [false, true]) {
      test('native liveness rechecks after a network change ($notifyNode)', () {
        fakeAsync((async) {
          final gate = Completer<DateTime?>();
          final network = StreamController<NetworkAttachment>(sync: true);
          var generation = 0;
          final t = snapshotCall(
            async,
            'network-during-liveness',
            () => gate.future,
            attachments: network.stream,
            readNetworkChangeGeneration: () => generation,
          );
          try {
            async.elapse(kCallLivenessTimeout + kCallHeartbeatInterval);
            expect(t.media.snapshotReads, 1);
            if (notifyNode) {
              network.add(NetworkAttachment.cellular);
            } else {
              generation++;
            }
            t.media.readSnapshot = () async => clock.now();
            gate.complete(null);
            async.flushMicrotasks();
            expect(t.svc.current?.status, CallStatus.active);
            expect(t.media.snapshotReads, 2);
            expect(
              t.wire.sent.where((signal) => signal.type == CallSignalType.end),
              isEmpty,
            );
          } finally {
            t.svc.dispose();
            unawaited(network.close());
            async.flushMicrotasks();
          }
        });
      });
    }

    test('native liveness bounds retries during repeated network changes', () {
      fakeAsync((async) {
        final initial = Completer<DateTime?>();
        final replacement = Completer<DateTime?>();
        var generation = 0;
        final t = snapshotCall(
          async,
          'network-flaps-during-liveness',
          () => initial.future,
          readNetworkChangeGeneration: () => generation,
        );
        try {
          async.elapse(kCallLivenessTimeout + kCallHeartbeatInterval);
          expect(t.media.snapshotReads, 1);
          generation++;
          t.media.readSnapshot = () => replacement.future;
          initial.complete(null);
          async.flushMicrotasks();
          expect(t.media.snapshotReads, 2);
          expect(t.svc.current?.status, CallStatus.active);

          generation++;
          async.elapse(kCallLivenessSnapshotTimeout);
          expect(t.media.snapshotReads, 2);
          expect(t.svc.current, isNull);
          expect(
            t.wire.sent
                .where((signal) => signal.type == CallSignalType.end)
                .single
                .reason,
            CallEndReason.timeout,
          );
        } finally {
          t.svc.dispose();
          async.flushMicrotasks();
        }
      });
    });

    for (final (relayResponds, handover) in [
      (true, 'none'),
      (false, 'none'),
      (true, 'admission first'),
      (false, 'admission first'),
      (true, 'admission later'),
      (true, 'already deferred'),
      (false, 'offline'),
    ]) {
      test(
        'native liveness awaits relay qualification '
        '(response=$relayResponds, handover=$handover)',
        () {
          fakeAsync((async) {
            const callId = 'relay-qualifying-at-liveness-deadline';
            final gate = Completer<bool>();
            final network = StreamController<NetworkAttachment>(sync: true);
            final admissions = StreamController<void>(sync: true);
            final wire = _FakeMessaging();
            final media = _ReconnectRelayMedia()
              ..liveDirectAdmission = true
              ..firstAttempt = gate;
            media.readSnapshot = () async =>
                media.activeTransport == CallTransportKind.relay
                ? clock.now()
                : null;
            final svc = CallService(
              wire,
              media: media,
              now: () => clock.now(),
              localAllowsP2P: (_) async => true,
              peerReachableForP2P: (_) async => true,
              networkAttachments: network.stream,
              overlaySessionAdmissions: admissions.stream,
            )..start();
            try {
              wire.onCallSignal!(
                peer,
                offer(callId).copyWith(
                  transport: const CallTransportProposal(CallTransportKind.p2p),
                ),
              );
              unawaited(svc.accept());
              async.flushMicrotasks();
              expect(svc.current?.transport, CallTransportKind.p2p);
              wire.onCallSignal!(
                peer,
                const CallSignal(
                  callId: callId,
                  type: CallSignalType.health,
                  capture: CallMedia(),
                ),
              );
              final firstSilenceCheck =
                  kCallLivenessTimeout + kCallHeartbeatInterval;
              const tick = Duration(seconds: 1);
              async.elapse(firstSilenceCheck - tick * 2);
              media.liveDirectAdmission = false;
              async.elapse(tick);
              expect(media.switches, [CallTransportKind.relay]);
              expect(svc.current?.transport, CallTransportKind.p2p);

              if (handover == 'already deferred') {
                network.add(NetworkAttachment.cellular);
                gate.complete(false);
                async.flushMicrotasks();
                expect(media.switches, hasLength(1));
              }
              async.elapse(tick);
              expect(svc.current?.status, CallStatus.active);
              expect(media.snapshotReads, 1);
              final ends = wire.sent.where((s) => s.type == CallSignalType.end);
              expect(ends, isEmpty);
              var candidate = gate;
              var elapsed = tick;
              if (handover != 'none') {
                async.elapse(tick);
                elapsed += tick;
                candidate = Completer<bool>();
                media.nextAttempt = candidate;
                if (handover != 'already deferred') {
                  network.add(
                    handover == 'offline'
                        ? NetworkAttachment.offline
                        : NetworkAttachment.cellular,
                  );
                  if (handover == 'admission first') admissions.add(null);
                  gate.complete(false);
                  async.flushMicrotasks();
                }
                if (handover == 'admission later' ||
                    handover == 'already deferred') {
                  expect(media.switches, hasLength(1));
                  expect(svc.current?.status, CallStatus.active);
                  async.elapse(tick);
                  elapsed += tick;
                  admissions.add(null);
                  async.flushMicrotasks();
                }
                expect(
                  media.switches,
                  hasLength(handover == 'offline' ? 1 : 2),
                );
                expect(svc.current?.status, CallStatus.active);
                expect(ends, isEmpty);
              }
              if (relayResponds) {
                candidate.complete(true);
                async.flushMicrotasks();
                expect(svc.current?.transport, CallTransportKind.relay);
                expect(svc.current?.callId, callId);
                expect(ends, isEmpty);
              } else {
                const lastStep = Duration(milliseconds: 1);
                async.elapse(kCallMediaStartTimeout - elapsed - lastStep);
                expect(svc.current?.status, CallStatus.active);
                async.elapse(lastStep);
                expect(svc.current, isNull);
                expect(ends.single.reason, CallEndReason.timeout);
                candidate.complete(false);
                async.flushMicrotasks();
                expect(svc.current, isNull);
                expect(ends, hasLength(1));
              }
              expect(media.snapshotReads, 2);
            } finally {
              svc.dispose();
              unawaited(network.close());
              unawaited(admissions.close());
              async.flushMicrotasks();
            }
          });
        },
      );
    }

    test('native liveness old snapshot cannot end a replacement call', () {
      fakeAsync((async) {
        final gate = Completer<DateTime?>();
        final t = snapshotCall(async, 'old-snapshot', () => gate.future);
        try {
          async.elapse(const Duration(seconds: 25));
          async.flushMicrotasks();
          expect(t.media.snapshotReads, 1);
          t.svc.hangup();
          async.flushMicrotasks();
          t.wire.onCallSignal!(peer, offer('replacement-snapshot'));
          t.svc.accept();
          async.flushMicrotasks();
          expect(t.svc.current?.callId, 'replacement-snapshot');
          gate.complete(null);
          async.flushMicrotasks();
          expect(t.svc.current?.callId, 'replacement-snapshot');
          expect(t.svc.current?.status, CallStatus.active);
        } finally {
          t.svc.dispose();
          async.flushMicrotasks();
        }
      });
    });

    test('fresh growing audio buffer reports before the five-second beat', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        final media = _FakeMedia()
          ..playout = const CallAudioPlayoutFeedback(
            sequence: 1,
            delayMs: 80,
            currentDelayMs: 80,
            bufferGrowing: false,
          );
        final svc = CallService(fake, now: () => clock.now(), media: media)
          ..start();
        fake.onCallSignal!(
          peer,
          CallSignal(
            callId: 'urgent-playout',
            type: CallSignalType.offer,
            media: const CallMedia(audio: true),
            posture: CallPosture.direct,
            protocolVersion: kCallSignalProtocolVersion,
          ),
        );
        svc.accept();
        async.flushMicrotasks();
        expect(svc.current?.status, CallStatus.active);
        fake.sent.clear();
        async.elapse(const Duration(seconds: 1));
        expect(
          fake.sent,
          isEmpty,
          reason: 'healthy audio retains normal cadence',
        );
        media.playout = const CallAudioPlayoutFeedback(
          sequence: 2,
          delayMs: 170,
          currentDelayMs: 170,
          bufferGrowing: true,
        );
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(fake.sent, hasLength(1));
        expect(fake.sent.single.type, CallSignalType.health);
        expect(fake.sent.single.audioPlayout?.sequence, 2);
        expect(fake.sent.single.audioPlayout?.bufferGrowing, isTrue);
        async.elapse(const Duration(seconds: 1));
        expect(
          fake.sent,
          hasLength(1),
          reason: 'cached samples are not resent',
        );
        media.playout = const CallAudioPlayoutFeedback(
          sequence: 3,
          delayMs: 310,
          currentDelayMs: 310,
          bufferGrowing: false,
        );
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(
          fake.sent,
          hasLength(2),
          reason: 'the hard ceiling is also urgent',
        );
        media.playout = const CallAudioPlayoutFeedback(
          sequence: 4,
          delayMs: 310,
          currentDelayMs: 310,
          bufferGrowing: false,
        );
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(fake.sent, hasLength(3), reason: 'coalesce the periodic beat');
        media.playout = const CallAudioPlayoutFeedback(
          sequence: 5,
          delayMs: 310,
          currentDelayMs: 80,
          bufferGrowing: false,
        );
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(fake.sent, hasLength(4), reason: 'clear pressure promptly too');
        expect(fake.sent.last.audioPlayout?.currentDelayMs, 80);
        expect(fake.sent.last.audioPlayout?.bufferGrowing, isFalse);
        media.playout = const CallAudioPlayoutFeedback(
          sequence: 6,
          delayMs: 80,
          currentDelayMs: 80,
          bufferGrowing: false,
        );
        async.elapse(const Duration(seconds: 1));
        expect(
          fake.sent,
          hasLength(4),
          reason: 'healthy samples stay periodic',
        );
        svc.dispose();
        async.elapse(const Duration(seconds: 6));
        expect(fake.sent, hasLength(4), reason: 'no feedback after disposal');
      });
    });

    test('reports upstream pressure until the receive reserve fills', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        final media = _FakeMedia();
        final svc = CallService(fake, now: () => clock.now(), media: media)
          ..start();
        try {
          fake.onCallSignal!(
            peer,
            const CallSignal(
              callId: 'upstream-playout',
              type: CallSignalType.offer,
              media: CallMedia(audio: true),
              posture: CallPosture.direct,
              protocolVersion: kCallSignalProtocolVersion,
            ),
          );
          svc.accept();
          async.flushMicrotasks();
          expect(svc.current?.status, CallStatus.active);
          fake.sent.clear();

          void sample(int sequence, int bufferedMs) {
            media.playout = CallAudioPlayoutFeedback(
              sequence: sequence,
              delayMs: 520,
              currentDelayMs: 520,
              bufferedDelayMs: bufferedMs,
              targetDelayMs: 500,
              bufferGrowing: false,
            );
            async.elapse(const Duration(seconds: 1));
          }

          sample(1, 205);
          expect(fake.sent, hasLength(1));
          expect(fake.sent.single.audioPlayout?.bufferedDelayMs, 205);
          sample(2, 520);
          expect(fake.sent, hasLength(2));
          expect(fake.sent.last.audioPlayout?.sequence, 2);
          expect(fake.sent.last.audioPlayout?.bufferedDelayMs, 520);
          sample(3, 520);
          expect(fake.sent, hasLength(2));
          sample(4, 520);
          expect(fake.sent, hasLength(3));
          expect(fake.sent.last.audioPlayout?.sequence, 4);
        } finally {
          svc.dispose();
          async.flushMicrotasks();
        }
      });
    });

    for (final (endsBeforeSend, announcesBeforeSend) in [
      (false, false),
      (true, false),
      (false, true),
    ]) {
      test('defers an urgent audio report near the rate limit '
          '(ends=$endsBeforeSend, announces=$announcesBeforeSend)', () {
        fakeAsync((async) {
          final fake = _FakeMessaging();
          final media = _FakeMedia();
          final svc = CallService(fake, now: () => clock.now(), media: media)
            ..start();
          try {
            fake.onCallSignal!(
              peer,
              CallSignal(
                callId: 'urgent-window',
                type: CallSignalType.offer,
                media: const CallMedia(audio: true),
                posture: CallPosture.direct,
                protocolVersion: kCallSignalProtocolVersion,
              ),
            );
            svc.accept();
            async.flushMicrotasks();
            expect(svc.current?.status, CallStatus.active);

            async.elapse(const Duration(milliseconds: 5));
            media.playout = const CallAudioPlayoutFeedback(
              sequence: 1,
              delayMs: 723,
              currentDelayMs: 723,
              targetDelayMs: 500,
              bufferGrowing: false,
            );
            svc.setMicEnabled(false);
            async.flushMicrotasks();
            expect(fake.sent.last.audioPlayout?.sequence, 1);
            fake.sent.clear();
            CallAudioPlayoutFeedback recovered(int sequence) =>
                CallAudioPlayoutFeedback(
                  sequence: sequence,
                  delayMs: 723,
                  currentDelayMs: 683,
                  targetDelayMs: 500,
                  bufferGrowing: false,
                );
            media.playout = recovered(2);
            async.elapse(const Duration(milliseconds: 995));
            expect(fake.sent, isEmpty);
            media.playout = recovered(3);
            async.elapse(const Duration(milliseconds: 4));
            expect(fake.sent, isEmpty);
            if (endsBeforeSend) {
              svc.hangup();
              async.flushMicrotasks();
              fake.sent.clear();
            } else if (announcesBeforeSend) {
              svc.setMicEnabled(true);
              async.flushMicrotasks();
              expect(fake.sent.single.audioPlayout?.sequence, 3);
              fake.sent.clear();
            }
            async.elapse(const Duration(milliseconds: 1));
            if (endsBeforeSend || announcesBeforeSend) {
              expect(fake.sent, isEmpty);
            } else {
              expect(fake.sent.single.audioPlayout?.sequence, 3);
              expect(fake.sent.single.audioPlayout?.currentDelayMs, 683);
              async.elapse(const Duration(seconds: 1));
              expect(fake.sent, hasLength(1));
            }
          } finally {
            svc.dispose();
            async.flushMicrotasks();
          }
        });
      });
    }

    for (final announceBeforeDeadline in [false, true]) {
      test('confirms a filled reserve at its deadline between watchdog ticks '
          '(announcement=$announceBeforeDeadline)', () {
        fakeAsync((async) {
          final fake = _FakeMessaging();
          final media = _FakeMedia();
          final svc = CallService(fake, now: () => clock.now(), media: media)
            ..start();
          CallAudioPlayoutFeedback playout(int sequence, int current) =>
              CallAudioPlayoutFeedback(
                sequence: sequence,
                delayMs: 723,
                currentDelayMs: current,
                targetDelayMs: 500,
                bufferGrowing: false,
              );
          try {
            fake.onCallSignal!(
              peer,
              CallSignal(
                callId: 'reserve-confirmation-deadline',
                type: CallSignalType.offer,
                media: const CallMedia(audio: true),
                posture: CallPosture.direct,
                protocolVersion: kCallSignalProtocolVersion,
              ),
            );
            svc.accept();
            async.flushMicrotasks();
            expect(svc.current?.status, CallStatus.active);

            async.elapse(const Duration(milliseconds: 5));
            media.playout = playout(1, 723);
            svc.setMicEnabled(false);
            async.flushMicrotasks();
            expect(fake.sent.last.audioPlayout?.sequence, 1);
            fake.sent.clear();

            media.playout = playout(2, 683);
            async.elapse(const Duration(seconds: 1));
            expect(fake.sent.single.audioPlayout?.sequence, 2);
            fake.sent.clear();

            media.playout = playout(3, 683);
            async.elapse(const Duration(milliseconds: 1999));
            expect(fake.sent, isEmpty);
            // The due-time check uses the latest sample, even if it arrived
            // just after the last watchdog tick.
            media.playout = playout(4, 681);
            if (announceBeforeDeadline) {
              svc.setMicEnabled(true);
              async.flushMicrotasks();
              expect(fake.sent.single.audioPlayout?.sequence, 4);
              fake.sent.clear();
            }
            async.elapse(const Duration(milliseconds: 1));
            if (announceBeforeDeadline) {
              expect(fake.sent, isEmpty);
            } else {
              expect(fake.sent.single.audioPlayout?.sequence, 4);
              expect(fake.sent.single.audioPlayout?.currentDelayMs, 681);
              fake.sent.clear();
            }
            media.playout = playout(5, 679);
            async.elapse(const Duration(seconds: 1));
            expect(fake.sent, isEmpty);
          } finally {
            svc.dispose();
            async.flushMicrotasks();
          }
        });
      });
    }

    test('compact health retains bootstrap, backstop and repair signaling', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        final media = _CompactHealthMedia()
          ..openedTransport = CallTransportKind.relay;
        final svc = CallService(fake, now: () => clock.now(), media: media)
          ..start();
        fake.onCallSignal!(peer, offer('compact-health'));
        svc.accept();
        async.flushMicrotasks();
        fake.sent.clear();
        void tick() {
          fake.onCallSignal!(
            peer,
            CallSignal(
              callId: 'compact-health',
              type: CallSignalType.health,
              compactHealthReady: true,
              sentAtMs: clock.now().millisecondsSinceEpoch,
            ),
          );
          media.rxAt = clock.now();
          async.elapse(kCallHeartbeatInterval);
          async.flushMicrotasks();
        }

        tick(); // regular bootstrap
        expect(fake.sent.length, 1);
        expect(media.compact, isEmpty);
        tick();
        expect(fake.sent.length, 1);
        expect(media.compact.length, 1);
        expect(media.compact.single.capture, isNotNull);
        media.admit = false; // bounded queue admission failed
        tick();
        expect(fake.sent.length, 2);
        media.admit = true;
        for (var i = 0; i < 6; i++) {
          tick();
        }
        expect(
          fake.sent.length,
          3,
          reason: 'regular signaling every 30 seconds',
        );
        async.elapse(kCallMediaRepairAfter + kCallHeartbeatInterval);
        async.flushMicrotasks();
        expect(
          fake.sent.last.mediaRepairRequested,
          isTrue,
          reason: 'repair cannot depend on the broken media carrier',
        );
        final compactCount = media.compact.length;
        svc.hangup();
        async.flushMicrotasks();
        expect(fake.sent.last.type, CallSignalType.end);
        expect(media.compact.length, compactCount);
        svc.dispose();
      });
    });

    test('committed relay can notify a direct peer while messaging is stalled',
        () {
      fakeAsync((async) {
        final phoneMedia = _CompactHealthMedia();
        final macMedia = _CompactHealthMedia();
        final phoneWire = _FakeMessaging();
        final macWire = _FakeMessaging();
        CallService start(_FakeMessaging wire, _CompactHealthMedia media) {
          final service = CallService(
            wire,
            now: () => clock.now(),
            media: media,
            localAllowsP2P: (_) async => true,
            peerReachableForP2P: (_) async => true,
          )..start();
          wire.onCallSignal!(
            peer,
            const CallSignal(
              callId: 'committed-relay',
              type: CallSignalType.offer,
              media: CallMedia(audio: true),
              posture: CallPosture.direct,
              transport: CallTransportProposal(CallTransportKind.p2p),
            ),
          );
          service.accept();
          return service;
        }

        final phone = start(phoneWire, phoneMedia);
        final mac = start(macWire, macMedia);
        async.flushMicrotasks();
        expect(phone.current?.transport, CallTransportKind.p2p);
        expect(mac.current?.transport, CallTransportKind.p2p);
        phoneWire.sent.clear();
        macWire.sent.clear();
        const relay = CallTransportProposal(CallTransportKind.relay);
        final now = clock.now().millisecondsSinceEpoch;
        for (final invalid in [
          const CallSignal(
            callId: 'committed-relay',
            type: CallSignalType.end,
          ),
          const CallSignal(
            callId: 'committed-relay',
            type: CallSignalType.transportInfo,
            transport: relay,
            p2pUpgradeAllowed: true,
          ),
          CallSignal(
            callId: 'other-call',
            type: CallSignalType.transportInfo,
            transport: relay,
            p2pUpgradeAllowed: true,
            sentAtMs: now,
          ),
          CallSignal(
            callId: 'committed-relay',
            type: CallSignalType.transportInfo,
            transport: relay,
            capture: const CallMedia(audio: false),
            p2pUpgradeAllowed: true,
            sentAtMs: now,
          ),
        ]) {
          macMedia.health.add(invalid);
          async.flushMicrotasks();
          expect(mac.current?.transport, CallTransportKind.p2p);
          expect(macMedia.switches, isEmpty);
        }
        // The messaging copies are recorded but never delivered. Only the
        // call-key-authenticated carrier reaches the remote service.
        phoneMedia.onCompact = macMedia.health.add;
        phone.requestRelayRecoveryForDiagnostics();
        async.flushMicrotasks();
        expect(phone.current?.transport, CallTransportKind.relay);
        expect(mac.current?.transport, CallTransportKind.relay);
        expect(phoneMedia.compact.single.type, CallSignalType.transportInfo);
        expect(phoneWire.sent.single.type, CallSignalType.transportInfo);
        expect(macMedia.switches, [CallTransportKind.relay]);

        // A later durable copy of the same timestamp cannot retrigger a move.
        macWire.onCallSignal!(peer, phoneWire.sent.single);
        async.flushMicrotasks();
        expect(macMedia.switches, [CallTransportKind.relay]);
        phone.dispose();
        mac.dispose();
        phoneMedia.health.close();
        macMedia.health.close();
        async.flushMicrotasks();
      });
    });

    test('compact receiver readiness must be fresh and can be withdrawn', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        final media = _CompactHealthMedia();
        final svc = CallService(fake, now: () => clock.now(), media: media)
          ..start();
        fake.onCallSignal!(peer, offer('compact-ready'));
        svc.accept();
        async.flushMicrotasks();
        fake.sent.clear();
        void tick() {
          media.rxAt = clock.now();
          async.elapse(kCallHeartbeatInterval);
          async.flushMicrotasks();
        }

        void readiness(bool ready, {int staleSeconds = 0}) {
          fake.onCallSignal!(
            peer,
            CallSignal(
              callId: 'compact-ready',
              type: CallSignalType.health,
              compactHealthReady: ready,
              sentAtMs: clock
                  .now()
                  .subtract(Duration(seconds: staleSeconds))
                  .millisecondsSinceEpoch,
            ),
          );
        }

        tick();
        tick();
        expect(media.compact, isEmpty, reason: 'v7 alone is insufficient');
        expect(
          CallSignal.tryDecode(fake.sent.last.encode())!.compactHealthReady,
          isTrue,
        );
        readiness(true);
        tick();
        expect(media.compact.length, 1);
        readiness(false);
        tick();
        expect(media.compact.length, 1, reason: 'peer withdrew its receiver');
        readiness(true, staleSeconds: 10);
        tick();
        expect(
          media.compact.length,
          1,
          reason: 'old readiness cannot replace withdrawal',
        );
        readiness(true);
        tick();
        expect(media.compact.length, 2);
        tick();
        expect(
          media.compact.length,
          2,
          reason: 'readiness expired after two beats',
        );
        svc.dispose();
      });
    });

    test('compact mute updates the peer before the direct audio watchdog', () {
      fakeAsync((async) {
        final messages = [_FakeMessaging(), _FakeMessaging()];
        final media = [
          _CompactHealthMedia()..audioTelemetry = true,
          _CompactHealthMedia()..audioTelemetry = true,
        ];
        final services = [
          for (var i = 0; i < 2; i++)
            CallService(
              messages[i],
              now: () => clock.now(),
              media: media[i],
              localAllowsP2P: (_) async => true,
              peerReachableForP2P: (_) async => true,
            )..start(),
        ];
        for (var i = 0; i < 2; i++) {
          messages[i].onCallSignal!(
            peer,
            const CallSignal(
              callId: 'compact-mute-watchdog',
              type: CallSignalType.offer,
              media: CallMedia(audio: true, video: true),
              posture: CallPosture.direct,
              transport: CallTransportProposal(CallTransportKind.p2p),
            ),
          );
          services[i].accept();
        }
        async.flushMicrotasks();
        CallSignal receivePosture(int i) {
          final signal = CallSignal(
            callId: 'compact-mute-watchdog',
            type: CallSignalType.health,
            compactHealthReady: true,
            capture: const CallMedia(audio: true, video: true),
            sentAtMs: clock.now().millisecondsSinceEpoch,
          );
          messages[i].onCallSignal!(peer, signal);
          return signal;
        }

        for (var i = 0; i < 2; i++) {
          expect(services[i].current!.transport, CallTransportKind.p2p);
          receivePosture(i);
          media[i].onCompact = (signal) =>
              media[1 - i].health.add(CallSignal.tryDecode(signal.encode())!);
        }
        // Establish ordinary heartbeat/readiness and actual audio first.
        for (var n = 0; n < 12; n++) {
          for (final m in media) {
            m.rxAt = m.audioRxAt = clock.now();
          }
          async.elapse(const Duration(milliseconds: 500));
          async.flushMicrotasks();
        }
        final olderPostures = [for (var i = 0; i < 2; i++) receivePosture(i)];
        async.elapse(const Duration(milliseconds: 1));
        for (var i = 0; i < 2; i++) {
          services[i].setMicEnabled(false);
          async.flushMicrotasks();
        }
        // Video/control continue, but intentionally muted audio stops. The
        // next five-second heartbeat must not be needed to cancel a three-
        // second audio outage verdict.
        for (var n = 0; n < 8; n++) {
          for (final m in media) {
            m.rxAt = clock.now();
          }
          async.elapse(const Duration(milliseconds: 500));
          async.flushMicrotasks();
        }
        for (var i = 0; i < 2; i++) {
          expect(media[i].compact, isNotEmpty);
          expect(media[i].switches, isEmpty);
          expect(services[i].current!.peerCapture!.audio, isFalse);
        }
        // Replayed earlier heartbeats cannot undo the newer mute.
        for (var i = 0; i < 2; i++) {
          media[i].health.add(olderPostures[i]);
        }
        async.flushMicrotasks();
        expect(services.every((s) => !s.current!.peerCapture!.audio), isTrue);
        // A real unmute is visible immediately and keeps actual subsequent
        // audio loss eligible for the existing early recovery.
        async.elapse(const Duration(milliseconds: 1));
        services[0].setMicEnabled(true);
        async.flushMicrotasks();
        expect(services[1].current!.peerCapture!.audio, isTrue);
        media[1].audioRxAt = clock.now();
        for (var n = 0; n < 8; n++) {
          for (final m in media) {
            m.rxAt = clock.now();
          }
          async.elapse(const Duration(milliseconds: 500));
          async.flushMicrotasks();
        }
        expect(media[1].switches, [CallTransportKind.relay]);
        for (final s in services) {
          s.dispose();
        }
        async.flushMicrotasks();
      });
    });

    test('compact health is not used with an older peer', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        final media = _CompactHealthMedia();
        final svc = CallService(fake, now: () => clock.now(), media: media)
          ..start();
        fake.onCallSignal!(
          peer,
          CallSignal(
            callId: 'old-compact',
            type: CallSignalType.offer,
            media: const CallMedia(audio: true),
            posture: CallPosture.direct,
            protocolVersion: 6,
          ),
        );
        svc.accept();
        async.flushMicrotasks();
        fake.sent.clear();
        for (var i = 0; i < 3; i++) {
          media.rxAt = clock.now();
          async.elapse(kCallHeartbeatInterval);
          async.flushMicrotasks();
        }
        expect(fake.sent.length, 3);
        expect(media.compact, isEmpty);
        svc.dispose();
      });
    });

    test(
      'compact inbound accepts only current negotiated health, then detaches',
      () {
        fakeAsync((async) {
          final fake = _FakeMessaging();
          final media = _CompactHealthMedia();
          final svc = CallService(fake, now: () => clock.now(), media: media)
            ..start();
          fake.onCallSignal!(peer, offer('compact-inbound'));
          svc.accept();
          async.flushMicrotasks();
          final health = CallSignal(
            callId: 'compact-inbound',
            type: CallSignalType.health,
            sentAtMs: clock.now().millisecondsSinceEpoch,
            capture: const CallMedia(audio: false),
            audioPlayout: const CallAudioPlayoutFeedback(
              sequence: 1,
              delayMs: 100,
            ),
          );
          for (final signal in [
            health.copyWith(type: CallSignalType.end),
            CallSignal(
              callId: 'other-call',
              type: CallSignalType.health,
              audioPlayout: health.audioPlayout,
            ),
            health.copyWith(onBehalfOf: peer.hex),
            health.copyWith(mediaKey: 'unexpected'),
            health.copyWith(reason: CallEndReason.hangup),
            CallSignal(
              callId: health.callId,
              type: CallSignalType.health,
              protocolVersion: 6,
              audioPlayout: health.audioPlayout,
            ),
          ]) {
            media.health.add(signal);
          }
          async.flushMicrotasks();
          expect(media.peerPlayout, isEmpty);
          expect(svc.current?.status, CallStatus.active);
          media.health.add(health);
          async.flushMicrotasks();
          expect(media.peerPlayout.length, 1);
          expect(svc.current?.peerCapture?.audio, isFalse);
          svc.dispose();
          async.flushMicrotasks();
          media.health.add(health);
          async.flushMicrotasks();
          expect(media.peerPlayout.length, 1);
          expect(media.health.hasListener, isFalse);
        });
      },
    );

    for (final (counts, retryResult) in [
      (<int>[], null),
      ([3], null),
      ([0, 1], true),
      ([1, 2], true),
      ([1, 2], false),
    ]) {
      test('failed relay rebuild after overlay changes $counts: $retryResult', () {
        fakeAsync((async) {
          final fake = _FakeMessaging();
          final media = _RepairThenRelayMedia()
            ..openedTransport = CallTransportKind.relay
            ..repairSucceeds = false
            ..relayGate = Completer<bool>();
          final sessions = StreamController<int>();
          final svc = CallService(
            fake,
            now: () => clock.now(),
            media: media,
            overlaySessions: sessions.stream,
          )..start();
          const callId = 'relay-repair-reconnect';
          sessions.add(2);
          fake.onCallSignal!(peer, offer(callId));
          svc.accept();
          async.flushMicrotasks();
          expect(svc.current?.transport, CallTransportKind.relay);
          media.rxAt = clock.now();
          async.elapse(kCallMediaRepairAfter);
          expect(media.repairs, 1);
          expect(media.activeTransport, isNull);

          for (final count in counts) {
            sessions.add(count);
          }
          async.flushMicrotasks();
          expect(media.switches, isEmpty);
          media.cameraStopped.complete();
          async.flushMicrotasks();
          if (retryResult != null) {
            expect(svc.current?.status, CallStatus.active);
            expect(media.switches, [CallTransportKind.relay]);
            // A second reconnect cannot turn a failed retry into a loop.
            sessions.add(0);
            sessions.add(2);
            async.flushMicrotasks();
            media.relayGate!.complete(retryResult);
            async.flushMicrotasks();
          }
          final ended = fake.sent.where((s) => s.type == CallSignalType.end);
          if (retryResult == true) {
            expect(svc.current?.callId, callId);
            expect(svc.current?.status, CallStatus.active);
            expect(svc.current?.transport, CallTransportKind.relay);
            expect(ended, isEmpty);
          } else {
            expect(svc.current, isNull);
            expect(ended.single.reason, CallEndReason.error);
          }
          expect(media.repairs, 1);
          expect(media.switches.length, retryResult == null ? 0 : 1);
          svc.dispose();
          sessions.close();
          async.flushMicrotasks();
        });
      });
    }

    for (final outcome in [
      'admission after earlier handover',
      'admission',
      'admission after offline',
      'stale admission while offline',
      'admission before online notification',
      'superseded admission before online notification',
      'admission while network IPC is pending',
      'network IPC pending at deadline',
      'deadline',
      'hangup',
    ]) {
      test('failed relay rebuild during a local handover: $outcome', () {
        fakeAsync((async) {
          final wire = _FakeMessaging();
          final network = StreamController<NetworkAttachment>(sync: true);
          final admissions = StreamController<void>(sync: true);
          final media = _RepairThenRelayMedia()
            ..openedTransport = CallTransportKind.relay
            ..repairSucceeds = false
            ..relayGate = Completer<bool>();
          var networkChangeGeneration = 0;
          final svc = CallService(
            wire,
            now: () => clock.now(),
            media: media,
            networkAttachments: network.stream,
            readNetworkChangeGeneration: () => networkChangeGeneration,
            overlaySessionAdmissions: admissions.stream,
          )..start();
          const callId = 'relay-rebuild-before-admission';
          wire.onCallSignal!(peer, offer(callId));
          unawaited(svc.accept());
          async.flushMicrotasks();
          expect(svc.current?.transport, CallTransportKind.relay);
          media.rxAt = clock.now();
          final earlierHandover = outcome == 'admission after earlier handover';
          if (earlierHandover) network.add(NetworkAttachment.cellular);
          async.elapse(kCallMediaRepairAfter);
          expect(media.repairs, 1);
          expect(media.activeTransport, isNull);

          final staleAdmission = outcome == 'stale admission while offline';
          final earlyAdmission = outcome == 'admission before online notification';
          final supersededAdmission =
              outcome == 'superseded admission before online notification';
          final wentOffline =
              outcome == 'admission after offline' ||
              staleAdmission ||
              earlyAdmission ||
              supersededAdmission;
          final ipcPendingAtDeadline = outcome == 'network IPC pending at deadline';
          final ipcPending =
              outcome == 'admission while network IPC is pending' ||
              ipcPendingAtDeadline;
          if (ipcPending) {
            networkChangeGeneration++;
          } else if (!earlierHandover) {
            network.add(
              wentOffline ? NetworkAttachment.offline : NetworkAttachment.cellular,
            );
          }
          const repairTail = Duration(milliseconds: 250);
          async.elapse(repairTail);
          media.cameraStopped.complete();
          async.flushMicrotasks();
          expect(svc.current?.status, CallStatus.active);
          expect(media.switches, isEmpty);

          // Another repair request must not end the call or race the reopen.
          wire.onCallSignal!(
            peer,
            const CallSignal(
              callId: callId,
              type: CallSignalType.health,
              mediaRepairRequested: true,
            ),
          );
          async.flushMicrotasks();
          expect(media.repairs, 1);
          expect(svc.current?.status, CallStatus.active);
          if (earlierHandover) {
            wire.sent.clear();
            async.elapse(kCallHeartbeatInterval - repairTail);
            expect(
              wire.sent
                  .where((s) => s.type == CallSignalType.health)
                  .single
                  .mediaRepairRequested,
              isFalse,
            );
          } else {
            async.elapse(const Duration(seconds: 1));
          }

          if (outcome == 'hangup') unawaited(svc.hangup());
          if (outcome == 'deadline' || ipcPendingAtDeadline) {
            async.elapse(kCallRelayCandidateRetry);
          }
          if (staleAdmission || earlyAdmission || supersededAdmission) {
            if (!staleAdmission) networkChangeGeneration++;
            admissions.add(null);
            async.flushMicrotasks();
            expect(media.switches, isEmpty);
            expect(svc.current?.status, CallStatus.active);
          }
          if (supersededAdmission) networkChangeGeneration++;
          if (wentOffline) {
            network.add(NetworkAttachment.cellular);
            async.flushMicrotasks();
            if (!earlyAdmission) expect(media.switches, isEmpty);
          }
          if (!earlyAdmission) admissions.add(null);
          async.flushMicrotasks();
          if (earlierHandover || wentOffline || outcome == 'admission' ||
              (ipcPending && !ipcPendingAtDeadline)) {
            expect(media.switches, [CallTransportKind.relay]);
            admissions.add(null);
            media.relayGate!.complete(true);
            async.flushMicrotasks();
            expect(media.switches, [CallTransportKind.relay]);
            expect(svc.current?.callId, callId);
            expect(svc.current?.status, CallStatus.active);
            expect(svc.current?.transport, CallTransportKind.relay);
          } else {
            expect(media.switches, isEmpty);
            expect(svc.current, isNull);
            expect(
              wire.sent
                  .where((s) => s.type == CallSignalType.end)
                  .single
                  .reason,
              outcome == 'hangup' ? CallEndReason.hangup : CallEndReason.error,
            );
          }
          svc.dispose();
          unawaited(network.close());
          unawaited(admissions.close());
          async.flushMicrotasks();
        });
      });
    }

    for (final outcome in [
      'new admission',
      'admission during repair',
      'network changes before repair completes',
      'IPC confirms the admitted network',
      'network drops after admission',
      'superseded admission still expires',
      'deadline',
      'hangup',
    ]) {
      test('failed direct rebuild during a local handover: $outcome', () {
        fakeAsync((async) {
          final wire = _FakeMessaging();
          final network = StreamController<NetworkAttachment>(sync: true);
          final admissions = StreamController<void>(sync: true);
          final media = _RepairThenRelayMedia()
            ..openedTransport = CallTransportKind.p2p
            ..repairSucceeds = false
            ..liveDirectAdmission = false
            ..relayGate = Completer<bool>();
          final ipcConfirmed = outcome == 'IPC confirms the admitted network';
          var osGeneration = 0;
          final svc = CallService(
            wire,
            now: () => clock.now(),
            media: media,
            networkAttachments: network.stream,
            readNetworkChangeGeneration: ipcConfirmed
                ? () => osGeneration
                : null,
            overlaySessionAdmissions: admissions.stream,
            localAllowsP2P: (_) async => true,
            peerReachableForP2P: (_) async => true,
          )..start();
          const id = 'direct-rebuild-before-admission';
          try {
            wire.onCallSignal!(
              peer,
              offer(id).copyWith(
                transport: const CallTransportProposal(CallTransportKind.p2p),
              ),
            );
            unawaited(svc.accept());
            async.flushMicrotasks();
            expect(svc.current?.transport, CallTransportKind.p2p);
            wire.onCallSignal!(
              peer,
              const CallSignal(
                callId: id,
                type: CallSignalType.health,
                mediaRepairRequested: true,
              ),
            );
            async.flushMicrotasks();
            expect(media.repairs, 1);
            expect(media.activeTransport, isNull);

            final superseded =
                outcome == 'network changes before repair completes';
            final admittedEarly =
                outcome == 'admission during repair' || ipcConfirmed;
            if (ipcConfirmed) {
              osGeneration++;
            } else {
              network.add(
                admittedEarly || superseded
                    ? NetworkAttachment.cellular
                    : NetworkAttachment.offline,
              );
            }
            if (admittedEarly || superseded) admissions.add(null);
            if (ipcConfirmed) network.add(NetworkAttachment.cellular);
            if (superseded) network.add(NetworkAttachment.wifi);
            media.cameraStopped.complete();
            async.flushMicrotasks();
            expect(svc.current?.status, CallStatus.active);
            if (!admittedEarly) {
              expect(media.switches, isEmpty);
              if (!superseded) {
                // Ignore a delayed admission received while still offline.
                admissions.add(null);
                async.flushMicrotasks();
                expect(media.switches, isEmpty);
                network.add(NetworkAttachment.cellular);
              }
              async.elapse(const Duration(seconds: 1));
              expect(media.switches, isEmpty);
              expect(svc.current?.status, CallStatus.active);
              if (outcome == 'network drops after admission' ||
                  outcome == 'superseded admission still expires') {
                admissions.add(null);
                network.add(NetworkAttachment.offline);
                async.flushMicrotasks();
                expect(media.switches, isEmpty);
                expect(svc.current?.status, CallStatus.active);
                if (outcome == 'superseded admission still expires') {
                  const waited = Duration(seconds: 1);
                  const lastTick = Duration(milliseconds: 1);
                  async.elapse(kCallRelayCandidateRetry - waited - lastTick);
                  expect(svc.current?.status, CallStatus.active);
                  async.elapse(lastTick);
                  expect(svc.current, isNull);
                }
                network.add(NetworkAttachment.wifi);
              } else if (outcome == 'deadline') {
                async.elapse(kCallRelayCandidateRetry);
              } else if (outcome == 'hangup') {
                unawaited(svc.hangup());
              }
              admissions.add(null);
              async.flushMicrotasks();
            }
            final end = wire.sent.where((s) => s.type == CallSignalType.end);
            if (outcome == 'deadline' ||
                outcome == 'hangup' ||
                outcome == 'superseded admission still expires') {
              expect(svc.current, isNull);
              expect(media.switches, isEmpty);
              expect(
                end.single.reason,
                outcome == 'hangup' ? CallEndReason.hangup : CallEndReason.error,
              );
            } else {
              expect(media.switches, [CallTransportKind.relay]);
              expect(svc.current?.transport, CallTransportKind.p2p);
              media.relayGate!.complete(true);
              async.flushMicrotasks();
              expect(svc.current?.callId, id);
              expect(svc.current?.status, CallStatus.active);
              expect(svc.current?.transport, CallTransportKind.relay);
              expect(end, isEmpty);
            }
          } finally {
            svc.dispose();
            unawaited(network.close());
            unawaited(admissions.close());
            async.flushMicrotasks();
          }
        });
      });
    }

    for (final outcome in [
      'recovery',
      'expired repair',
      'stable network',
      'snapshot overlaps handover',
    ]) {
      test('liveness during local route repair: $outcome', () {
        fakeAsync((async) {
          final wire = _FakeMessaging();
          final network = StreamController<NetworkAttachment>(sync: true);
          final admissions = StreamController<void>(sync: true);
          final lateHandover = outcome == 'snapshot overlaps handover';
          final snapshot = Completer<DateTime?>();
          final media = _RepairThenRelayMedia()
            ..openedTransport = CallTransportKind.relay
            ..repairSucceeds = false
            ..readSnapshot = (() async => lateHandover ? snapshot.future : null);
          final svc = CallService(
            wire,
            now: () => clock.now(),
            media: media,
            networkAttachments: network.stream,
            overlaySessionAdmissions: admissions.stream,
          )..start();
          const callId = 'local-repair-crosses-liveness';
          try {
            wire.onCallSignal!(
              peer,
              offer(callId).copyWith(media: CallMedia(audio: true, video: true)),
            );
            unawaited(svc.accept());
            async.flushMicrotasks();
            expect(svc.current?.status, CallStatus.active);
            media.rxAt = clock.now();
            async.elapse(kCallMediaRepairAfter);
            expect(media.repairs, 1);
            expect(media.activeTransport, isNull);
            if (outcome != 'stable network' && !lateHandover) {
              network.add(NetworkAttachment.wifi);
              admissions.add(null);
            }

            final livenessTick = kCallLivenessTimeout + kCallHeartbeatInterval;
            wire.sent.clear();
            async.elapse(livenessTick - kCallMediaRepairAfter);
            if (lateHandover) {
              expect(media.snapshotReads, 1);
              network.add(NetworkAttachment.wifi);
              admissions.add(null);
              snapshot.complete(null);
              async.flushMicrotasks();
              expect(media.snapshotReads, 1);
            }
            final ends = wire.sent.where((s) => s.type == CallSignalType.end);
            if (outcome == 'stable network') {
              expect(svc.current, isNull);
              expect(ends.single.reason, CallEndReason.timeout);
              return;
            }
            expect(svc.current?.status, CallStatus.active);
            expect(ends, isEmpty);
            if (!lateHandover) {
              expect(wire.sent.any((s) => s.type == CallSignalType.health), isTrue);
            }
            expect(media.switches, isEmpty);

            if (outcome == 'expired repair') {
              final remaining =
                  kCallMediaRepairAfter + kCallVisualMediaStartTimeout -
                  livenessTick;
              async.elapse(remaining - kCallHeartbeatInterval);
              // A subsequent attachment change cannot extend this repair.
              network.add(NetworkAttachment.cellular);
              async.elapse(kCallHeartbeatInterval);
              expect(svc.current, isNull);
              expect(ends.single.reason, CallEndReason.timeout);
              return;
            }
            media.cameraStopped.complete();
            async.flushMicrotasks();
            expect(svc.current?.callId, callId);
            expect(svc.current?.status, CallStatus.active);
            expect(media.switches, [CallTransportKind.relay]);
            expect(media.activeTransport, CallTransportKind.relay);
            expect(ends, isEmpty);
          } finally {
            svc.dispose();
            if (!snapshot.isCompleted) snapshot.complete(null);
            if (!media.cameraStopped.isCompleted) media.cameraStopped.complete();
            unawaited(network.close());
            unawaited(admissions.close());
            async.flushMicrotasks();
          }
        });
      });
    }

    for (final outcome in [
      'already waiting',
      'snapshot pending',
      'snapshot outlasts admission',
      'relay crosses the next heartbeat',
      'relay rebuild expires',
      'video relay rebuild expires',
      'admission before the old relay open returns',
      'admission after the old relay open returns',
      'admission after a second network change',
      'replacement admission expires',
      'hangup during relay rebuild',
      'no admission',
    ]) {
      test('liveness lets a bounded relay reconnect finish: $outcome', () {
        fakeAsync((async) {
          final wire = _FakeMessaging();
          final network = StreamController<NetworkAttachment>(sync: true);
          final admissions = StreamController<void>(sync: true);
          final snapshot = Completer<DateTime?>();
          final snapshotOutlastsAdmission =
              outcome == 'snapshot outlasts admission';
          final visualRebuild = outcome == 'video relay rebuild expires';
          final replacementExpires = outcome == 'replacement admission expires';
          final rebuildExpires =
              outcome == 'relay rebuild expires' || visualRebuild ||
              replacementExpires;
          final admissionAlreadyAvailable =
              outcome == 'admission before the old relay open returns';
          final networkChangesTwice =
              outcome == 'admission after a second network change';
          final networkChangesDuringOpen =
              admissionAlreadyAvailable ||
              networkChangesTwice ||
              outcome == 'admission after the old relay open returns';
          final relayStillOpening =
              snapshotOutlastsAdmission ||
              outcome == 'relay crosses the next heartbeat' ||
              rebuildExpires ||
              networkChangesDuringOpen ||
              outcome == 'hangup during relay rebuild';
          final media = _RepairThenRelayMedia()
            ..openedTransport = CallTransportKind.relay
            ..repairSucceeds = false
            ..relayGate = relayStillOpening ? Completer<bool>() : null
            ..readSnapshot = (() => snapshot.future);
          final svc = CallService(
            wire,
            now: () => clock.now(),
            media: media,
            networkAttachments: network.stream,
            overlaySessionAdmissions: admissions.stream,
          )..start();
          const callId = 'relay-rebuild-crosses-liveness';
          wire.onCallSignal!(
            peer,
            offer(callId).copyWith(
              media: CallMedia(audio: true, video: visualRebuild),
            ),
          );
          unawaited(svc.accept());
          async.flushMicrotasks();
          media.rxAt = clock.now();
          async.elapse(kCallMediaRepairAfter);
          expect(media.repairs, 1);
          expect(media.activeTransport, isNull);

          final snapshotPending =
              outcome == 'snapshot pending' || snapshotOutlastsAdmission;
          final expiryTick = kCallLivenessTimeout + kCallHeartbeatInterval;
          const offset = Duration(milliseconds: 250);
          async.elapse(
            expiryTick - kCallMediaRepairAfter +
                (snapshotPending ? offset : -offset),
          );
          expect(media.snapshotReads, snapshotPending ? 1 : 0);
          network.add(NetworkAttachment.cellular);
          media.cameraStopped.complete();
          async.flushMicrotasks();
          wire.sent.clear();
          if (relayStillOpening) {
            admissions.add(null);
            async.flushMicrotasks();
            expect(media.switches, [CallTransportKind.relay]);
            expect(media.activeTransport, isNull);
          }
          async.elapse(offset);
          snapshot.complete(null);
          async.flushMicrotasks();
          expect(svc.current?.status, CallStatus.active);
          expect(media.switches, [
            if (relayStillOpening) CallTransportKind.relay,
          ]);
          expect(wire.sent.where((s) => s.type == CallSignalType.end), isEmpty);
          if (!snapshotPending) {
            expect(media.snapshotReads, 0);
            final health = wire.sent.where((s) => s.type == CallSignalType.health);
            expect(health, isNotEmpty);
            expect(health.any((signal) => signal.mediaRepairRequested), isFalse);
          }
          if (relayStillOpening) {
            wire.onCallSignal!(
              peer,
              const CallSignal(
                callId: callId,
                type: CallSignalType.health,
                mediaRepairRequested: true,
              ),
            );
            async.flushMicrotasks();
            expect(media.repairs, 1);
          }

          if (networkChangesDuringOpen) {
            final oldOpen = media.relayGate!;
            network.add(NetworkAttachment.wifi);
            if (admissionAlreadyAvailable) admissions.add(null);
            media.relayGate = Completer<bool>();
            oldOpen.complete(false);
            async.flushMicrotasks();
            expect(svc.current?.status, CallStatus.active);
            expect(media.switches, hasLength(admissionAlreadyAvailable ? 2 : 1));
            if (!admissionAlreadyAvailable) {
              admissions.add(null);
              async.flushMicrotasks();
            }
            expect(media.switches, [
              CallTransportKind.relay,
              CallTransportKind.relay,
            ]);
            if (networkChangesTwice) {
              final previousOpen = media.relayGate!;
              // Another successful registration on Wi-Fi is stale once that
              // attachment is lost, even if the open finishes afterwards.
              admissions.add(null);
              network.add(NetworkAttachment.offline);
              previousOpen.complete(false);
              async.flushMicrotasks();
              expect(svc.current?.status, CallStatus.active);
              expect(media.switches, hasLength(2));

              network.add(NetworkAttachment.cellular);
              async.flushMicrotasks();
              expect(media.switches, hasLength(2));
              media.relayGate = Completer<bool>();
              admissions.add(null);
              async.flushMicrotasks();
              expect(media.switches, hasLength(3));
            }
            media.relayGate!.complete(true);
            async.flushMicrotasks();
            expect(svc.current?.callId, callId);
            expect(svc.current?.status, CallStatus.active);
            expect(media.activeTransport, CallTransportKind.relay);
            expect(wire.sent.where((s) => s.type == CallSignalType.end), isEmpty);
          } else if (rebuildExpires || outcome == 'hangup during relay rebuild') {
            if (rebuildExpires) {
              var elapsed = offset;
              if (replacementExpires) {
                network.add(NetworkAttachment.wifi);
                const oldOpenDelay = Duration(seconds: 1);
                async.elapse(oldOpenDelay);
                elapsed += oldOpenDelay;
                final oldOpen = media.relayGate!;
                media.relayGate = Completer<bool>();
                oldOpen.complete(false);
                async.flushMicrotasks();
                expect(svc.current?.status, CallStatus.active);
                admissions.add(null);
                async.flushMicrotasks();
                expect(media.switches, hasLength(2));

                network.add(NetworkAttachment.offline);
                final previousOpen = media.relayGate!;
                media.relayGate = Completer<bool>();
                previousOpen.complete(false);
                network.add(NetworkAttachment.cellular);
                async.flushMicrotasks();
                expect(svc.current?.status, CallStatus.active);
              }
              final startBudget = visualRebuild
                  ? kCallVisualMediaStartTimeout
                  : kCallMediaStartTimeout;
              const lastTick = Duration(milliseconds: 1);
              async.elapse(startBudget - elapsed - lastTick);
              expect(svc.current?.status, CallStatus.active);
              async.elapse(lastTick);
            } else {
              unawaited(svc.hangup());
              async.flushMicrotasks();
            }
            expect(svc.current, isNull);
            admissions.add(null);
            media.relayGate!.complete(true);
            async.flushMicrotasks();
            expect(media.switches, hasLength(replacementExpires ? 2 : 1));
            expect(svc.current, isNull);
            expect(
              wire.sent.where((s) => s.type == CallSignalType.end).single.reason,
              rebuildExpires ? CallEndReason.error : CallEndReason.hangup,
            );
            expect(
              wire.sent.where((s) => s.type == CallSignalType.transportInfo),
              isEmpty,
            );
          } else if (outcome == 'no admission') {
            async.elapse(kCallRelayCandidateRetry - offset);
            expect(svc.current, isNull);
            final end = wire.sent.where((s) => s.type == CallSignalType.end);
            expect(end.single.reason, CallEndReason.error);
            expect(media.switches, isEmpty);
          } else {
            if (relayStillOpening) {
              media.relayGate!.complete(true);
            } else {
              admissions.add(null);
            }
            async.flushMicrotasks();
            expect(media.switches, [CallTransportKind.relay]);
            expect(media.activeTransport, CallTransportKind.relay);
            media.rxAt = clock.now();
            async.elapse(kCallHeartbeatInterval);
            expect(svc.current?.status, CallStatus.active);
            expect(wire.sent.where((s) => s.type == CallSignalType.end), isEmpty);
          }
          svc.dispose();
          unawaited(network.close());
          unawaited(admissions.close());
          async.flushMicrotasks();
        });
      });
    }

    for (final (newAdmission, retryResult) in [
      (false, false),
      (true, false),
      (true, true),
      (true, null),
    ]) {
      test('relay rebuild with unchanged attachment '
          '(new admission: $newAdmission, retry result: $retryResult)', () {
        fakeAsync((async) {
          final wire = _FakeMessaging();
          final network = StreamController<NetworkAttachment>(sync: true);
          final admissions = StreamController<void>(sync: true);
          final firstOpen = Completer<bool>();
          final media = _RepairThenRelayMedia()
            ..openedTransport = CallTransportKind.relay
            ..repairSucceeds = false
            ..relayGate = firstOpen;
          final svc = CallService(
            wire,
            now: () => clock.now(),
            media: media,
            networkAttachments: network.stream,
            overlaySessionAdmissions: admissions.stream,
          )..start();
          const id = 'relay-rebuild-same-attachment';
          try {
            wire.onCallSignal!(peer, offer(id));
            unawaited(svc.accept());
            async.flushMicrotasks();
            expect(svc.current?.transport, CallTransportKind.relay);
            wire.onCallSignal!(
              peer,
              const CallSignal(
                callId: id,
                type: CallSignalType.health,
                mediaRepairRequested: true,
              ),
            );
            async.flushMicrotasks();
            expect(media.repairs, 1);
            network.add(NetworkAttachment.cellular);
            media.cameraStopped.complete();
            async.flushMicrotasks();
            expect(media.switches, isEmpty);
            admissions.add(null);
            async.flushMicrotasks();
            expect(media.switches, [CallTransportKind.relay]);
            expect(media.activeTransport, isNull);

            const firstOpenDelay = Duration(seconds: 2);
            if (retryResult == null) async.elapse(firstOpenDelay);
            if (newAdmission) admissions.add(null);
            final secondOpen = Completer<bool>();
            media.relayGate = secondOpen;
            firstOpen.complete(false);
            async.flushMicrotasks();
            expect(media.switches, [
              CallTransportKind.relay,
              if (newAdmission) CallTransportKind.relay,
            ]);
            if (newAdmission) {
              expect(svc.current?.status, CallStatus.active);
              admissions.add(null);
              if (retryResult == null) {
                const lastTick = Duration(milliseconds: 1);
                async.elapse(
                  kCallMediaStartTimeout - firstOpenDelay - lastTick,
                );
                expect(svc.current?.status, CallStatus.active);
                async.elapse(lastTick);
                expect(svc.current, isNull);
                secondOpen.complete(true);
              } else {
                secondOpen.complete(retryResult);
              }
              async.flushMicrotasks();
              expect(media.switches, hasLength(2));
            }
            final ended = wire.sent.where((s) => s.type == CallSignalType.end);
            if (retryResult == true) {
              expect(svc.current?.callId, id);
              expect(svc.current?.status, CallStatus.active);
              expect(svc.current?.transport, CallTransportKind.relay);
              expect(media.activeTransport, CallTransportKind.relay);
              expect(ended, isEmpty);
            } else {
              expect(svc.current, isNull);
              expect(ended.single.reason, CallEndReason.error);
            }
          } finally {
            svc.dispose();
            unawaited(network.close());
            unawaited(admissions.close());
            async.flushMicrotasks();
          }
        });
      });
    }

    for (final route in [CallTransportKind.p2p, CallTransportKind.relay]) {
      test('keeps $route media in place while the local network is offline', () {
        fakeAsync((async) {
          final wire = _FakeMessaging();
          final network = StreamController<NetworkAttachment>(sync: true);
          final media = _FakeMedia()
            ..openedTransport = route
            ..liveDirectAdmission = false;
          final svc = CallService(
            wire,
            now: () => clock.now(),
            media: media,
            networkAttachments: network.stream,
            localAllowsP2P: (_) async => true,
            peerReachableForP2P: (_) async => true,
          )..start();
          const callId = 'network-offline-with-live-call';
          wire.onCallSignal!(
            peer,
            offer(callId).copyWith(transport: CallTransportProposal(route)),
          );
          unawaited(svc.accept());
          async.flushMicrotasks();
          expect(svc.current?.transport, route);
          media.rxAt = clock.now();

          network.add(NetworkAttachment.offline);
          async.elapse(kCallMediaRepairAfter);
          expect(media.repairs, 0);
          expect(media.switches, isEmpty);
          expect(media.liveAdmissionChecks, isEmpty);
          expect(wire.sent.where((s) => s.mediaRepairRequested), isEmpty);
          expect(svc.current?.callId, callId);

          network.add(NetworkAttachment.cellular);
          async.flushMicrotasks();
          if (route == CallTransportKind.p2p) {
            expect(media.switches, [CallTransportKind.relay]);
          } else {
            async.elapse(kCallHeartbeatInterval);
            expect(media.repairs, 1);
          }
          expect(svc.current?.callId, callId);
          expect(svc.current?.status, CallStatus.active);
          expect(svc.current?.transport, CallTransportKind.relay);
          svc.dispose();
          unawaited(network.close());
          async.flushMicrotasks();
        });
      });
    }

    for (final route in [CallTransportKind.p2p, CallTransportKind.relay]) {
      test('a receive-only peer does not trigger silence repair on $route', () {
        fakeAsync((async) {
          final wire = _FakeMessaging();
          final media = _FakeMedia()
            ..openedTransport = route
            ..liveDirectAdmission = true;
          final svc = CallService(
            wire,
            media: media,
            now: () => clock.now(),
            localAllowsP2P: (_) async => true,
            peerReachableForP2P: (_) async => true,
          )..start();
          const callId = 'receive-only-peer';
          wire.onCallSignal!(
            peer,
            CallSignal(
              callId: callId,
              type: CallSignalType.offer,
              posture: CallPosture.direct,
              media: const CallMedia(audio: true),
              transport: CallTransportProposal(route),
            ),
          );
          svc.accept();
          async.flushMicrotasks();
          expect(svc.current?.transport, route);
          wire.onCallSignal!(
            peer,
            const CallSignal(
              callId: callId,
              type: CallSignalType.health,
              capture: CallMedia(),
            ),
          );
          async.elapse(kCallMediaRepairAfter + kCallHeartbeatInterval);
          expect(svc.current?.status, CallStatus.active);
          expect(svc.current?.transport, route);
          expect(media.switches, isEmpty);
          expect(media.repairs, 0);
          expect(wire.sent.where((s) => s.mediaRepairRequested), isEmpty);

          if (route == CallTransportKind.p2p) {
            media.liveDirectAdmission = false;
            async.elapse(const Duration(seconds: 1));
            expect(media.switches, [CallTransportKind.relay]);
          } else {
            wire.onCallSignal!(
              peer,
              const CallSignal(
                callId: callId,
                type: CallSignalType.health,
                mediaRepairRequested: true,
              ),
            );
            async.flushMicrotasks();
            expect(media.repairs, 1);
          }
          svc.dispose();
          async.flushMicrotasks();
        });
      });
    }

    for (final capture in [
      const CallMedia(audio: true),
      const CallMedia(video: true),
    ]) {
      test('resumed capture has receive grace, audio=${capture.audio}', () {
        fakeAsync((async) {
          final wire = _FakeMessaging();
          final media = _FakeMedia()..openedTransport = CallTransportKind.relay;
          final svc = CallService(wire, now: () => clock.now(), media: media)
            ..start();
          const callId = 'resumed-capture';
          wire.onCallSignal!(
            peer,
            const CallSignal(
              callId: callId,
              type: CallSignalType.offer,
              posture: CallPosture.direct,
              media: CallMedia(audio: true, video: true),
            ),
          );
          svc.accept();
          async.flushMicrotasks();
          void report(CallMedia capture) => wire.onCallSignal!(
            peer,
            CallSignal(
              callId: callId,
              type: CallSignalType.health,
              capture: capture,
              sentAtMs: clock.now().millisecondsSinceEpoch,
            ),
          );
          report(const CallMedia());
          async.elapse(const Duration(seconds: 12));
          final repairs = media.repairs;
          report(capture);
          async.elapse(const Duration(seconds: 4));
          report(capture); // duplicate state cannot renew the grace
          async.elapse(const Duration(seconds: 5));
          expect(media.repairs, repairs);
          async.elapse(const Duration(seconds: 4));
          expect(media.repairs, repairs + 1);
          expect(svc.current?.status, CallStatus.active);
          svc.dispose();
          async.flushMicrotasks();
        });
      });
    }

    test('silent relay repairs locally without a peer heartbeat', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        final media = _FakeMedia()..openedTransport = CallTransportKind.relay;
        final svc = CallService(fake, now: () => clock.now(), media: media)
          ..start();
        fake.onCallSignal!(peer, offer('silent-relay'));
        svc.accept();
        async.flushMicrotasks();
        expect(svc.current?.transport, CallTransportKind.relay);
        media.rxAt = clock.now();

        async.elapse(kCallMediaRepairAfter - const Duration(milliseconds: 1));
        async.flushMicrotasks();
        expect(media.repairs, 0, reason: 'honor the receive grace');
        async.elapse(kCallHeartbeatInterval);
        async.flushMicrotasks();
        expect(media.repairs, 1, reason: 'do not wait for a lost peer request');
        expect(svc.current?.status, CallStatus.active);
        expect(
          media.switches,
          isEmpty,
          reason: 'retain the agreed relay route',
        );

        // A native rebuild can take several heartbeat ticks. Neither that
        // silence nor old receive counters should initiate another rebuild.
        media.receiveRepairing = true;
        media.rxAt = clock.now();
        async.elapse(kCallMediaRepairAfter);
        async.flushMicrotasks();
        expect(media.repairs, 1);
        media.receiveRepairing = false;
        media.receiveStartedAt = clock.now();
        async.elapse(kCallHeartbeatInterval);
        async.flushMicrotasks();
        expect(
          media.repairs,
          1,
          reason: 'new receive session gets fresh grace',
        );
        svc.dispose();
      });
    });

    for (final mode in [
      'confirmed stall',
      'stale cache',
      'missing snapshot',
      'only direct audio',
      'muted while reading',
      'replaced while reading',
      'stall starts near window end',
      'snapshot crosses window end',
      'native audio after window end',
      'cached audio after window end',
    ]) {
      test('relay audio after handover: $mode', () {
        fakeAsync((async) {
          final wire = _FakeMessaging();
          final media = _FakeMedia()..audioTelemetry = true;
          final svc = CallService(
            wire,
            now: () => clock.now(),
            media: media,
            localAllowsP2P: (_) async => true,
            peerReachableForP2P: (_) async => true,
          )..start();
          const callId = 'relay-after-handover';
          wire.onCallSignal!(
            peer,
            offer(callId).copyWith(
              transport: const CallTransportProposal(CallTransportKind.p2p),
            ),
          );
          svc.accept();
          async.flushMicrotasks();
          expect(svc.current?.transport, CallTransportKind.p2p);
          void capture(bool on) => wire.onCallSignal!(
            peer,
            CallSignal(
              callId: callId,
              type: CallSignalType.health,
              capture: CallMedia(audio: on),
              sentAtMs: clock.now().millisecondsSinceEpoch,
            ),
          );
          media.audioRxAt = clock.now();
          capture(true);
          async.elapse(const Duration(milliseconds: 100));
          wire.onCallSignal!(
            peer,
            const CallSignal(
              callId: callId,
              type: CallSignalType.transportInfo,
              transport: CallTransportProposal(CallTransportKind.relay),
            ),
          );
          async.flushMicrotasks();
          expect(svc.current?.transport, CallTransportKind.relay);
          final handoverAt = clock.now();
          if (mode != 'only direct audio') {
            final lastRelayAudio = switch (mode) {
              'snapshot crosses window end' => const Duration(
                milliseconds: 6400,
              ),
              'stall starts near window end' ||
              'native audio after window end' => const Duration(
                milliseconds: 9400,
              ),
              'cached audio after window end' => const Duration(
                milliseconds: 10200,
              ),
              _ => const Duration(milliseconds: 100),
            };
            final lastAudioAt = handoverAt.add(lastRelayAudio);
            while (clock.now().isBefore(lastAudioAt)) {
              final remaining = lastAudioAt.difference(clock.now());
              const step = Duration(seconds: 1);
              async.elapse(remaining < step ? remaining : step);
              media.audioRxAt = clock.now();
              media.rxAt = clock.now();
            }
          }
          final snapshot = Completer<DateTime?>();
          media.latestAudioRead = () => snapshot.future;
          // RTCP can keep aggregate ingress fresh while speech stops.
          media.rxAt = clock.now();
          async.elapse(const Duration(seconds: 3));
          expect(media.repairs, 0);
          async.elapse(const Duration(seconds: 1));
          if (mode != 'only direct audio' &&
              mode != 'cached audio after window end') {
            expect(media.latestAudioReads, 1);
          } else {
            expect(media.latestAudioReads, 0);
          }
          if (mode == 'muted while reading') capture(false);
          if (mode == 'replaced while reading') {
            media.receiveStartedAt = clock.now();
          }
          snapshot.complete(switch (mode) {
            'stale cache' => clock.now(),
            'missing snapshot' => null,
            'native audio after window end' => handoverAt.add(
              kCallMediaRepairAfter + const Duration(milliseconds: 100),
            ),
            _ => media.audioRxAt,
          });
          async.flushMicrotasks();
          final repairs = switch (mode) {
            'confirmed stall' ||
            'stall starts near window end' ||
            'snapshot crosses window end' => 1,
            _ => 0,
          };
          expect(media.repairs, repairs);
          expect(svc.current?.status, CallStatus.active);
          expect(media.switches, [CallTransportKind.relay]);
          if (repairs == 1) {
            async.elapse(const Duration(seconds: 2));
            expect(media.repairs, 1, reason: 'one early repair per handover');
          }
          svc.dispose();
          async.flushMicrotasks();
        });
      });
    }

    for (final outcome in ['confirmed', 'rejected', 'expired']) {
      test('liveness awaits the current relay handover probe: $outcome', () {
        fakeAsync((async) {
          final wire = _FakeMessaging();
          final network = StreamController<NetworkAttachment>(sync: true);
          final admissions = StreamController<void>(sync: true);
          final echo = Completer<bool>();
          final media = _FakeMedia()
            ..openedTransport = CallTransportKind.relay
            ..audioTelemetry = true;
          bool? committed;
          media.relayRefresh = (canCommit) async {
            if (media.relayRefreshes == 1) return false;
            final accepted = await echo.future && await canCommit();
            committed = accepted;
            if (accepted) media.rxAt = media.audioRxAt = clock.now();
            return accepted;
          };
          final svc = CallService(
            wire,
            now: () => clock.now(),
            media: media,
            networkAttachments: network.stream,
            overlaySessionAdmissions: admissions.stream,
            localAllowsP2P: (_) async => false,
          )..start();
          const id = 'relay-probe-crosses-liveness';
          final ends = wire.sent.where((s) => s.type == CallSignalType.end);
          try {
            wire.onCallSignal!(
              peer,
              offer(id).copyWith(
                transport: const CallTransportProposal(CallTransportKind.relay),
              ),
            );
            unawaited(svc.accept());
            async.flushMicrotasks();
            wire.onCallSignal!(
              peer,
              const CallSignal(
                callId: id,
                type: CallSignalType.health,
                capture: CallMedia(audio: true),
              ),
            );
            async.elapse(const Duration(milliseconds: 4100));
            media.rxAt = media.audioRxAt = clock.now();
            async.elapse(const Duration(milliseconds: 2700));
            network.add(NetworkAttachment.cellular);
            async.elapse(const Duration(seconds: 13));
            expect(media.relayRefreshes, 1);
            expect(media.repairs, 1);

            // The first attempt could not qualify. A new admission during
            // the same handover starts the one allowed retry at the next tick.
            admissions.add(null);
            async.elapse(const Duration(milliseconds: 5200));
            expect(media.relayRefreshes, 2);
            expect(svc.current?.callId, id);
            expect(ends, isEmpty);
            expect(media.repairs, 1, reason: 'keep the candidate in flight');

            if (outcome == 'expired') {
              async.elapse(const Duration(milliseconds: 1800));
              expect(ends.single.reason, CallEndReason.timeout);
            }
            echo.complete(outcome != 'rejected');
            async.flushMicrotasks();
            expect(committed, outcome == 'confirmed');
            if (outcome == 'confirmed') {
              expect(svc.current?.status, CallStatus.active);
              expect(ends, isEmpty);
            } else {
              expect(svc.current, isNull);
              expect(ends.single.reason, CallEndReason.timeout);
            }
          } finally {
            svc.dispose();
            if (!echo.isCompleted) echo.complete(false);
            unawaited(network.close());
            unawaited(admissions.close());
            async.flushMicrotasks();
          }
        });
      });
    }

    for (final mode in [
      'confirmed stall',
      'only pre-change audio',
      'unclassified attachment',
      'stale pre-change audio',
      'no echo for pre-change audio',
      'audio resumes while probing',
      'new handover while probing',
      'without a network change',
      'superseded during confirmation',
      'network IPC pending during confirmation',
    ]) {
      test('relay audio after local network change: $mode', () {
        fakeAsync((async) {
          final ipcPending = mode == 'network IPC pending during confirmation';
          final superseded = mode == 'superseded during confirmation' ||
              ipcPending;
          final network = StreamController<NetworkAttachment>(sync: true);
          final wire = _FakeMessaging();
          final media = _FakeMedia()
            ..openedTransport = CallTransportKind.relay
            ..audioTelemetry = true;
          var generation = 0;
          final svc = CallService(
            wire,
            now: () => clock.now(),
            media: media,
            networkAttachments: network.stream,
            readNetworkChangeGeneration: () => generation,
            localAllowsP2P: (_) async => false,
          )..start();
          const callId = 'already-relay-network-change';
          wire.onCallSignal!(
            peer,
            offer(callId).copyWith(
              transport: const CallTransportProposal(CallTransportKind.relay),
            ),
          );
          svc.accept();
          async.flushMicrotasks();
          expect(svc.current?.transport, CallTransportKind.relay);

          media.audioRxAt = clock.now();
          wire.onCallSignal!(
            peer,
            CallSignal(
              callId: callId,
              type: CallSignalType.health,
              capture: const CallMedia(audio: true),
              sentAtMs: clock.now().millisecondsSinceEpoch,
            ),
          );
          final preChangeAudio = const {
            'only pre-change audio',
            'unclassified attachment',
            'stale pre-change audio',
            'no echo for pre-change audio',
            'audio resumes while probing',
            'new handover while probing',
          }.contains(mode);
          if (mode == 'stale pre-change audio') {
            async.elapse(const Duration(seconds: 4));
          }
          async.elapse(const Duration(milliseconds: 100));
          if (mode != 'without a network change') {
            network.add(
              mode == 'unclassified attachment'
                  ? NetworkAttachment.unknown
                  : NetworkAttachment.cellular,
            );
          }
          async.elapse(const Duration(milliseconds: 100));
          if (!preChangeAudio) media.audioRxAt = clock.now();
          media.rxAt = clock.now();

          final probe = Completer<bool>();
          bool? boundRelay;
          media.relayRefresh = (canCommit) async {
            return boundRelay = await probe.future && await canCommit();
          };
          final snapshot = Completer<DateTime?>();
          media.latestAudioRead = () => snapshot.future;
          async.elapse(const Duration(seconds: 3));
          expect(media.repairs, 0);
          expect(media.relayRefreshes, 0);
          async.elapse(const Duration(seconds: 1));
          final shouldProbe = preChangeAudio && mode != 'stale pre-change audio';
          final shouldRead =
              shouldProbe || mode == 'confirmed stall' || superseded;
          expect(media.latestAudioReads, shouldRead ? 1 : 0);

          if (mode == 'superseded during confirmation') {
            network.add(NetworkAttachment.cellular);
            async.flushMicrotasks();
          }
          if (ipcPending) generation++;
          snapshot.complete(media.audioRxAt);
          async.flushMicrotasks();
          expect(media.repairs, mode == 'confirmed stall' ? 1 : 0);
          expect(media.relayRefreshes, shouldProbe ? 1 : 0);

          if (mode == 'audio resumes while probing') {
            media.audioRxAt = clock.now();
          }
          media.latestAudioRead = () async => media.audioRxAt;
          if (mode == 'new handover while probing') {
            async.elapse(const Duration(milliseconds: 100));
            network.add(NetworkAttachment.cellular);
            async.flushMicrotasks();
          }
          probe.complete(mode != 'no echo for pre-change audio');
          async.flushMicrotasks();
          expect(
            boundRelay,
            shouldProbe
                ? mode == 'only pre-change audio' ||
                      mode == 'unclassified attachment'
                : null,
          );
          expect(media.repairs, mode == 'confirmed stall' ? 1 : 0);
          if (mode == 'no echo for pre-change audio') {
            async.elapse(const Duration(seconds: 6));
            expect(media.relayRefreshes, 1);
            expect(media.repairs, 1, reason: 'ordinary recovery is still armed');
          }

          if (superseded) {
            async.elapse(const Duration(milliseconds: 100));
            if (ipcPending) network.add(NetworkAttachment.cellular);
            media.audioRxAt = clock.now();
            media.rxAt = clock.now();
            media.latestAudioRead = () async => media.audioRxAt;
            async.elapse(const Duration(seconds: 4));
            expect(media.repairs, 1, reason: 'the new event owns recovery');
          }
          expect(svc.current?.status, CallStatus.active);
          expect(svc.current?.transport, CallTransportKind.relay);
          expect(media.switches, isEmpty);
          svc.dispose();
          unawaited(network.close());
          async.flushMicrotasks();
        });
      });
    }

    for (final timing in ['during probe', 'after failure', 'audio resumed']) {
      test('a relay refresh observes admission $timing', () {
        fakeAsync((async) {
          final network = StreamController<NetworkAttachment>(sync: true);
          final admissions = StreamController<void>(sync: true);
          final wire = _FakeMessaging();
          final first = Completer<bool>();
          final media = _FakeMedia()
            ..openedTransport = CallTransportKind.relay
            ..audioTelemetry = true;
          final svc = CallService(
            wire,
            now: () => clock.now(),
            media: media,
            networkAttachments: network.stream,
            overlaySessionAdmissions: admissions.stream,
            localAllowsP2P: (_) async => false,
          )..start();
          const callId = 'relay-refresh-new-admission';
          wire.onCallSignal!(
            peer,
            offer(callId).copyWith(
              transport: const CallTransportProposal(CallTransportKind.relay),
            ),
          );
          svc.accept();
          async.flushMicrotasks();
          wire.onCallSignal!(
            peer,
            CallSignal(
              callId: callId,
              type: CallSignalType.health,
              capture: const CallMedia(audio: true),
              sentAtMs: clock.now().millisecondsSinceEpoch,
            ),
          );
          media.audioRxAt = clock.now();
          media.rxAt = clock.now();
          media.latestAudioRead = () async => media.audioRxAt;
          var qualified = 0;
          media.relayRefresh = (canCommit) async {
            if (media.relayRefreshes == 1) return first.future;
            if (!await canCommit()) return false;
            qualified++;
            return timing == 'during probe';
          };

          async.elapse(const Duration(milliseconds: 100));
          network.add(NetworkAttachment.cellular);
          async.elapse(const Duration(seconds: 4));
          expect(media.relayRefreshes, 1);
          if (timing == 'during probe') {
            admissions.add(null);
            async.elapse(const Duration(seconds: 1));
            expect(media.relayRefreshes, 1, reason: 'do not overlap probes');
          }
          first.complete(false);
          async.flushMicrotasks();
          if (timing != 'during probe') {
            async.elapse(const Duration(seconds: 1));
            expect(
              media.relayRefreshes,
              1,
              reason: 'admission has not changed',
            );
            if (timing == 'audio resumed') media.audioRxAt = clock.now();
            admissions.add(null);
          }
          async.elapse(const Duration(seconds: 1));
          final expected = timing == 'audio resumed' ? 1 : 2;
          expect(media.relayRefreshes, expected);
          expect(qualified, expected - 1);
          if (timing != 'audio resumed') {
            admissions.add(null);
            async.elapse(const Duration(seconds: 1));
            expect(
              media.relayRefreshes,
              2,
              reason: 'at most one admission retry',
            );
          }
          expect(media.repairs, 0);
          expect(svc.current?.status, CallStatus.active);
          expect(svc.current?.transport, CallTransportKind.relay);
          svc.dispose();
          unawaited(network.close());
          unawaited(admissions.close());
          async.flushMicrotasks();
        });
      });
    }

    for (final (failedProbes, confirmedAudio) in [
      (1, true),
      (2, true),
      (1, false),
    ]) {
      test('relay receive stalls after $failedProbes failed probes '
          '(confirmed audio=$confirmedAudio)', () {
        fakeAsync((async) {
          final network = StreamController<NetworkAttachment>(sync: true);
          final admissions = StreamController<void>(sync: true);
          final wire = _FakeMessaging();
          final media = _FakeMedia()
            ..openedTransport = CallTransportKind.relay
            ..audioTelemetry = true
            ..relayRefresh = (_) async => false;
          final svc = CallService(
            wire,
            now: () => clock.now(),
            media: media,
            networkAttachments: network.stream,
            overlaySessionAdmissions: admissions.stream,
            localAllowsP2P: (_) async => false,
          )..start();
          const callId = 'relay-receive-after-failed-probe';
          wire.onCallSignal!(peer, offer(callId));
          unawaited(svc.accept());
          async.flushMicrotasks();
          expect(svc.current?.transport, CallTransportKind.relay);
          wire.onCallSignal!(
            peer,
            const CallSignal(
              callId: callId,
              type: CallSignalType.health,
              capture: CallMedia(audio: true),
            ),
          );
          final oldAudio = clock.now();
          media.audioRxAt = oldAudio;
          media.rxAt = oldAudio;
          async.elapse(const Duration(milliseconds: 100));
          network.add(NetworkAttachment.cellular);
          async.elapse(const Duration(seconds: 4));
          expect(media.relayRefreshes, 1);

          if (failedProbes == 2) {
            admissions.add(null);
            async.elapse(const Duration(seconds: 1));
            expect(media.relayRefreshes, 2);
          }
          media.audioRxAt = clock.now();
          media.rxAt = media.audioRxAt;
          media.latestAudioRead = () async =>
              confirmedAudio ? media.audioRxAt : oldAudio;
          async.elapse(
            kCallDirectSessionSilence - const Duration(milliseconds: 1),
          );
          expect(media.repairs, 0, reason: 'allow the brief return of audio');
          async.elapse(const Duration(seconds: 1));
          expect(media.repairs, confirmedAudio ? 1 : 0);
          expect(media.relayRefreshes, failedProbes, reason: 'no extra probe');
          expect(svc.current?.status, CallStatus.active);
          expect(svc.current?.transport, CallTransportKind.relay);
          svc.dispose();
          unawaited(network.close());
          unawaited(admissions.close());
          async.flushMicrotasks();
        });
      });
    }

    for (final readsPolicy in [true, false]) {
      final lookup = readsPolicy ? 'P2P policy' : 'device lookup';
      test('dial timeout covers a pending $lookup', () {
        fakeAsync((async) {
          final pending = Completer<void>();
          var lookupStarted = false;
          Future<void> waitForLookup() {
            lookupStarted = true;
            return pending.future;
          }

          final fake = _FakeMessaging();
          if (!readsPolicy) {
            fake.readLocalDevice = () async {
              await waitForLookup();
              return NodeId.fromHex('f' * 64);
            };
          }
          final svc = CallService(
            fake,
            localAllowsP2P: (_) async {
              if (readsPolicy) await waitForLookup();
              return true;
            },
          )..start();
          try {
            unawaited(svc.placeCall(peer, const CallMedia(audio: true)));
            async.flushMicrotasks();
            expect(lookupStarted, isTrue);
            expect(svc.current?.status, CallStatus.dialing);
            expect(fake.sent, isEmpty);

            async.elapse(kCallRingTimeout);

            expect(svc.current, isNull);
            expect(fake.sent.single.type, CallSignalType.cancel);
            expect(fake.sent.single.reason, CallEndReason.timeout);
            pending.complete();
            async.flushMicrotasks();
            expect(fake.sent, hasLength(1));
          } finally {
            svc.dispose();
            if (!pending.isCompleted) pending.complete();
            async.flushMicrotasks();
          }
        });
      });
    }

    test('dial timeout runs while the durable offer is still pending', () {
      fakeAsync((async) {
        final enqueue = Completer<void>();
        final fake = _FakeMessaging()..sendGate = enqueue;
        final svc = CallService(fake)..start();
        try {
          var placed = false;
          unawaited(
            svc.placeCall(peer, const CallMedia(audio: true)).then((_) {
              placed = true;
            }),
          );
          async.flushMicrotasks();
          expect(svc.current?.status, CallStatus.dialing);
          expect(placed, isFalse);
          final callId = svc.current!.callId;
          fake.sendGate = null; // The timeout's cancel can complete normally.

          async.elapse(kCallRingTimeout);

          expect(svc.current, isNull);
          final cancel = fake.sent.single;
          expect(cancel.callId, callId);
          expect(cancel.type, CallSignalType.cancel);
          expect(cancel.reason, CallEndReason.timeout);
          enqueue.complete();
          async.flushMicrotasks();
          expect(placed, isTrue);
          expect(svc.current, isNull);
        } finally {
          svc.dispose();
          if (!enqueue.isCompleted) enqueue.complete();
          async.flushMicrotasks();
        }
      });
    });

    test(
      'answer racing a slow durable offer keeps the active call connected',
      () {
        fakeAsync((async) {
          final fake = _FakeMessaging()..sendGate = Completer<void>();
          final media = _FakeMedia();
          final svc = CallService(fake, now: () => clock.now(), media: media)
            ..start();

          final placing = svc.placeCall(
            peer,
            const CallMedia(audio: true, video: true),
          );
          async.flushMicrotasks();
          final callId = svc.current!.callId;
          expect(svc.current?.status, CallStatus.dialing);

          // The realtime offer/answer completes while sendCallSignal is still
          // awaiting its durable encrypted-store enqueue.
          fake.onCallSignal!(
            peer,
            CallSignal(
              callId: callId,
              type: CallSignalType.answer,
              posture: CallPosture.direct,
              transport: const CallTransportProposal(CallTransportKind.relay),
            ),
          );
          async.flushMicrotasks();
          expect(svc.current?.status, CallStatus.active);

          fake.sendGate!.complete();
          async.flushMicrotasks();
          expect(placing, completion(isNull));

          // Keep media demonstrably live past the old 75-second failure point.
          for (var i = 0; i < 16; i++) {
            media.rxAt = clock.now();
            async.elapse(const Duration(seconds: 5));
            async.flushMicrotasks();
          }

          expect(svc.current?.status, CallStatus.active);
          expect(
            media.repairs,
            0,
            reason: 'flowing relay media needs no repair',
          );
          expect(
            fake.sent.where((s) => s.type == CallSignalType.cancel),
            isEmpty,
          );
          svc.dispose();
        });
      },
    );

    test('a connected call whose peer goes silent ends with timeout', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        final svc = CallService(fake, now: () => clock.now())..start();
        final seen = <Call?>[];
        svc.changes.listen(seen.add);

        fake.onCallSignal!(peer, offer('call-1'));
        svc.accept(); // → connecting; no media controller, so it rests there
        async.flushMicrotasks();
        expect(svc.current?.status, CallStatus.connecting);

        // No post-connect proof has arrived yet, so the startup grace applies.
        async.elapse(kCallStartupLivenessTimeout + const Duration(seconds: 5));
        async.flushMicrotasks();

        expect(svc.current, isNull); // slot cleared
        final terminal = seen.lastWhere(
          (c) => c?.status == CallStatus.ended,
          orElse: () => null,
        );
        expect(terminal?.endReason, CallEndReason.timeout);
      });
    });

    test('callee survives a delayed first post-connect peer signal', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        final svc = CallService(fake, now: () => clock.now())..start();

        fake.onCallSignal!(peer, offer('slow-answer-path'));
        svc.accept();
        async.flushMicrotasks();

        async.elapse(kCallLivenessTimeout + const Duration(seconds: 5));
        async.flushMicrotasks();
        expect(svc.current?.isLive, isTrue);

        fake.onCallSignal!(
          peer,
          const CallSignal(
            callId: 'slow-answer-path',
            type: CallSignalType.health,
          ),
        );
        async.flushMicrotasks();
        expect(svc.current?.isLive, isTrue);

        // After the first proof of life, the ordinary strict timeout resumes.
        async.elapse(kCallLivenessTimeout + kCallHeartbeatInterval);
        async.flushMicrotasks();
        expect(svc.current, isNull);
      });
    });

    test(
      'repair retains the real receipt but does not extend its deadline',
      () {
        fakeAsync((async) {
          final wire = _FakeMessaging();
          final media = _ReceiveHistoryMedia();
          final svc = CallService(wire, now: () => clock.now(), media: media)
            ..start();
          wire.onCallSignal!(peer, offer('repair-history'));
          svc.accept();
          async.flushMicrotasks();
          media.receipts.observe({
            'rx_pkts': 1,
            'worker_stalled': 0,
          }, clock.now());
          async.elapse(const Duration(seconds: 9));
          media.receipts.observe({
            'rx_pkts': 2,
            'worker_stalled': 0,
          }, clock.now());
          async.elapse(const Duration(seconds: 1));
          media.receipts.reset(preserveLastRxAt: true);
          media.receiveRepairing = true;
          // The peer was last heard at t=9; a local rebuild at t=10 neither
          // deletes that evidence nor supplies a newer t=10 proof of life.
          async.elapse(const Duration(seconds: 15));
          async.flushMicrotasks();
          expect(
            svc.current?.status,
            CallStatus.active,
            reason: 't=25 is only 16 seconds since the real receipt',
          );
          async.elapse(const Duration(seconds: 5));
          async.flushMicrotasks();
          expect(
            svc.current,
            isNull,
            reason: 't=30 exceeds the unchanged 20-second deadline from t=9',
          );
          svc.dispose();
        });
      },
    );

    test('inbound heartbeats keep the call alive past the timeout', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        final svc = CallService(fake, now: () => clock.now())..start();
        fake.onCallSignal!(peer, offer('call-2'));
        svc.accept();
        async.flushMicrotasks();
        expect(svc.current?.status, CallStatus.connecting);

        // Peer beats every 5s for 60s — well past the 20s liveness timeout.
        for (var i = 0; i < 12; i++) {
          async.elapse(const Duration(seconds: 5));
          fake.onCallSignal!(
            peer,
            const CallSignal(callId: 'call-2', type: CallSignalType.health),
          );
        }
        async.flushMicrotasks();
        expect(svc.current?.status, CallStatus.connecting); // still live
      });
    });

    test('we emit periodic health beats while connected', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        final svc = CallService(fake, now: () => clock.now())..start();
        fake.onCallSignal!(peer, offer('call-3'));
        svc.accept();
        async.flushMicrotasks();
        fake.sent.clear(); // drop the answer signal

        async.elapse(const Duration(seconds: 16)); // ticks at 5, 10, 15
        final beats = fake.sent
            .where((s) => s.type == CallSignalType.health)
            .length;
        expect(beats, greaterThanOrEqualTo(3));
      });
    });

    test(
      'end-to-end media silence asks the peer to repair its outbound route',
      () {
        fakeAsync((async) {
          final fake = _FakeMessaging();
          final media = _FakeMedia();
          final svc = CallService(fake, now: () => clock.now(), media: media)
            ..start();
          fake.onCallSignal!(peer, offer('call-repair-request'));
          svc.accept();
          async.flushMicrotasks();
          expect(svc.current?.status, CallStatus.active);
          fake.sent.clear();

          async.elapse(kCallMediaRepairAfter + const Duration(seconds: 1));
          async.flushMicrotasks();

          expect(
            fake.sent
                .where((s) => s.type == CallSignalType.health)
                .any((s) => s.mediaRepairRequested),
            isTrue,
          );
        });
      },
    );

    test('health and immediate mute announcements carry receiver playout', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        final media = _FakeMedia()
          ..playout = const CallAudioPlayoutFeedback(sequence: 3, delayMs: 540);
        final svc = CallService(fake, now: () => clock.now(), media: media)
          ..start();
        fake.onCallSignal!(peer, offer('playout-health'));
        svc.accept();
        async.flushMicrotasks();
        fake.sent.clear();
        async.elapse(kCallHeartbeatInterval);
        async.flushMicrotasks();
        expect(
          fake.sent,
          hasLength(2),
          reason: 'urgent ceiling then periodic health',
        );
        expect(fake.sent.every((s) => s.type == CallSignalType.health), isTrue);
        final back = CallSignal.tryDecode(fake.sent.last.encode())!;
        expect(back.audioPlayout!.delayMs, 540);
        expect(back.audioPlayout!.sequence, 3);
        fake.sent.clear();
        svc.setMicEnabled(false);
        async.flushMicrotasks();
        expect(fake.sent.single.capture!.audio, isFalse);
        expect(
          fake.sent.single.audioPlayout!.delayMs,
          540,
          reason: 'local mute does not mute incoming audio',
        );
        svc.dispose();
      });
    });

    test(
      'only active-call health from its peer reaches the playout policy',
      () {
        fakeAsync((async) {
          final fake = _FakeMessaging();
          final media = _FakeMedia()..startGate = Completer<bool>();
          final svc = CallService(fake, now: () => clock.now(), media: media)
            ..start();
          final device = NodeId.fromHex('8' * 64);
          fake.onCallSignal!(
            peer,
            offer(
              'playout-auth',
            ).copyWith(posture: CallPosture.direct, replyDevice: device.hex),
          );
          svc.accept();
          async.flushMicrotasks();
          const health = CallSignal(
            callId: 'playout-auth',
            type: CallSignalType.health,
            audioPlayout: CallAudioPlayoutFeedback(sequence: 1, delayMs: 540),
          );
          fake.onCallSignal!(peer, health);
          expect(media.peerPlayout, isEmpty, reason: 'initial media not ready');
          media.startGate!.complete(true);
          async.flushMicrotasks();
          expect(svc.current!.status, CallStatus.active);
          fake.onCallSignal!(NodeId.fromHex('9' * 64), health);
          fake.onCallSignal!(
            peer,
            const CallSignal(
              callId: 'other-call',
              type: CallSignalType.health,
              audioPlayout: CallAudioPlayoutFeedback(sequence: 2, delayMs: 100),
            ),
          );
          fake.onCallSignal!(
            peer,
            health.copyWith(type: CallSignalType.unknown),
          );
          expect(media.peerPlayout, isEmpty);
          fake.onCallSignal!(peer, CallSignal.tryDecode(health.encode())!);
          expect(media.peerPlayout.single.delayMs, 540);
          fake.onCallSignal!(
            device,
            CallSignal(
              callId: 'other-call',
              type: CallSignalType.health,
              audioPlayout: const CallAudioPlayoutFeedback(
                sequence: 2,
                delayMs: 100,
              ),
            ),
          );
          expect(media.peerPlayout.length, 1);
          // A direct session without a sovereign alias names the physical
          // device pinned by the original offer, while media still belongs
          // to the contact dialog. It must deliver feedback to that dialog.
          fake.onCallSignal!(device, health);
          expect(media.peerPlayout.length, 2);
          svc.hangup();
          async.flushMicrotasks();
          fake.onCallSignal!(peer, health);
          expect(
            media.peerPlayout.length,
            2,
            reason: 'ended call ignores feedback',
          );
          svc.dispose();
        });
      },
    );

    test('peer media-repair request refreshes our outbound route', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        final media = _FakeMedia();
        final svc = CallService(fake, now: () => clock.now(), media: media)
          ..start();
        fake.onCallSignal!(peer, offer('call-repair-apply'));
        svc.accept();
        async.flushMicrotasks();

        fake.onCallSignal!(
          peer,
          const CallSignal(
            callId: 'call-repair-apply',
            type: CallSignalType.health,
            mediaRepairRequested: true,
          ),
        );
        async.flushMicrotasks();

        expect(media.repairs, 1);
      });
    });

    for (final newer in ['health', 'health without route', 'transport']) {
      test('dated media repair cannot precede newer $newer state', () {
        fakeAsync((async) {
          final wire = _FakeMessaging();
          final media = _FakeMedia();
          final service = CallService(
            wire,
            now: () => clock.now(),
            media: media,
          )..start();
          wire.onCallSignal!(peer, offer('repair-order'));
          service.accept();
          async.flushMicrotasks();
          expect(service.current?.status, CallStatus.active);
          wire.onCallSignal!(
            peer,
            CallSignal(
              callId: 'repair-order',
              type: newer == 'transport'
                  ? CallSignalType.transportInfo
                  : CallSignalType.health,
              sentAtMs: 2000,
              transport: newer == 'health without route'
                  ? null
                  : const CallTransportProposal(CallTransportKind.relay),
            ),
          );
          wire.onCallSignal!(
            peer,
            const CallSignal(
              callId: 'repair-order',
              type: CallSignalType.health,
              sentAtMs: 1000,
              transport: CallTransportProposal(CallTransportKind.relay),
              mediaRepairRequested: true,
            ),
          );
          async.flushMicrotasks();
          expect(
            media.repairs,
            0,
            reason: 'old observations cannot rebuild media',
          );
          wire.onCallSignal!(
            peer,
            const CallSignal(
              callId: 'repair-order',
              type: CallSignalType.health,
              sentAtMs: 3000,
              mediaRepairRequested: true,
            ),
          );
          async.flushMicrotasks();
          expect(
            media.repairs,
            1,
            reason: 'a newer repair request still applies',
          );
          service.dispose();
        });
      });
    }

    test('dated media repair deduplicates without poisoning another call', () {
      fakeAsync((async) {
        final wire = _FakeMessaging();
        final media = _GatedRepairMedia();
        final service = CallService(wire, now: () => clock.now(), media: media)
          ..start();
        wire.onCallSignal!(peer, offer('repair-dedupe'));
        service.accept();
        async.flushMicrotasks();
        const request = CallSignal(
          callId: 'repair-dedupe',
          type: CallSignalType.health,
          sentAtMs: 2000,
          mediaRepairRequested: true,
        );
        for (var i = 0; i < 2; i++) {
          wire.onCallSignal!(peer, request);
          async.flushMicrotasks();
        }
        expect(media.repairs, 1, reason: 'one dated request admits one repair');
        media.gate.complete(true);
        async.flushMicrotasks();
        // Another peer or call cannot advance this call's timestamp floor.
        for (final unrelated in [true, false]) {
          wire.onCallSignal!(
            unrelated ? NodeId.fromHex('b' * 64) : peer,
            CallSignal(
              callId: unrelated ? 'repair-dedupe' : 'another-call',
              type: CallSignalType.health,
              sentAtMs: 999999,
              mediaRepairRequested: true,
            ),
          );
        }
        wire.onCallSignal!(
          peer,
          const CallSignal(
            callId: 'repair-dedupe',
            type: CallSignalType.health,
            sentAtMs: 3000,
            mediaRepairRequested: true,
          ),
        );
        async.flushMicrotasks();
        expect(media.repairs, 2);
        service.hangup();
        async.flushMicrotasks();
        wire.onCallSignal!(peer, offer('repair-new-call'));
        service.accept();
        async.flushMicrotasks();
        wire.onCallSignal!(
          peer,
          const CallSignal(
            callId: 'repair-new-call',
            type: CallSignalType.health,
            sentAtMs: 100,
            mediaRepairRequested: true,
          ),
        );
        async.flushMicrotasks();
        expect(media.repairs, 3, reason: 'timestamp floors belong to one call');
        service.dispose();
      });
    });

    test(
      'dated media repair during startup remains usable after media starts',
      () {
        fakeAsync((async) {
          final wire = _FakeMessaging();
          final media = _FakeMedia()..startGate = Completer<bool>();
          final service = CallService(
            wire,
            now: () => clock.now(),
            media: media,
          )..start();
          wire.onCallSignal!(peer, offer('repair-startup'));
          service.accept();
          async.flushMicrotasks();
          expect(service.current?.status, CallStatus.connecting);
          const request = CallSignal(
            callId: 'repair-startup',
            type: CallSignalType.health,
            sentAtMs: 1000,
            mediaRepairRequested: true,
          );
          wire.onCallSignal!(peer, request);
          async.flushMicrotasks();
          expect(media.repairs, 0);
          media.startGate!.complete(true);
          async.flushMicrotasks();
          expect(service.current?.status, CallStatus.active);
          wire.onCallSignal!(peer, request);
          async.flushMicrotasks();
          expect(
            media.repairs,
            1,
            reason: 'startup did not consume the request',
          );
          service.dispose();
        });
      },
    );

    for (final (outcome, admission) in <(String, bool?)>[
      ('resumed', true),
      ('resumed', false),
      ('unavailable', true),
      ('unavailable', null),
      ('unavailable', false),
      ('failed', true),
      ('failed', false),
      ('timeout', true),
      ('timeout', false),
      ('stopped', true),
    ]) {
      test('cached direct outage: $outcome / $admission', () {
        fakeAsync((async) {
          final fake = _FakeMessaging();
          final media = _FakeMedia()
            ..liveDirectAdmission = admission
            ..audioTelemetry = true;
          final pending = Completer<DateTime?>();
          final svc = CallService(
            fake,
            now: () => clock.now(),
            media: media,
            localAllowsP2P: (_) async => true,
            peerReachableForP2P: (_) async => true,
          )..start();
          fake.onCallSignal!(
            peer,
            const CallSignal(
              callId: 'cached-audio-outage',
              type: CallSignalType.offer,
              media: CallMedia(audio: true, video: true),
              posture: CallPosture.direct,
              transport: CallTransportProposal(CallTransportKind.p2p),
            ),
          );
          svc.accept();
          async.flushMicrotasks();
          media.audioRxAt = clock.now(); // Last periodic poll before the gap.
          media.latestAudioRead = () async => switch (outcome) {
            'resumed' => clock.now().subtract(const Duration(milliseconds: 2)),
            'unavailable' => null,
            'failed' => throw StateError('native snapshot unavailable'),
            'timeout' => await pending.future,
            _ => media.audioRxAt,
          };
          fake.onCallSignal!(
            peer,
            CallSignal(
              callId: 'cached-audio-outage',
              type: CallSignalType.health,
              capture: const CallMedia(audio: true, video: true),
              sentAtMs: clock.now().millisecondsSinceEpoch,
            ),
          );
          fake.sent.clear();
          for (var i = 0; i < 8; i++) {
            media.rxAt = clock.now(); // For example, video or RTCP.
            async.elapse(const Duration(milliseconds: 500));
            async.flushMicrotasks();
          }
          if (outcome == 'timeout') {
            expect(media.liveAdmissionChecks, isEmpty);
            expect(media.switches, isEmpty);
            async.elapse(const Duration(seconds: 1));
            async.flushMicrotasks();
          }
          final missingAudio = outcome != 'resumed' && outcome != 'stopped';
          final recover =
              outcome == 'stopped' || (missingAudio && admission == false);
          expect(media.switches, recover ? [CallTransportKind.relay] : isEmpty);
          expect(
            svc.current?.transport,
            recover ? CallTransportKind.relay : CallTransportKind.p2p,
          );
          expect(svc.current?.callId, 'cached-audio-outage');
          expect(svc.current?.status, CallStatus.active);
          expect(media.latestAudioReads, greaterThan(0));
          expect(
            media.liveAdmissionChecks.toSet(),
            missingAudio ? {peer} : isEmpty,
          );
          if (!recover) {
            expect(
              fake.sent.where((s) => s.type == CallSignalType.transportInfo),
              isEmpty,
            );
          }
          expect(fake.sent.where((s) => s.type == CallSignalType.end), isEmpty);
          svc.dispose();
          if (outcome == 'timeout') {
            final switches = media.switches.length;
            pending.complete(media.audioRxAt);
            async.flushMicrotasks();
            expect(
              media.switches,
              hasLength(switches),
              reason: 'late read after disposal',
            );
          }
          async.flushMicrotasks();
        });
      });
    }

    for (final mode in [
      'audio stopped',
      'audio flowing',
      'peer muted',
      'legacy engine',
    ]) {
      test('video liveness with $mode handles audio repair independently', () {
        fakeAsync((async) {
          final fake = _FakeMessaging();
          final media = _FakeMedia()..audioTelemetry = mode != 'legacy engine';
          final svc = CallService(fake, now: () => clock.now(), media: media)
            ..start();
          fake.onCallSignal!(peer, offer('audio-watchdog'));
          svc.accept();
          async.flushMicrotasks();
          media.audioRxAt = clock.now();
          fake.sent.clear();
          for (var i = 0; i < 4; i++) {
            media.rxAt = clock.now(); // video / RTCP keeps arriving
            if (mode == 'audio flowing') media.audioRxAt = clock.now();
            fake.onCallSignal!(
              peer,
              CallSignal(
                callId: 'audio-watchdog',
                type: CallSignalType.health,
                capture: CallMedia(audio: mode != 'peer muted', video: true),
                sentAtMs: clock.now().millisecondsSinceEpoch,
              ),
            );
            async.elapse(kCallHeartbeatInterval);
            async.flushMicrotasks();
          }
          expect(svc.current?.status, CallStatus.active);
          final repairs = fake.sent.where(
            (s) => s.type == CallSignalType.health && s.mediaRepairRequested,
          );
          expect(repairs.isNotEmpty, mode == 'audio stopped');
          svc.dispose();
        });
      });
    }

    test(
      'unmuting gets audio startup grace without video masking a later outage',
      () {
        fakeAsync((async) {
          final fake = _FakeMessaging();
          final media = _FakeMedia()..audioTelemetry = true;
          final svc = CallService(fake, now: () => clock.now(), media: media)
            ..start();
          fake.onCallSignal!(peer, offer('unmute-grace'));
          svc.accept();
          async.flushMicrotasks();
          void capture(bool audio) {
            fake.onCallSignal!(
              peer,
              CallSignal(
                callId: 'unmute-grace',
                type: CallSignalType.health,
                capture: CallMedia(audio: audio, video: true),
                sentAtMs: clock.now().millisecondsSinceEpoch,
              ),
            );
          }

          capture(false);
          for (var i = 0; i < 4; i++) {
            media.rxAt = clock.now();
            async.elapse(kCallHeartbeatInterval);
          }
          capture(true);
          fake.sent.clear();
          media.rxAt = clock.now();
          async.elapse(kCallHeartbeatInterval);
          expect(fake.sent.any((s) => s.mediaRepairRequested), isFalse);
          media.rxAt = clock.now();
          capture(true); // unchanged heartbeat must not restart the grace
          async.elapse(kCallHeartbeatInterval);
          async.flushMicrotasks();
          expect(fake.sent.any((s) => s.mediaRepairRequested), isTrue);
          svc.dispose();
        });
      },
    );

    test(
      'unchanged new capture heartbeat rejects an older mute without UI churn',
      () {
        fakeAsync((async) {
          final fake = _FakeMessaging();
          final media = _FakeMedia();
          final svc = CallService(fake, now: () => clock.now(), media: media)
            ..start();
          fake.onCallSignal!(peer, offer('posture-order'));
          svc.accept();
          async.flushMicrotasks();
          final updates = <Call?>[];
          svc.changes.listen(updates.add);
          void posture(bool audio, int timestamp) => fake.onCallSignal!(
            peer,
            CallSignal(
              callId: 'posture-order',
              type: CallSignalType.health,
              capture: CallMedia(audio: audio, video: true),
              sentAtMs: timestamp,
            ),
          );
          final stamp = clock.now().millisecondsSinceEpoch;
          posture(true, stamp);
          async.flushMicrotasks();
          final before = updates.length;
          posture(true, stamp + 100);
          posture(false, stamp + 50);
          async.flushMicrotasks();
          expect(svc.current!.peerMicOff, isFalse);
          expect(svc.current!.peerCaptureAtMs, stamp + 100);
          expect(updates.length, before);
          expect(media.peerAudioCapture, [true]);
          posture(false, stamp + 200);
          async.flushMicrotasks();
          expect(media.peerAudioCapture, [true, false]);
          expect(svc.current!.peerMicOff, isTrue);
          svc.dispose();
        });
      },
    );

    test('repair request is ignored while initial media is still starting', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        final media = _FakeMedia()..startGate = Completer<bool>();
        final svc = CallService(fake, now: () => clock.now(), media: media)
          ..start();
        svc.placeCall(peer, const CallMedia(audio: true, video: true));
        async.flushMicrotasks();
        final callId = svc.current!.callId;
        fake.onCallSignal!(
          peer,
          CallSignal(
            callId: callId,
            type: CallSignalType.answer,
            posture: CallPosture.direct,
          ),
        );
        async.flushMicrotasks();
        expect(svc.current?.status, CallStatus.connecting);
        fake.sent.clear();

        fake.onCallSignal!(
          peer,
          CallSignal(
            callId: callId,
            type: CallSignalType.health,
            mediaRepairRequested: true,
          ),
        );
        async.flushMicrotasks();

        expect(media.repairs, 0);
        expect(svc.current?.status, CallStatus.connecting);
        expect(fake.sent.where((s) => s.type == CallSignalType.end), isEmpty);

        media.startGate!.complete(true);
        async.flushMicrotasks();
        expect(svc.current?.status, CallStatus.active);
      });
    });

    test(
      'receiver rebuild suppresses peer repairs and restarts receive grace',
      () {
        fakeAsync((async) {
          final fake = _FakeMessaging();
          final media = _FakeMedia()..audioTelemetry = true;
          final svc = CallService(fake, now: () => clock.now(), media: media)
            ..start();
          fake.onCallSignal!(peer, offer('receive-rebuild'));
          svc.accept();
          async.flushMicrotasks();
          void peerBeat() => fake.onCallSignal!(
            peer,
            CallSignal(
              callId: 'receive-rebuild',
              type: CallSignalType.health,
              capture: const CallMedia(audio: true, video: true),
              sentAtMs: clock.now().millisecondsSinceEpoch,
            ),
          );
          media.receiveRepairing = true;
          fake.sent.clear();
          for (var i = 0; i < 4; i++) {
            peerBeat();
            async.elapse(kCallHeartbeatInterval);
          }
          expect(svc.current?.status, CallStatus.active);
          expect(fake.sent.any((s) => s.mediaRepairRequested), isFalse);
          media.receiveRepairing = false;
          media.receiveStartedAt = clock.now();
          async.elapse(kCallHeartbeatInterval);
          expect(fake.sent.any((s) => s.mediaRepairRequested), isFalse);
          peerBeat();
          async.elapse(kCallHeartbeatInterval);
          async.flushMicrotasks();
          expect(fake.sent.any((s) => s.mediaRepairRequested), isTrue);
          svc.dispose();
        });
      },
    );

    test('a repair request landing mid-rebuild does not kill the call', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        // repairRoute reports success while activeTransport is still null —
        // exactly what a peer sees when its request lands while our local
        // session rebuild is in flight (channel closed, engine not yet up).
        final media = _FakeMedia();
        final svc = CallService(fake, now: () => clock.now(), media: media)
          ..start();
        fake.onCallSignal!(peer, offer('call-repair-pending'));
        svc.accept();
        async.flushMicrotasks();
        expect(svc.current?.status, CallStatus.active);
        fake.sent.clear();

        fake.onCallSignal!(
          peer,
          const CallSignal(
            callId: 'call-repair-pending',
            type: CallSignalType.health,
            mediaRepairRequested: true,
          ),
        );
        async.flushMicrotasks();

        expect(media.repairs, 1);
        expect(
          svc.current?.isLive,
          isTrue,
          reason: 'a pending repair must not fail closed',
        );
        expect(fake.sent.where((s) => s.type == CallSignalType.end), isEmpty);
      });
    });

    test(
      'peer relay announcement waits for a health-triggered repair',
      () async {
        final fake = _FakeMessaging();
        final media = _RepairThenRelayMedia()
          ..openedTransport = CallTransportKind.p2p;
        final svc = CallService(
          fake,
          media: media,
          localAllowsP2P: (_) async => true,
          peerReachableForP2P: (_) async => true,
        )..start();
        addTearDown(svc.dispose);
        fake.onCallSignal!(
          peer,
          const CallSignal(
            callId: 'repair-relay-overlap',
            type: CallSignalType.offer,
            media: CallMedia(audio: true),
            posture: CallPosture.direct,
            transport: CallTransportProposal(CallTransportKind.p2p),
          ),
        );
        await svc.accept();
        await pumpEventQueue();
        fake.sent.clear();
        fake.onCallSignal!(
          peer,
          const CallSignal(
            callId: 'repair-relay-overlap',
            type: CallSignalType.health,
            mediaRepairRequested: true,
          ),
        );
        await pumpEventQueue();
        expect(media.receiveRepairing, isTrue);
        expect(media.activeTransport, isNull);
        fake.onCallSignal!(
          peer,
          const CallSignal(
            callId: 'repair-relay-overlap',
            type: CallSignalType.transportInfo,
            transport: CallTransportProposal(CallTransportKind.relay),
          ),
        );
        await pumpEventQueue();
        expect(svc.current?.isLive, isTrue);
        expect(media.switches, isEmpty);
        media.cameraStopped.complete();
        await pumpEventQueue();
        expect(media.switches, [CallTransportKind.relay]);
        expect(svc.current?.transport, CallTransportKind.relay);
        expect(svc.current?.status, CallStatus.active);
        expect(fake.sent.where((s) => s.type == CallSignalType.end), isEmpty);
      },
    );

    test('silent P2P is repaired in place and never announces onion', () async {
      final fake = _FakeMessaging();
      final media = _FakeMedia()..openedTransport = CallTransportKind.p2p;
      final svc = CallService(
        fake,
        media: media,
        localAllowsP2P: (_) async => true,
        peerReachableForP2P: (_) async => true,
      )..start();
      fake.onCallSignal!(
        peer,
        const CallSignal(
          callId: 'p2p-repair',
          type: CallSignalType.offer,
          media: CallMedia(audio: true, video: true),
          posture: CallPosture.direct,
          transport: CallTransportProposal(CallTransportKind.p2p),
        ),
      );
      await svc.accept();
      await Future<void>.delayed(Duration.zero);
      expect(svc.current?.transport, CallTransportKind.p2p);
      fake.sent.clear();

      fake.onCallSignal!(
        peer,
        const CallSignal(
          callId: 'p2p-repair',
          type: CallSignalType.health,
          mediaRepairRequested: true,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(media.repairs, 1);
      expect(svc.current?.transport, CallTransportKind.p2p);
      expect(fake.sent, isEmpty);
    });

    test(
      'closed direct session recovers before the ordinary silence grace',
      () {
        fakeAsync((async) {
          final fake = _FakeMessaging();
          final media = _FakeMedia()..liveDirectAdmission = false;
          final svc = CallService(
            fake,
            now: () => clock.now(),
            media: media,
            localAllowsP2P: (_) async => true,
            peerReachableForP2P: (_) async => true,
          )..start();
          final device = NodeId.fromHex('b' * 64);
          fake.onCallSignal!(
            peer,
            CallSignal(
              callId: 'closed-direct',
              type: CallSignalType.offer,
              media: CallMedia(audio: true),
              posture: CallPosture.direct,
              transport: const CallTransportProposal(CallTransportKind.p2p),
              replyDevice: device.hex,
            ),
          );
          svc.accept();
          async.flushMicrotasks();
          expect(svc.current?.transport, CallTransportKind.p2p);
          media.rxAt = clock.now();
          fake.sent.clear();
          async.elapse(
            kCallDirectSessionSilence - const Duration(milliseconds: 1),
          );
          async.flushMicrotasks();
          expect(media.liveAdmissionChecks, isEmpty);
          expect(media.switches, isEmpty);
          async.elapse(const Duration(seconds: 1));
          async.flushMicrotasks();
          expect(media.liveAdmissionChecks, [device]);
          expect(media.switches, [CallTransportKind.relay]);
          expect(svc.current?.status, CallStatus.active);
          expect(svc.current?.callId, 'closed-direct');
          expect(
            fake.sent
                .where((s) => s.type == CallSignalType.transportInfo)
                .single
                .transport
                ?.kind,
            CallTransportKind.relay,
          );
          svc.dispose();
          async.flushMicrotasks();
          final checked = media.liveAdmissionChecks.length;
          async.elapse(const Duration(seconds: 5));
          async.flushMicrotasks();
          expect(
            media.liveAdmissionChecks.length,
            checked,
            reason: 'disposed probe timer',
          );
        });
      },
    );

    for (final mode in ['first report', 'unmute', 'new receive session']) {
      test('late first capture report preserves established audio ($mode)', () {
        fakeAsync((async) {
          final fake = _FakeMessaging();
          final media = _FakeMedia()
            ..liveDirectAdmission = true
            ..audioTelemetry = true;
          final svc = CallService(
            fake,
            now: () => clock.now(),
            media: media,
            localAllowsP2P: (_) async => true,
            peerReachableForP2P: (_) async => true,
          )..start();
          fake.onCallSignal!(
            peer,
            const CallSignal(
              callId: 'late-capture',
              type: CallSignalType.offer,
              media: CallMedia(audio: true, video: true),
              posture: CallPosture.direct,
              transport: CallTransportProposal(CallTransportKind.p2p),
            ),
          );
          svc.accept();
          async.flushMicrotasks();
          expect(svc.current?.status, CallStatus.active);
          expect(svc.current?.peerCapture, isNull);
          media.audioRxAt = clock.now();
          void capture(bool audio) => fake.onCallSignal!(
            peer,
            CallSignal(
              callId: 'late-capture',
              type: CallSignalType.health,
              capture: CallMedia(audio: audio, video: true),
              sentAtMs: clock.now().millisecondsSinceEpoch,
            ),
          );
          if (mode == 'unmute') capture(false);
          async.elapse(const Duration(seconds: 1));
          if (mode == 'new receive session') {
            media.receiveStartedAt = clock.now();
          }
          // Audio was received before this first capture report. When the
          // network changes between them, no later packet can validate the
          // existing session again. A first report is not evidence of unmute.
          capture(true);
          for (var i = 0; i < 5; i++) {
            media.rxAt = clock.now(); // parent / video remain healthy
            async.elapse(const Duration(seconds: 1));
            async.flushMicrotasks();
          }
          expect(
            media.switches,
            mode == 'first report' ? [CallTransportKind.relay] : isEmpty,
          );
          expect(svc.current?.status, CallStatus.active);
          expect(svc.current?.callId, 'late-capture');
          expect(
            media.liveDirectAdmission,
            isTrue,
            reason: 'parent admission must not hide the audio outage',
          );
          svc.dispose();
          async.flushMicrotasks();
        });
      });
    }

    for (final mode in [
      'stopped',
      'flowing',
      'muted',
      'unknown capture',
      'legacy engine',
      'startup',
      'new session',
      'unmute',
      'repairing',
      'peer anonymous',
    ]) {
      test(
        'established direct audio $mode is checked independently of parent admission',
        () {
          fakeAsync((async) {
            final fake = _FakeMessaging();
            final media = _FakeMedia()
              ..liveDirectAdmission = true
              ..audioTelemetry = mode != 'legacy engine';
            final svc = CallService(
              fake,
              now: () => clock.now(),
              media: media,
              localAllowsP2P: (_) async => true,
              peerReachableForP2P: (_) async => true,
            )..start();
            fake.onCallSignal!(
              peer,
              CallSignal(
                callId: 'independent-audio',
                type: CallSignalType.offer,
                media: CallMedia(audio: true, video: true),
                posture: mode == 'peer anonymous'
                    ? CallPosture.anonymous
                    : CallPosture.direct,
                transport: const CallTransportProposal(CallTransportKind.p2p),
              ),
            );
            svc.accept();
            async.flushMicrotasks();
            expect(
              svc.current?.transport,
              mode == 'peer anonymous'
                  ? CallTransportKind.onion
                  : CallTransportKind.p2p,
            );
            media.audioRxAt = mode == 'startup' ? null : clock.now();
            media.receiveRepairing = mode == 'repairing';
            void capture(bool audio) => fake.onCallSignal!(
              peer,
              CallSignal(
                callId: 'independent-audio',
                type: CallSignalType.health,
                capture: CallMedia(audio: audio, video: true),
                sentAtMs: clock.now().millisecondsSinceEpoch,
              ),
            );
            if (mode != 'unknown capture') {
              capture(mode != 'muted' && mode != 'unmute');
            }
            fake.sent.clear();
            for (var i = 0; i < 8; i++) {
              media.rxAt = clock.now(); // RTCP/video and the parent stay live.
              if (mode == 'flowing') media.audioRxAt = clock.now();
              if (mode == 'new session' && i == 1) {
                media.receiveStartedAt = clock.now();
              }
              if (mode == 'unmute' && i == 2) capture(true);
              async.elapse(const Duration(milliseconds: 500));
              async.flushMicrotasks();
              if (i < 5) {
                expect(
                  media.switches,
                  isEmpty,
                  reason: 'honor audio silence grace',
                );
              }
            }
            expect(
              media.switches,
              mode == 'stopped' ? [CallTransportKind.relay] : isEmpty,
            );
            expect(svc.current?.status, CallStatus.active);
            if (mode == 'stopped') {
              expect(
                media.liveAdmissionChecks,
                isEmpty,
                reason:
                    'established audio delivery is stronger than parent eligibility',
              );
              expect(
                fake.sent
                    .where((s) => s.type == CallSignalType.transportInfo)
                    .single
                    .transport
                    ?.kind,
                CallTransportKind.relay,
              );
              // Fresh relay ingress and repeated old P2P readiness must not bounce
              // this call back onto the failed media path.
              for (var i = 0; i < 3; i++) {
                media.rxAt = clock.now();
                media.audioRxAt = clock.now();
                fake.onCallSignal!(
                  peer,
                  const CallSignal(
                    callId: 'independent-audio',
                    type: CallSignalType.transportInfo,
                    transport: CallTransportProposal(CallTransportKind.p2p),
                  ),
                );
                async.elapse(kCallHeartbeatInterval);
                async.flushMicrotasks();
              }
              expect(media.switches, [CallTransportKind.relay]);
              expect(svc.current?.transport, CallTransportKind.relay);
              expect(
                fake.sent.where((s) => s.type == CallSignalType.end),
                isEmpty,
              );
            }
            svc.dispose();
            async.flushMicrotasks();
          });
        },
      );
    }

    for (final mode in [
      'closed',
      'closed on an unclassified attachment',
      'closes on the next tick',
      'still admitted',
      'unknown',
      'fresh media',
      'fresh ingress but no sender',
      'cached ingress while direct closes',
      'snapshot failed',
      'snapshot timed out',
      'snapshot failed with fresh cached ingress',
      'superseded handover',
    ]) {
      test('checks P2P early after a network handover ($mode)', () {
        fakeAsync((async) {
          final network = StreamController<NetworkAttachment>(sync: true);
          final fake = _FakeMessaging();
          final media = _SnapshotMedia()
            ..openedTransport = CallTransportKind.p2p;
          final svc = CallService(
            fake,
            now: () => clock.now(),
            media: media,
            localAllowsP2P: (_) async => true,
            peerReachableForP2P: (_) async => true,
            networkAttachments: network.stream,
          )..start();
          network.add(NetworkAttachment.cellular);
          async.flushMicrotasks();
          expect(media.liveAdmissionChecks, isEmpty);

          final device = NodeId.fromHex('b' * 64);
          fake.onCallSignal!(
            peer,
            CallSignal(
              callId: 'local-network-handover',
              type: CallSignalType.offer,
              media: CallMedia(audio: true),
              posture: CallPosture.direct,
              transport: const CallTransportProposal(CallTransportKind.p2p),
              replyDevice: device.hex,
            ),
          );
          svc.accept();
          async.flushMicrotasks();
          expect(svc.current?.transport, CallTransportKind.p2p);
          media.rxAt = clock.now();
          media.liveDirectAdmission = switch (mode) {
            'unknown' ||
            'closes on the next tick' ||
            'cached ingress while direct closes' => null,
            'still admitted' => true,
            _ => false,
          };
          final freshIngress =
              mode == 'fresh media' || mode == 'fresh ingress but no sender';
          final unavailableSnapshot = mode.startsWith('snapshot ');
          final fresh = Completer<DateTime?>();
          final admission = Completer<bool?>();
          if (freshIngress || unavailableSnapshot) {
            media.readSnapshot = () => fresh.future;
          }
          if (mode == 'snapshot timed out') {
            // Avoid sharing a tick with the snapshot's timeout.
            async.elapse(const Duration(milliseconds: 250));
          }
          if (mode == 'superseded handover') media.liveAdmissionGate = admission;
          network.add(
            mode == 'closed on an unclassified attachment'
                ? NetworkAttachment.unknown
                : NetworkAttachment.cellular,
          );
          async.flushMicrotasks();
          expect(media.liveAdmissionChecks, [device]);
          switch (mode) {
            case 'closes on the next tick':
              media.liveDirectAdmission = false;
              async.elapse(const Duration(seconds: 1));
            case 'cached ingress while direct closes':
              async.elapse(const Duration(milliseconds: 10));
              media.rxAt = clock.now();
              media.liveDirectAdmission = false;
              async.elapse(const Duration(milliseconds: 990));
            case 'fresh media':
            case 'fresh ingress but no sender':
              async.elapse(const Duration(milliseconds: 10));
              media.liveDirectAdmission = mode == 'fresh media';
              fresh.complete(clock.now());
            case 'snapshot failed with fresh cached ingress':
              async.elapse(const Duration(milliseconds: 10));
              media.rxAt = clock.now();
              media.liveDirectAdmission = true;
              fresh.completeError(StateError('media snapshot unavailable'));
            case 'snapshot failed':
              fresh.completeError(StateError('media snapshot unavailable'));
            case 'snapshot timed out':
              async.elapse(kCallLivenessSnapshotTimeout);
            case 'superseded handover':
              async.elapse(const Duration(milliseconds: 10));
              network.add(NetworkAttachment.cellular);
              media.liveAdmissionGate = null;
              media.liveDirectAdmission = true;
              admission.complete(false);
          }
          async.flushMicrotasks();
          final switched = const {
            'closed',
            'closed on an unclassified attachment',
            'closes on the next tick',
            'cached ingress while direct closes',
            'fresh ingress but no sender',
            'snapshot failed',
            'snapshot timed out',
          }.contains(mode);
          expect(media.switches, switched ? [CallTransportKind.relay] : isEmpty);
          expect(
            media.liveAdmissionChecks,
            mode == 'closes on the next tick' ||
                    freshIngress ||
                    mode == 'snapshot failed with fresh cached ingress' ||
                    mode == 'superseded handover'
                ? [device, device]
                : mode == 'cached ingress while direct closes'
                ? [device, device, device]
                : [device],
          );
          expect(
            media.snapshotReads,
            switched || freshIngress || unavailableSnapshot ? 1 : 0,
          );
          expect(svc.current?.status, CallStatus.active);
          svc.dispose();
          network.close();
          async.flushMicrotasks();
        });
      });
    }

    for (final outcome in [
      'late first reply',
      'late confirmation',
      'unproven relay',
      'sender recovered',
      'new overlay admission with a closed sender',
      'new overlay admission with a recovered sender',
      'overlay admission supersedes the recheck',
      'new handover',
    ]) {
      test('P2P admission started within the handover window: $outcome', () {
        fakeAsync((async) {
          final network = StreamController<NetworkAttachment>(sync: true);
          final admissions = StreamController<void>(sync: true);
          final wire = _FakeMessaging();
          final media = _ReconnectRelayMedia()
            ..liveDirectAdmission = true
            ..proven = outcome != 'unproven relay';
          final svc = CallService(
            wire,
            now: () => clock.now(),
            media: media,
            networkAttachments: network.stream,
            overlaySessionAdmissions: admissions.stream,
            localAllowsP2P: (_) async => true,
            peerReachableForP2P: (_) async => true,
          )..start();
          final device = NodeId.fromHex('b' * 64);
          wire.onCallSignal!(
            peer,
            offer('late-handover-admission').copyWith(
              transport: const CallTransportProposal(CallTransportKind.p2p),
              replyDevice: device.hex,
            ),
          );
          unawaited(svc.accept());
          async.flushMicrotasks();
          expect(svc.current?.transport, CallTransportKind.p2p);

          media.rxAt = clock.now();
          network.add(NetworkAttachment.cellular);
          const offset = Duration(milliseconds: 100);
          async.elapse(
            kCallDirectSessionSilence - const Duration(seconds: 1) - offset,
          );
          media.rxAt = clock.now();
          final first = Completer<bool?>();
          final confirmation = Completer<bool?>();
          final recheck = Completer<bool?>();
          media.liveAdmissionGate = first;
          async.elapse(offset);
          expect(media.liveAdmissionChecks, [device, device, device]);

          final delayFirst = outcome == 'late first reply';
          if (!delayFirst) {
            media.liveAdmissionGate = confirmation;
            first.complete(false);
            async.flushMicrotasks();
            expect(media.liveAdmissionChecks, hasLength(4));
          }
          async.elapse(const Duration(seconds: 1) + offset);
          expect(media.switches, isEmpty);

          final admissionChanged =
              outcome.startsWith('new overlay admission') ||
              outcome == 'overlay admission supersedes the recheck';
          if (admissionChanged) admissions.add(null);
          if (outcome == 'new handover') network.add(NetworkAttachment.cellular);
          media.liveAdmissionGate = admissionChanged ? recheck : null;
          media.liveDirectAdmission =
              outcome == 'sender recovered' || outcome == 'new handover';
          if (delayFirst) {
            first.complete(false);
          } else {
            confirmation.complete(outcome == 'sender recovered');
          }
          async.flushMicrotasks();
          async.elapse(Duration.zero);
          if (admissionChanged) {
            expect(media.liveAdmissionChecks, hasLength(5));
            expect(media.switches, isEmpty, reason: 'the old reply is stale');
            if (outcome == 'overlay admission supersedes the recheck') {
              admissions.add(null);
            }
            media.liveAdmissionGate = null;
            recheck.complete(
              outcome == 'new overlay admission with a recovered sender',
            );
            async.flushMicrotasks();
          }
          final startRelay = const {
            'late first reply',
            'late confirmation',
            'unproven relay',
            'new overlay admission with a closed sender',
          }.contains(outcome);
          expect(media.liveAdmissionChecks, [
            device,
            device,
            device,
            device,
            if (outcome == 'new handover' || admissionChanged) device,
          ]);
          expect(media.switches, startRelay ? [CallTransportKind.relay] : []);
          expect(svc.current?.status, CallStatus.active);

          if (outcome == 'unproven relay') {
            expect(svc.current?.transport, CallTransportKind.p2p);
            media.proven = true;
            async.elapse(kCallRelayCandidateRetry - offset);
            expect(media.switches, [CallTransportKind.relay]);
            async.elapse(offset);
            expect(media.switches, [
              CallTransportKind.relay,
              CallTransportKind.relay,
            ]);
            expect(svc.current?.transport, CallTransportKind.relay);
          }
          svc.dispose();
          unawaited(network.close());
          unawaited(admissions.close());
          async.flushMicrotasks();
        });
      });
    }

    test('keeps the P2P handover observation while media is repairing', () {
      fakeAsync((async) {
        final network = StreamController<NetworkAttachment>(sync: true);
        final wire = _FakeMessaging();
        final media = _SnapshotMedia()..openedTransport = CallTransportKind.p2p;
        final svc = CallService(
          wire,
          now: () => clock.now(),
          media: media,
          networkAttachments: network.stream,
          localAllowsP2P: (_) async => true,
          peerReachableForP2P: (_) async => true,
        )..start();
        final device = NodeId.fromHex('b' * 64);
        wire.onCallSignal!(
          peer,
          offer('network-change-during-repair').copyWith(
            transport: const CallTransportProposal(CallTransportKind.p2p),
            replyDevice: device.hex,
          ),
        );
        unawaited(svc.accept());
        async.flushMicrotasks();
        expect(svc.current?.transport, CallTransportKind.p2p);

        media.rxAt = clock.now();
        media.receiveRepairing = true;
        media.liveDirectAdmission = false;
        network.add(NetworkAttachment.cellular);
        async.elapse(const Duration(seconds: 1));
        expect(media.liveAdmissionChecks, isEmpty);
        expect(media.switches, isEmpty);

        media.receiveRepairing = false;
        async.elapse(const Duration(seconds: 1));
        expect(media.liveAdmissionChecks, [device]);
        expect(media.switches, [CallTransportKind.relay]);
        expect(svc.current?.status, CallStatus.active);
        expect(svc.current?.transport, CallTransportKind.relay);
        svc.dispose();
        unawaited(network.close());
        async.flushMicrotasks();
      });
    });

    for (final offline in [false, true]) {
      test('rechecks the newest P2P handover when a stale query ends '
          '(went offline: $offline)', () {
        fakeAsync((async) {
          final network = StreamController<NetworkAttachment>(sync: true);
          final wire = _FakeMessaging();
          final old = Completer<bool?>();
          final fresh = Completer<bool?>();
          final media = _SnapshotMedia()
            ..openedTransport = CallTransportKind.p2p
            ..liveAdmissionGate = old;
          final svc = CallService(
            wire,
            now: () => clock.now(),
            media: media,
            networkAttachments: network.stream,
            localAllowsP2P: (_) async => true,
            peerReachableForP2P: (_) async => true,
          )..start();
          final device = NodeId.fromHex('b' * 64);
          try {
            wire.onCallSignal!(
              peer,
              offer('handover-awaiting-old-admission').copyWith(
                transport: const CallTransportProposal(CallTransportKind.p2p),
                replyDevice: device.hex,
              ),
            );
            unawaited(svc.accept());
            async.flushMicrotasks();
            expect(svc.current?.transport, CallTransportKind.p2p);
            media.rxAt = clock.now();
            network.add(NetworkAttachment.cellular);
            async.flushMicrotasks();
            expect(media.liveAdmissionChecks, [device]);

            media.liveAdmissionGate = fresh;
            async.elapse(const Duration(milliseconds: 100));
            network.add(NetworkAttachment.wifi);
            network.add(NetworkAttachment.unknown);
            if (offline) network.add(NetworkAttachment.offline);
            async.flushMicrotasks();
            expect(media.liveAdmissionChecks, [device]);
            expect(media.switches, isEmpty);

            old.complete(false);
            async.flushMicrotasks();
            expect(
              media.liveAdmissionChecks,
              offline ? [device] : [device, device],
            );
            expect(media.switches, isEmpty, reason: 'the old result is stale');
            fresh.complete(false);
            async.flushMicrotasks();
            expect(media.switches, offline ? [] : [CallTransportKind.relay]);
            expect(svc.current?.status, CallStatus.active);
          } finally {
            svc.dispose();
            unawaited(network.close());
            async.flushMicrotasks();
          }
        });
      });
    }

    test('unproven early relay keeps the ordinary recovery opportunity', () {
      fakeAsync((async) {
        final network = StreamController<NetworkAttachment>(sync: true);
        final fake = _FakeMessaging();
        final media = _ReconnectRelayMedia()..liveDirectAdmission = false;
        final svc = CallService(
          fake,
          now: () => clock.now(),
          media: media,
          localAllowsP2P: (_) async => true,
          peerReachableForP2P: (_) async => true,
          networkAttachments: network.stream,
        )..start();
        fake.onCallSignal!(
          peer,
          const CallSignal(
            callId: 'relay-not-yet-ready',
            type: CallSignalType.offer,
            media: CallMedia(audio: true),
            posture: CallPosture.direct,
            transport: CallTransportProposal(CallTransportKind.p2p),
          ),
        );
        svc.accept();
        async.flushMicrotasks();
        media.rxAt = clock.now();
        network.add(NetworkAttachment.cellular);
        async.flushMicrotasks();
        expect(media.switches, [CallTransportKind.relay]);
        expect(svc.current?.transport, CallTransportKind.p2p);
        media.proven = true;
        async.elapse(kCallDirectSessionSilence);
        async.flushMicrotasks();
        expect(media.switches, [
          CallTransportKind.relay,
          CallTransportKind.relay,
        ]);
        expect(svc.current?.transport, CallTransportKind.relay);
        expect(svc.current?.status, CallStatus.active);
        svc.dispose();
        network.close();
        async.flushMicrotasks();
      });
    });

    for (final admission in [false, true, null]) {
      test(
        'closed direct session can advance one relay retry ($admission)',
        () {
          fakeAsync((async) {
            final fake = _FakeMessaging();
            final firstCandidate = Completer<bool>();
            final media = _ReconnectRelayMedia()
              ..liveDirectAdmission = false
              ..firstAttempt = firstCandidate;
            final svc = CallService(
              fake,
              now: () => clock.now(),
              media: media,
              localAllowsP2P: (_) async => true,
              peerReachableForP2P: (_) async => true,
            )..start();
            try {
              fake.onCallSignal!(
                peer,
                offer('confirmed-direct-loss').copyWith(
                  transport: const CallTransportProposal(CallTransportKind.p2p),
                ),
              );
              unawaited(svc.accept());
              async.flushMicrotasks();
              expect(svc.current?.transport, CallTransportKind.p2p);
              media.rxAt = clock.now();
              async.elapse(kCallDirectSessionSilence);
              expect(media.switches, [CallTransportKind.relay]);

              async.elapse(const Duration(milliseconds: 1800));
              firstCandidate.complete(false);
              media.liveDirectAdmission = admission;
              async.flushMicrotasks();
              async.elapse(const Duration(milliseconds: 1199));
              expect(media.switches, hasLength(1));
              async.elapse(const Duration(milliseconds: 1));
              expect(media.switches, hasLength(admission == false ? 2 : 1));
              expect(svc.current?.transport, CallTransportKind.p2p);

            // The early probe is optional. Its failure cannot push the
            // original 4.8 s + 5 s retry opportunity further out.
            async.elapse(const Duration(milliseconds: 3799));
              expect(media.switches, hasLength(admission == false ? 2 : 1));
              media.proven = true;
              async.elapse(const Duration(milliseconds: 1));
              expect(media.switches, hasLength(admission == false ? 3 : 2));
              expect(svc.current?.transport, CallTransportKind.relay);
            } finally {
              svc.dispose();
              async.flushMicrotasks();
            }
          });
        },
      );
    }

    for (final readyDuringWake in [false, true]) {
      test('an early reconnect wake preserves the handover deadline '
          '(proved relay during wake: $readyDuringWake)', () {
        fakeAsync((async) {
          final network = StreamController<NetworkAttachment>(sync: true);
          final counts = StreamController<int>(sync: true);
          final fake = _FakeMessaging();
          final initialResult = Completer<bool>();
          final media = _ReconnectRelayMedia()
            ..liveDirectAdmission = false
            ..firstAttempt = initialResult;
          final svc = CallService(
            fake,
            now: () => clock.now(),
            media: media,
            localAllowsP2P: (_) async => true,
            peerReachableForP2P: (_) async => true,
            networkAttachments: network.stream,
            overlaySessions: counts.stream,
          )..start();
          counts.add(0);
          fake.onCallSignal!(
            peer,
            const CallSignal(
              callId: 'handover-retry-deadline',
              type: CallSignalType.offer,
              media: CallMedia(audio: true),
              posture: CallPosture.direct,
              transport: CallTransportProposal(CallTransportKind.p2p),
            ),
          );
          svc.accept();
          async.flushMicrotasks();
          media.rxAt = clock.now();
          network.add(NetworkAttachment.cellular);
          async.flushMicrotasks();
          expect(media.switches, hasLength(1));

          const wakeAt = Duration(seconds: 2);
          async.elapse(const Duration(seconds: 1));
          counts.add(1);
          async.flushMicrotasks();
          expect(media.switches, hasLength(1));
          async.elapse(wakeAt - const Duration(seconds: 1));
          final wakeResult = Completer<bool>();
          media.nextAttempt = wakeResult;
          initialResult.complete(false);
          async.flushMicrotasks();
          expect(media.switches, hasLength(2));
          async.elapse(
            kCallDirectSessionSilence -
                wakeAt +
                const Duration(milliseconds: 200),
          );
          expect(media.switches, hasLength(2), reason: 'no overlapping opens');

          wakeResult.complete(readyDuringWake);
          async.flushMicrotasks();
          async.elapse(Duration.zero);
          expect(media.switches, hasLength(readyDuringWake ? 2 : 3));
          expect(svc.current?.status, CallStatus.active);
          expect(
            svc.current?.transport,
            readyDuringWake ? CallTransportKind.relay : CallTransportKind.p2p,
          );
          async.elapse(
            kCallRelayCandidateRetry - const Duration(milliseconds: 1),
          );
          expect(media.switches, hasLength(readyDuringWake ? 2 : 3));
          svc.dispose();
          network.close();
          counts.close();
          async.flushMicrotasks();
        });
      });
    }

    test('healthy and unknown direct admission retain the normal grace', () {
      for (final verdict in [true, null]) {
        fakeAsync((async) {
          final fake = _FakeMessaging();
          final media = _FakeMedia()..liveDirectAdmission = verdict;
          final svc = CallService(
            fake,
            now: () => clock.now(),
            media: media,
            localAllowsP2P: (_) async => true,
            peerReachableForP2P: (_) async => true,
          )..start();
          fake.onCallSignal!(
            peer,
            const CallSignal(
              callId: 'uncertain-direct',
              type: CallSignalType.offer,
              media: CallMedia(audio: true),
              posture: CallPosture.direct,
              transport: CallTransportProposal(CallTransportKind.p2p),
            ),
          );
          svc.accept();
          async.flushMicrotasks();
          media.rxAt = clock.now();
          async.elapse(kCallMediaRepairAfter - const Duration(milliseconds: 1));
          async.flushMicrotasks();
          expect(media.liveAdmissionChecks, isNotEmpty);
          expect(media.switches, isEmpty);
          svc.dispose();
          async.flushMicrotasks();
        });
      }
    });

    test('a delayed closed-session reply cannot replace recovered media', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        final media = _FakeMedia()..liveAdmissionGate = Completer<bool?>();
        final svc = CallService(
          fake,
          now: () => clock.now(),
          media: media,
          localAllowsP2P: (_) async => true,
          peerReachableForP2P: (_) async => true,
        )..start();
        fake.onCallSignal!(
          peer,
          const CallSignal(
            callId: 'probe-race',
            type: CallSignalType.offer,
            media: CallMedia(audio: true),
            posture: CallPosture.direct,
            transport: CallTransportProposal(CallTransportKind.p2p),
          ),
        );
        svc.accept();
        async.flushMicrotasks();
        media.rxAt = clock.now();
        async.elapse(kCallDirectSessionSilence);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(
          media.liveAdmissionChecks,
          hasLength(1),
          reason: 'only one local query in flight',
        );
        media.rxAt = clock.now();
        media.liveAdmissionGate!.complete(false);
        async.flushMicrotasks();
        expect(
          media.switches,
          isEmpty,
          reason: 'media recovered while admission query was pending',
        );
        expect(svc.current?.transport, CallTransportKind.p2p);
        svc.dispose();
        async.flushMicrotasks();
      });
    });

    for (final admitted in [true, false]) {
      test('direct admission after overlay recovery: $admitted', () {
        fakeAsync((async) {
          final fake = _FakeMessaging();
          final pending = Completer<bool?>();
          final media = _FakeMedia()..liveAdmissionGate = pending;
          final counts = StreamController<int>();
          final svc = CallService(
            fake,
            now: () => clock.now(),
            media: media,
            overlaySessions: counts.stream,
            localAllowsP2P: (_) async => true,
            peerReachableForP2P: (_) async => true,
          )..start();
          counts.add(2);
          fake.onCallSignal!(
            peer,
            const CallSignal(
              callId: 'probe-reconnect',
              type: CallSignalType.offer,
              media: CallMedia(audio: true),
              posture: CallPosture.direct,
              transport: CallTransportProposal(CallTransportKind.p2p),
            ),
          );
          svc.accept();
          async.flushMicrotasks();
          expect(svc.current?.transport, CallTransportKind.p2p);
          media.rxAt = clock.now();
          counts.add(1);
          async.flushMicrotasks();
          async.elapse(kCallDirectSessionSilence);
          expect(media.liveAdmissionChecks, [peer]);

          // The negative result describes a snapshot before reconnect. Keep
          // media silent so cached receive activity cannot mask the race.
          counts.add(2);
          async.flushMicrotasks();
          media.liveAdmissionGate = null;
          media.liveDirectAdmission = admitted;
          pending.complete(false);
          async.flushMicrotasks();
          expect(media.switches, isEmpty, reason: 'the old result is stale');
          expect(media.liveAdmissionChecks, [peer]);

          async.elapse(const Duration(seconds: 1));
          expect(media.liveAdmissionChecks, [peer, peer]);
          expect(
            media.switches,
            admitted ? isEmpty : [CallTransportKind.relay],
          );
          expect(svc.current?.status, CallStatus.active);
          expect(svc.current?.callId, 'probe-reconnect');
          svc.dispose();
          counts.close();
          async.flushMicrotasks();
        });
      });
    }

    for (final readAudio in [false, true]) {
      for (final ipcPending in [false, true]) {
        test('ignores stale direct watchdog evidence after network change '
            '(audio: $readAudio, IPC pending: $ipcPending)', () {
          fakeAsync((async) {
            final fake = _FakeMessaging();
            final network = StreamController<NetworkAttachment>(sync: true);
            final lastAudio = Completer<DateTime?>();
            final admission = Completer<bool?>();
            final media = _FakeMedia()
              ..audioTelemetry = readAudio
              ..latestAudioRead = (() => lastAudio.future)
              ..liveAdmissionGate = admission;
            var generation = 0;
            final svc = CallService(
              fake,
              now: () => clock.now(),
              media: media,
              localAllowsP2P: (_) async => true,
              peerReachableForP2P: (_) async => true,
              networkAttachments: network.stream,
              readNetworkChangeGeneration: () => generation,
            )..start();
            fake.onCallSignal!(
              peer,
              offer('watchdog-network-change').copyWith(
                transport: const CallTransportProposal(CallTransportKind.p2p),
              ),
            );
            unawaited(svc.accept());
            async.flushMicrotasks();
            expect(svc.current?.transport, CallTransportKind.p2p);

            final beforeChange = clock.now();
            media.rxAt = beforeChange;
            media.audioRxAt = beforeChange;
            fake.onCallSignal!(
              peer,
              const CallSignal(
                callId: 'watchdog-network-change',
                type: CallSignalType.health,
                capture: CallMedia(audio: true),
              ),
            );
            async.elapse(kCallDirectSessionSilence);
            expect(media.latestAudioReads, readAudio ? 1 : 0);
            expect(media.liveAdmissionChecks, readAudio ? isEmpty : [peer]);

            if (ipcPending) {
              generation++;
            } else {
              network.add(NetworkAttachment.cellular);
            }
            media.liveAdmissionGate = null;
            media.liveDirectAdmission = true;
            media.latestAudioRead = () async => clock.now();
            lastAudio.complete(beforeChange);
            admission.complete(false);
            async.flushMicrotasks();
            expect(media.switches, isEmpty);
            expect(svc.current?.transport, CallTransportKind.p2p);

            if (ipcPending) network.add(NetworkAttachment.cellular);
            async.elapse(const Duration(seconds: 1));
            if (readAudio) {
              expect(media.latestAudioReads, greaterThan(1));
            } else {
              expect(media.liveAdmissionChecks.length, greaterThan(1));
            }
            expect(media.switches, isEmpty);
            expect(svc.current?.status, CallStatus.active);
            svc.dispose();
            unawaited(network.close());
            async.flushMicrotasks();
          });
        });
      }
    }

    test('a closed-session reply after hangup cannot restart media', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        final media = _FakeMedia()..liveAdmissionGate = Completer<bool?>();
        final svc = CallService(
          fake,
          now: () => clock.now(),
          media: media,
          localAllowsP2P: (_) async => true,
          peerReachableForP2P: (_) async => true,
        )..start();
        fake.onCallSignal!(
          peer,
          const CallSignal(
            callId: 'probe-hangup',
            type: CallSignalType.offer,
            media: CallMedia(audio: true),
            posture: CallPosture.direct,
            transport: CallTransportProposal(CallTransportKind.p2p),
          ),
        );
        svc.accept();
        async.flushMicrotasks();
        media.rxAt = clock.now();
        async.elapse(kCallDirectSessionSilence);
        async.flushMicrotasks();
        expect(media.liveAdmissionChecks, hasLength(1));
        svc.hangup();
        async.flushMicrotasks();
        media.liveAdmissionGate!.complete(false);
        async.flushMicrotasks();
        expect(media.switches, isEmpty);
        expect(svc.current, isNull);
        svc.dispose();
        async.flushMicrotasks();
      });
    });

    test('silent direct media recovers without an incoming peer heartbeat', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        final media = _FakeMedia();
        final svc = CallService(
          fake,
          now: () => clock.now(),
          media: media,
          localAllowsP2P: (_) async => true,
          peerReachableForP2P: (_) async => true,
        )..start();
        fake.onCallSignal!(
          peer,
          const CallSignal(
            callId: 'silent-direct',
            type: CallSignalType.offer,
            media: CallMedia(audio: true),
            posture: CallPosture.direct,
            transport: CallTransportProposal(CallTransportKind.p2p),
          ),
        );
        svc.accept();
        async.flushMicrotasks();
        expect(svc.current?.transport, CallTransportKind.p2p);
        media.rxAt = clock.now();
        fake.sent.clear();
        async.elapse(kCallMediaRepairAfter - const Duration(milliseconds: 1));
        async.flushMicrotasks();
        expect(media.switches, isEmpty, reason: 'honor the receive grace');
        async.elapse(kCallHeartbeatInterval);
        async.flushMicrotasks();
        expect(media.switches, [CallTransportKind.relay]);
        expect(svc.current?.status, CallStatus.active);
        expect(svc.current?.transport, CallTransportKind.relay);
        expect(
          fake.sent
              .where(
                (s) =>
                    s.type == CallSignalType.transportInfo &&
                    s.transport?.kind == CallTransportKind.relay,
              )
              .single
              .transport
              ?.kind,
          CallTransportKind.relay,
        );
        // Fresh ingress on the recovery path keeps the same call alive.
        for (var i = 0; i < 6; i++) {
          media.rxAt = clock.now();
          async.elapse(kCallHeartbeatInterval);
          async.flushMicrotasks();
        }
        expect(svc.current?.callId, 'silent-direct');
        expect(media.switches, [CallTransportKind.relay]);
        expect(fake.sent.where((s) => s.type == CallSignalType.end), isEmpty);
        svc.dispose();
      });
    });

    test(
      'healthy direct ingress does not recover just because health is lost',
      () {
        fakeAsync((async) {
          final fake = _FakeMessaging();
          final media = _FakeMedia();
          final svc = CallService(
            fake,
            now: () => clock.now(),
            media: media,
            localAllowsP2P: (_) async => true,
            peerReachableForP2P: (_) async => true,
          )..start();
          fake.onCallSignal!(
            peer,
            const CallSignal(
              callId: 'healthy-direct',
              type: CallSignalType.offer,
              media: CallMedia(audio: true),
              posture: CallPosture.direct,
              transport: CallTransportProposal(CallTransportKind.p2p),
            ),
          );
          svc.accept();
          async.flushMicrotasks();
          for (var i = 0; i < 8; i++) {
            media.rxAt = clock.now();
            async.elapse(kCallHeartbeatInterval);
            async.flushMicrotasks();
          }
          expect(svc.current?.transport, CallTransportKind.p2p);
          expect(media.switches, isEmpty);
          svc.dispose();
        });
      },
    );

    for (final relaySucceeds in [true, false]) {
      test(
        'superseded failed repair cannot end a pending relay handover: $relaySucceeds',
        () async {
          diagnosticJournal.clear();
          final fake = _FakeMessaging();
          final media = _RepairThenRelayMedia()
            ..openedTransport = CallTransportKind.p2p
            ..repairSucceeds = false
            ..relayGate = Completer<bool>();
          final svc = CallService(
            fake,
            media: media,
            localAllowsP2P: (_) async => true,
            peerReachableForP2P: (_) async => true,
          )..start();
          addTearDown(svc.dispose);
          Call? terminal;
          final sub = svc.changes.listen((c) {
            if (c?.status == CallStatus.ended) terminal = c;
          });
          addTearDown(sub.cancel);
          fake.onCallSignal!(
            peer,
            const CallSignal(
              callId: 'superseded-repair',
              type: CallSignalType.offer,
              media: CallMedia(audio: true),
              posture: CallPosture.direct,
              transport: CallTransportProposal(CallTransportKind.p2p),
            ),
          );
          await svc.accept();
          await pumpEventQueue();
          fake.onCallSignal!(
            peer,
            const CallSignal(
              callId: 'superseded-repair',
              type: CallSignalType.health,
              mediaRepairRequested: true,
            ),
          );
          await pumpEventQueue();
          expect(media.receiveRepairing, isTrue);
          fake.onCallSignal!(
            peer,
            const CallSignal(
              callId: 'superseded-repair',
              type: CallSignalType.transportInfo,
              transport: CallTransportProposal(CallTransportKind.relay),
              sentAtMs: 1,
            ),
          );
          await pumpEventQueue();
          media.cameraStopped.complete();
          await pumpEventQueue();
          expect(media.switches, [CallTransportKind.relay]);
          expect(
            svc.current?.status,
            CallStatus.active,
            reason:
                'the old repair failed, but its successor still owns recovery',
          );
          expect(terminal, isNull);
          expect(fake.sent.where((s) => s.type == CallSignalType.end), isEmpty);
          media.relayGate!.complete(relaySucceeds);
          await pumpEventQueue();
          if (relaySucceeds) {
            expect(svc.current?.transport, CallTransportKind.relay);
            expect(svc.current?.status, CallStatus.active);
            expect(terminal, isNull);
          } else {
            expect(svc.current, isNull);
            expect(
              terminal?.endReason,
              CallEndReason.error,
              reason: 'a successor with no usable route still fails closed',
            );
            if (kDiagnosticReportEnabled) {
              final last = diagnosticJournal.toJson()['last_call_end'] as Map;
              expect(
                (last['values'] as Map)['origin'],
                CallEndOrigin.routeHandoverFailure.index,
              );
            }
          }
        },
      );
    }

    test(
      'a failed repair without a successor still ends the unusable call',
      () async {
        diagnosticJournal.clear();
        final fake = _FakeMessaging();
        final media = _RepairThenRelayMedia()
          ..openedTransport = CallTransportKind.p2p
          ..repairSucceeds = false;
        final svc = CallService(
          fake,
          media: media,
          localAllowsP2P: (_) async => true,
          peerReachableForP2P: (_) async => true,
        )..start();
        addTearDown(svc.dispose);
        fake.onCallSignal!(
          peer,
          const CallSignal(
            callId: 'failed-repair-alone',
            type: CallSignalType.offer,
            media: CallMedia(audio: true),
            posture: CallPosture.direct,
            transport: CallTransportProposal(CallTransportKind.p2p),
          ),
        );
        await svc.accept();
        await pumpEventQueue();
        fake.onCallSignal!(
          peer,
          const CallSignal(
            callId: 'failed-repair-alone',
            type: CallSignalType.health,
            mediaRepairRequested: true,
          ),
        );
        await pumpEventQueue();
        media.cameraStopped.complete();
        await pumpEventQueue();
        expect(svc.current, isNull);
        expect(
          fake.sent.where((s) => s.type == CallSignalType.end),
          hasLength(1),
        );
        if (kDiagnosticReportEnabled) {
          final last = diagnosticJournal.toJson()['last_call_end'] as Map;
          expect(
            (last['values'] as Map)['origin'],
            CallEndOrigin.mediaRepairFailure.index,
          );
        }
      },
    );

    test('concurrent relay announcements join the same route switch', () async {
      final fake = _FakeMessaging();
      final media = _GatedRelaySwitchMedia();
      final svc = CallService(
        fake,
        media: media,
        localAllowsP2P: (_) async => true,
        peerReachableForP2P: (_) async => true,
      )..start();
      addTearDown(svc.dispose);
      fake.onCallSignal!(
        peer,
        const CallSignal(
          callId: 'relay-flight',
          type: CallSignalType.offer,
          media: CallMedia(audio: true),
          posture: CallPosture.direct,
          transport: CallTransportProposal(CallTransportKind.p2p),
        ),
      );
      await svc.accept();
      await pumpEventQueue();
      for (var i = 1; i <= 2; i++) {
        fake.onCallSignal!(
          peer,
          CallSignal(
            callId: 'relay-flight',
            type: CallSignalType.transportInfo,
            transport: const CallTransportProposal(CallTransportKind.relay),
            sentAtMs: i,
          ),
        );
      }
      await pumpEventQueue();
      expect(media.switches, [CallTransportKind.relay]);
      expect(svc.current?.isLive, isTrue);
      media.relayGate.complete(true);
      await pumpEventQueue();
      expect(svc.current?.transport, CallTransportKind.relay);
      expect(svc.current?.status, CallStatus.active);
      expect(fake.sent.where((s) => s.type == CallSignalType.end), isEmpty);
    });

    test(
      'an unproven relay candidate keeps direct alive and bounds retries',
      () {
        fakeAsync((async) {
          final fake = _FakeMessaging();
          final media = _UnprovenRelayMedia()
            ..openedTransport = CallTransportKind.p2p;
          final svc = CallService(
            fake,
            now: () => clock.now(),
            media: media,
            localAllowsP2P: (_) async => true,
            peerReachableForP2P: (_) async => true,
          )..start();
          fake.onCallSignal!(
            peer,
            const CallSignal(
              callId: 'unproven-relay',
              type: CallSignalType.offer,
              media: CallMedia(audio: true),
              posture: CallPosture.direct,
              transport: CallTransportProposal(CallTransportKind.p2p),
            ),
          );
          svc.accept();
          async.flushMicrotasks();
          fake.sent.clear();
          svc.requestRelayRecoveryForDiagnostics();
          async.flushMicrotasks();
          expect(media.switches, [CallTransportKind.relay]);
          expect(svc.current?.status, CallStatus.active);
          expect(svc.current?.transport, CallTransportKind.p2p);
          expect(media.stops, 0);
          expect(
            fake.sent.where(
              (s) =>
                  s.type == CallSignalType.end ||
                  s.type == CallSignalType.transportInfo,
            ),
            isEmpty,
          );
          for (var i = 0; i < 4; i++) {
            svc.requestRelayRecoveryForDiagnostics();
            fake.onCallSignal!(
              peer,
              CallSignal(
                callId: 'unproven-relay',
                type: CallSignalType.transportInfo,
                transport: const CallTransportProposal(CallTransportKind.relay),
                sentAtMs: i + 1,
              ),
            );
            async.flushMicrotasks();
          }
          expect(media.switches, hasLength(1));
          async.elapse(const Duration(seconds: 5));
          svc.requestRelayRecoveryForDiagnostics();
          async.flushMicrotasks();
          expect(media.switches, hasLength(2));
          expect(svc.current?.status, CallStatus.active);
          svc.dispose();
          async.flushMicrotasks();
        });
      },
    );

    group('overlay reconnect', () {
      ({
        CallService svc,
        _ReconnectRelayMedia media,
        StreamController<int> counts,
        StreamController<void> admissions,
        _FakeMessaging wire,
      })
      fixture(
        FakeAsync async, {
        bool seedOffline = true,
        bool defer = true,
        bool useAdmissionEvents = false,
        Completer<bool>? gate,
        Stream<NetworkAttachment>? networkAttachments,
      }) {
        final fake = _FakeMessaging();
        final media = _ReconnectRelayMedia()..firstAttempt = gate;
        final counts = StreamController<int>();
        final admissions = StreamController<void>();
        if (!useAdmissionEvents) unawaited(admissions.close());
        final svc = CallService(
          fake,
          now: () => clock.now(),
          media: media,
          overlaySessions: counts.stream,
          overlaySessionAdmissions: useAdmissionEvents ? admissions.stream : null,
          networkAttachments: networkAttachments,
          localAllowsP2P: (_) async => true,
          peerReachableForP2P: (_) async => true,
        )..start();
        if (seedOffline) counts.add(0);
        fake.onCallSignal!(
          peer,
          const CallSignal(
            callId: 'overlay-retry',
            type: CallSignalType.offer,
            media: CallMedia(audio: true),
            posture: CallPosture.direct,
            transport: CallTransportProposal(CallTransportKind.p2p),
          ),
        );
        svc.accept();
        async.flushMicrotasks();
        if (defer) svc.requestRelayRecoveryForDiagnostics();
        async.flushMicrotasks();
        expect(media.switches, defer ? [CallTransportKind.relay] : isEmpty);
        return (
          svc: svc,
          media: media,
          counts: counts,
          admissions: admissions,
          wire: fake,
        );
      }

      test('a second real admission wakes retries with the count unchanged', () {
        fakeAsync((async) {
          final t = fixture(async, defer: false, useAdmissionEvents: true);
          t.counts.add(3);
          t.admissions.add(null);
          async.flushMicrotasks();
          expect(t.media.switches, isEmpty, reason: 'no pending handover');
          t.svc.requestRelayRecoveryForDiagnostics();
          async.flushMicrotasks();
          expect(t.media.switches, hasLength(1));
          t.admissions.add(null);
          async.flushMicrotasks();
          expect(t.media.switches, hasLength(2));
          expect(t.svc.current?.transport, CallTransportKind.p2p);

          t.media.proven = true;
          t.counts.add(3);
          async.flushMicrotasks();
          expect(t.media.switches, hasLength(2));
          final before = clock.now();
          t.admissions.add(null);
          async.flushMicrotasks();
          expect(clock.now(), before);
          expect(t.media.switches, hasLength(3));
          expect(t.svc.current?.transport, CallTransportKind.relay);
          t.svc.dispose();
          expect(t.admissions.hasListener, isFalse);
          t.admissions.close();
          // This stream was intentionally not subscribed in this mode.
          unawaited(t.counts.close());
          async.flushMicrotasks();
        });
      });

      test('admissions during one candidate coalesce until verification ends', () {
        fakeAsync((async) {
          final gate = Completer<bool>();
          final t = fixture(async, gate: gate, useAdmissionEvents: true);
          for (var i = 0; i < 3; i++) {
            t.admissions.add(null);
          }
          async.flushMicrotasks();
          expect(t.media.switches, hasLength(1));
          gate.complete(false);
          async.flushMicrotasks();
          expect(t.media.switches, hasLength(2));
          expect(t.svc.current?.transport, CallTransportKind.p2p);

          t.svc.dispose();
          expect(t.admissions.hasListener, isFalse);
          t.admissions.close();
          unawaited(t.counts.close());
          async.flushMicrotasks();
        });
      });

      test('wakes a deferred candidate without advancing the retry clock', () {
        fakeAsync((async) {
          final t = fixture(async);
          t.media.proven = true;
          t.counts.add(1);
          async.flushMicrotasks();
          expect(t.media.switches, hasLength(2));
          expect(t.svc.current?.transport, CallTransportKind.relay);
          t.svc.dispose();
          t.counts.close();
          async.flushMicrotasks();
        });
      });

      void peerRelay(
        _FakeMessaging wire,
        CallSignalType type,
        int? at, {
        NodeId? sender,
        bool? retainedConsent = true,
      }) {
        wire.onCallSignal!(
          sender ?? peer,
          CallSignal(
            callId: 'overlay-retry',
            type: type,
            transport: const CallTransportProposal(CallTransportKind.relay),
            p2pUpgradeAllowed: retainedConsent,
            sentAtMs: at,
          ),
        );
      }

      for (final type in [CallSignalType.transportInfo, CallSignalType.health]) {
        test('fresh peer relay report wakes a deferred candidate: $type', () {
          fakeAsync((async) {
            final t = fixture(async);
            t.media.proven = true;
            peerRelay(t.wire, type, 10);
            async.flushMicrotasks();
            expect(t.media.switches, hasLength(2));
            expect(t.svc.current?.transport, CallTransportKind.relay);
            expect(t.svc.current?.status, CallStatus.active);
            t.svc.dispose();
            t.counts.close();
            async.flushMicrotasks();
          });
        });
      }

      test('a fresh peer relay hint survives unfinished qualification', () {
        fakeAsync((async) {
          final gate = Completer<bool>();
          final t = fixture(async, gate: gate);
          peerRelay(t.wire, CallSignalType.transportInfo, 10);
          async.flushMicrotasks();
          expect(t.media.switches, hasLength(1));
          t.media.proven = true;
          gate.complete(false);
          async.flushMicrotasks();
          expect(t.media.switches, hasLength(2));
          expect(t.svc.current?.transport, CallTransportKind.relay);
          t.svc.dispose();
          t.counts.close();
          async.flushMicrotasks();
        });
      });

      test('only one dated peer relay report can bypass the retry delay', () {
        fakeAsync((async) {
          final t = fixture(async);
          t.wire.onCallSignal!(
            peer,
            const CallSignal(
              callId: 'overlay-retry',
              type: CallSignalType.health,
              transport: CallTransportProposal(CallTransportKind.p2p),
              sentAtMs: 10,
            ),
          );
          peerRelay(t.wire, CallSignalType.transportInfo, 9);
          peerRelay(t.wire, CallSignalType.health, 9);
          peerRelay(t.wire, CallSignalType.transportInfo, null);
          peerRelay(
            t.wire,
            CallSignalType.transportInfo,
            11,
            retainedConsent: null,
          );
          peerRelay(
            t.wire,
            CallSignalType.transportInfo,
            12,
            sender: NodeId.fromHex('b' * 64),
          );
          async.flushMicrotasks();
          expect(t.media.switches, hasLength(1));
          peerRelay(t.wire, CallSignalType.transportInfo, 12);
          async.flushMicrotasks();
          expect(t.media.switches, hasLength(2));
          expect(t.svc.current?.transport, CallTransportKind.p2p);

          t.media.proven = true;
          for (var at = 12; at < 16; at++) {
            peerRelay(t.wire, CallSignalType.transportInfo, at);
            peerRelay(t.wire, CallSignalType.health, at);
          }
          async.flushMicrotasks();
          expect(t.media.switches, hasLength(2));
          async.elapse(const Duration(seconds: 5));
          expect(t.media.switches, hasLength(3));
          expect(t.svc.current?.transport, CallTransportKind.relay);
          t.svc.dispose();
          t.counts.close();
          async.flushMicrotasks();
        });
      });

      test(
        'a surviving session does not hide a restored relay opportunity',
        () {
          fakeAsync((async) {
            final t = fixture(async, seedOffline: false, defer: false);
            t.counts.add(2);
            async.flushMicrotasks();
            t.svc.requestRelayRecoveryForDiagnostics();
            async.flushMicrotasks();
            expect(t.media.switches, hasLength(1));
            expect(t.svc.current?.transport, CallTransportKind.p2p);

            // One old session remains visible throughout handover. Requiring
            // a zero count loses the recovery opportunity of the new session.
            t.counts.add(1);
            async.flushMicrotasks();
            expect(t.media.switches, hasLength(1));
            t.media.proven = true;
            t.counts.add(2);
            async.flushMicrotasks();
            expect(t.media.switches, hasLength(2));
            expect(t.svc.current?.transport, CallTransportKind.relay);
            expect(t.svc.current?.status, CallStatus.active);
            expect(
              t.wire.sent.where((s) => s.type == CallSignalType.end),
              isEmpty,
            );
            t.svc.dispose();
            t.counts.close();
            async.flushMicrotasks();
          });
        },
      );

      test('replacement published before old session exit wakes once', () {
        fakeAsync((async) {
          final t = fixture(async, seedOffline: false, defer: false);
          t.counts.add(2);
          async.flushMicrotasks();
          t.svc.requestRelayRecoveryForDiagnostics();
          async.flushMicrotasks();
          t.media.proven = true;
          t.counts.add(3);
          async.flushMicrotasks();
          expect(t.media.switches, hasLength(1));
          // Native registration may publish its successor before the old
          // runner's teardown. This order never passes through zero either.
          t.counts.add(2);
          async.flushMicrotasks();
          expect(t.media.switches, hasLength(2));
          expect(t.svc.current?.transport, CallTransportKind.relay);
          t.svc.dispose();
          t.counts.close();
          async.flushMicrotasks();
        });
      });

      for (final replacementFirst in [false, true]) {
        test(
          'partial reconnect during qualification retains wake, '
          'replacement first=$replacementFirst',
          () {
            fakeAsync((async) {
              final gate = Completer<bool>();
              final t = fixture(
                async,
                seedOffline: false,
                defer: false,
                gate: gate,
              );
              t.counts.add(replacementFirst ? 2 : 3);
              async.flushMicrotasks();
              t.svc.requestRelayRecoveryForDiagnostics();
              async.flushMicrotasks();
              t.counts.add(replacementFirst ? 3 : 2);
              t.counts.add(replacementFirst ? 2 : 3);
              async.flushMicrotasks();
              expect(
                t.media.switches,
                hasLength(1),
                reason: 'no overlapping opens',
              );
              t.media.proven = true;
              gate.complete(false);
              async.flushMicrotasks();
              expect(t.media.switches, hasLength(2));
              expect(t.svc.current?.transport, CallTransportKind.relay);
              t.svc.dispose();
              t.counts.close();
              async.flushMicrotasks();
            });
          },
        );
      }

      test(
        'partial recovery is a single wake hint, never a delivery proof',
        () {
          fakeAsync((async) {
            final t = fixture(async, seedOffline: false, defer: false);
            t.counts.add(2);
            async.flushMicrotasks();
            t.svc.requestRelayRecoveryForDiagnostics();
            async.flushMicrotasks();
            t.counts.add(1);
            t.counts.add(2);
            async.flushMicrotasks();
            expect(t.media.switches, hasLength(2));
            expect(t.svc.current?.transport, CallTransportKind.p2p);
            for (final n in [2, 3, 3, 4]) {
              t.counts.add(n);
            }
            async.flushMicrotasks();
            expect(t.media.switches, hasLength(2));
            expect(t.svc.current?.status, CallStatus.active);
            expect(
              t.wire.sent.where((s) => s.type == CallSignalType.end),
              isEmpty,
            );
            t.svc.dispose();
            t.counts.close();
            async.flushMicrotasks();
          });
        },
      );

      test(
        'a count is only a wake hint and duplicate positives do not retry',
        () {
          fakeAsync((async) {
            final t = fixture(async);
            t.counts.add(1);
            async.flushMicrotasks();
            expect(t.media.switches, hasLength(2));
            expect(t.svc.current?.transport, CallTransportKind.p2p);
            for (final n in [1, 2, 2, 3]) {
              t.counts.add(n);
            }
            async.flushMicrotasks();
            expect(t.media.switches, hasLength(2));
            t.counts.add(0);
            t.counts.add(2);
            async.flushMicrotasks();
            expect(t.media.switches, hasLength(3));
            expect(t.svc.current?.status, CallStatus.active);
            t.svc.dispose();
            t.counts.close();
            async.flushMicrotasks();
          });
        },
      );

      test(
        'initial positive snapshot does not cancel the normal retry delay',
        () {
          fakeAsync((async) {
            final t = fixture(async, seedOffline: false);
            t.media.proven = true;
            t.counts.add(1);
            async.flushMicrotasks();
            expect(t.media.switches, hasLength(1));
            expect(t.svc.current?.transport, CallTransportKind.p2p);
            t.svc.dispose();
            t.counts.close();
            async.flushMicrotasks();
          });
        },
      );

      for (final succeeded in [false, true]) {
        test(
          'an in-flight candidate retains wake until completion=$succeeded',
          () {
            fakeAsync((async) {
              final gate = Completer<bool>();
              final t = fixture(async, gate: gate);
              t.media.proven = true;
              t.counts.add(1);
              async.flushMicrotasks();
              expect(t.media.switches, hasLength(1), reason: 'no overlap');
              gate.complete(succeeded);
              async.flushMicrotasks();
              expect(t.media.switches, hasLength(succeeded ? 1 : 2));
              expect(t.svc.current?.transport, CallTransportKind.relay);
              t.svc.dispose();
              t.counts.close();
              async.flushMicrotasks();
            });
          },
        );
      }

      test('a retired call cannot consume an in-flight wake', () {
        fakeAsync((async) {
          final gate = Completer<bool>();
          final t = fixture(async, gate: gate);
          t.counts.add(1);
          async.flushMicrotasks();
          t.svc.hangup();
          async.flushMicrotasks();
          gate.complete(false);
          async.flushMicrotasks();
          expect(t.media.switches, hasLength(1));
          expect(t.svc.current, isNull);
          t.svc.dispose();
          async.flushMicrotasks();
          expect(t.counts.hasListener, isFalse);
          t.counts.add(0);
          t.counts.add(1);
          t.counts.close();
          async.flushMicrotasks();
          expect(t.media.switches, hasLength(1));
        });
      });

      test('a retired relay attempt cannot delay the next call', () {
        fakeAsync((async) {
          final oldCandidate = Completer<bool>();
          final t = fixture(async, gate: oldCandidate);
          t.svc.hangup();
          async.flushMicrotasks();
          const nextCall = 'next-direct-call';
          t.wire.onCallSignal!(
            peer,
            const CallSignal(
              callId: nextCall,
              type: CallSignalType.offer,
              media: CallMedia(audio: true),
              posture: CallPosture.direct,
              transport: CallTransportProposal(CallTransportKind.p2p),
            ),
          );
          t.svc.accept();
          async.flushMicrotasks();
          expect(t.svc.current?.status, CallStatus.active);
          expect(t.svc.current?.transport, CallTransportKind.p2p);
          t.media.rxAt = clock.now();
          t.media.liveDirectAdmission = false;
          t.media.proven = true;
          async.elapse(kCallDirectSessionSilence);
          expect(oldCandidate.isCompleted, isFalse);
          expect(t.media.liveAdmissionChecks, [peer]);
          expect(t.svc.current?.transport, CallTransportKind.relay);

          oldCandidate.complete(false);
          async.flushMicrotasks();
          expect(t.media.switches, [
            CallTransportKind.relay,
            CallTransportKind.relay,
          ]);
          expect(t.svc.current?.callId, nextCall);
          expect(t.svc.current?.status, CallStatus.active);
          expect(t.svc.current?.transport, CallTransportKind.relay);
          t.svc.dispose();
          t.counts.close();
          async.flushMicrotasks();
        });
      });

      test('new connections alone cannot request a relay handover', () {
        fakeAsync((async) {
          final t = fixture(async, defer: false);
          t.counts.add(1);
          async.flushMicrotasks();
          expect(t.media.switches, isEmpty);
          expect(t.svc.current?.transport, CallTransportKind.p2p);
          t.svc.dispose();
          t.counts.close();
          async.flushMicrotasks();
        });
      });

      test('observer errors cannot discard a later reconnect wake', () {
        fakeAsync((async) {
          final t = fixture(async);
          t.counts.addError(StateError('observer unavailable'));
          async.flushMicrotasks();
          expect(t.svc.current?.status, CallStatus.active);
          t.media.proven = true;
          t.counts.add(1);
          async.flushMicrotasks();
          expect(t.media.switches, hasLength(2));
          expect(t.svc.current?.transport, CallTransportKind.relay);
          t.svc.dispose();
          t.counts.close();
          async.flushMicrotasks();
        });
      });

      test(
        'retries a failed outbound route while inbound audio stays fresh',
        () {
          fakeAsync((async) {
            final t = fixture(async);
            t.media.proven = true;
            for (var i = 0; i < 5; i++) {
              t.media.rxAt = clock.now();
              async.elapse(const Duration(seconds: 1));
              async.flushMicrotasks();
            }
            expect(t.media.switches, hasLength(2));
            expect(t.svc.current?.transport, CallTransportKind.relay);
            t.svc.dispose();
            t.counts.close();
            async.flushMicrotasks();
          });
        },
      );

      test(
        'timer retries remain bounded and cannot authorize an unproven path',
        () {
          fakeAsync((async) {
            final t = fixture(async);
            for (var i = 1; i <= 10; i++) {
              t.media.rxAt = clock.now();
              async.elapse(const Duration(seconds: 1));
              async.flushMicrotasks();
              expect(t.media.switches, hasLength(1 + i ~/ 5));
              expect(t.svc.current?.transport, CallTransportKind.p2p);
            }
            t.svc.dispose();
            t.counts.close();
            async.flushMicrotasks();
          });
        },
      );

      for (final wake in ['timer', 'admission', 'return before deadline']) {
        test('deferred relay waits out the local outage: $wake', () {
          fakeAsync((async) {
            final network = StreamController<NetworkAttachment>(sync: true);
            final t = fixture(async, networkAttachments: network.stream);
            network.add(NetworkAttachment.offline);
            t.media.proven = true;
            if (wake == 'admission') t.counts.add(1);
            async.flushMicrotasks();
            expect(t.media.switches, [CallTransportKind.relay]);

            const beforeDeadline = Duration(seconds: 1);
            final earlyReturn = wake == 'return before deadline';
            async.elapse(
              earlyReturn
                  ? kCallRelayCandidateRetry - beforeDeadline
                  : kCallRelayCandidateRetry,
            );
            expect(t.media.switches, [CallTransportKind.relay]);
            expect(t.svc.current?.transport, CallTransportKind.p2p);
            expect(t.svc.current?.status, CallStatus.active);

            t.media.rxAt = clock.now();
            network.add(NetworkAttachment.cellular);
            async.flushMicrotasks();
            if (earlyReturn) {
              expect(t.media.switches, [CallTransportKind.relay]);
              async.elapse(beforeDeadline);
            }
            expect(t.media.switches, [
              CallTransportKind.relay,
              CallTransportKind.relay,
            ]);
            expect(t.svc.current?.transport, CallTransportKind.relay);
            expect(t.svc.current?.status, CallStatus.active);
            t.svc.dispose();
            unawaited(network.close());
            unawaited(t.counts.close());
            async.flushMicrotasks();
          });
        });
      }

      test(
        'reconnect wake waits for repair without losing the deferred retry',
        () {
          fakeAsync((async) {
            final t = fixture(async);
            t.media.receiveRepairing = true;
            t.media.proven = true;
            t.counts.add(1);
            async.flushMicrotasks();
            expect(t.media.switches, hasLength(1));
            t.media.receiveRepairing = false;
            t.media.rxAt = clock.now();
            async.elapse(const Duration(seconds: 1));
            async.flushMicrotasks();
            expect(t.media.switches, hasLength(2));
            expect(t.svc.current?.transport, CallTransportKind.relay);
            t.svc.dispose();
            t.counts.close();
            async.flushMicrotasks();
          });
        },
      );

      test('hangup cancels a pending timer before another call can use it', () {
        fakeAsync((async) {
          final t = fixture(async);
          for (var i = 0; i < 2; i++) {
            t.media.rxAt = clock.now();
            async.elapse(const Duration(seconds: 1));
            async.flushMicrotasks();
          }
          t.svc.hangup();
          async.flushMicrotasks();
          t.wire.onCallSignal!(
            peer,
            const CallSignal(
              callId: 'new-overlay-call',
              type: CallSignalType.offer,
              media: CallMedia(audio: true),
              posture: CallPosture.direct,
              transport: CallTransportProposal(CallTransportKind.p2p),
            ),
          );
          t.svc.accept();
          async.flushMicrotasks();
          t.svc.requestRelayRecoveryForDiagnostics();
          async.flushMicrotasks();
          expect(t.media.switches, hasLength(2));
          t.media.proven = true;
          for (var i = 0; i < 3; i++) {
            t.media.rxAt = clock.now();
            async.elapse(const Duration(seconds: 1));
            async.flushMicrotasks();
          }
          expect(
            t.media.switches,
            hasLength(2),
            reason: 'retired timer deadline',
          );
          expect(t.svc.current?.callId, 'new-overlay-call');
          expect(t.svc.current?.transport, CallTransportKind.p2p);
          for (var i = 0; i < 2; i++) {
            t.media.rxAt = clock.now();
            async.elapse(const Duration(seconds: 1));
            async.flushMicrotasks();
          }
          expect(
            t.media.switches,
            hasLength(3),
            reason: 'new call owns its timer',
          );
          expect(t.svc.current?.transport, CallTransportKind.relay);
          t.svc.dispose();
          t.counts.close();
          async.flushMicrotasks();
        });
      });

      test('a repairing receiver is not interrupted by a count hint', () {
        fakeAsync((async) {
          final t = fixture(async);
          t.media.receiveRepairing = true;
          t.counts.add(1);
          async.flushMicrotasks();
          expect(t.media.switches, hasLength(1));
          expect(t.svc.current?.status, CallStatus.active);
          t.svc.dispose();
          t.counts.close();
          async.flushMicrotasks();
        });
      });
    });

    test(
      'a failed candidate with no surviving old route still ends the call',
      () async {
        final fake = _FakeMessaging();
        final media = _UnprovenRelayMedia()..retainDirect = false;
        Call? terminal;
        final svc = CallService(
          fake,
          media: media,
          localAllowsP2P: (_) async => true,
          peerReachableForP2P: (_) async => true,
        )..start();
        final subscription = svc.changes.listen((call) {
          if (call?.status == CallStatus.ended) terminal = call;
        });
        addTearDown(subscription.cancel);
        addTearDown(svc.dispose);
        fake.onCallSignal!(
          peer,
          const CallSignal(
            callId: 'no-surviving-route',
            type: CallSignalType.offer,
            media: CallMedia(audio: true),
            posture: CallPosture.direct,
            transport: CallTransportProposal(CallTransportKind.p2p),
          ),
        );
        await svc.accept();
        await pumpEventQueue();
        fake.sent.clear();
        expect(await svc.requestRelayRecoveryForDiagnostics(), isFalse);
        await pumpEventQueue();
        expect(svc.current, isNull);
        expect(terminal?.endReason, CallEndReason.error);
        expect(
          fake.sent.where((s) => s.type == CallSignalType.end),
          hasLength(1),
        );
      },
    );

    test('failed P2P repair falls back to relay and tells the peer', () async {
      final fake = _FakeMessaging();
      final media = _FakeMedia()
        ..openedTransport = CallTransportKind.p2p
        ..repairTo = CallTransportKind.relay;
      final svc = CallService(
        fake,
        media: media,
        localAllowsP2P: (_) async => true,
        peerReachableForP2P: (_) async => true,
      )..start();
      fake.onCallSignal!(
        peer,
        const CallSignal(
          callId: 'p2p-relay-repair',
          type: CallSignalType.offer,
          media: CallMedia(audio: true),
          posture: CallPosture.direct,
          transport: CallTransportProposal(CallTransportKind.p2p),
        ),
      );
      await svc.accept();
      await Future<void>.delayed(Duration.zero);
      fake.sent.clear();

      fake.onCallSignal!(
        peer,
        const CallSignal(
          callId: 'p2p-relay-repair',
          type: CallSignalType.health,
          mediaRepairRequested: true,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(svc.current?.transport, CallTransportKind.relay);
      expect(fake.sent.single.type, CallSignalType.transportInfo);
      expect(fake.sent.single.transport?.kind, CallTransportKind.relay);
    });

    test('peer onion downgrade is ignored without local consent', () async {
      final fake = _FakeMessaging();
      final media = _FakeMedia()..openedTransport = CallTransportKind.p2p;
      final svc = CallService(
        fake,
        media: media,
        localAllowsP2P: (_) async => true,
        peerReachableForP2P: (_) async => true,
      )..start();
      fake.onCallSignal!(
        peer,
        const CallSignal(
          callId: 'p2p-follow',
          type: CallSignalType.offer,
          media: CallMedia(audio: true),
          posture: CallPosture.direct,
          transport: CallTransportProposal(CallTransportKind.p2p),
        ),
      );
      await svc.accept();
      await Future<void>.delayed(Duration.zero);
      fake.sent.clear();

      fake.onCallSignal!(
        peer,
        const CallSignal(
          callId: 'p2p-follow',
          type: CallSignalType.transportInfo,
          transport: CallTransportProposal(CallTransportKind.onion),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(media.repairs, 0);
      expect(svc.current?.transport, CallTransportKind.p2p);
      expect(fake.sent, isEmpty);
    });

    for (final posture in CallPosture.values) {
      test('diagnostic relay recovery preserves $posture posture', () async {
        final fake = _FakeMessaging();
        final media = _FakeMedia()
          ..openedTransport = posture == CallPosture.anonymous
              ? CallTransportKind.onion
              : CallTransportKind.p2p;
        final svc = CallService(
          fake,
          media: media,
          localAllowsP2P: (_) async => true,
          peerReachableForP2P: (_) async => true,
        )..start();
        addTearDown(svc.dispose);
        expect(await svc.requestRelayRecoveryForDiagnostics(), isFalse);
        fake.onCallSignal!(
          peer,
          CallSignal(
            callId: 'diagnostic-relay-recovery',
            type: CallSignalType.offer,
            media: const CallMedia(audio: true),
            posture: posture,
            transport: const CallTransportProposal(CallTransportKind.p2p),
          ),
        );
        expect(await svc.requestRelayRecoveryForDiagnostics(), isFalse);
        expect(
          media.switches,
          isEmpty,
          reason: 'ringing is not an active route',
        );
        await svc.accept();
        await Future<void>.delayed(Duration.zero);
        final previousTransport = svc.current?.transport;
        fake.sent.clear();
        final recovered = await svc.requestRelayRecoveryForDiagnostics();
        if (posture == CallPosture.direct) {
          expect(recovered, isTrue);
          expect(media.switches, [CallTransportKind.relay]);
          expect(svc.current?.status, CallStatus.active);
          expect(svc.current?.transport, CallTransportKind.relay);
          expect(
            fake.sent
                .where((s) => s.type == CallSignalType.transportInfo)
                .single
                .transport
                ?.kind,
            CallTransportKind.relay,
            reason:
                'the peer follows the ordinary authenticated recovery signal',
          );
        } else {
          expect(recovered, isFalse);
          expect(media.switches, isEmpty);
          expect(svc.current?.transport, previousTransport);
          if (posture == CallPosture.anonymous) {
            expect(previousTransport, CallTransportKind.onion);
          }
          expect(
            fake.sent,
            isEmpty,
            reason: 'an anonymous call cannot be exposed',
          );
        }
        svc.dispose();
        expect(await svc.requestRelayRecoveryForDiagnostics(), isFalse);
      });
    }

    test('peer relay fallback is followed for a direct P2P call', () async {
      final fake = _FakeMessaging();
      final media = _FakeMedia()..openedTransport = CallTransportKind.p2p;
      final svc = CallService(
        fake,
        media: media,
        localAllowsP2P: (_) async => true,
        peerReachableForP2P: (_) async => true,
      )..start();
      fake.onCallSignal!(
        peer,
        const CallSignal(
          callId: 'p2p-relay-follow',
          type: CallSignalType.offer,
          media: CallMedia(audio: true),
          posture: CallPosture.direct,
          transport: CallTransportProposal(CallTransportKind.p2p),
        ),
      );
      await svc.accept();
      await Future<void>.delayed(Duration.zero);
      fake.sent.clear();

      fake.onCallSignal!(
        peer,
        const CallSignal(
          callId: 'p2p-relay-follow',
          type: CallSignalType.transportInfo,
          transport: CallTransportProposal(CallTransportKind.relay),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(media.switches, [CallTransportKind.relay]);
      expect(svc.current?.transport, CallTransportKind.relay);
      expect(fake.sent.single.type, CallSignalType.transportInfo);
      expect(fake.sent.single.p2pUpgradeAllowed, isTrue);
      // Once settled, repeats acknowledge no new transition and cannot
      // create a relay-announcement feedback loop.
      fake.onCallSignal!(peer, fake.sent.single);
      await Future<void>.delayed(Duration.zero);
      expect(media.switches, [CallTransportKind.relay]);
      expect(fake.sent.length, 1);
    });

    test(
      'relay follow waits for an in-flight P2P start before switching',
      () async {
        final fake = _FakeMessaging();
        final media = _GatedStartMedia()
          ..openedTransport = CallTransportKind.p2p;
        final svc = CallService(
          fake,
          media: media,
          localAllowsP2P: (_) async => true,
          peerReachableForP2P: (_) async => true,
        )..start();
        fake.onCallSignal!(
          peer,
          const CallSignal(
            callId: 'p2p-start-race',
            type: CallSignalType.offer,
            media: CallMedia(audio: true),
            posture: CallPosture.direct,
            transport: CallTransportProposal(CallTransportKind.p2p),
          ),
        );
        await svc.accept();
        await Future<void>.delayed(Duration.zero);

        fake.onCallSignal!(
          peer,
          const CallSignal(
            callId: 'p2p-start-race',
            type: CallSignalType.transportInfo,
            transport: CallTransportProposal(CallTransportKind.relay),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(
          media.switches,
          isEmpty,
          reason: 'setup has no session to switch yet',
        );
        expect(svc.current?.status, CallStatus.connecting);
        media.initialStart.complete(false);
        await Future<void>.delayed(Duration.zero);

        expect(media.switches, [CallTransportKind.relay]);
        expect(svc.current?.transport, CallTransportKind.relay);
        expect(svc.current?.status, CallStatus.active);
      },
    );
  });

  group('late direct route after relay startup', () {
    final peer = NodeId.fromHex('a' * 64);

    CallSignal ready(String id, {int version = 6}) => CallSignal(
      callId: id,
      type: CallSignalType.transportInfo,
      transport: const CallTransportProposal(CallTransportKind.p2p),
      protocolVersion: version,
    );

    void offer(
      _FakeMessaging fake,
      String id, {
      int version = 6,
      CallTransportKind proposal = CallTransportKind.p2p,
      CallPosture posture = CallPosture.direct,
      NodeId? device,
    }) => fake.onCallSignal!(
      peer,
      CallSignal(
        callId: id,
        type: CallSignalType.offer,
        media: const CallMedia(audio: true),
        posture: posture,
        transport: CallTransportProposal(proposal),
        protocolVersion: version,
        replyDevice: device?.hex,
      ),
    );

    for (final (audioOnNewNetwork, directStartsDuringSample) in [
      (true, false),
      (false, false),
      (true, true),
    ]) {
      test('early relay recovery while direct admission is pending '
          '(audio on new network: $audioOnNewNetwork, '
          'direct starts during sample: $directStartsDuringSample)', () {
        fakeAsync((async) {
          final network = StreamController<NetworkAttachment>(sync: true);
          final fake = _FakeMessaging();
          final media = _GatedSwitchMedia()
            ..openedTransport = CallTransportKind.relay
            ..audioTelemetry = true;
          var directReachable = false;
          final svc = CallService(
            fake,
            media: media,
            now: () => clock.now(),
            networkAttachments: network.stream,
            localAllowsP2P: (_) async => true,
            peerReachableForP2P: (_) async => directReachable,
          )..start();
          const id = 'relay-handover-during-direct-admission';
          try {
            offer(fake, id);
            unawaited(svc.accept());
            async.flushMicrotasks();
            expect(svc.current?.transport, CallTransportKind.relay);
            media.audioRxAt = clock.now();
            fake.onCallSignal!(
              peer,
              CallSignal(
                callId: id,
                type: CallSignalType.health,
                capture: const CallMedia(audio: true),
                sentAtMs: clock.now().millisecondsSinceEpoch,
              ),
            );
            async.elapse(const Duration(milliseconds: 100));
            network.add(NetworkAttachment.cellular);
            async.elapse(const Duration(milliseconds: 100));
            if (audioOnNewNetwork) media.audioRxAt = clock.now();
            media.rxAt = clock.now();

            final admission = media.requiredAdmissionGate = Completer<bool>();
            directReachable = true;
            fake.onCallSignal!(peer, ready(id));
            async.flushMicrotasks();
            final reads = media.admissionChecks.length;
            expect(reads, 1);

            final echo = Completer<bool>();
            bool? qualified;
            media.relayRefresh = (canCommit) async {
              return qualified = await echo.future && await canCommit();
            };
            final sample = Completer<DateTime?>();
            final replacementAdmission = Completer<bool>();
            if (directStartsDuringSample) {
              media.latestAudioRead = () => sample.future;
            } else {
              media.requiredAdmissionGate = replacementAdmission;
            }
            async.elapse(const Duration(seconds: 4));
            if (directStartsDuringSample) {
              expect(media.latestAudioReads, 1);
              admission.complete(true);
              async.flushMicrotasks();
              expect(media.switches, [CallTransportKind.p2p]);
              sample.complete(media.audioRxAt);
              async.flushMicrotasks();
              expect(media.repairs, 0);
              expect(media.relayRefreshes, 0);
              media.switchGate.complete(true);
              async.flushMicrotasks();
              expect(svc.current?.transport, CallTransportKind.p2p);
              return;
            }
            expect(media.repairs, audioOnNewNetwork ? 1 : 0);
            expect(media.relayRefreshes, audioOnNewNetwork ? 0 : 1);
            expect(svc.current?.transport, CallTransportKind.relay);

            admission.complete(true);
            async.flushMicrotasks();
            expect(media.switches, isEmpty);
            if (!audioOnNewNetwork) {
              // Another heartbeat cannot enter P2P while the relay waits for
              // the authenticated echo on its candidate channel.
              async.elapse(const Duration(seconds: 1));
              expect(media.admissionChecks, hasLength(reads));
              expect(media.switches, isEmpty);
              echo.complete(true);
              async.flushMicrotasks();
              expect(qualified, isTrue);
            }
            expect(media.admissionChecks, hasLength(reads + 1));
            expect(media.switches, isEmpty);
            media.requiredAdmissionGate = null;
            replacementAdmission.complete(true);
            media.switchGate.complete(true);
            async.flushMicrotasks();
            expect(media.switches, [CallTransportKind.p2p]);
            expect(svc.current?.status, CallStatus.active);
          } finally {
            svc.dispose();
            unawaited(network.close());
            async.flushMicrotasks();
          }
        });
      });
    }

    for (final (handover, admitted) in [
      (false, true),
      (true, true),
      (true, false),
    ]) {
      test('initial relay evaluates fresh admission (handover=$handover, '
          'admitted=$admitted)', () {
        fakeAsync((async) {
          final fake = _FakeMessaging();
          final media = _FakeMedia()..openedTransport = CallTransportKind.relay;
          final admissions = StreamController<void>(sync: true);
          final discovery = Completer<bool>();
          final device = NodeId.fromHex('b' * 64);
          var probes = 0;
          var networkGeneration = 0;
          final svc = CallService(
            fake,
            media: media,
            now: () => clock.now(),
            localAllowsP2P: (_) async => true,
            peerReachableForP2P: (_) =>
                ++probes == 1 ? Future.value(false) : discovery.future,
            overlaySessionAdmissions: admissions.stream,
            readNetworkChangeGeneration: () => networkGeneration,
          )..start();
          const id = 'initial-relay-device-admission';
          try {
            offer(fake, id, device: device);
            unawaited(svc.accept());
            async.flushMicrotasks();
            expect(svc.current?.status, CallStatus.active);
            expect(svc.current?.transport, CallTransportKind.relay);
            expect(probes, 2);
            fake.onCallSignal!(peer, ready(id));
            async.flushMicrotasks();
            expect(media.switches, isEmpty);

            if (handover) networkGeneration++;
            media.liveDirectAdmission = admitted;
            admissions.add(null);
            async.flushMicrotasks();
            expect(media.liveAdmissionChecks, [device]);
            expect(media.admissionChecks, [if (admitted) device]);
            expect(media.switches, [if (admitted) CallTransportKind.p2p]);
            expect(svc.current?.callId, id);
            expect(
              svc.current?.transport,
              admitted ? CallTransportKind.p2p : CallTransportKind.relay,
            );
            expect(discovery.isCompleted, isFalse);
            expect(probes, handover && !admitted ? 3 : 2);

            discovery.complete(false);
            async.flushMicrotasks();
            expect(media.switches, [if (admitted) CallTransportKind.p2p]);
          } finally {
            if (!discovery.isCompleted) discovery.complete(false);
            svc.dispose();
            unawaited(admissions.close());
            async.flushMicrotasks();
          }
        });
      });
    }

    for (final (admitted, overlapping) in [
      (true, false),
      (false, false),
      (true, true),
      (false, true),
    ]) {
      test('admission after a completed discovery miss '
          '(admitted=$admitted, overlapping=$overlapping)', () {
        fakeAsync((async) {
          final fake = _FakeMessaging();
          final media = _FakeMedia()..openedTransport = CallTransportKind.relay;
          final admissions = StreamController<void>(sync: true);
          final staleRead = Completer<bool>();
          final device = NodeId.fromHex('b' * 64);
          var probes = 0;
          final svc = CallService(
            fake,
            media: media,
            localAllowsP2P: (_) async => true,
            peerReachableForP2P: (_) async {
              probes++;
              return false;
            },
            overlaySessionAdmissions: admissions.stream,
          )..start();
          const id = 'admission-after-discovery-miss';
          try {
            offer(fake, id, device: device);
            unawaited(svc.accept());
            async.flushMicrotasks();
            fake.onCallSignal!(peer, ready(id));
            async.flushMicrotasks();
            final previousProbes = probes;
            expect(previousProbes, greaterThan(1));
            expect(media.admissionChecks, isEmpty);
            expect(media.switches, isEmpty);
            expect(svc.current?.transport, CallTransportKind.relay);

            if (overlapping) {
              media.requiredAdmissionGate = staleRead;
              admissions.add(null);
              async.flushMicrotasks();
              expect(media.admissionChecks, [device]);
              media.requiredAdmissionGate = null;
            }
            media.directPeerAdmitted = admitted;
            admissions.add(null);
            if (overlapping) {
              admissions.add(null);
              async.flushMicrotasks();
              expect(media.admissionChecks, [device]);
              expect(media.switches, isEmpty);
              staleRead.complete(false);
            }
            async.flushMicrotasks();
            expect(media.admissionChecks, [device, if (overlapping) device]);
            expect(media.switches, [if (admitted) CallTransportKind.p2p]);
            expect(svc.current?.callId, id);
            expect(
              svc.current?.transport,
              admitted ? CallTransportKind.p2p : CallTransportKind.relay,
            );
            expect(probes, previousProbes);
          } finally {
            if (!staleRead.isCompleted) staleRead.complete(false);
            svc.dispose();
            unawaited(admissions.close());
            async.flushMicrotasks();
          }
        });
      });
    }

    for (final admission in <bool?>[true, false, null]) {
      test('relay recovery reuses current device admission=$admission', () {
        fakeAsync((async) {
          final fake = _FakeMessaging();
          final media = _FakeMedia()..openedTransport = CallTransportKind.p2p;
          final refresh = Completer<bool>();
          var holdRefresh = false;
          var refreshCalls = 0;
          final svc = CallService(
            fake,
            media: media,
            now: () => clock.now(),
            localAllowsP2P: (_) async => true,
            peerReachableForP2P: (_) {
              if (!holdRefresh) return Future.value(true);
              refreshCalls++;
              return refresh.future;
            },
          )..start();
          final device = NodeId.fromHex('b' * 64);
          offer(fake, 'admission-recovery', device: device);
          svc.accept();
          async.flushMicrotasks();
          expect(svc.current?.transport, CallTransportKind.p2p);
          holdRefresh = true;
          svc.requestRelayRecoveryForDiagnostics();
          async.flushMicrotasks();
          expect(svc.current?.transport, CallTransportKind.relay);
          media.liveDirectAdmission = admission;
          for (var i = 0; i < kCallP2PCandidateRetry.inSeconds; i++) {
            media.rxAt = clock.now();
            async.elapse(const Duration(seconds: 1));
            async.flushMicrotasks();
          }
          fake.onCallSignal!(
            peer,
            ready(
              'admission-recovery',
            ).copyWith(sentAtMs: clock.now().millisecondsSinceEpoch + 1),
          );
          async.flushMicrotasks();
          expect(
            svc.current?.transport,
            admission == true ? CallTransportKind.p2p : CallTransportKind.relay,
          );
          expect(refreshCalls, admission == true ? 0 : 1);
          if (admission == true) {
            expect(media.liveAdmissionChecks, isNotEmpty);
            expect(media.liveAdmissionChecks, everyElement(device));
          }
          // The old discovery remains held: a valid native admission must
          // restore media independently of its result, never of a timer.
          refresh.complete(false);
          async.flushMicrotasks();
          svc.dispose();
          async.flushMicrotasks();
        });
      });
    }

    for (final scenario in [
      'exact device',
      'registration during first read',
      'unrelated registrations',
      'retired network',
    ]) {
      test(
        'direct session admission can finish pending discovery: $scenario',
        () {
          fakeAsync((async) {
            final fake = _FakeMessaging();
            final media = _FakeMedia()
              ..openedTransport = CallTransportKind.p2p
              ..liveDirectAdmission = false;
            final admissions = StreamController<void>(sync: true);
            final network = StreamController<NetworkAttachment>(sync: true);
            final discovery = Completer<bool>();
            final device = NodeId.fromHex('b' * 64);
            var holdDiscovery = false;
            var pendingDiscoveries = 0;
            final svc = CallService(
              fake,
              media: media,
              now: () => clock.now(),
              localAllowsP2P: (_) async => true,
              peerReachableForP2P: (identity) {
                expect(identity, peer);
                if (!holdDiscovery) return Future.value(true);
                pendingDiscoveries++;
                return discovery.future;
              },
              overlaySessionAdmissions: admissions.stream,
              networkAttachments: network.stream,
            )..start();
            const id = 'direct-admission-during-discovery';
            try {
              offer(fake, id, device: device);
              unawaited(svc.accept());
              async.flushMicrotasks();
              unawaited(svc.requestRelayRecoveryForDiagnostics());
              async.flushMicrotasks();
              expect(svc.current?.transport, CallTransportKind.relay);

              holdDiscovery = true;
              final initial = scenario == 'registration during first read'
                  ? Completer<bool?>()
                  : null;
              media.liveAdmissionGate = initial;
              for (var i = 0; i < kCallP2PCandidateRetry.inSeconds; i++) {
                media.rxAt = clock.now();
                async.elapse(const Duration(seconds: 1));
              }
              expect(media.liveAdmissionChecks, [device]);
              expect(pendingDiscoveries, initial == null ? 1 : 0);
              fake.onCallSignal!(
                peer,
                ready(
                  id,
                ).copyWith(sentAtMs: clock.now().millisecondsSinceEpoch),
              );
              async.flushMicrotasks();
              expect(media.switches, [CallTransportKind.relay]);

              final snapshot =
                  scenario == 'unrelated registrations' ||
                      scenario == 'retired network'
                  ? Completer<bool?>()
                  : null;
              media.liveAdmissionGate = snapshot;
              media.liveDirectAdmission = true;
              admissions.add(null);
              async.flushMicrotasks();
              initial?.complete(false);
              async.flushMicrotasks();
              if (snapshot != null) {
                expect(media.liveAdmissionChecks, [device, device]);
                expect(media.switches, [CallTransportKind.relay]);
                if (scenario == 'retired network') {
                  network.add(NetworkAttachment.offline);
                } else {
                  // A burst can arrive while the first read still describes an
                  // unrelated session. Recheck the newest registration once.
                  admissions.add(null);
                  admissions.add(null);
                  async.flushMicrotasks();
                  expect(media.liveAdmissionChecks, hasLength(2));
                }
                media.liveAdmissionGate = null;
                snapshot.complete(scenario == 'retired network');
                async.flushMicrotasks();
              }
              expect(discovery.isCompleted, isFalse);
              final switched = scenario != 'retired network';
              expect(
                media.liveAdmissionChecks,
                List.filled(
                  scenario == 'unrelated registrations' ? 3 : 2,
                  device,
                ),
              );
              expect(media.switches, [
                CallTransportKind.relay,
                if (switched) CallTransportKind.p2p,
              ]);
              expect(
                svc.current?.transport,
                switched ? CallTransportKind.p2p : CallTransportKind.relay,
              );

              discovery.complete(false);
              async.flushMicrotasks();
              expect(pendingDiscoveries, 1);
              expect(svc.current?.callId, id);
              expect(media.switches.length, switched ? 2 : 1);
            } finally {
              if (!discovery.isCompleted) discovery.complete(false);
              svc.dispose();
              unawaited(admissions.close());
              unawaited(network.close());
              async.flushMicrotasks();
            }
          });
        },
      );
    }

    for (final (handover, pendingStage) in [
      ('attachment', 'discovery'),
      ('offline', 'discovery'),
      ('pending IPC', 'discovery'),
      ('attachment', 'initial device read'),
      ('pending IPC', 'required device read'),
    ]) {
      test(
        'fresh admission replaces $pendingStage on the old network ($handover)',
        () {
          fakeAsync((async) {
            final fake = _FakeMessaging();
            final media = _FakeMedia()
              ..openedTransport = CallTransportKind.p2p
              ..liveDirectAdmission = false;
            final admissions = StreamController<void>(sync: true);
            final network = StreamController<NetworkAttachment>(sync: true);
            final oldDiscovery = Completer<bool>();
            final oldSnapshot = Completer<bool?>();
            final oldRequiredRead = Completer<bool>();
            final device = NodeId.fromHex('b' * 64);
            var holdDiscovery = false;
            var networkGeneration = 0;
            final svc = CallService(
              fake,
              media: media,
              now: () => clock.now(),
              localAllowsP2P: (_) async => true,
              peerReachableForP2P: (_) =>
                  holdDiscovery ? oldDiscovery.future : Future.value(true),
              overlaySessionAdmissions: admissions.stream,
              networkAttachments: network.stream,
              readNetworkChangeGeneration: () => networkGeneration,
            )..start();
            const id = 'admission-supersedes-old-discovery';
            try {
              offer(fake, id, device: device);
              unawaited(svc.accept());
              async.flushMicrotasks();
              unawaited(svc.requestRelayRecoveryForDiagnostics());
              async.flushMicrotasks();
              expect(svc.current?.transport, CallTransportKind.relay);

              holdDiscovery = true;
              final waitingForDiscovery = pendingStage == 'discovery';
              final waitingForRequiredRead =
                  pendingStage == 'required device read';
              if (waitingForRequiredRead) {
                media.liveDirectAdmission = true;
                media.requiredAdmissionGate = oldRequiredRead;
              } else if (!waitingForDiscovery) {
                media.liveAdmissionGate = oldSnapshot;
              }
              for (var i = 0; i < kCallP2PCandidateRetry.inSeconds; i++) {
                media.rxAt = clock.now();
                async.elapse(const Duration(seconds: 1));
              }
              fake.onCallSignal!(
                peer,
                ready(
                  id,
                ).copyWith(sentAtMs: clock.now().millisecondsSinceEpoch),
              );
              if (waitingForDiscovery) {
                media.liveAdmissionGate = oldSnapshot;
                admissions.add(null);
              }
              async.flushMicrotasks();
              final oldChecks = [device, if (waitingForDiscovery) device];
              expect(media.liveAdmissionChecks, oldChecks);
              expect(media.admissionChecks, [
                if (waitingForRequiredRead) device,
              ]);

              if (handover == 'offline') network.add(NetworkAttachment.offline);
              networkGeneration++;
              if (handover == 'attachment') {
                network.add(NetworkAttachment.cellular);
              }
              async.flushMicrotasks();
              expect(media.switches, [CallTransportKind.relay]);

              media.liveAdmissionGate = null;
              media.requiredAdmissionGate = null;
              media.liveDirectAdmission = true;
              admissions.add(null);
              async.flushMicrotasks();
              if (handover == 'offline') {
                expect(media.switches, [CallTransportKind.relay]);
                network.add(NetworkAttachment.cellular);
                async.flushMicrotasks();
              }
              expect(media.liveAdmissionChecks, [...oldChecks, device]);
              expect(media.admissionChecks, [
                if (waitingForRequiredRead) device,
                device,
              ]);
              expect(svc.current?.callId, id);
              expect(svc.current?.transport, CallTransportKind.p2p);
              expect(oldDiscovery.isCompleted, isFalse);
              expect(oldSnapshot.isCompleted, isFalse);

              oldDiscovery.complete(false);
              oldSnapshot.complete(true);
              oldRequiredRead.complete(true);
              async.flushMicrotasks();
              expect(media.switches, [
                CallTransportKind.relay,
                CallTransportKind.p2p,
              ]);
            } finally {
              if (!oldDiscovery.isCompleted) oldDiscovery.complete(false);
              if (!oldSnapshot.isCompleted) oldSnapshot.complete(false);
              if (!oldRequiredRead.isCompleted) oldRequiredRead.complete(false);
              svc.dispose();
              unawaited(admissions.close());
              unawaited(network.close());
              async.flushMicrotasks();
            }
          });
        },
      );
    }

    for (final beforeDeadline in [true, false]) {
      test('discovery miss respects pending exact-device read '
          'before deadline: $beforeDeadline', () {
        fakeAsync((async) {
          final fake = _FakeMessaging();
          final media = _FakeMedia()
            ..openedTransport = CallTransportKind.p2p
            ..liveDirectAdmission = false;
          final admissions = StreamController<void>(sync: true);
          final discovery = Completer<bool>();
          final snapshot = Completer<bool?>();
          final device = NodeId.fromHex('b' * 64);
          var holdDiscovery = false;
          final svc = CallService(
            fake,
            media: media,
            now: () => clock.now(),
            localAllowsP2P: (_) async => true,
            peerReachableForP2P: (_) =>
                holdDiscovery ? discovery.future : Future.value(true),
            overlaySessionAdmissions: admissions.stream,
          )..start();
          const id = 'discovery-miss-before-admission';
          try {
            offer(fake, id, device: device);
            unawaited(svc.accept());
            async.flushMicrotasks();
            // Keep the retry deadline distinct from the heartbeat tick.
            async.elapse(const Duration(milliseconds: 250));
            unawaited(svc.requestRelayRecoveryForDiagnostics());
            async.flushMicrotasks();
            expect(svc.current?.transport, CallTransportKind.relay);
            holdDiscovery = true;
            for (var i = 0; i < kCallP2PCandidateRetry.inSeconds; i++) {
              media.rxAt = clock.now();
              async.elapse(const Duration(seconds: 1));
            }
            expect(media.liveAdmissionChecks, [device]);
            fake.onCallSignal!(
              peer,
              ready(id).copyWith(sentAtMs: clock.now().millisecondsSinceEpoch),
            );
            media.liveAdmissionGate = snapshot;
            admissions.add(null);
            async.flushMicrotasks();
            expect(media.liveAdmissionChecks, [device, device]);
            // Let the intervening heartbeat see the discovery still busy.
            const remaining = Duration(milliseconds: 200);
            media.rxAt = clock.now();
            async.elapse(kCallP2PSetupTimeout - remaining);
            discovery.complete(false);
            async.flushMicrotasks();
            expect(media.switches, [CallTransportKind.relay]);

            async.elapse(
              remaining - Duration(milliseconds: beforeDeadline ? 1 : 0),
            );
            snapshot.complete(true);
            async.flushMicrotasks();
            expect(svc.current?.callId, id);
            expect(media.switches, [
              CallTransportKind.relay,
              if (beforeDeadline) CallTransportKind.p2p,
            ]);
          } finally {
            if (!snapshot.isCompleted) snapshot.complete(false);
            if (!discovery.isCompleted) discovery.complete(false);
            svc.dispose();
            unawaited(admissions.close());
            async.flushMicrotasks();
          }
        });
      });
    }

    test('retired call cannot use a delayed admitted recovery snapshot', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        final media = _FakeMedia()..openedTransport = CallTransportKind.p2p;
        final svc = CallService(
          fake,
          media: media,
          now: () => clock.now(),
          localAllowsP2P: (_) async => true,
          peerReachableForP2P: (_) async => true,
        )..start();
        offer(fake, 'retired-admission');
        svc.accept();
        async.flushMicrotasks();
        svc.requestRelayRecoveryForDiagnostics();
        async.flushMicrotasks();
        media.liveAdmissionGate = Completer<bool?>();
        for (var i = 0; i < kCallP2PCandidateRetry.inSeconds; i++) {
          media.rxAt = clock.now();
          async.elapse(const Duration(seconds: 1));
          async.flushMicrotasks();
        }
        expect(media.liveAdmissionChecks, isNotEmpty);
        svc.hangup();
        async.flushMicrotasks();
        final afterHangup = fake.sent.length;
        media.liveAdmissionGate!.complete(true);
        async.flushMicrotasks();
        expect(svc.current, isNull);
        expect(media.switches, [CallTransportKind.relay]);
        expect(fake.sent.skip(afterHangup), isEmpty);
        svc.dispose();
        async.flushMicrotasks();
      });
    });

    for (final handover in ['offline', 'offline then online', 'IPC pending']) {
      test('drops late direct readiness from a previous network ($handover)', () {
        fakeAsync((async) {
          final network = StreamController<NetworkAttachment>(sync: true);
          var networkChangeGeneration = 0;
          final fake = _FakeMessaging();
          final media = _FakeMedia()..openedTransport = CallTransportKind.p2p;
          final svc = CallService(
            fake,
            media: media,
            now: () => clock.now(),
            localAllowsP2P: (_) async => true,
            peerReachableForP2P: (_) async => true,
            networkAttachments: network.stream,
            readNetworkChangeGeneration: () => networkChangeGeneration,
          )..start();
          offer(fake, 'late-direct-handover');
          svc.accept();
          async.flushMicrotasks();
          expect(svc.current?.transport, CallTransportKind.p2p);
          svc.requestRelayRecoveryForDiagnostics();
          async.flushMicrotasks();
          expect(svc.current?.transport, CallTransportKind.relay);

          final oldAdmission = Completer<bool?>();
          media.liveAdmissionGate = oldAdmission;
          for (var i = 0; i < kCallP2PCandidateRetry.inSeconds; i++) {
            media.rxAt = clock.now();
            async.elapse(const Duration(seconds: 1));
          }
          expect(media.liveAdmissionChecks, hasLength(1));
          fake.onCallSignal!(
            peer,
            ready('late-direct-handover').copyWith(
              sentAtMs: clock.now().millisecondsSinceEpoch + 1,
            ),
          );
          async.flushMicrotasks();
          final beforeChange = fake.sent.length;
          if (handover == 'IPC pending') {
            networkChangeGeneration++;
          } else {
            network.add(NetworkAttachment.offline);
            if (handover == 'offline then online') {
              network.add(NetworkAttachment.cellular);
            }
          }
          oldAdmission.complete(true);
          async.flushMicrotasks();
          final announcedDirect = fake.sent.skip(beforeChange).where(
            (signal) =>
                signal.type == CallSignalType.transportInfo &&
                signal.transport?.kind == CallTransportKind.p2p,
          );
          expect(announcedDirect, isEmpty);
          expect(media.switches, [CallTransportKind.relay]);
          expect(svc.current?.transport, CallTransportKind.relay);

          if (handover != 'offline then online') {
            network.add(NetworkAttachment.cellular);
          }
          media.liveAdmissionGate = null;
          media.liveDirectAdmission = true;
          media.rxAt = clock.now();
          async.elapse(const Duration(seconds: 5));
          expect(media.liveAdmissionChecks, hasLength(2));
          expect(media.switches, [
            CallTransportKind.relay,
            CallTransportKind.p2p,
          ]);
          expect(svc.current?.transport, CallTransportKind.p2p);
          svc.dispose();
          unawaited(network.close());
          async.flushMicrotasks();
        });
      });
    }

    for (final repairFinishesFirst in [false, true]) {
      test('relay repair supersedes a pending direct policy read '
          '(repair finishes first: $repairFinishesFirst)', () {
        fakeAsync((async) {
          final fake = _FakeMessaging();
          final media = _GatedRepairMedia()
            ..openedTransport = CallTransportKind.relay;
          final policy = Completer<bool>();
          final replacementPolicy = Completer<bool>();
          var holdPolicy = false;
          var pendingReads = 0;
          final svc = CallService(
            fake,
            media: media,
            now: () => clock.now(),
            localAllowsP2P: (_) async {
              if (!holdPolicy) return true;
              return ++pendingReads == 1
                  ? policy.future
                  : replacementPolicy.future;
            },
            peerReachableForP2P: (_) async => true,
          )..start();
          const id = 'relay-repair-during-direct-policy';
          try {
            offer(fake, id);
            unawaited(svc.accept());
            async.flushMicrotasks();
            expect(svc.current?.transport, CallTransportKind.relay);
            expect(svc.current?.status, CallStatus.active);

            holdPolicy = true;
            fake.onCallSignal!(peer, ready(id));
            async.flushMicrotasks();
            expect(pendingReads, 1);
            fake.onCallSignal!(
              peer,
              const CallSignal(
                callId: id,
                type: CallSignalType.health,
                mediaRepairRequested: true,
              ),
            );
            async.flushMicrotasks();
            expect(media.repairs, 1);
            expect(media.switches, isEmpty);

            if (repairFinishesFirst) {
              media.gate.complete(true);
              async.flushMicrotasks();
              expect(pendingReads, 2);
            }
            policy.complete(true);
            async.flushMicrotasks();
            expect(media.switches, isEmpty);
            expect(svc.current?.transport, CallTransportKind.relay);

            if (!repairFinishesFirst) {
              media.rxAt = clock.now();
              async.elapse(kCallHeartbeatInterval);
              expect(media.switches, isEmpty);
              expect(media.repairs, 1);
              media.gate.complete(true);
              async.flushMicrotasks();
            }
            expect(pendingReads, 2);
            expect(media.switches, isEmpty);
            holdPolicy = false;
            replacementPolicy.complete(true);
            async.flushMicrotasks();
            expect(media.switches, [CallTransportKind.p2p]);
            expect(svc.current?.transport, CallTransportKind.p2p);
            expect(svc.current?.status, CallStatus.active);
            expect(
              fake.sent.where((s) => s.type == CallSignalType.end),
              isEmpty,
            );
          } finally {
            svc.dispose();
            async.flushMicrotasks();
          }
        });
      });
    }

    test('a network change during P2P commit leaves a retry on relay', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        final media = _FakeMedia()..openedTransport = CallTransportKind.relay;
        final commitPolicy = Completer<bool>();
        var networkChangeGeneration = 0;
        var commitChecks = 0;
        final svc = CallService(
          fake,
          media: media,
          now: () => clock.now(),
          localAllowsP2P: (_) async {
            if (media.switches.isEmpty || commitPolicy.isCompleted) return true;
            commitChecks++;
            return commitPolicy.future;
          },
          peerReachableForP2P: (_) async => true,
          readNetworkChangeGeneration: () => networkChangeGeneration,
        )..start();
        offer(fake, 'late-direct-commit');
        svc.accept();
        async.flushMicrotasks();
        fake.onCallSignal!(peer, ready('late-direct-commit'));
        async.flushMicrotasks();
        expect(commitChecks, 1);
        expect(media.switches, [CallTransportKind.p2p]);

        networkChangeGeneration++;
        commitPolicy.complete(true);
        async.flushMicrotasks();
        expect(svc.current?.transport, CallTransportKind.relay);
        expect(media.activeTransport, CallTransportKind.relay);

        for (var i = 0; i < kCallP2PCandidateRetry.inSeconds; i++) {
          media.rxAt = clock.now();
          async.elapse(const Duration(seconds: 1));
        }
        fake.onCallSignal!(
          peer,
          ready('late-direct-commit').copyWith(
            sentAtMs: clock.now().millisecondsSinceEpoch,
          ),
        );
        async.flushMicrotasks();
        expect(media.switches, [CallTransportKind.p2p, CallTransportKind.p2p]);
        expect(svc.current?.transport, CallTransportKind.p2p);
        svc.dispose();
        async.flushMicrotasks();
      });
    });

    test('admitted recovery snapshot still needs the current device gate', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        final media = _FakeMedia()..openedTransport = CallTransportKind.p2p;
        var refreshCalls = 0;
        final svc = CallService(
          fake,
          media: media,
          now: () => clock.now(),
          localAllowsP2P: (_) async => true,
          peerReachableForP2P: (_) async {
            refreshCalls++;
            return true;
          },
        )..start();
        offer(fake, 'admission-changed');
        svc.accept();
        async.flushMicrotasks();
        svc.requestRelayRecoveryForDiagnostics();
        async.flushMicrotasks();
        media.liveAdmissionGate = Completer<bool?>();
        for (var i = 0; i < kCallP2PCandidateRetry.inSeconds; i++) {
          media.rxAt = clock.now();
          async.elapse(const Duration(seconds: 1));
          async.flushMicrotasks();
        }
        final before = refreshCalls;
        media.directPeerAdmitted = false;
        media.liveAdmissionGate!.complete(true);
        fake.onCallSignal!(
          peer,
          ready(
            'admission-changed',
          ).copyWith(sentAtMs: clock.now().millisecondsSinceEpoch + 1),
        );
        async.flushMicrotasks();
        expect(svc.current?.transport, CallTransportKind.relay);
        expect(media.switches, [CallTransportKind.relay]);
        expect(refreshCalls, before);
        svc.dispose();
        async.flushMicrotasks();
      });
    });

    for (final recovery in ['handover', 'repair']) {
      test('returns from relay to direct twice after temporary $recovery', () {
        fakeAsync((async) {
          final fake = _FakeMessaging();
          final media = _FakeMedia()..openedTransport = CallTransportKind.p2p;
          final svc = CallService(
            fake,
            media: media,
            now: () => clock.now(),
            localAllowsP2P: (_) async => true,
            peerReachableForP2P: (_) async => true,
          )..start();
          void receiveFor(Duration duration) {
            for (var i = 0; i < duration.inSeconds; i++) {
              media.rxAt = clock.now();
              async.elapse(const Duration(seconds: 1));
              async.flushMicrotasks();
            }
          }

          offer(fake, 'return-twice');
          svc.accept();
          async.flushMicrotasks();
          expect(svc.current?.transport, CallTransportKind.p2p);
          for (var cycle = 0; cycle < 2; cycle++) {
            fake.onCallSignal!(
              peer,
              ready(
                'return-twice',
              ).copyWith(sentAtMs: clock.now().millisecondsSinceEpoch),
            );
            async.flushMicrotasks();
            if (recovery == 'handover') {
              svc.requestRelayRecoveryForDiagnostics();
            } else {
              media.repairTo = CallTransportKind.relay;
              fake.onCallSignal!(
                peer,
                CallSignal(
                  callId: 'return-twice',
                  type: CallSignalType.health,
                  mediaRepairRequested: true,
                ),
              );
            }
            async.flushMicrotasks();
            expect(svc.current?.transport, CallTransportKind.relay);
            media.rxAt = clock.now();
            receiveFor(kCallP2PCandidateRetry);
            async.flushMicrotasks();
            expect(
              svc.current?.transport,
              CallTransportKind.relay,
              reason: 'old readiness cannot authorize the next handover',
            );
            fake.onCallSignal!(
              peer,
              ready(
                'return-twice',
              ).copyWith(sentAtMs: clock.now().millisecondsSinceEpoch + 1),
            );
            async.flushMicrotasks();
            expect(svc.current?.status, CallStatus.active);
            expect(svc.current?.transport, CallTransportKind.p2p);
            fake.onCallSignal!(
              peer,
              CallSignal(
                callId: 'return-twice',
                type: CallSignalType.health,
                transport: const CallTransportProposal(CallTransportKind.p2p),
                p2pUpgradeAllowed: true,
                sentAtMs: clock.now().millisecondsSinceEpoch + 2,
              ),
            );
            media.rxAt = clock.now();
            receiveFor(kCallHeartbeatInterval);
            async.flushMicrotasks();
          }
          expect(
            media.switches,
            recovery == 'handover'
                ? [
                    CallTransportKind.relay,
                    CallTransportKind.p2p,
                    CallTransportKind.relay,
                    CallTransportKind.p2p,
                  ]
                : [CallTransportKind.p2p, CallTransportKind.p2p],
          );
          expect(media.repairs, recovery == 'repair' ? 2 : 0);
          expect(fake.sent.where((s) => s.type == CallSignalType.end), isEmpty);
          svc.dispose();
          async.flushMicrotasks();
        });
      });
    }

    for (final trigger in [
      null,
      CallSignalType.transportInfo,
      CallSignalType.health,
    ]) {
      test('direct recovery during a pending readiness send: $trigger', () {
        fakeAsync((async) {
          final fake = _FakeMessaging();
          final media = _FakeMedia()..openedTransport = CallTransportKind.relay;
          final svc = CallService(
            fake,
            media: media,
            now: () => clock.now(),
            localAllowsP2P: (_) async => true,
            peerReachableForP2P: (_) async => true,
          )..start();
          const callId = 'recovery-during-readiness';
          offer(fake, callId);
          svc.accept();
          async.flushMicrotasks();
          fake.onCallSignal!(peer, ready(callId));
          async.flushMicrotasks();
          expect(svc.current?.transport, CallTransportKind.p2p);

          final pendingSend = Completer<void>();
          final admissionChecks = media.admissionChecks.length;
          fake.sendGate = pendingSend;
          async.elapse(kCallHeartbeatInterval - const Duration(seconds: 1));
          media.rxAt = clock.now();
          async.elapse(const Duration(seconds: 1));
          final readyAt = clock.now().millisecondsSinceEpoch;
          expect(media.admissionChecks.length, admissionChecks + 1);
          expect(media.switches, [CallTransportKind.p2p]);

          if (trigger == null) {
            media.liveAdmissionChecks.clear();
            media.liveDirectAdmission = false;
            async.elapse(kCallDirectSessionSilence);
          } else {
            fake.onCallSignal!(
              peer,
              CallSignal(
                callId: callId,
                type: trigger,
                transport: const CallTransportProposal(CallTransportKind.relay),
                p2pUpgradeAllowed: trigger != CallSignalType.health,
                sentAtMs: clock.now().millisecondsSinceEpoch,
              ),
            );
            async.flushMicrotasks();
          }
          expect(pendingSend.isCompleted, isFalse);
          expect(svc.current?.transport, CallTransportKind.relay);
          if (trigger == null) expect(media.liveAdmissionChecks, [peer]);
          fake.sendGate = null;
          async.elapse(const Duration(milliseconds: 1));
          pendingSend.complete();
          async.flushMicrotasks();
          final repeatedReadiness = fake.sent.lastWhere(
            (s) =>
                s.type == CallSignalType.transportInfo &&
                s.transport?.kind == CallTransportKind.p2p,
          );
          expect(repeatedReadiness.sentAtMs, readyAt);
          expect(media.switches, [
            CallTransportKind.p2p,
            CallTransportKind.relay,
          ]);
          expect(svc.current?.status, CallStatus.active);
          expect(svc.current?.callId, callId);
          expect(fake.sent.where((s) => s.type == CallSignalType.end), isEmpty);
          svc.dispose();
          async.flushMicrotasks();
        });
      });
    }

    test('direct qualification proceeds while readiness is being saved', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        final media = _GatedSwitchMedia()
          ..openedTransport = CallTransportKind.relay;
        final svc = CallService(
          fake,
          media: media,
          now: () => clock.now(),
          localAllowsP2P: (_) async => true,
          peerReachableForP2P: (_) async => true,
        )..start();
        const callId = 'readiness-storage';
        offer(fake, callId);
        svc.accept();
        async.flushMicrotasks();
        fake.sent.clear();
        final pending = Completer<void>();
        fake.sendGate = pending;
        for (var i = 0; i < 3; i++) {
          media.rxAt = clock.now();
          async.elapse(kCallHeartbeatInterval);
        }
        expect(svc.current?.transport, CallTransportKind.relay);
        expect(media.switches, isEmpty);

        fake.onCallSignal!(peer, ready(callId));
        async.flushMicrotasks();
        expect(pending.isCompleted, isFalse);
        expect(media.switches, [CallTransportKind.p2p]);
        expect(svc.current?.transport, CallTransportKind.relay);
        media.switchGate.complete(true);
        async.flushMicrotasks();
        expect(svc.current?.transport, CallTransportKind.p2p);

        fake.sendGate = null;
        pending.complete();
        async.flushMicrotasks();
        expect(
          fake.sent.where((s) => s.type == CallSignalType.transportInfo),
          hasLength(1),
          reason: 'coalesce readiness while its previous send is outstanding',
        );
        expect(svc.current?.status, CallStatus.active);
        svc.dispose();
        async.flushMicrotasks();
      });
    });

    test('a pending relay settlement cannot block return to direct', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        final media = _FakeMedia()..openedTransport = CallTransportKind.p2p;
        final svc = CallService(
          fake,
          media: media,
          now: () => clock.now(),
          localAllowsP2P: (_) async => true,
          peerReachableForP2P: (_) async => true,
        )..start();
        const callId = 'settlement-storage';
        offer(fake, callId);
        svc.accept();
        async.flushMicrotasks();
        fake.sent.clear();
        final pending = Completer<void>();
        fake.sendGate = pending;
        svc.requestRelayRecoveryForDiagnostics();
        async.flushMicrotasks();
        expect(svc.current?.transport, CallTransportKind.relay);
        final settledAt = clock.now().millisecondsSinceEpoch;
        for (var i = 0; i < kCallP2PCandidateRetry.inSeconds; i++) {
          media.rxAt = clock.now();
          async.elapse(const Duration(seconds: 1));
        }
        fake.onCallSignal!(
          peer,
          ready(callId).copyWith(sentAtMs: clock.now().millisecondsSinceEpoch),
        );
        async.flushMicrotasks();
        expect(pending.isCompleted, isFalse);
        expect(svc.current?.transport, CallTransportKind.p2p);
        expect(media.switches, [CallTransportKind.relay, CallTransportKind.p2p]);

        fake.sendGate = null;
        pending.complete();
        async.flushMicrotasks();
        final settlement = fake.sent.singleWhere(
          (s) =>
              s.type == CallSignalType.transportInfo &&
              s.transport?.kind == CallTransportKind.relay,
        );
        expect(settlement.sentAtMs, settledAt);
        expect(settlement.p2pUpgradeAllowed, isTrue);
        expect(svc.current?.status, CallStatus.active);
        expect(svc.current?.callId, callId);
        svc.dispose();
        async.flushMicrotasks();
      });
    });

    for (final wake in ['native admission', 'dated peer readiness']) {
      test('verified direct route can return early after relay ($wake)', () {
        fakeAsync((async) {
          final fake = _FakeMessaging();
          final media = _FakeMedia()..openedTransport = CallTransportKind.p2p;
          final admissions = StreamController<void>(sync: true);
          final device = NodeId.fromHex('b' * 64);
          var discoveries = 0;
          final svc = CallService(
            fake,
            media: media,
            now: () => clock.now(),
            localAllowsP2P: (_) async => true,
            peerReachableForP2P: (_) async {
              discoveries++;
              return true;
            },
            overlaySessionAdmissions: admissions.stream,
          )..start();
          const id = 'early-direct-after-relay';
          void peerReady() {
            fake.onCallSignal!(
              peer,
              ready(id).copyWith(sentAtMs: clock.now().millisecondsSinceEpoch),
            );
            async.flushMicrotasks();
          }

          try {
            offer(fake, id, device: device);
            unawaited(svc.accept());
            async.flushMicrotasks();
            expect(svc.current?.transport, CallTransportKind.p2p);
            unawaited(svc.requestRelayRecoveryForDiagnostics());
            async.flushMicrotasks();
            expect(svc.current?.transport, CallTransportKind.relay);
            final priorDiscoveries = discoveries;
            async.elapse(const Duration(seconds: 1));
            if (wake == 'native admission') {
              media.directPeerAdmitted = false;
              admissions.add(null);
              async.flushMicrotasks();
              expect(media.admissionChecks, [device]);
              expect(svc.current?.transport, CallTransportKind.relay);
              media.directPeerAdmitted = true;
              admissions.add(null);
              async.flushMicrotasks();
              expect(media.admissionChecks, [device, device]);
              expect(media.switches, [CallTransportKind.relay]);
            }
            peerReady();
            expect(media.admissionChecks, isNotEmpty);
            expect(media.admissionChecks.last, device);
            expect(discoveries, priorDiscoveries);
            expect(media.switches, [
              CallTransportKind.relay,
              CallTransportKind.p2p,
            ]);
            expect(svc.current?.transport, CallTransportKind.p2p);
            expect(svc.current?.callId, id);

            // A rapid second fallback keeps the ordinary cooldown.
            async.elapse(const Duration(milliseconds: 1));
            unawaited(svc.requestRelayRecoveryForDiagnostics());
            async.flushMicrotasks();
            final reads = media.admissionChecks.length;
            async.elapse(const Duration(milliseconds: 1));
            admissions.add(null);
            peerReady();
            expect(media.admissionChecks, hasLength(reads));
            expect(media.switches, [
              CallTransportKind.relay,
              CallTransportKind.p2p,
              CallTransportKind.relay,
            ]);
          } finally {
            svc.dispose();
            unawaited(admissions.close());
            async.flushMicrotasks();
          }
        });
      });
    }

    test('admission during relay opening is checked after relay settles', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        final media = _GatedRelaySwitchMedia()
          ..openedTransport = CallTransportKind.p2p;
        final admissions = StreamController<void>(sync: true);
        final device = NodeId.fromHex('b' * 64);
        final svc = CallService(
          fake,
          media: media,
          now: () => clock.now(),
          localAllowsP2P: (_) async => true,
          peerReachableForP2P: (_) async => true,
          overlaySessionAdmissions: admissions.stream,
        )..start();
        const id = 'relay-open-direct-admission';
        try {
          offer(fake, id, device: device);
          unawaited(svc.accept());
          async.flushMicrotasks();
          expect(svc.current?.transport, CallTransportKind.p2p);
          unawaited(svc.requestRelayRecoveryForDiagnostics());
          async.flushMicrotasks();
          expect(media.switches, [CallTransportKind.relay]);
          admissions.add(null);
          async.flushMicrotasks();
          expect(media.admissionChecks, isEmpty);
          media.relayGate.complete(true);
          async.flushMicrotasks();
          expect(svc.current?.transport, CallTransportKind.relay);
          expect(media.admissionChecks, [device]);
          expect(media.switches, [CallTransportKind.relay]);
        } finally {
          svc.dispose();
          unawaited(admissions.close());
          async.flushMicrotasks();
        }
      });
    });

    for (final (scenario, readyDuringOpen, expected) in [
      ('unchanged network', true, CallTransportKind.p2p),
      ('readiness on replacement network', true, CallTransportKind.p2p),
      ('readiness on previous network', true, CallTransportKind.relay),
      ('peer withdrawal', true, CallTransportKind.relay),
      ('readiness before relay opening', false, CallTransportKind.relay),
    ]) {
      test('peer readiness during relay fallback ($scenario)', () {
        fakeAsync((async) {
          final fake = _FakeMessaging();
          final media = _GatedRelaySwitchMedia()
            ..openedTransport = CallTransportKind.p2p;
          final device = NodeId.fromHex('b' * 64);
          var network = 0;
          final svc = CallService(
            fake,
            media: media,
            now: () => clock.now(),
            localAllowsP2P: (_) async => true,
            peerReachableForP2P: (_) async => true,
            readNetworkChangeGeneration: () => network,
          )..start();
          const id = 'ready-during-relay-open';

          void peerReady() {
            async.elapse(const Duration(milliseconds: 1));
            fake.onCallSignal!(
              peer,
              ready(id).copyWith(sentAtMs: clock.now().millisecondsSinceEpoch),
            );
            async.flushMicrotasks();
          }

          try {
            offer(fake, id, device: device);
            unawaited(svc.accept());
            async.flushMicrotasks();
            expect(svc.current?.transport, CallTransportKind.p2p);
            if (!readyDuringOpen) peerReady();
            unawaited(svc.requestRelayRecoveryForDiagnostics());
            async.flushMicrotasks();
            expect(media.switches, [CallTransportKind.relay]);
            final readsBefore = media.admissionChecks.length;
            if (scenario == 'readiness on replacement network') network++;
            if (readyDuringOpen) peerReady();
            if (scenario == 'readiness on previous network') network++;
            if (scenario == 'peer withdrawal') {
              async.elapse(const Duration(milliseconds: 1));
              fake.onCallSignal!(
                peer,
                CallSignal(
                  callId: id,
                  type: CallSignalType.transportInfo,
                  transport: const CallTransportProposal(
                    CallTransportKind.relay,
                  ),
                  p2pUpgradeAllowed: false,
                  sentAtMs: clock.now().millisecondsSinceEpoch,
                  protocolVersion: 6,
                ),
              );
              async.flushMicrotasks();
            }
            expect(media.admissionChecks, hasLength(readsBefore));
            expect(media.switches, [CallTransportKind.relay]);

            media.relayGate.complete(true);
            async.flushMicrotasks();
            expect(svc.current?.callId, id);
            expect(svc.current?.status, CallStatus.active);
            expect(svc.current?.transport, expected);
            if (expected == CallTransportKind.p2p) {
              expect(media.admissionChecks.skip(readsBefore), [device]);
              expect(media.switches, [CallTransportKind.relay, expected]);
            } else {
              expect(media.admissionChecks, hasLength(readsBefore));
              expect(media.switches, [CallTransportKind.relay]);
            }
          } finally {
            svc.dispose();
            async.flushMicrotasks();
          }
        });
      });
    }

    test('scheduled retry survives an early read that spans the deadline', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        final media = _FakeMedia()..openedTransport = CallTransportKind.p2p;
        final svc = CallService(
          fake,
          media: media,
          now: () => clock.now(),
          localAllowsP2P: (_) async => true,
          peerReachableForP2P: (_) async => true,
        )..start();
        const id = 'early-read-spans-retry';
        try {
          offer(fake, id);
          unawaited(svc.accept());
          async.flushMicrotasks();
          async.elapse(const Duration(milliseconds: 250));
          unawaited(svc.requestRelayRecoveryForDiagnostics());
          async.flushMicrotasks();
          async.elapse(const Duration(seconds: 1));
          final held = media.requiredAdmissionGate = Completer<bool>();
          fake.onCallSignal!(
            peer,
            ready(id).copyWith(sentAtMs: clock.now().millisecondsSinceEpoch),
          );
          async.flushMicrotasks();
          expect(media.admissionChecks, [peer]);
          media.rxAt = clock.now();
          async.elapse(kCallP2PCandidateRetry - const Duration(seconds: 1));
          expect(media.switches, [CallTransportKind.relay]);
          media.requiredAdmissionGate = null;
          held.complete(false);
          async.flushMicrotasks();
          expect(media.admissionChecks, [peer, peer]);
          expect(media.switches, [
            CallTransportKind.relay,
            CallTransportKind.p2p,
          ]);
          expect(svc.current?.transport, CallTransportKind.p2p);
        } finally {
          svc.dispose();
          async.flushMicrotasks();
        }
      });
    });

    for (final (scenario, replaceRelay, settled, holdAdmission) in [
      ('rebuild', false, true, false),
      ('qualified relay probe', true, true, false),
      ('rejected relay probe', true, false, false),
      ('audio resumed on original relay', true, true, false),
      ('audio resumed with a pending admission', true, true, true),
      ('rebuild with a pending admission', false, true, true),
      ('relay probe with a pending admission', true, true, true),
    ]) {
      test('remember peer readiness during relay recovery ($scenario)', () {
        fakeAsync((async) {
          final fake = _FakeMessaging();
          final network = StreamController<NetworkAttachment>(sync: true);
          final media = _GatedRepairMedia()
            ..openedTransport = CallTransportKind.p2p
            ..audioTelemetry = true;
          final echo = Completer<bool>();
          final audioResumed = scenario.startsWith('audio resumed');
          bool? reboundRelay;
          media.relayRefresh = (canCommit) async =>
              reboundRelay = await echo.future && await canCommit();
          final device = NodeId.fromHex('b' * 64);
          final svc = CallService(
            fake,
            media: media,
            now: () => clock.now(),
            networkAttachments: network.stream,
            localAllowsP2P: (_) async => true,
            peerReachableForP2P: (_) async => true,
          )..start();
          const id = 'ready-during-relay-repair';
          final heldAdmission = holdAdmission ? Completer<bool>() : null;

          void peerReady() {
            async.elapse(const Duration(milliseconds: 1));
            fake.onCallSignal!(
              peer,
              ready(id).copyWith(sentAtMs: clock.now().millisecondsSinceEpoch),
            );
            async.flushMicrotasks();
          }

          void beginHeldAdmission() {
            media.requiredAdmissionGate = heldAdmission;
            peerReady();
            expect(media.admissionChecks, [device]);
          }

          try {
            offer(fake, id, device: device);
            unawaited(svc.accept());
            async.flushMicrotasks();
            expect(svc.current?.transport, CallTransportKind.p2p);
            unawaited(svc.requestRelayRecoveryForDiagnostics());
            async.flushMicrotasks();
            expect(svc.current?.transport, CallTransportKind.relay);

            media.audioRxAt = media.rxAt = clock.now();
            if (holdAdmission && !replaceRelay) beginHeldAdmission();
            fake.onCallSignal!(
              peer,
              CallSignal(
                callId: id,
                type: CallSignalType.health,
                capture: const CallMedia(audio: true),
                mediaRepairRequested: !replaceRelay,
                sentAtMs: clock.now().millisecondsSinceEpoch,
              ),
            );
            async.flushMicrotasks();
            if (replaceRelay) {
              async.elapse(const Duration(milliseconds: 100));
              network.add(NetworkAttachment.cellular);
              if (holdAdmission) beginHeldAdmission();
              async.elapse(const Duration(seconds: 4));
            }
            expect(media.repairs, replaceRelay ? 0 : 1);
            expect(media.relayRefreshes, replaceRelay ? 1 : 0);
            final before = [if (holdAdmission) device];
            expect(media.admissionChecks, before);

            if (!holdAdmission) peerReady();
            expect(media.admissionChecks, before);
            expect(media.switches, [CallTransportKind.relay]);

            media.requiredAdmissionGate = null;
            if (replaceRelay) {
              if (audioResumed) media.audioRxAt = media.rxAt = clock.now();
              echo.complete(settled);
            } else {
              media.gate.complete(true);
            }
            async.flushMicrotasks();
            expect(svc.current?.callId, id);
            expect(svc.current?.status, CallStatus.active);
            expect(
              reboundRelay,
              replaceRelay ? settled && !audioResumed : null,
            );
            final expected = [...before, if (settled) device];
            expect(media.admissionChecks, expected);
            expect(media.switches, [
              CallTransportKind.relay,
              if (settled) CallTransportKind.p2p,
            ]);
            expect(
              svc.current?.transport,
              settled ? CallTransportKind.p2p : CallTransportKind.relay,
            );
            if (heldAdmission != null) {
              expect(heldAdmission.isCompleted, isFalse);
              heldAdmission.complete(true);
              async.flushMicrotasks();
              expect(media.admissionChecks, expected);
              expect(media.switches, [
                CallTransportKind.relay,
                CallTransportKind.p2p,
              ]);
            }
          } finally {
            svc.dispose();
            unawaited(network.close());
            async.flushMicrotasks();
          }
        });
      });
    }

    for (final trigger in ['relay fallback', 'failed direct probe', 'hangup']) {
      test('direct retry observes its own deadline after $trigger', () {
        fakeAsync((async) {
          final fake = _FakeMessaging();
          final fromFallback = trigger == 'relay fallback';
          final media = _FailOnceDirectSwitchMedia(throws: false)
            ..openedTransport = fromFallback
                ? CallTransportKind.p2p
                : CallTransportKind.relay
            ..failed = fromFallback;
          final admissions = StreamController<void>(sync: true);
          final svc = CallService(
            fake,
            media: media,
            now: () => clock.now(),
            localAllowsP2P: (_) async => true,
            peerReachableForP2P: (_) async => true,
            overlaySessionAdmissions: admissions.stream,
          )..start();
          const callId = 'direct-retry-deadline';
          void peerReady() {
            fake.onCallSignal!(
              peer,
              ready(callId).copyWith(sentAtMs: clock.now().millisecondsSinceEpoch),
            );
            async.flushMicrotasks();
          }

          try {
            offer(fake, callId);
            unawaited(svc.accept());
            async.flushMicrotasks();
            async.elapse(const Duration(seconds: 2));
            if (fromFallback) {
              unawaited(svc.requestRelayRecoveryForDiagnostics());
              async.flushMicrotasks();
            } else {
              peerReady(); // The first candidate fails and preserves relay.
            }
            expect(svc.current?.transport, CallTransportKind.relay);
            expect(media.switches, [
              fromFallback ? CallTransportKind.relay : CallTransportKind.p2p,
            ]);
            async.elapse(const Duration(seconds: 1));
            if (fromFallback) media.directPeerAdmitted = false;
            peerReady();
            final reads = media.admissionChecks.length;
            admissions.add(null);
            async.flushMicrotasks();
            if (!fromFallback) expect(media.admissionChecks, hasLength(reads));
            const beforeDeadline = Duration(milliseconds: 1);
            media.rxAt = clock.now();
            async.elapse(
              kCallP2PCandidateRetry - const Duration(seconds: 1) - beforeDeadline,
            );
            expect(svc.current?.transport, CallTransportKind.relay);
            expect(media.switches, hasLength(1), reason: 'no early retry');
            media.directPeerAdmitted = true;
            if (trigger == 'hangup') {
              unawaited(svc.hangup());
              async.flushMicrotasks();
              expect(svc.current, isNull);
              const nextCall = 'successor-before-retry';
              offer(fake, nextCall);
              unawaited(svc.accept());
              async.flushMicrotasks();
              expect(svc.current?.callId, nextCall);
              final admissions = media.admissionChecks.length;
              async.elapse(beforeDeadline);
              expect(svc.current?.callId, nextCall);
              expect(media.admissionChecks, hasLength(admissions));
              expect(media.switches, hasLength(1));
              return;
            }
            async.elapse(beforeDeadline);
            expect(media.switches.last, CallTransportKind.p2p);
            expect(media.switches, hasLength(2));
            expect(svc.current?.callId, callId);
            expect(svc.current?.transport, CallTransportKind.p2p);
          } finally {
            svc.dispose();
            unawaited(admissions.close());
            async.flushMicrotasks();
          }
        });
      });
    }

    test('failed return trial preserves relay and can retry', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        final media = _FailOnceDirectSwitchMedia(throws: false)
          ..openedTransport = CallTransportKind.p2p;
        final svc = CallService(
          fake,
          media: media,
          now: () => clock.now(),
          localAllowsP2P: (_) async => true,
          peerReachableForP2P: (_) async => true,
        )..start();
        offer(fake, 'return-retry');
        svc.accept();
        async.flushMicrotasks();
        svc.requestRelayRecoveryForDiagnostics();
        async.flushMicrotasks();
        media.rxAt = clock.now();
        async.elapse(kCallP2PCandidateRetry);
        fake.onCallSignal!(
          peer,
          ready(
            'return-retry',
          ).copyWith(sentAtMs: clock.now().millisecondsSinceEpoch),
        );
        async.flushMicrotasks();
        expect(media.switches, [
          CallTransportKind.relay,
          CallTransportKind.p2p,
        ]);
        expect(svc.current?.transport, CallTransportKind.relay);
        expect(media.openedTransport, CallTransportKind.relay);
        media.rxAt = clock.now();
        async.elapse(kCallP2PCandidateRetry);
        fake.onCallSignal!(
          peer,
          ready(
            'return-retry',
          ).copyWith(sentAtMs: clock.now().millisecondsSinceEpoch),
        );
        async.flushMicrotasks();
        expect(svc.current?.transport, CallTransportKind.p2p);
        expect(svc.current?.status, CallStatus.active);
        expect(fake.sent.where((s) => s.type == CallSignalType.end), isEmpty);
        svc.dispose();
        async.flushMicrotasks();
      });
    });

    test('policy withdrawal during direct qualification preserves relay', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        final media = _GatedSwitchMedia()
          ..openedTransport = CallTransportKind.relay;
        var allowed = true;
        final svc = CallService(
          fake,
          media: media,
          now: () => clock.now(),
          localAllowsP2P: (_) async => allowed,
          peerReachableForP2P: (_) async => true,
        )..start();
        offer(fake, 'withdraw-during-probe');
        svc.accept();
        async.flushMicrotasks();
        fake.onCallSignal!(peer, ready('withdraw-during-probe'));
        async.flushMicrotasks();
        expect(media.switches, [CallTransportKind.p2p]);
        expect(media.openedTransport, CallTransportKind.relay);
        allowed = false;
        media.switchGate.complete(true);
        async.flushMicrotasks();
        expect(
          media.openedTransport,
          CallTransportKind.relay,
          reason: 'permission must still hold at the traffic switch',
        );
        expect(svc.current?.transport, CallTransportKind.relay);
        expect(svc.current?.status, CallStatus.active);
        media.rxAt = clock.now();
        async.elapse(kCallP2PCandidateRetry);
        async.flushMicrotasks();
        expect(media.switches, hasLength(1));
        svc.dispose();
        async.flushMicrotasks();
      });
    });

    test('keeps relay until peer readiness; repeats a lost announcement', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        final media = _FakeMedia()..openedTransport = CallTransportKind.relay;
        final svc = CallService(
          fake,
          media: media,
          now: () => clock.now(),
          localAllowsP2P: (_) async => true,
          peerReachableForP2P: (_) async => true,
        )..start();
        offer(fake, 'late');
        svc.accept();
        async.flushMicrotasks();
        expect(svc.current?.transport, CallTransportKind.relay);
        expect(media.switches, isEmpty);
        int announcements() => fake.sent
            .where(
              (s) =>
                  s.type == CallSignalType.transportInfo &&
                  s.transport?.kind == CallTransportKind.p2p,
            )
            .length;
        expect(announcements(), 1);
        async.elapse(kCallHeartbeatInterval);
        async.flushMicrotasks();
        expect(announcements(), 2);
        fake.onCallSignal!(peer, ready('late'));
        async.flushMicrotasks();
        expect(media.switches, [CallTransportKind.p2p]);
        expect(svc.current?.transport, CallTransportKind.p2p);
        final afterUpgrade = announcements();
        // Distinct fresh signals, not merely a retransmitted timestamp: two
        // peers repeating readiness must not sustain a reply feedback loop.
        for (var i = 0; i < 20; i++) {
          fake.onCallSignal!(peer, ready('late'));
          async.flushMicrotasks();
        }
        expect(announcements(), afterUpgrade);
        expect(media.switches.length, 1);
        media.rxAt = clock.now();
        async.elapse(kCallHeartbeatInterval);
        async.flushMicrotasks();
        expect(announcements(), afterUpgrade + 1);
        svc.dispose();
        async.flushMicrotasks();
      });
    });

    test(
      'active peer heartbeat stops readiness retries until a newer relay beat',
      () {
        fakeAsync((async) {
          final fake = _FakeMessaging();
          final media = _FakeMedia()..openedTransport = CallTransportKind.relay;
          final svc = CallService(
            fake,
            media: media,
            now: () => clock.now(),
            localAllowsP2P: (_) async => true,
            peerReachableForP2P: (_) async => true,
          )..start();
          offer(fake, 'confirmed');
          svc.accept();
          async.flushMicrotasks();
          fake.onCallSignal!(peer, ready('confirmed'));
          async.flushMicrotasks();
          expect(svc.current?.transport, CallTransportKind.p2p);
          int announcements() => fake.sent
              .where(
                (s) =>
                    s.type == CallSignalType.transportInfo &&
                    s.transport?.kind == CallTransportKind.p2p,
              )
              .length;
          void beat(NodeId source, String id, CallTransportKind route, int at) {
            fake.onCallSignal!(
              source,
              CallSignal(
                callId: id,
                type: CallSignalType.health,
                transport: CallTransportProposal(route),
                sentAtMs: at,
              ),
            );
            async.flushMicrotasks();
          }

          final before = announcements();
          // A route claim from another identity or another dialog is not an ack.
          beat(
            NodeId.fromHex('43' * 32),
            'confirmed',
            CallTransportKind.p2p,
            1000,
          );
          beat(peer, 'old-call', CallTransportKind.p2p, 1000);
          media.rxAt = clock.now();
          async.elapse(kCallHeartbeatInterval);
          async.flushMicrotasks();
          expect(announcements(), before + 1);
          expect(
            fake.sent
                .lastWhere((s) => s.type == CallSignalType.health)
                .transport
                ?.kind,
            CallTransportKind.p2p,
          );

          beat(peer, 'confirmed', CallTransportKind.p2p, 2000);
          final confirmed = announcements();
          for (var i = 0; i < 3; i++) {
            media.rxAt = clock.now();
            async.elapse(kCallHeartbeatInterval);
            async.flushMicrotasks();
          }
          expect(announcements(), confirmed);
          expect(media.switches, [CallTransportKind.p2p]);

          beat(peer, 'confirmed', CallTransportKind.relay, 3000);
          beat(peer, 'confirmed', CallTransportKind.p2p, 2500);
          media.rxAt = clock.now();
          async.elapse(kCallHeartbeatInterval);
          async.flushMicrotasks();
          expect(announcements(), confirmed + 1);
          // A lost new acknowledgment keeps retries alive; its eventual arrival
          // stops them again without another local route switch.
          beat(peer, 'confirmed', CallTransportKind.p2p, 4000);
          media.rxAt = clock.now();
          async.elapse(kCallHeartbeatInterval);
          async.flushMicrotasks();
          expect(announcements(), confirmed + 1);
          expect(media.switches, [CallTransportKind.p2p]);
          svc.dispose();
          async.flushMicrotasks();
        });
      },
    );

    test(
      'upgrade permission keeps legacy absence and requires a wire boolean',
      () {
        for (final allowed in [null, true, false]) {
          final signal = CallSignal(
            callId: 'permission-codec',
            type: CallSignalType.health,
            p2pUpgradeAllowed: allowed,
          );
          expect(
            CallSignal.tryDecode(signal.encode())?.p2pUpgradeAllowed,
            allowed,
          );
          expect(
            CallSignal.tryDecode(
              signal.copyWith(sentAtMs: 123).encode(),
            )?.p2pUpgradeAllowed,
            allowed,
          );
        }
        for (final invalid in ['0', '"false"', '{}', '[]']) {
          final body =
              '{"c":"permission-codec","k":${CallSignalType.health.index},"pu":$invalid}';
          expect(CallSignal.tryDecode(body)?.p2pUpgradeAllowed, isNull);
        }
      },
    );

    test(
      'relay settlement converges both peers after only one trial succeeds',
      () {
        fakeAsync((async) {
          final a = NodeId.fromHex('1' * 64);
          final b = NodeId.fromHex('2' * 64);
          final fa = _FakeMessaging();
          final fb = _FakeMessaging();
          final ma = _FakeMedia()..openedTransport = CallTransportKind.relay;
          final mb = _RejectDirectSwitchMedia()
            ..openedTransport = CallTransportKind.relay;
          CallService service(_FakeMessaging messaging, _FakeMedia media) =>
              CallService(
                messaging,
                media: media,
                now: () => clock.now(),
                localAllowsP2P: (_) async => true,
                peerReachableForP2P: (_) async => true,
              )..start();
          final sa = service(fa, ma);
          final sb = service(fb, mb);
          var stamp = clock.now().millisecondsSinceEpoch;
          CallSignal wire(CallSignal s) {
            final now = clock.now().millisecondsSinceEpoch;
            stamp = now > stamp ? now : stamp + 1;
            return CallSignal.tryDecode(s.copyWith(sentAtMs: stamp).encode())!;
          }

          sa.placeCall(b, const CallMedia(audio: true));
          async.flushMicrotasks();
          fb.onCallSignal!(
            a,
            wire(fa.sent.firstWhere((s) => s.type == CallSignalType.offer)),
          );
          sb.accept();
          async.flushMicrotasks();
          fa.onCallSignal!(
            b,
            wire(fb.sent.firstWhere((s) => s.type == CallSignalType.answer)),
          );
          async.flushMicrotasks();
          CallSignal readiness(_FakeMessaging f) => f.sent.lastWhere(
            (s) =>
                s.type == CallSignalType.transportInfo &&
                s.transport?.kind == CallTransportKind.p2p,
          );
          final oldReadyA = wire(readiness(fa));
          fa.onCallSignal!(b, wire(readiness(fb)));
          async.flushMicrotasks();
          expect(sa.current?.transport, CallTransportKind.p2p);
          fb.onCallSignal!(a, oldReadyA);
          async.flushMicrotasks();
          expect(sb.current?.transport, CallTransportKind.relay);
          final trialFailure = fb.sent.lastWhere(
            (s) =>
                s.type == CallSignalType.transportInfo &&
                s.transport?.kind == CallTransportKind.relay,
          );
          expect(trialFailure.p2pUpgradeAllowed, isTrue);
          fa.onCallSignal!(b, wire(trialFailure));
          async.flushMicrotasks();
          expect(sa.current?.transport, CallTransportKind.relay);
          expect(fa.sent.last.p2pUpgradeAllowed, isTrue);
          // Drop that announcement. Health confirms relay without revoking
          // consent; old readiness alone must not start a new trial.
          ma.rxAt = mb.rxAt = clock.now();
          async.elapse(kCallHeartbeatInterval);
          async.flushMicrotasks();
          final beat = fa.sent.lastWhere(
            (s) => s.type == CallSignalType.health,
          );
          expect(beat.transport?.kind, CallTransportKind.relay);
          expect(beat.p2pUpgradeAllowed, isTrue);
          fb.onCallSignal!(a, CallSignal.tryDecode(beat.encode())!);
          fb.onCallSignal!(a, oldReadyA);
          async.flushMicrotasks();
          for (var i = 0; i < 4; i++) {
            ma.rxAt = mb.rxAt = clock.now();
            async.elapse(kCallHeartbeatInterval);
            async.flushMicrotasks();
          }
          expect(ma.switches, [CallTransportKind.p2p, CallTransportKind.relay]);
          expect(mb.switches, [CallTransportKind.p2p]);
          expect(sa.current?.transport, CallTransportKind.relay);
          expect(sb.current?.transport, CallTransportKind.relay);
          mb.rejectDirect = false;
          fa.onCallSignal!(b, wire(readiness(fb)));
          async.flushMicrotasks();
          fb.onCallSignal!(a, wire(readiness(fa)));
          async.flushMicrotasks();
          expect(sa.current?.transport, CallTransportKind.p2p);
          expect(sb.current?.transport, CallTransportKind.p2p);
          expect(ma.switches, [
            CallTransportKind.p2p,
            CallTransportKind.relay,
            CallTransportKind.p2p,
          ]);
          expect(mb.switches, [CallTransportKind.p2p, CallTransportKind.p2p]);
          sa.dispose();
          sb.dispose();
          async.flushMicrotasks();
        });
      },
    );

    test(
      'lost relay announcement converges through health after handover grace',
      () {
        fakeAsync((async) {
          final fake = _FakeMessaging();
          final media = _FakeMedia()..openedTransport = CallTransportKind.relay;
          final svc = CallService(
            fake,
            media: media,
            now: () => clock.now(),
            localAllowsP2P: (_) async => true,
            peerReachableForP2P: (_) async => true,
          )..start();
          offer(fake, 'lost-fallback');
          svc.accept();
          async.flushMicrotasks();
          fake.onCallSignal!(
            peer,
            ready('lost-fallback').copyWith(sentAtMs: 1000),
          );
          async.flushMicrotasks();
          void relayHealth(int at) {
            fake.onCallSignal!(
              peer,
              CallSignal(
                callId: 'lost-fallback',
                type: CallSignalType.health,
                sentAtMs: at,
                transport: const CallTransportProposal(CallTransportKind.relay),
                p2pUpgradeAllowed: true,
              ),
            );
            async.flushMicrotasks();
          }

          relayHealth(2000);
          expect(
            svc.current?.transport,
            CallTransportKind.p2p,
            reason: 'peer may still be qualifying its candidate',
          );
          media.rxAt = clock.now();
          async.elapse(kCallP2PCandidateRetry);
          relayHealth(3000);
          expect(svc.current?.transport, CallTransportKind.relay);
          expect(fake.sent.last.p2pUpgradeAllowed, isTrue);
          media.rxAt = clock.now();
          async.elapse(kCallP2PCandidateRetry);
          fake.onCallSignal!(
            peer,
            ready('lost-fallback').copyWith(sentAtMs: 2500),
          );
          async.flushMicrotasks();
          // A transportInfo older than the most recent route health is stale.
          expect(svc.current?.transport, CallTransportKind.relay);
          fake.onCallSignal!(
            peer,
            ready('lost-fallback').copyWith(sentAtMs: 4000),
          );
          async.flushMicrotasks();
          expect(svc.current?.transport, CallTransportKind.p2p);
          expect(media.switches, [
            CallTransportKind.p2p,
            CallTransportKind.relay,
            CallTransportKind.p2p,
          ]);
          svc.dispose();
          async.flushMicrotasks();
        });
      },
    );

    test('relay health can retry a failed fallback that kept direct alive', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        final media = _UnprovenRelayMedia()
          ..openedTransport = CallTransportKind.p2p;
        final svc = CallService(
          fake,
          media: media,
          now: () => clock.now(),
          localAllowsP2P: (_) async => true,
          peerReachableForP2P: (_) async => true,
        )..start();
        offer(fake, 'failed-relay-health');
        svc.accept();
        async.flushMicrotasks();
        svc.requestRelayRecoveryForDiagnostics();
        async.flushMicrotasks();
        expect(media.switches, [CallTransportKind.relay]);
        expect(svc.current?.transport, CallTransportKind.p2p);
        media.candidateProven = true;
        for (var i = 0; i < 10; i++) {
          media.rxAt = clock.now();
          async.elapse(const Duration(seconds: 1));
          async.flushMicrotasks();
        }
        fake.onCallSignal!(
          peer,
          CallSignal(
            callId: 'failed-relay-health',
            type: CallSignalType.health,
            sentAtMs: clock.now().millisecondsSinceEpoch,
            transport: const CallTransportProposal(CallTransportKind.relay),
            p2pUpgradeAllowed: true,
          ),
        );
        async.flushMicrotasks();
        expect(svc.current?.transport, CallTransportKind.relay);
        expect(media.switches, [
          CallTransportKind.relay,
          CallTransportKind.relay,
        ]);
        expect(fake.sent.where((s) => s.type == CallSignalType.end), isEmpty);
        svc.dispose();
        async.flushMicrotasks();
      });
    });

    test('settled relay health waits for an in-flight direct candidate', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        final media = _GatedSwitchMedia()
          ..openedTransport = CallTransportKind.relay;
        final svc = CallService(
          fake,
          media: media,
          now: () => clock.now(),
          localAllowsP2P: (_) async => true,
          peerReachableForP2P: (_) async => true,
        )..start();
        offer(fake, 'health-switch');
        svc.accept();
        async.flushMicrotasks();
        fake.onCallSignal!(peer, ready('health-switch'));
        async.flushMicrotasks();
        expect(media.switches, [CallTransportKind.p2p]);
        fake.onCallSignal!(
          peer,
          const CallSignal(
            callId: 'health-switch',
            type: CallSignalType.health,
            sentAtMs: 2000,
            transport: CallTransportProposal(CallTransportKind.relay),
            p2pUpgradeAllowed: false,
          ),
        );
        async.flushMicrotasks();
        expect(media.switches, [CallTransportKind.p2p]);
        fake.onCallSignal!(
          peer,
          ready('health-switch').copyWith(sentAtMs: 3000),
        );
        media.switchGate.complete(true);
        async.flushMicrotasks();
        expect(media.switches, [CallTransportKind.p2p]);
        expect(svc.current?.transport, CallTransportKind.relay);
        media.rxAt = clock.now();
        async.elapse(kCallP2PCandidateRetry);
        async.flushMicrotasks();
        expect(media.switches.length, 1);
        svc.dispose();
        async.flushMicrotasks();
      });
    });

    test('identity control survives a forked device answer and route change', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        final media = _FakeMedia()..openedTransport = CallTransportKind.relay;
        final policyPeers = <NodeId>[];
        final discoveryPeers = <NodeId>[];
        final svc = CallService(
          fake,
          media: media,
          now: () => clock.now(),
          localAllowsP2P: (node) async {
            policyPeers.add(node);
            return node == peer;
          },
          peerReachableForP2P: (node) async {
            discoveryPeers.add(node);
            return node == peer;
          },
        )..start();
        final device = NodeId.fromHex('b' * 64);
        final stranger = NodeId.fromHex('c' * 64);
        svc.placeCall(peer, const CallMedia(audio: true));
        async.flushMicrotasks();
        final id = svc.current!.callId;
        fake.onCallSignal!(
          device,
          CallSignal(
            callId: id,
            type: CallSignalType.answer,
            posture: CallPosture.direct,
            transport: const CallTransportProposal(CallTransportKind.p2p),
            protocolVersion: 6,
            mediaKey: generateCallMediaKeyContribution(),
          ),
        );
        async.flushMicrotasks();
        expect(svc.current?.peer, device);
        expect(svc.current?.mediaIdentity, peer);
        expect(fake.replyPins, contains((id, peer, device)));
        expect(svc.current?.transport, CallTransportKind.relay);

        // Knowing a call id does not make another identity a readiness source.
        fake.onCallSignal!(stranger, ready(id));
        async.flushMicrotasks();
        expect(media.switches, isEmpty);
        fake.onCallSignal!(peer, ready(id));
        async.flushMicrotasks();
        expect(media.switches, [CallTransportKind.p2p]);
        expect(media.admissionChecks, everyElement(device));
        expect(policyPeers, everyElement(peer));
        expect(discoveryPeers, everyElement(peer));
        expect(svc.current?.peer, device);
        expect(svc.current?.transport, CallTransportKind.p2p);
        final readiness = fake.sentTo.where(
          (entry) =>
              entry.$2.type == CallSignalType.transportInfo &&
              entry.$2.transport?.kind == CallTransportKind.p2p,
        );
        expect(readiness, isNotEmpty);
        expect(
          readiness.map((entry) => entry.$1),
          everyElement(peer),
          reason:
              'device-addressed readiness loses the identity inbox and ratchet',
        );
        fake.sentTo.clear();
        svc.setMicEnabled(false);
        async.flushMicrotasks();
        expect(
          fake.sentTo
              .where((entry) => entry.$2.type == CallSignalType.health)
              .map((entry) => entry.$1),
          contains(peer),
        );
        expect(
          svc.current?.peer,
          device,
          reason: 'media remains pinned to the answerer',
        );

        // Identity-attributed health must keep the accepted dialog alive even
        // with no media. Other identities with this id must not renew it.
        for (var i = 0; i < 12; i++) {
          async.elapse(kCallHeartbeatInterval);
          fake.onCallSignal!(
            peer,
            CallSignal(callId: id, type: CallSignalType.health),
          );
          async.flushMicrotasks();
          expect(svc.current?.status, CallStatus.active);
        }
        fake.onCallSignal!(
          stranger,
          CallSignal(callId: id, type: CallSignalType.health),
        );
        async.elapse(kCallLivenessTimeout + kCallHeartbeatInterval * 2);
        async.flushMicrotasks();
        expect(svc.current?.isLive ?? false, isFalse);
        final endings = fake.sentTo.where(
          (entry) => entry.$2.type == CallSignalType.end,
        );
        expect(endings, isNotEmpty);
        expect(endings.map((entry) => entry.$1), everyElement(peer));
        svc.dispose();
        async.flushMicrotasks();
      });
    });

    test('waits for local admission even after peer readiness', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        final media = _FakeMedia()..openedTransport = CallTransportKind.relay;
        var reachable = false;
        final svc = CallService(
          fake,
          media: media,
          now: () => clock.now(),
          localAllowsP2P: (_) async => true,
          peerReachableForP2P: (_) async => reachable,
        )..start();
        offer(fake, 'admission');
        svc.accept();
        async.flushMicrotasks();
        fake.onCallSignal!(peer, ready('admission'));
        async.flushMicrotasks();
        expect(media.switches, isEmpty);
        reachable = true;
        async.elapse(kCallHeartbeatInterval);
        async.flushMicrotasks();
        expect(media.switches, [CallTransportKind.p2p]);
        svc.dispose();
        async.flushMicrotasks();
      });
    });

    test('identity readiness cannot substitute for the answering device', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        final media = _FakeMedia()
          ..openedTransport = CallTransportKind.relay
          ..directPeerAdmitted = false;
        final svc = CallService(
          fake,
          media: media,
          now: () => clock.now(),
          localAllowsP2P: (_) async => true,
          peerReachableForP2P: (_) async => true,
        )..start();
        final device = NodeId.fromHex('b' * 64);
        offer(fake, 'device-admission', device: device);
        svc.accept();
        async.flushMicrotasks();
        fake.onCallSignal!(peer, ready('device-admission'));
        async.flushMicrotasks();
        expect(media.admissionChecks, isNotEmpty);
        expect(media.admissionChecks, everyElement(device));
        expect(media.switches, isEmpty);
        expect(
          fake.sent.where(
            (s) =>
                s.type == CallSignalType.transportInfo &&
                s.transport?.kind == CallTransportKind.p2p,
          ),
          isEmpty,
        );
        expect(svc.current?.transport, CallTransportKind.relay);
        media.directPeerAdmitted = true;
        async.elapse(kCallHeartbeatInterval);
        async.flushMicrotasks();
        expect(media.switches, [CallTransportKind.p2p]);
        svc.dispose();
        async.flushMicrotasks();
      });
    });

    for (final scenario in [
      'peer denied',
      'local denied',
      'old peer',
      'old local',
      'anonymous',
      'revoked local policy',
    ]) {
      test('does not upgrade when $scenario', () {
        fakeAsync((async) {
          final fake = _FakeMessaging();
          final media = _FakeMedia()
            ..openedTransport = scenario == 'anonymous'
                ? CallTransportKind.onion
                : CallTransportKind.relay;
          if (scenario == 'old local') media.signalVersion = 5;
          var allowed = scenario != 'local denied';
          final svc = CallService(
            fake,
            media: media,
            now: () => clock.now(),
            localAllowsP2P: (_) async => allowed,
            peerReachableForP2P: (_) async => true,
          )..start();
          offer(
            fake,
            scenario,
            proposal: scenario == 'peer denied'
                ? CallTransportKind.relay
                : CallTransportKind.p2p,
            version: scenario == 'old peer' ? 5 : 6,
            posture: scenario == 'anonymous'
                ? CallPosture.anonymous
                : CallPosture.direct,
          );
          svc.accept();
          async.flushMicrotasks();
          if (scenario == 'revoked local policy') allowed = false;
          fake.onCallSignal!(peer, ready(scenario));
          async.flushMicrotasks();
          async.elapse(kCallHeartbeatInterval);
          async.flushMicrotasks();
          expect(media.switches, isEmpty);
          svc.dispose();
          async.flushMicrotasks();
        });
      });
    }

    test('ignores a different peer and stale call readiness', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        final media = _FakeMedia()..openedTransport = CallTransportKind.relay;
        final svc = CallService(
          fake,
          media: media,
          now: () => clock.now(),
          localAllowsP2P: (_) async => true,
          peerReachableForP2P: (_) async => true,
        )..start();
        offer(fake, 'bound');
        svc.accept();
        async.flushMicrotasks();
        fake.onCallSignal!(NodeId.fromHex('b' * 64), ready('bound'));
        fake.onCallSignal!(peer, ready('previous'));
        async.flushMicrotasks();
        expect(media.switches, isEmpty);
        svc.dispose();
        async.flushMicrotasks();
      });
    });

    test('peer fallback during upgrade waits and suppresses oscillation', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        final media = _GatedSwitchMedia()
          ..openedTransport = CallTransportKind.relay;
        final svc = CallService(
          fake,
          media: media,
          now: () => clock.now(),
          localAllowsP2P: (_) async => true,
          peerReachableForP2P: (_) async => true,
        )..start();
        offer(fake, 'switch-race');
        svc.accept();
        async.flushMicrotasks();
        fake.onCallSignal!(peer, ready('switch-race'));
        async.flushMicrotasks();
        expect(media.switches, [CallTransportKind.p2p]);
        fake.onCallSignal!(
          peer,
          const CallSignal(
            callId: 'switch-race',
            type: CallSignalType.transportInfo,
            transport: CallTransportProposal(CallTransportKind.relay),
            protocolVersion: 6,
          ),
        );
        async.flushMicrotasks();
        expect(media.switches.length, 1);
        media.switchGate.complete(true);
        async.flushMicrotasks();
        expect(media.switches, [
          CallTransportKind.p2p,
          CallTransportKind.relay,
        ]);
        expect(svc.current?.transport, CallTransportKind.relay);
        fake.onCallSignal!(peer, ready('switch-race'));
        async.elapse(kCallHeartbeatInterval);
        async.flushMicrotasks();
        expect(media.switches.length, 2);
        svc.dispose();
        async.flushMicrotasks();
      });
    });

    test('caller retains original mutual consent through native fallback', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        final media = _FakeMedia()..openedTransport = CallTransportKind.relay;
        final svc = CallService(
          fake,
          media: media,
          now: () => clock.now(),
          localAllowsP2P: (_) async => true,
          peerReachableForP2P: (_) async => true,
        )..start();
        svc.placeCall(peer, const CallMedia(audio: true));
        async.flushMicrotasks();
        final id = svc.current!.callId;
        fake.onCallSignal!(
          peer,
          CallSignal(
            callId: id,
            type: CallSignalType.answer,
            posture: CallPosture.direct,
            transport: const CallTransportProposal(CallTransportKind.p2p),
            protocolVersion: 6,
          ),
        );
        async.flushMicrotasks();
        expect(svc.current?.transport, CallTransportKind.relay);
        fake.onCallSignal!(peer, ready(id));
        async.flushMicrotasks();
        expect(media.switches, [CallTransportKind.p2p]);
        expect(svc.current?.transport, CallTransportKind.p2p);
        svc.dispose();
        async.flushMicrotasks();
      });
    });

    for (final throws in [false, true]) {
      test('unconfirmed direct candidate retries without replacing relay '
          '(throws=$throws)', () {
        fakeAsync((async) {
          final fake = _FakeMessaging();
          final media = _FailOnceDirectSwitchMedia(throws: throws)
            ..openedTransport = CallTransportKind.relay;
          final svc = CallService(
            fake,
            media: media,
            now: () => clock.now(),
            localAllowsP2P: (_) async => true,
            peerReachableForP2P: (_) async => true,
          )..start();
          media.onCandidateFailure = () => fake.onCallSignal!(
            peer,
            const CallSignal(
              callId: 'candidate-retry',
              type: CallSignalType.transportInfo,
              transport: CallTransportProposal(CallTransportKind.relay),
              protocolVersion: 6,
            ),
          );
          offer(fake, 'candidate-retry');
          svc.accept();
          async.flushMicrotasks();
          fake.onCallSignal!(peer, ready('candidate-retry'));
          async.flushMicrotasks();
          expect(svc.current?.transport, CallTransportKind.relay);
          expect(media.switches, [CallTransportKind.p2p]);
          expect(media.openedTransport, CallTransportKind.relay);
          for (var i = 0; i < 10; i++) {
            fake.onCallSignal!(peer, ready('candidate-retry'));
            async.flushMicrotasks();
          }
          async.elapse(kCallHeartbeatInterval);
          async.flushMicrotasks();
          expect(media.switches.length, 1, reason: 'failure must back off');
          async.elapse(kCallHeartbeatInterval);
          async.flushMicrotasks();
          expect(media.switches, [
            CallTransportKind.p2p,
            CallTransportKind.p2p,
          ]);
          expect(svc.current?.transport, CallTransportKind.p2p);
          svc.dispose();
          async.flushMicrotasks();
        });
      });
    }

    test(
      'revoking local P2P consent during candidate backoff prevents retry',
      () {
        fakeAsync((async) {
          final fake = _FakeMessaging();
          final media = _RejectDirectSwitchMedia()
            ..openedTransport = CallTransportKind.relay;
          var allowed = true;
          final svc = CallService(
            fake,
            media: media,
            now: () => clock.now(),
            localAllowsP2P: (_) async => allowed,
            peerReachableForP2P: (_) async => true,
          )..start();
          offer(fake, 'retry-revoked');
          svc.accept();
          async.flushMicrotasks();
          fake.onCallSignal!(peer, ready('retry-revoked'));
          async.flushMicrotasks();
          allowed = false;
          async.elapse(kCallP2PCandidateRetry);
          async.flushMicrotasks();
          expect(media.switches, [CallTransportKind.p2p]);
          expect(svc.current?.transport, CallTransportKind.relay);
          svc.dispose();
          async.flushMicrotasks();
        });
      },
    );

    test(
      'native admission loss announces relay and bounds candidate retries',
      () {
        fakeAsync((async) {
          final fake = _FakeMessaging();
          final media = _RejectDirectSwitchMedia()
            ..openedTransport = CallTransportKind.relay;
          final svc = CallService(
            fake,
            media: media,
            now: () => clock.now(),
            localAllowsP2P: (_) async => true,
            peerReachableForP2P: (_) async => true,
          )..start();
          offer(fake, 'lost-admission');
          svc.accept();
          async.flushMicrotasks();
          fake.sent.clear();
          fake.onCallSignal!(peer, ready('lost-admission'));
          async.flushMicrotasks();
          expect(svc.current?.transport, CallTransportKind.relay);
          expect(fake.sent.last.transport?.kind, CallTransportKind.relay);
          fake.onCallSignal!(peer, ready('lost-admission'));
          async.elapse(kCallHeartbeatInterval);
          async.flushMicrotasks();
          expect(media.switches, [CallTransportKind.p2p]);
          svc.dispose();
          async.flushMicrotasks();
        });
      },
    );

    test('delayed initial fallback cannot undo newer direct readiness', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        final media = _FakeMedia()..openedTransport = CallTransportKind.relay;
        final svc = CallService(
          fake,
          media: media,
          now: () => clock.now(),
          localAllowsP2P: (_) async => true,
          peerReachableForP2P: (_) async => true,
        )..start();
        offer(fake, 'reordered');
        svc.accept();
        async.flushMicrotasks();
        fake.onCallSignal!(
          peer,
          CallSignal(
            callId: 'reordered',
            type: CallSignalType.transportInfo,
            protocolVersion: 6,
            sentAtMs: 2000,
            transport: const CallTransportProposal(CallTransportKind.p2p),
          ),
        );
        async.flushMicrotasks();
        fake.onCallSignal!(
          peer,
          const CallSignal(
            callId: 'reordered',
            type: CallSignalType.transportInfo,
            protocolVersion: 6,
            sentAtMs: 1000,
            transport: CallTransportProposal(CallTransportKind.relay),
          ),
        );
        async.flushMicrotasks();
        expect(media.switches, [CallTransportKind.p2p]);
        expect(svc.current?.transport, CallTransportKind.p2p);
        svc.dispose();
        async.flushMicrotasks();
      });
    });

    for (final scenario in [
      'newer readiness',
      'older readiness',
      'undated fallback',
    ]) {
      test('pending fallback during qualification respects $scenario', () {
        fakeAsync((async) {
          final fake = _FakeMessaging();
          final media = _GatedSwitchMedia()
            ..openedTransport = CallTransportKind.relay;
          final svc = CallService(
            fake,
            media: media,
            now: () => clock.now(),
            localAllowsP2P: (_) async => true,
            peerReachableForP2P: (_) async => true,
          )..start();
          offer(fake, 'queued-fallback');
          svc.accept();
          async.flushMicrotasks();
          fake.onCallSignal!(
            peer,
            CallSignal(
              callId: 'queued-fallback',
              type: CallSignalType.transportInfo,
              protocolVersion: 6,
              sentAtMs: 1000,
              transport: const CallTransportProposal(CallTransportKind.p2p),
            ),
          );
          async.flushMicrotasks();
          expect(media.switches, [CallTransportKind.p2p]);
          fake.onCallSignal!(
            peer,
            CallSignal(
              callId: 'queued-fallback',
              type: CallSignalType.transportInfo,
              protocolVersion: 6,
              sentAtMs: scenario == 'undated fallback' ? null : 2000,
              transport: const CallTransportProposal(CallTransportKind.relay),
            ),
          );
          async.flushMicrotasks();
          fake.onCallSignal!(
            peer,
            CallSignal(
              callId: 'queued-fallback',
              type: CallSignalType.transportInfo,
              protocolVersion: 6,
              sentAtMs: scenario == 'older readiness' ? 1500 : 3000,
              transport: const CallTransportProposal(CallTransportKind.p2p),
            ),
          );
          async.flushMicrotasks();
          media.switchGate.complete(true);
          async.flushMicrotasks();
          final superseded = scenario == 'newer readiness';
          expect(media.switches, [
            CallTransportKind.p2p,
            if (!superseded) CallTransportKind.relay,
          ]);
          expect(
            svc.current?.transport,
            superseded ? CallTransportKind.p2p : CallTransportKind.relay,
          );
          svc.dispose();
          async.flushMicrotasks();
        });
      });
    }

    test('late switch cannot resurrect a hung-up call', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        final media = _GatedSwitchMedia()
          ..openedTransport = CallTransportKind.relay;
        final svc = CallService(
          fake,
          media: media,
          now: () => clock.now(),
          localAllowsP2P: (_) async => true,
          peerReachableForP2P: (_) async => true,
        )..start();
        offer(fake, 'hangup-race');
        svc.accept();
        async.flushMicrotasks();
        fake.onCallSignal!(peer, ready('hangup-race'));
        async.flushMicrotasks();
        svc.hangup();
        async.flushMicrotasks();
        media.switchGate.complete(true);
        async.flushMicrotasks();
        expect(svc.current, isNull);
        expect(media.switches.length, 1);
        svc.dispose();
        async.flushMicrotasks();
      });
    });
  });

  test('a route mismatch fails closed instead of changing posture', () {
    fakeAsync((async) {
      final peer = NodeId.fromHex('d' * 64);
      final fake = _FakeMessaging();
      final media = _FakeMedia()..openedTransport = CallTransportKind.onion;
      final svc = CallService(
        fake,
        now: () => clock.now(),
        media: media,
        localAllowsP2P: (_) async => true,
        peerReachableForP2P: (_) async => true,
      )..start();
      fake.onCallSignal!(
        peer,
        const CallSignal(
          callId: 'actual-route',
          type: CallSignalType.offer,
          media: CallMedia(audio: true),
          posture: CallPosture.direct,
          transport: CallTransportProposal(CallTransportKind.p2p),
        ),
      );

      svc.accept();
      async.flushMicrotasks();

      expect(svc.current, isNull);
      expect(fake.sent.last.type, CallSignalType.end);
      expect(fake.sent.last.reason, CallEndReason.error);
    });
  });

  group('a media start that never answers (report18 XV18-M9)', () {
    final peer = NodeId.fromHex('a' * 64);

    test(
      'pending relay fallback cannot restart a media start that timed out',
      () {
        fakeAsync((async) {
          final fake = _FakeMessaging();
          final media = _GatedStartMedia()
            ..openedTransport = CallTransportKind.p2p;
          final svc = CallService(
            fake,
            media: media,
            now: () => clock.now(),
            localAllowsP2P: (_) async => true,
            peerReachableForP2P: (_) async => true,
          )..start();
          fake.onCallSignal!(
            peer,
            const CallSignal(
              callId: 'never-starts',
              type: CallSignalType.offer,
              posture: CallPosture.direct,
              media: CallMedia(audio: true),
              transport: CallTransportProposal(CallTransportKind.p2p),
            ),
          );
          svc.accept();
          async.flushMicrotasks();
          fake.onCallSignal!(
            peer,
            const CallSignal(
              callId: 'never-starts',
              type: CallSignalType.transportInfo,
              transport: CallTransportProposal(CallTransportKind.relay),
            ),
          );
          async.flushMicrotasks();
          async.elapse(
            kCallMediaStartTimeout + const Duration(milliseconds: 1),
          );
          async.flushMicrotasks();
          expect(svc.current, isNull);
          expect(media.switches, isEmpty);
          expect(fake.sent.last.reason, CallEndReason.error);
          media.initialStart.complete(true);
          async.flushMicrotasks();
          expect(svc.current, isNull);
          svc.dispose();
          async.flushMicrotasks();
        });
      },
    );

    CallSignal offer(String id, CallMedia media) => CallSignal(
      callId: id,
      type: CallSignalType.offer,
      media: media,
      posture: CallPosture.direct,
    );

    (CallService, _GatedStartMedia) stalled(FakeAsync async, CallMedia want) {
      final fake = _FakeMessaging();
      final media = _GatedStartMedia();
      final svc = CallService(fake, now: () => clock.now(), media: media)
        ..start();
      fake.onCallSignal!(peer, offer('stalled', want));
      svc.accept();
      async.flushMicrotasks();
      return (svc, media);
    }

    test('a video start still waiting is not a call in progress', () {
      fakeAsync((async) {
        final (svc, _) = stalled(
          async,
          const CallMedia(audio: true, video: true),
        );
        // Where the old timeout fired and answered `true` for video.
        async.elapse(const Duration(seconds: 9));
        async.flushMicrotasks();
        expect(
          svc.current?.status,
          isNot(CallStatus.active),
          reason:
              'the call went active on a media start that has not come back: '
              'slot and stash held, a transport badge for a route nothing is '
              'flowing on',
        );
      });
    });

    test('a camera IS given longer than audio before it is given up on', () {
      fakeAsync((async) {
        final (svc, media) = stalled(
          async,
          const CallMedia(audio: true, video: true),
        );
        async.elapse(const Duration(seconds: 20));
        async.flushMicrotasks();
        // Still connecting — not active, and not ended either. This is the
        // consent dialog the old `true` was really papering over.
        expect(svc.current?.status, CallStatus.connecting);
        media.initialStart.complete(true);
        async.flushMicrotasks();
        expect(svc.current?.status, CallStatus.active);
      });
    });

    test('a start that never answers ends the call rather than faking it', () {
      fakeAsync((async) {
        final (svc, _) = stalled(
          async,
          const CallMedia(audio: true, video: true),
        );
        async.elapse(kCallVisualMediaStartTimeout + const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(svc.current, isNull);
      });
    });

    test('audio keeps the short budget it always had', () {
      fakeAsync((async) {
        final (svc, _) = stalled(async, const CallMedia(audio: true));
        async.elapse(kCallMediaStartTimeout + const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(svc.current, isNull);
      });
    });
  });

  group('CallService screen share orchestration', () {
    final peer = NodeId.fromHex('a' * 64);

    CallSignal videoOffer(String id) => CallSignal(
      callId: id,
      type: CallSignalType.offer,
      media: const CallMedia(audio: true, video: true),
      posture: CallPosture.direct,
    );

    /// A live video call with [media] attached, inside [async]'s zone.
    (CallService, _FakeMedia) liveVideoCall(FakeAsync async) {
      final fake = _FakeMessaging();
      final media = _FakeMedia();
      final svc = CallService(fake, now: () => clock.now(), media: media)
        ..start();
      fake.onCallSignal!(peer, videoOffer('call-s'));
      svc.accept();
      async.flushMicrotasks();
      expect(svc.current?.status, CallStatus.active);
      media.log.clear(); // drop start()-time calls; the tests assert toggles
      return (svc, media);
    }

    (CallService, _FakeMessaging, _FakeMedia, Completer<bool>) pendingShare(
      FakeAsync async, {
      required bool enabling,
      bool observedStop = false,
    }) {
      final messaging = _FakeMessaging(), media = _FakeMedia();
      final service = CallService(
        messaging,
        now: () => clock.now(),
        media: media,
      )..start();
      messaging.onCallSignal!(peer, videoOffer('call-pending-share'));
      service.accept();
      async.flushMicrotasks();
      expect(service.current?.status, CallStatus.active);
      if (!enabling) {
        service.setScreenShareEnabled(true);
        async.flushMicrotasks();
        expect(service.current?.screenOn, isTrue);
      }
      final gate = Completer<bool>();
      media.screenOperation = (on) =>
          on == enabling ? gate.future : Future.value(true);
      if (observedStop) {
        media.screenStops.add(null);
      } else {
        service.setScreenShareEnabled(enabling);
      }
      async.flushMicrotasks();
      media.log.clear();
      messaging.sent.clear();
      return (service, messaging, media, gate);
    }

    for (final enabling in [false, true]) {
      for (final terminal in ['hangup', 'replacement', 'dispose']) {
        test('pending share enabling=$enabling cannot outlive $terminal', () {
          fakeAsync((async) {
            final (service, messaging, media, gate) = pendingShare(
              async,
              enabling: enabling,
            );
            switch (terminal) {
              case 'hangup' || 'replacement':
                service.hangup();
                async.flushMicrotasks();
                expect(service.current, isNull);
                if (terminal == 'replacement') {
                  messaging.onCallSignal!(peer, videoOffer('replacement-call'));
                  service.accept();
                  async.flushMicrotasks();
                  expect(service.current?.callId, 'replacement-call');
                  expect(service.current?.status, CallStatus.active);
                }
              case 'dispose':
                service.dispose();
                async.flushMicrotasks();
                expect(service.current, isNull);
            }
            final before = service.current;
            media.log.clear();
            messaging.sent.clear();
            gate.complete(true);
            async.flushMicrotasks();
            expect(
              service.current,
              same(before),
              reason:
                  'capture completion is not permission to restore an old call',
            );
            expect(
              media.log,
              isEmpty,
              reason: 'old share completion must not restart a camera',
            );
            expect(
              messaging.sent.where((s) => s.type == CallSignalType.renegotiate),
              isEmpty,
            );
            service.dispose();
            async.flushMicrotasks();
          });
        });
      }
      test(
        'pending share enabling=$enabling preserves newer mic and camera off',
        () {
          fakeAsync((async) {
            final (service, messaging, media, gate) = pendingShare(
              async,
              enabling: enabling,
            );
            service.setMicEnabled(false);
            service.setCameraEnabled(false);
            async.flushMicrotasks();
            expect(service.current?.micOn, isFalse);
            expect(service.current?.cameraOn, isFalse);
            media.log.clear();
            messaging.sent.clear();
            gate.complete(true);
            async.flushMicrotasks();
            expect(service.current?.micOn, isFalse);
            expect(service.current?.cameraOn, isFalse);
            expect(service.current?.screenOn, enabling);
            expect(media.log.where((entry) => entry == 'cam:true'), isEmpty);
            final update = messaging.sent.lastWhere(
              (s) => s.type == CallSignalType.renegotiate,
            );
            expect(update.media?.screen, enabling);
            service.dispose();
            async.flushMicrotasks();
          });
        },
      );
    }

    test('a refused share stop does not claim camera restoration', () {
      fakeAsync((async) {
        final (service, messaging, media, gate) = pendingShare(
          async,
          enabling: false,
        );
        gate.complete(false);
        async.flushMicrotasks();
        expect(service.current?.screenOn, isTrue);
        expect(service.current?.media.screen, isTrue);
        expect(media.log, isEmpty);
        expect(
          messaging.sent.where((s) => s.type == CallSignalType.renegotiate),
          isEmpty,
        );
        service.dispose();
        async.flushMicrotasks();
      });
    });

    test('an observed OS stop survives a refused redundant cleanup', () {
      fakeAsync((async) {
        final (service, media) = liveVideoCall(async);
        service.setScreenShareEnabled(true);
        async.flushMicrotasks();
        media.log.clear();
        media.screenOperation = (_) async => false;
        media.screenStops.add(null);
        async.flushMicrotasks();
        expect(service.current?.screenOn, isFalse);
        expect(service.current?.media.screen, isFalse);
        expect(media.log, ['screen:false', 'cam:true']);
        service.dispose();
        async.flushMicrotasks();
      });
    });

    test('an observed stop cannot authorize capture in a replacement call', () {
      fakeAsync((async) {
        final (service, messaging, media, gate) = pendingShare(
          async,
          enabling: false,
          observedStop: true,
        );
        service.hangup();
        async.flushMicrotasks();
        messaging.onCallSignal!(peer, videoOffer('after-observed-stop'));
        service.accept();
        async.flushMicrotasks();
        expect(service.current?.callId, 'after-observed-stop');
        expect(service.current?.status, CallStatus.active);
        final before = service.current;
        media.log.clear();
        messaging.sent.clear();
        gate.complete(false);
        async.flushMicrotasks();
        expect(service.current, same(before));
        expect(media.log, isEmpty);
        expect(
          messaging.sent.where((s) => s.type == CallSignalType.renegotiate),
          isEmpty,
        );
        service.dispose();
        async.flushMicrotasks();
      });
    });

    test('share hand-back uses a camera enabled during its wait', () {
      fakeAsync((async) {
        final (service, media) = liveVideoCall(async);
        service.setScreenShareEnabled(true);
        async.flushMicrotasks();
        service.setCameraEnabled(false);
        async.flushMicrotasks();
        final gate = Completer<bool>();
        media.screenOperation = (_) => gate.future;
        service.setScreenShareEnabled(false);
        async.flushMicrotasks();
        service.setCameraEnabled(true);
        async.flushMicrotasks();
        media.log.clear();
        gate.complete(true);
        async.flushMicrotasks();
        expect(service.current?.cameraOn, isTrue);
        expect(service.current?.screenOn, isFalse);
        expect(media.log, ['cam:true']);
        service.dispose();
        async.flushMicrotasks();
      });
    });

    for (final mode in ['throw', 'unavailable']) {
      test('share hand-back handles camera $mode', () {
        fakeAsync((async) {
          final (service, messaging, media, gate) = pendingShare(
            async,
            enabling: false,
          );
          media.cameraOperation = (_) async {
            if (mode == 'throw') throw StateError('fixture camera refused');
            media.startedWithoutCamera = true;
          };
          gate.complete(true);
          async.flushMicrotasks();
          expect(service.current?.status, CallStatus.active);
          expect(service.current?.screenOn, isFalse);
          expect(service.current?.cameraOn, isFalse);
          expect(media.cameraIntent, isFalse);
          expect(
            messaging.sent
                .lastWhere((s) => s.type == CallSignalType.renegotiate)
                .media
                ?.screen,
            isFalse,
          );
          service.dispose();
          async.flushMicrotasks();
        });
      });
    }

    for (final change in ['hangup', 'replacement', 'camera off']) {
      test('camera hand-back wait respects $change', () {
        fakeAsync((async) {
          final (service, messaging, media, screenGate) = pendingShare(
            async,
            enabling: false,
          );
          final cameraGate = Completer<void>();
          media.cameraOperation = (on) =>
              on ? cameraGate.future : Future.value();
          screenGate.complete(true);
          async.flushMicrotasks();
          expect(service.current?.screenOn, isFalse);
          expect(media.log, ['cam:true']);
          if (change == 'camera off') {
            service.setCameraEnabled(false);
          } else {
            service.hangup();
          }
          async.flushMicrotasks();
          if (change == 'replacement') {
            messaging.onCallSignal!(peer, videoOffer('after-hand-back'));
            service.accept();
            async.flushMicrotasks();
            expect(service.current?.callId, 'after-hand-back');
          }
          final before = service.current;
          messaging.sent.clear();
          media.log.clear();
          cameraGate.complete();
          async.flushMicrotasks();
          expect(service.current, same(before));
          expect(media.log, isEmpty);
          final updates = messaging.sent.where(
            (s) => s.type == CallSignalType.renegotiate,
          );
          expect(updates, hasLength(change == 'camera off' ? 1 : 0));
          if (change == 'camera off') {
            expect(service.current?.cameraOn, isFalse);
          }
          service.dispose();
          async.flushMicrotasks();
        });
      });
    }

    test('share on drives the controller and flips screenOn; share off '
        'restores the camera the intent flag still wants', () {
      fakeAsync((async) {
        final (svc, media) = liveVideoCall(async);

        svc.setScreenShareEnabled(true);
        async.flushMicrotasks();
        expect(svc.current?.screenOn, isTrue);
        expect(media.log, ['screen:true']);

        svc.setScreenShareEnabled(false);
        async.flushMicrotasks();
        expect(svc.current?.screenOn, isFalse);
        expect(
          media.log,
          ['screen:true', 'screen:false', 'cam:true'],
          reason: 'cameraOn stayed true → the share hand-back restores it',
        );
      });
    });

    test('a failed capture start leaves the call in camera state', () {
      fakeAsync((async) {
        final (svc, media) = liveVideoCall(async);
        media.screenOk = false;

        svc.setScreenShareEnabled(true);
        async.flushMicrotasks();
        expect(
          svc.current?.screenOn,
          isFalse,
          reason: 'no backend / capture failed — nothing changed',
        );
      });
    });

    test('an OS-revoked share returns to camera state and tells the peer', () {
      fakeAsync((async) {
        final (svc, media) = liveVideoCall(async);
        svc.setScreenShareEnabled(true);
        async.flushMicrotasks();
        expect(svc.current?.screenOn, isTrue);
        media.log.clear();

        media.screenStops.add(null);
        async.flushMicrotasks();

        expect(svc.current?.screenOn, isFalse);
        expect(media.log, ['screen:false', 'cam:true']);
      });
    });

    test('camera toggle while sharing flips only the INTENT: no source '
        'switch, and the share hand-back honours the final value', () {
      fakeAsync((async) {
        final (svc, media) = liveVideoCall(async);
        svc.setScreenShareEnabled(true);
        async.flushMicrotasks();
        media.log.clear();

        svc.setCameraEnabled(false); // user turns the camera OFF mid-share
        async.flushMicrotasks();
        expect(svc.current?.cameraOn, isFalse);
        expect(
          media.log,
          isEmpty,
          reason: 'the share owns the single video source',
        );
        expect(media.cameraIntent, isFalse);

        svc.setScreenShareEnabled(false);
        async.flushMicrotasks();
        expect(media.log, [
          'screen:false',
        ], reason: 'cameraOn=false → nothing to restore');
      });
    });

    test('toggling the share tells the peer via renegotiate with the updated '
        'media set', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        final media = _FakeMedia();
        final svc = CallService(fake, now: () => clock.now(), media: media)
          ..start();
        fake.onCallSignal!(peer, videoOffer('call-r'));
        svc.accept();
        async.flushMicrotasks();
        fake.sent.clear();

        svc.setScreenShareEnabled(true);
        async.flushMicrotasks();
        var renegs = fake.sent.where(
          (s) => s.type == CallSignalType.renegotiate,
        );
        expect(renegs.single.media?.screen, isTrue);
        expect(svc.current?.media.screen, isTrue);

        svc.setScreenShareEnabled(false);
        async.flushMicrotasks();
        renegs = fake.sent.where((s) => s.type == CallSignalType.renegotiate);
        expect(renegs.last.media?.screen, isFalse);
        expect(svc.current?.media.screen, isFalse);
      });
    });

    test('peer renegotiate folds strictly-newer media; a stale re-drive '
        'never regresses it', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        final media = _FakeMedia();
        final svc = CallService(fake, now: () => clock.now(), media: media)
          ..start();
        fake.onCallSignal!(peer, videoOffer('call-n'));
        svc.accept();
        async.flushMicrotasks();
        expect(svc.current?.status, CallStatus.active);

        CallSignal reneg(bool screen, int atMs) => CallSignal(
          callId: 'call-n',
          type: CallSignalType.renegotiate,
          media: CallMedia(audio: true, video: true, screen: screen),
          sentAtMs: atMs,
        );

        // Newer applies.
        fake.onCallSignal!(peer, reneg(true, 1000));
        async.flushMicrotasks();
        expect(svc.current?.media.screen, isTrue);

        // A stale or duplicate re-drive (older/equal sentAt) is ignored.
        fake.onCallSignal!(peer, reneg(false, 900));
        fake.onCallSignal!(peer, reneg(false, 1000));
        async.flushMicrotasks();
        expect(
          svc.current?.media.screen,
          isTrue,
          reason: 'older sentAt must not overwrite the newer set',
        );

        // The genuinely newer OFF lands.
        fake.onCallSignal!(peer, reneg(false, 1100));
        async.flushMicrotasks();
        expect(svc.current?.media.screen, isFalse);
      });
    });

    test(
      'camera ON upgrades an audio-only call to video and tells the peer',
      () {
        fakeAsync((async) {
          final fake = _FakeMessaging();
          final media = _FakeMedia();
          final svc = CallService(fake, now: () => clock.now(), media: media)
            ..start();
          fake.onCallSignal!(
            peer,
            const CallSignal(
              callId: 'call-up',
              type: CallSignalType.offer,
              media: CallMedia(audio: true),
              posture: CallPosture.direct,
            ),
          );
          svc.accept();
          async.flushMicrotasks();
          expect(svc.current?.media.video, isFalse);
          media.log.clear();
          fake.sent.clear();

          svc.setCameraEnabled(true);
          async.flushMicrotasks();
          expect(svc.current?.media.video, isTrue, reason: 'call became video');
          expect(svc.current?.cameraOn, isTrue);
          expect(media.log, ['video:true', 'cam:true']);
          final reneg = fake.sent.where(
            (s) => s.type == CallSignalType.renegotiate,
          );
          expect(reneg, hasLength(1));
          expect(reneg.single.media?.video, isTrue);

          // Camera OFF after the upgrade is the ordinary mid-video toggle.
          svc.setCameraEnabled(false);
          async.flushMicrotasks();
          expect(
            svc.current?.media.video,
            isTrue,
            reason: 'stays a video call',
          );
          expect(svc.current?.cameraOn, isFalse);
        });
      },
    );

    test('an audio-only call starts with camera intent OFF on both ends', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        final media = _FakeMedia();
        final svc = CallService(fake, now: () => clock.now(), media: media)
          ..start();
        // Incoming audio-only offer: cameraOn must be false, or the UI camera
        // toggle reads "on" and its tap (→ off) is a no-op that makes the
        // audio→video upgrade unreachable (user report 2026-07-17).
        fake.onCallSignal!(
          peer,
          const CallSignal(
            callId: 'call-audio-intent',
            type: CallSignalType.offer,
            media: CallMedia(audio: true),
            posture: CallPosture.direct,
          ),
        );
        expect(svc.current?.cameraOn, isFalse);
        svc.hangup();
        async.flushMicrotasks();

        // Outgoing: audio-only dial → camera OFF; video dial → camera ON.
        svc.placeCall(peer, const CallMedia(audio: true));
        async.flushMicrotasks();
        expect(svc.current?.cameraOn, isFalse);
        svc.cancel();
        async.flushMicrotasks();
        svc.placeCall(peer, const CallMedia(audio: true, video: true));
        async.flushMicrotasks();
        expect(svc.current?.cameraOn, isTrue);
      });
    });

    test('the shipped policy is to start a call unmuted', () {
      // The provider used to pass `Platform.isAndroid` here, so on a phone
      // every call — placed or answered — began with the mic off and the peer
      // heard only DTX comfort noise, with nothing in the UI saying so. This
      // pins the value the provider actually passes. It does NOT stop someone
      // inlining a platform check again; the provider itself has no test
      // because nothing can construct it without the whole messaging stack.
      expect(kCallsStartMuted, isFalse);
    });

    test('a call starts unmuted when start-muted is not asked for', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        final svc = CallService(fake, now: () => clock.now())..start();

        svc.placeCall(peer, const CallMedia(audio: true, video: false));
        async.flushMicrotasks();
        expect(svc.current?.micOn, isTrue, reason: 'outgoing starts unmuted');
        svc.cancel();
        async.flushMicrotasks();

        fake.onCallSignal!(
          peer,
          const CallSignal(
            callId: 'incoming-unmuted',
            type: CallSignalType.offer,
            media: CallMedia(audio: true, video: false),
          ),
        );
        async.flushMicrotasks();
        expect(svc.current?.micOn, isTrue, reason: 'incoming starts unmuted');
        svc.dispose();
      });
    });

    test('start-muted policy applies to outgoing and incoming calls', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        final svc = CallService(fake, now: () => clock.now(), startMuted: true)
          ..start();

        svc.placeCall(peer, const CallMedia(audio: true, video: true));
        async.flushMicrotasks();
        expect(svc.current?.micOn, isFalse);
        svc.cancel();
        async.flushMicrotasks();

        fake.onCallSignal!(
          peer,
          const CallSignal(
            callId: 'incoming-muted',
            type: CallSignalType.offer,
            media: CallMedia(audio: true, video: true),
            posture: CallPosture.direct,
          ),
        );
        expect(svc.current?.micOn, isFalse);
      });
    });

    test('failed video mount leaves the call audio-only', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        final media = _FakeMedia()..videoOk = false;
        final svc = CallService(fake, now: () => clock.now(), media: media)
          ..start();
        fake.onCallSignal!(
          peer,
          const CallSignal(
            callId: 'call-up2',
            type: CallSignalType.offer,
            media: CallMedia(audio: true),
            posture: CallPosture.direct,
          ),
        );
        svc.accept();
        async.flushMicrotasks();
        fake.sent.clear();

        svc.setCameraEnabled(true);
        async.flushMicrotasks();
        expect(svc.current?.media.video, isFalse, reason: 'still audio-only');
        expect(
          fake.sent.where((s) => s.type == CallSignalType.renegotiate),
          isEmpty,
          reason: 'no renegotiate for a set that did not change',
        );
      });
    });

    test('camera OFF on an audio-only call stays a no-op', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        final media = _FakeMedia();
        final svc = CallService(fake, now: () => clock.now(), media: media)
          ..start();
        fake.onCallSignal!(
          peer,
          const CallSignal(
            callId: 'call-up3',
            type: CallSignalType.offer,
            media: CallMedia(audio: true),
            posture: CallPosture.direct,
          ),
        );
        svc.accept();
        async.flushMicrotasks();
        media.log.clear();

        svc.setCameraEnabled(false);
        async.flushMicrotasks();
        expect(svc.current?.media.video, isFalse);
        expect(media.log, isEmpty);
      });
    });

    test('peer video upgrade via renegotiate mounts local video with the '
        'camera left off', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        final media = _FakeMedia();
        final svc = CallService(fake, now: () => clock.now(), media: media)
          ..start();
        fake.onCallSignal!(
          peer,
          const CallSignal(
            callId: 'call-up4',
            type: CallSignalType.offer,
            media: CallMedia(audio: true),
            posture: CallPosture.direct,
          ),
        );
        svc.accept();
        async.flushMicrotasks();
        media.log.clear();

        fake.onCallSignal!(
          peer,
          const CallSignal(
            callId: 'call-up4',
            type: CallSignalType.renegotiate,
            media: CallMedia(audio: true, video: true),
            sentAtMs: 2000,
          ),
        );
        async.flushMicrotasks();
        expect(svc.current?.media.video, isTrue);
        expect(media.log, ['video:true'], reason: 'mount only, no camera');
        expect(
          svc.current?.cameraOn,
          isFalse,
          reason: 'receiving video never implies transmitting it',
        );
      });
    });

    test('share is a no-op on an audio-only call', () {
      fakeAsync((async) {
        final fake = _FakeMessaging();
        final media = _FakeMedia();
        final svc = CallService(fake, now: () => clock.now(), media: media)
          ..start();
        fake.onCallSignal!(
          peer,
          const CallSignal(
            callId: 'call-a',
            type: CallSignalType.offer,
            media: CallMedia(audio: true),
            posture: CallPosture.direct,
          ),
        );
        svc.accept();
        async.flushMicrotasks();
        media.log.clear();

        svc.setScreenShareEnabled(true);
        async.flushMicrotasks();
        expect(svc.current?.screenOn, isFalse);
        expect(media.log, isEmpty);
      });
    });
  });

  group('CallService instant local teardown', () {
    final peer = NodeId.fromHex('d' * 64);

    for (final incoming in [false, true]) {
      test('hangup during device lookup suppresses the pending '
          '${incoming ? 'answer' : 'offer'}', () {
        fakeAsync((async) {
          final device = Completer<NodeId>();
          var readingDevice = false;
          final fake = _FakeMessaging()
            ..readLocalDevice = () {
              readingDevice = true;
              return device.future;
            };
          final media = _FakeMedia();
          final svc = CallService(fake, media: media)..start();
          try {
            if (incoming) fake.onCallSignal!(peer, _diagnosticOffer());
            unawaited(
              incoming
                  ? svc.accept()
                  : svc.placeCall(peer, const CallMedia(audio: true)),
            );
            async.flushMicrotasks();
            expect(readingDevice, isTrue);
            expect(svc.current?.isLive, isTrue);
            expect(fake.sent, isEmpty);
            final callId = svc.current!.callId;

            unawaited(svc.hangup());
            async.flushMicrotasks();
            expect(svc.current, isNull);
            expect(fake.sent.single.callId, callId);

            device.complete(NodeId.fromHex('f' * 64));
            async.flushMicrotasks();
            expect(fake.sent, hasLength(1));
            expect(media.startedWith, isEmpty);
          } finally {
            svc.dispose();
            if (!device.isCompleted) device.complete(NodeId.fromHex('f' * 64));
            async.flushMicrotasks();
          }
        });
      });
    }

    test(
      'hangup while dialing clears the call before the signal is sent',
      () async {
        final fake = _FakeMessaging();
        final svc = CallService(fake)..start();
        addTearDown(svc.dispose);

        await svc.placeCall(peer, const CallMedia(audio: true));
        expect(svc.current?.status, CallStatus.dialing);

        // The durable control-signal enqueue is slow (encrypted-store write) —
        // the local teardown must not be gated on it.
        fake.sendGate = Completer<void>();
        await svc.hangup().timeout(const Duration(milliseconds: 100));
        expect(svc.current, isNull);
        expect(
          fake.sent.where((s) => s.type == CallSignalType.cancel),
          isEmpty,
          reason: 'cancel is still in flight behind the gate',
        );

        fake.sendGate!.complete();
        await pumpEventQueue();
        expect(fake.sent.last.type, CallSignalType.cancel);
      },
    );

    test(
      'reject while ringing clears the call before the signal is sent',
      () async {
        final fake = _FakeMessaging();
        final svc = CallService(fake)..start();
        addTearDown(svc.dispose);

        fake.onCallSignal!(
          peer,
          const CallSignal(
            callId: 'ring-1',
            type: CallSignalType.offer,
            media: CallMedia(audio: true),
            posture: CallPosture.direct,
          ),
        );
        expect(svc.current?.status, CallStatus.ringing);

        fake.sendGate = Completer<void>();
        await svc.reject().timeout(const Duration(milliseconds: 100));
        expect(svc.current, isNull);
        expect(
          fake.sent.where((s) => s.type == CallSignalType.reject),
          isEmpty,
        );

        fake.sendGate!.complete();
        await pumpEventQueue();
        expect(fake.sent.last.type, CallSignalType.reject);
      },
    );

    test('hangup on a connected call clears the call before the signal is '
        'sent', () async {
      final fake = _FakeMessaging();
      final svc = CallService(fake)..start();
      addTearDown(svc.dispose);

      await svc.placeCall(peer, const CallMedia(audio: true));
      final callId = svc.current!.callId;
      fake.onCallSignal!(
        peer,
        CallSignal(
          callId: callId,
          type: CallSignalType.answer,
          posture: CallPosture.direct,
        ),
      );
      expect(svc.current?.status, CallStatus.connecting);

      fake.sendGate = Completer<void>();
      await svc.hangup().timeout(const Duration(milliseconds: 100));
      expect(svc.current, isNull);
      expect(fake.sent.where((s) => s.type == CallSignalType.end), isEmpty);

      fake.sendGate!.complete();
      await pumpEventQueue();
      expect(fake.sent.last.type, CallSignalType.end);
    });
  });

  group('device fan-out (multi-device epic)', () {
    final caller = NodeId.fromHex('c' * 64);
    final sibling = NodeId.fromHex('b' * 64);
    final stranger = NodeId.fromHex('e' * 64);

    CallSignal offer(String callId, {String? onBehalfOf, int? sentAtMs}) =>
        CallSignal(
          callId: callId,
          type: CallSignalType.offer,
          media: const CallMedia(audio: true),
          posture: CallPosture.direct,
          onBehalfOf: onBehalfOf,
          sentAtMs: sentAtMs ?? DateTime.now().millisecondsSinceEpoch,
        );

    for (final restored in [false, true]) {
      for (final relayed in [false, true]) {
        test('finished call suppresses clock-skewed replay across its whole '
            'admission window (restored=$restored relayed=$relayed)', () async {
          var now = DateTime(2026, 11, 5, 12);
          final sentAt = now.add(const Duration(seconds: 30));
          final fake = _FakeMessaging();
          const id = 'finished-future-stamp';
          final svc = CallService(
            fake,
            now: () => now,
            loadFinishedCalls: restored
                ? () async => [
                    CallLogEntry(
                      id: id,
                      peerHex: caller.hex,
                      outgoing: false,
                      video: false,
                      outcome: CallLogOutcome.declined,
                      atMs: now.millisecondsSinceEpoch,
                    ),
                  ]
                : null,
          )..start();
          addTearDown(svc.dispose);
          svc.isOwnDevice = (peer) async => peer == sibling;
          await pumpEventQueue();
          if (!restored) {
            fake.onCallSignal!(
              caller,
              offer(id, sentAtMs: sentAt.millisecondsSinceEpoch),
            );
            await pumpEventQueue();
            expect(
              svc.current?.status,
              CallStatus.ringing,
              reason: 'the initial future stamp is inside tolerated skew',
            );
            await svc.reject();
            expect(svc.current, isNull);
          }
          var replayRings = 0;
          final subscription = svc.changes.listen((call) {
            if (call?.status == CallStatus.ringing) replayRings++;
          });
          addTearDown(subscription.cancel);
          // The cache used to expire at 90s while this accepted offer remains
          // within its age gate through 120s, because its sender is 30s ahead.
          for (final seconds in [91, 120]) {
            now = DateTime(2026, 11, 5, 12).add(Duration(seconds: seconds));
            fake.onCallSignal!(
              relayed ? sibling : caller,
              offer(
                id,
                onBehalfOf: relayed ? caller.hex : null,
                sentAtMs: sentAt.millisecondsSinceEpoch,
              ),
            );
            await pumpEventQueue();
            expect(
              svc.current,
              isNull,
              reason: 'a finished call must not ring at +$seconds seconds',
            );
          }
          expect(replayRings, 0);
          // Once cache evidence may expire, the original offer is stale.
          now = now.add(const Duration(milliseconds: 1));
          fake.onCallSignal!(
            caller,
            offer(id, sentAtMs: sentAt.millisecondsSinceEpoch),
          );
          await pumpEventQueue();
          expect(svc.current, isNull);
          fake.onCallSignal!(
            caller,
            offer('fresh-after-replay', sentAtMs: now.millisecondsSinceEpoch),
          );
          await pumpEventQueue();
          expect(
            svc.current?.status,
            CallStatus.ringing,
            reason: 'fresh calls must remain available',
          );
          expect(replayRings, 1);
        });
      }
    }

    for (final type in [CallSignalType.cancel, CallSignalType.end]) {
      for (final relayed in [false, true]) {
        test('${type.name} before an offer keeps the delayed ring silent '
            '(relayed=$relayed)', () async {
          final fake = _FakeMessaging();
          final svc = CallService(fake)..start();
          svc.isOwnDevice = (p) async => p == sibling;
          final id = 'ending-first-${type.name}-$relayed';
          fake.onCallSignal!(
            relayed ? sibling : caller,
            CallSignal(
              callId: id,
              type: type,
              reason: type == CallSignalType.cancel
                  ? CallEndReason.cancelled
                  : CallEndReason.hangup,
              onBehalfOf: relayed ? caller.hex : null,
            ),
          );
          await pumpEventQueue();
          fake.onCallSignal!(caller, offer(id));
          await pumpEventQueue();
          expect(svc.current, isNull);
          expect(fake.sentTo, isEmpty);
          svc.dispose();
        });
      }
    }

    test(
      'a caller ending cannot suppress another peer with the same call id',
      () async {
        final fake = _FakeMessaging();
        final svc = CallService(fake)..start();
        fake.onCallSignal!(
          stranger,
          const CallSignal(callId: 'shared-id', type: CallSignalType.cancel),
        );
        fake.onCallSignal!(caller, offer('shared-id'));
        await pumpEventQueue();
        expect(svc.current?.status, CallStatus.ringing);
        expect(svc.current?.peer, caller);
        svc.dispose();
      },
    );

    test('an untrusted relayed ending cannot suppress the caller', () async {
      final fake = _FakeMessaging();
      final svc = CallService(fake)..start();
      svc.isOwnDevice = (p) async => p == sibling;
      fake.onCallSignal!(
        stranger,
        CallSignal(
          callId: 'untrusted-ending',
          type: CallSignalType.cancel,
          onBehalfOf: caller.hex,
        ),
      );
      await pumpEventQueue();
      fake.onCallSignal!(caller, offer('untrusted-ending'));
      await pumpEventQueue();
      expect(svc.current?.status, CallStatus.ringing);
      svc.dispose();
    });

    test('another peer cannot consume the caller ending fan-out', () async {
      final fake = _FakeMessaging();
      final svc = CallService(fake)..start();
      svc.ownSiblingDevices = () async => [sibling];
      fake.onCallSignal!(caller, offer('shared-fan-out'));
      await pumpEventQueue();
      fake.onCallSignal!(
        stranger,
        const CallSignal(callId: 'shared-fan-out', type: CallSignalType.cancel),
      );
      await pumpEventQueue();
      expect(svc.current?.status, CallStatus.ringing);
      fake.onCallSignal!(
        caller,
        const CallSignal(callId: 'shared-fan-out', type: CallSignalType.cancel),
      );
      await pumpEventQueue();
      final endings = fake.sentTo.where(
        (s) => s.$2.type == CallSignalType.cancel && s.$1 == sibling,
      );
      expect(endings.length, 1);
      expect(endings.single.$2.onBehalfOf, caller.hex);
      svc.dispose();
    });

    test(
      'cancel while siblings resolve prevents a delayed offer fan-out',
      () async {
        final fake = _FakeMessaging();
        final siblings = Completer<List<NodeId>>();
        final svc = CallService(fake)..start();
        svc.ownSiblingDevices = () => siblings.future;
        fake.onCallSignal!(caller, offer('cancel-during-resolve'));
        await pumpEventQueue();
        fake.onCallSignal!(
          caller,
          const CallSignal(
            callId: 'cancel-during-resolve',
            type: CallSignalType.cancel,
          ),
        );
        await pumpEventQueue();
        siblings.complete([sibling]);
        await pumpEventQueue();
        expect(fake.sentTo, isEmpty);
        svc.dispose();
      },
    );

    test('a different peer cannot settle the current ring elsewhere', () async {
      final fake = _FakeMessaging();
      final svc = CallService(fake)..start();
      fake.onCallSignal!(caller, offer('wrong-peer-settle'));
      fake.onCallSignal!(
        stranger,
        const CallSignal(
          callId: 'wrong-peer-settle',
          type: CallSignalType.cancel,
          reason: CallEndReason.answeredElsewhere,
        ),
      );
      await pumpEventQueue();
      expect(svc.current?.status, CallStatus.ringing);
      expect(svc.current?.peer, caller);
      svc.dispose();
    });

    test(
      'an original offer is relayed to every sibling naming the caller',
      () async {
        final fake = _FakeMessaging();
        final svc = CallService(fake)..start();
        svc.ownSiblingDevices = () async => [sibling];
        svc.isOwnDevice = (p) async => p.hex == sibling.hex;

        fake.onCallSignal!(caller, offer('fan-1'));
        await pumpEventQueue();

        expect(svc.current?.status, CallStatus.ringing);
        expect(svc.current?.peer, caller);
        final relayed = fake.sentTo
            .where((r) => r.$2.type == CallSignalType.offer)
            .toList();
        expect(relayed, hasLength(1));
        expect(relayed.single.$1.hex, sibling.hex);
        expect(relayed.single.$2.onBehalfOf, caller.hex);
        expect(relayed.single.$2.callId, 'fan-1');
        svc.dispose();
      },
    );

    // Measured on a three-device stand (2026-09-20): C called an identity with
    // two devices. The device the rendezvous picked rang in ~1s and cleared 3ms
    // after the caller cancelled; the SIBLING — rung by the fan-out — heard
    // nothing about the ending and went on ringing for the rest of its 75s
    // timeout, then sent the caller a `reject` for a call the caller had
    // already cancelled. Seventy seconds of a phone ringing for nobody.
    test('the caller giving up is fanned out like the offer was', () async {
      final fake = _FakeMessaging();
      final svc = CallService(fake)..start();
      svc.ownSiblingDevices = () async => [sibling];
      svc.isOwnDevice = (p) async => p.hex == sibling.hex;

      fake.onCallSignal!(caller, offer('fan-end'));
      await pumpEventQueue();
      expect(svc.current?.status, CallStatus.ringing);

      fake.onCallSignal!(
        caller,
        CallSignal(
          callId: 'fan-end',
          type: CallSignalType.cancel,
          reason: CallEndReason.cancelled,
        ),
      );
      await pumpEventQueue();

      final ends = fake.sentTo
          .where((r) => r.$2.type == CallSignalType.cancel)
          .toList();
      expect(
        ends,
        hasLength(1),
        reason: 'the sibling rung by the fan-out was never told it ended',
      );
      expect(ends.single.$1.hex, sibling.hex);
      expect(ends.single.$2.callId, 'fan-end');
      expect(
        ends.single.$2.onBehalfOf,
        caller.hex,
        reason: 'the sibling admits a relayed signal only as the true caller',
      );
      expect(
        ends.single.$2.reason,
        CallEndReason.cancelled,
        reason: 'a cancelled call is missed, not answeredElsewhere',
      );
      svc.dispose();
    });

    // THE CONTROL. Fanning every ending out would satisfy the test above and
    // put back the ping-pong the offer lane is careful about: a sibling that
    // was never rung by us has nothing to stop, and a device that received a
    // RELAYED offer must not forward its ending on to the others.
    test('an ending nobody was fanned for is not relayed', () async {
      final fake = _FakeMessaging();
      final svc = CallService(fake)..start();
      svc.ownSiblingDevices = () async => [sibling];
      svc.isOwnDevice = (p) async => p.hex == sibling.hex;

      // A cancel for a call this device never rang for, let alone fanned out.
      fake.onCallSignal!(
        caller,
        CallSignal(
          callId: 'never-fanned',
          type: CallSignalType.cancel,
          reason: CallEndReason.cancelled,
        ),
      );
      await pumpEventQueue();

      expect(
        fake.sentTo.where((r) => r.$2.type == CallSignalType.cancel),
        isEmpty,
        reason: 'siblings were told to stop a ring that never started',
      );
      svc.dispose();
    });

    test(
      'a RELAYED offer does not fan out again (no sibling ping-pong)',
      () async {
        final fake = _FakeMessaging();
        final svc = CallService(fake)..start();
        svc.ownSiblingDevices = () async => [sibling];
        svc.isOwnDevice = (p) async => p.hex == sibling.hex;

        fake.onCallSignal!(sibling, offer('fan-2', onBehalfOf: caller.hex));
        await pumpEventQueue();

        expect(svc.current?.status, CallStatus.ringing);
        expect(
          svc.current?.peer,
          caller,
          reason: 'the ring must show the true caller, not the sibling',
        );
        expect(fake.sentTo, isEmpty);
        svc.dispose();
      },
    );

    test('a relayed offer from a NON-sibling is refused outright', () async {
      final fake = _FakeMessaging();
      final svc = CallService(fake)..start();
      svc.ownSiblingDevices = () async => [sibling];
      svc.isOwnDevice = (p) async => p.hex == sibling.hex;

      fake.onCallSignal!(stranger, offer('fan-3', onBehalfOf: caller.hex));
      await pumpEventQueue();

      expect(
        svc.current,
        isNull,
        reason: 'a contact must not ring us wearing another caller\'s name',
      );
      svc.dispose();
    });

    test('a STALE relayed offer is history, not a ring', () async {
      final fake = _FakeMessaging();
      final svc = CallService(fake)..start();
      svc.ownSiblingDevices = () async => [sibling];
      svc.isOwnDevice = (p) async => p.hex == sibling.hex;

      final old = DateTime.now()
          .subtract(const Duration(minutes: 30))
          .millisecondsSinceEpoch;
      fake.onCallSignal!(
        sibling,
        offer('fan-4', onBehalfOf: caller.hex, sentAtMs: old),
      );
      await pumpEventQueue();

      expect(svc.current, isNull);
      svc.dispose();
    });

    /// The lane the haunting actually arrived on.
    ///
    /// A crashed or missed call leaves its offer in the recipient's mailbox,
    /// and the next drain hands it over intact — hours later, from the CALLER
    /// directly, with no `onBehalfOf`. Reported on Windows 2026-08-28: "the
    /// call-start signalling arrives without the call being initiated".
    ///
    /// The age gate existed, and guarded the relayed lane only — while nothing
    /// stamped an outgoing offer at all, so the direct lane had no age to
    /// judge even if it had asked.
    test('a STALE DIRECT offer is history, not a ring', () async {
      final fake = _FakeMessaging();
      final svc = CallService(fake)..start();

      final old = DateTime.now()
          .subtract(const Duration(minutes: 30))
          .millisecondsSinceEpoch;
      fake.onCallSignal!(caller, offer('direct-stale', sentAtMs: old));
      await pumpEventQueue();

      expect(
        svc.current,
        isNull,
        reason: 'a half-hour-old offer rang the device',
      );
      svc.dispose();
    });

    test('CONTROL: a fresh direct offer still rings', () async {
      // Vacuity guard. A gate that refuses everything would satisfy the check
      // above and take every call with it.
      final fake = _FakeMessaging();
      final svc = CallService(fake)..start();

      fake.onCallSignal!(caller, offer('direct-fresh'));
      await pumpEventQueue();

      expect(svc.current?.status, CallStatus.ringing);
      svc.dispose();
    });

    test('a direct offer with NO timestamp is admitted, not dropped', () async {
      // Compatibility, stated on purpose: a peer built before offers carried a
      // stamp cannot be judged, and refusing it would take that peer's calls
      // away entirely. The gap is logged rather than silently closed.
      final fake = _FakeMessaging();
      final svc = CallService(fake)..start();

      fake.onCallSignal!(
        caller,
        CallSignal(
          callId: 'direct-unstamped',
          type: CallSignalType.offer,
          media: const CallMedia(audio: true),
          posture: CallPosture.direct,
        ),
      );
      await pumpEventQueue();

      expect(svc.current?.status, CallStatus.ringing);
      svc.dispose();
    });

    test('an outgoing offer carries the time it was sent', () async {
      // Without this the gate above can never fire for anybody: the callee has
      // nothing to measure. The two halves only work together.
      final fake = _FakeMessaging();
      final svc = CallService(fake)..start();

      final before = DateTime.now().millisecondsSinceEpoch;
      await svc.placeCall(caller, const CallMedia(audio: true));
      await pumpEventQueue();

      final offers = fake.sent
          .where((sig) => sig.type == CallSignalType.offer)
          .toList();
      expect(offers, isNotEmpty, reason: 'no offer was sent at all');
      final stamp = offers.first.sentAtMs;
      expect(stamp, isNotNull, reason: 'the offer went out unstamped');
      expect(stamp!, greaterThanOrEqualTo(before));
      svc.dispose();
    });

    test('accepting notifies the siblings, never the caller', () async {
      final fake = _FakeMessaging();
      final svc = CallService(fake)..start();
      svc.ownSiblingDevices = () async => [sibling];
      svc.isOwnDevice = (p) async => p.hex == sibling.hex;

      fake.onCallSignal!(caller, offer('fan-5'));
      await pumpEventQueue();
      await svc.accept();
      await pumpEventQueue();

      final answers = fake.sentTo
          .where((r) => r.$2.type == CallSignalType.answer)
          .toList();
      expect(answers.single.$1.hex, caller.hex);
      final hushes = fake.sentTo
          .where(
            (r) =>
                r.$2.type == CallSignalType.cancel &&
                r.$2.reason == CallEndReason.answeredElsewhere,
          )
          .toList();
      expect(hushes, hasLength(1));
      expect(hushes.single.$1.hex, sibling.hex);
      expect(hushes.single.$2.onBehalfOf, caller.hex);
      svc.dispose();
    });

    test(
      'answered-elsewhere from a sibling ends the ring as TAKEN, not missed',
      () async {
        final fake = _FakeMessaging();
        final svc = CallService(fake)..start();
        svc.ownSiblingDevices = () async => [sibling];
        svc.isOwnDevice = (p) async => p.hex == sibling.hex;

        fake.onCallSignal!(caller, offer('fan-6'));
        await pumpEventQueue();
        expect(svc.current?.status, CallStatus.ringing);

        fake.onCallSignal!(
          sibling,
          CallSignal(
            callId: 'fan-6',
            type: CallSignalType.cancel,
            reason: CallEndReason.answeredElsewhere,
            onBehalfOf: caller.hex,
            sentAtMs: DateTime.now().millisecondsSinceEpoch,
          ),
        );
        await pumpEventQueue();

        expect(svc.current, isNull);
        expect(
          callLogOutcomeFor(
            outgoing: false,
            connected: false,
            reason: CallEndReason.answeredElsewhere,
          ),
          CallLogOutcome.completed,
          reason: 'the identity took the call — "missed" would be a lie',
        );
        svc.dispose();
      },
    );

    // A decline on ANY device is the identity declining (owner's decision,
    // 2026-09-26). Every device now receives the caller's offer itself, so
    // "was this ring relayed?" came down to which copy landed first, and the
    // same tap either hung up on the caller with the siblings still ringing,
    // or left the caller dialing — both measured on the stand.
    for (final relayed in [false, true]) {
      test(
        'declining a ${relayed ? 'relayed' : 'direct'} ring declines for the '
        'identity: the caller hears it and the siblings stop',
        () async {
          final fake = _FakeMessaging();
          final svc = CallService(fake)..start();
          svc.ownSiblingDevices = () async => [sibling];
          svc.isOwnDevice = (p) async => p.hex == sibling.hex;

          fake.onCallSignal!(
            relayed ? sibling : caller,
            relayed ? offer('dec-1', onBehalfOf: caller.hex) : offer('dec-1'),
          );
          await pumpEventQueue();
          expect(svc.current?.status, CallStatus.ringing);

          await svc.reject();
          await pumpEventQueue();

          expect(svc.current, isNull);
          final rejects = fake.sentTo
              .where((r) => r.$2.type == CallSignalType.reject)
              .toList();
          expect(rejects.single.$1.hex, caller.hex);
          final hushes = fake.sentTo
              .where(
                (r) =>
                    r.$2.type == CallSignalType.cancel &&
                    r.$2.reason == CallEndReason.declined,
              )
              .toList();
          expect(hushes.single.$1.hex, sibling.hex);
          expect(hushes.single.$2.onBehalfOf, caller.hex);
          svc.dispose();
        },
      );
    }

    test('a sibling\'s decline stops this ring', () async {
      final fake = _FakeMessaging();
      final svc = CallService(fake)..start();
      svc.ownSiblingDevices = () async => [sibling];
      svc.isOwnDevice = (p) async => p.hex == sibling.hex;

      fake.onCallSignal!(caller, offer('dec-2'));
      await pumpEventQueue();
      fake.onCallSignal!(
        sibling,
        CallSignal(
          callId: 'dec-2',
          type: CallSignalType.cancel,
          reason: CallEndReason.declined,
          onBehalfOf: caller.hex,
          sentAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      await pumpEventQueue();

      expect(svc.current, isNull);
      expect(
        fake.sentTo.where((r) => r.$2.type == CallSignalType.reject),
        isEmpty,
        reason: 'the sibling already told the caller; a second "no" is noise',
      );
      svc.dispose();
    });

    // Measured on the stand: A declined, and 167 ms later the copy of the
    // offer its sibling had fanned out arrived and A rang again.
    test(
      'a late copy of an offer does not ring a declined call again',
      () async {
        final fake = _FakeMessaging();
        final svc = CallService(fake)..start();
        svc.ownSiblingDevices = () async => [sibling];
        svc.isOwnDevice = (p) async => p.hex == sibling.hex;

        fake.onCallSignal!(caller, offer('dec-3'));
        await pumpEventQueue();
        await svc.reject();
        await pumpEventQueue();

        fake.onCallSignal!(sibling, offer('dec-3', onBehalfOf: caller.hex));
        await pumpEventQueue();
        expect(svc.current, isNull);
        svc.dispose();
      },
    );

    test('a sibling\'s decline that beats this device\'s own copy of the offer '
        'keeps that copy silent', () async {
      final fake = _FakeMessaging();
      final svc = CallService(fake)..start();
      svc.ownSiblingDevices = () async => [sibling];
      svc.isOwnDevice = (p) async => p.hex == sibling.hex;

      fake.onCallSignal!(
        sibling,
        CallSignal(
          callId: 'dec-4',
          type: CallSignalType.cancel,
          reason: CallEndReason.declined,
          onBehalfOf: caller.hex,
          sentAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      await pumpEventQueue();
      fake.onCallSignal!(caller, offer('dec-4'));
      await pumpEventQueue();
      expect(svc.current, isNull);
      svc.dispose();
    });

    for (final response in [CallSignalType.reject, CallSignalType.busy]) {
      test('$response still ends an unanswered outgoing offer', () async {
        final fake = _FakeMessaging();
        final svc = CallService(fake)..start();
        addTearDown(svc.dispose);
        final peer = NodeId.fromHex('a' * 64);
        final changes = <Call?>[];
        final sub = svc.changes.listen(changes.add);
        addTearDown(sub.cancel);
        await svc.placeCall(peer, const CallMedia(audio: true));
        final id = svc.current!.callId;
        expect(svc.current?.status, CallStatus.dialing);
        fake.onCallSignal!(peer, CallSignal(callId: id, type: response));
        await pumpEventQueue();
        expect(svc.current, isNull);
        expect(
          changes.whereType<Call>().last.endReason,
          response == CallSignalType.reject
              ? CallEndReason.declined
              : CallEndReason.busy,
        );
        fake.onCallSignal!(
          peer,
          CallSignal(
            callId: id,
            type: CallSignalType.answer,
            mediaKey: generateCallMediaKeyContribution(),
          ),
        );
        await pumpEventQueue();
        expect(svc.current, isNull, reason: 'a refused offer cannot revive');
      });
    }

    for (final answeredAsIdentity in [false, true]) {
      for (final active in [false, true]) {
        test(
          'late fork decline preserves ${active ? 'active' : 'connecting'} call '
          'after ${answeredAsIdentity ? 'identity' : 'device'} answer',
          () async {
            final fake = _FakeMessaging();
            final media = active
                ? (_FakeMedia()..openedTransport = CallTransportKind.relay)
                : null;
            final svc = CallService(fake, media: media)..start();
            addTearDown(svc.dispose);
            final identity = NodeId.fromHex('a' * 64);
            final selectedDevice = NodeId.fromHex('b' * 64);
            await svc.placeCall(identity, const CallMedia(audio: true));
            final id = svc.current!.callId;
            fake.onCallSignal!(
              answeredAsIdentity ? identity : selectedDevice,
              CallSignal(
                callId: id,
                type: CallSignalType.answer,
                posture: CallPosture.direct,
                transport: const CallTransportProposal(CallTransportKind.relay),
                replyDevice: selectedDevice.hex,
                mediaKey: generateCallMediaKeyContribution(),
              ),
            );
            await pumpEventQueue();
            final phase = active ? CallStatus.active : CallStatus.connecting;
            expect(svc.current?.status, phase);
            expect(svc.current?.peerDevice, selectedDevice);
            final before = svc.current;
            final changes = <Call?>[];
            final sub = svc.changes.listen(changes.add);
            addTearDown(sub.cancel);
            // The identity's other device declined while its hush/selection was
            // still in flight. That pre-answer response arrives after B's answer.
            fake.onCallSignal!(
              identity,
              CallSignal(
                callId: id,
                type: CallSignalType.reject,
                reason: CallEndReason.declined,
              ),
            );
            await pumpEventQueue();
            expect(svc.current, same(before));
            expect(changes, isEmpty);
            // A real hangup from the elected endpoint still terminates the call.
            fake.onCallSignal!(
              selectedDevice,
              CallSignal(
                callId: id,
                type: CallSignalType.end,
                reason: CallEndReason.hangup,
              ),
            );
            await pumpEventQueue();
            expect(svc.current, isNull);
            expect(
              changes.whereType<Call>().single.endReason,
              CallEndReason.hangup,
            );
          },
        );
      }
    }

    test('the caller rebinds to whichever device answers', () async {
      final fake = _FakeMessaging();
      final svc = CallService(fake)..start();
      final identity = NodeId.fromHex('a' * 64);
      final device = NodeId.fromHex('b' * 64);

      await svc.placeCall(identity, const CallMedia(audio: true));
      final callId = svc.current!.callId;
      expect(fake.sent.single.replyDevice, NodeId.fromHex('f' * 64).hex);
      expect(
        CallSignal.tryDecode(fake.sent.single.encode())?.replyDevice,
        NodeId.fromHex('f' * 64).hex,
      );

      fake.onCallSignal!(
        device,
        CallSignal(
          callId: callId,
          type: CallSignalType.answer,
          posture: CallPosture.direct,
          transport: const CallTransportProposal(CallTransportKind.relay),
          mediaKey: generateCallMediaKeyContribution(),
        ),
      );
      await pumpEventQueue();

      expect(
        svc.current?.peer,
        device,
        reason: 'the dialog belongs to whoever picked up',
      );
      expect(svc.current?.mediaIdentity, identity);
      expect(svc.current?.mediaPeer, device);
      expect(svc.current?.status, CallStatus.connecting);

      // A late busy from a re-driven offer at another device must not tear
      // down the connected call.
      fake.onCallSignal!(
        device,
        CallSignal(
          callId: callId,
          type: CallSignalType.busy,
          reason: CallEndReason.busy,
        ),
      );
      await pumpEventQueue();
      expect(svc.current?.status, CallStatus.connecting);
      svc.dispose();
    });

    test(
      'an identity-sent answer binds media to its physical device',
      () async {
        final fake = _FakeMessaging();
        final svc = CallService(fake)..start();
        final identity = NodeId.fromHex('a' * 64);
        final device = NodeId.fromHex('b' * 64);

        await svc.placeCall(identity, const CallMedia(audio: true));
        fake.onCallSignal!(
          identity,
          CallSignal(
            callId: svc.current!.callId,
            type: CallSignalType.answer,
            posture: CallPosture.direct,
            transport: const CallTransportProposal(CallTransportKind.relay),
            replyDevice: device.hex,
            mediaKey: generateCallMediaKeyContribution(),
          ),
        );
        await pumpEventQueue();

        expect(
          svc.current?.peer,
          identity,
          reason: 'signaling stays on the accepted contact identity',
        );
        expect(
          svc.current?.mediaPeer,
          device,
          reason: 'native media ingress is attributed to the answering device',
        );
        expect(svc.current?.mediaIdentity, identity);
        svc.dispose();
      },
    );

    test(
      'a re-driven offer of the current call is swallowed, not busied',
      () async {
        final fake = _FakeMessaging();
        final svc = CallService(fake)..start();

        fake.onCallSignal!(caller, offer('fan-8'));
        await pumpEventQueue();
        expect(svc.current?.status, CallStatus.ringing);

        fake.onCallSignal!(caller, offer('fan-8'));
        await pumpEventQueue();

        expect(svc.current?.status, CallStatus.ringing);
        expect(
          fake.sentTo.where((r) => r.$2.type == CallSignalType.busy),
          isEmpty,
          reason: 're-drives of the same call must not busy the caller',
        );
        svc.dispose();
      },
    );
  });

  group('teardown is a boundary', () {
    // Every async mutator here already re-checks after its awaits — placeCall
    // compares callId and status, accept compares callId, peer and status —
    // and every one of those checks PASSED after dispose(), because teardown
    // cancelled the timers, released the slot and left `_current` holding the
    // very call it had torn down. The continuation then found exactly what it
    // expected and sent an offer, or an answer, and started media, from a
    // service whose identity is gone (report18 XV18-H1/H2).

    test('an offer is not sent after dispose', () async {
      final peer = NodeId.fromHex('e' * 64);
      final messaging = _FakeMessaging();
      final slot = CallSlot();
      final gate = Completer<bool>();
      var reachedTheGap = false;
      final svc = CallService(
        messaging,
        callSlot: slot,
        localAllowsP2P: (_) {
          reachedTheGap = true;
          return gate.future;
        },
      )..start();

      final placing = svc.placeCall(peer, const CallMedia(audio: true));
      await pumpEventQueue();
      expect(svc.current, isNotNull, reason: 'premise: the call is dialing');
      // Vacuity guard: everything below passes on a placeCall that never got
      // as far as the await this test is about.
      expect(
        reachedTheGap,
        isTrue,
        reason: 'placeCall never reached the gap — this test proves nothing',
      );

      svc.dispose();
      gate.complete(false);
      await placing;

      expect(
        messaging.sent.where((s) => s.type == CallSignalType.offer),
        isEmpty,
        reason: 'an offer went out from a service whose identity is gone',
      );
      expect(svc.current, isNull, reason: 'teardown left the call behind');
    });

    test('an answer and media do not start after dispose', () async {
      final peer = NodeId.fromHex('f' * 64);
      final messaging = _FakeMessaging();
      final media = _FakeMedia();
      final gate = Completer<bool>();
      var reachedTheGap = false;
      final svc = CallService(
        messaging,
        media: media,
        localAllowsP2P: (_) {
          reachedTheGap = true;
          return gate.future;
        },
      )..start();

      messaging.onCallSignal!(
        peer,
        CallSignal(
          callId: 'incoming-after-dispose',
          type: CallSignalType.offer,
          media: const CallMedia(audio: true),
          posture: CallPosture.direct,
          transport: const CallTransportProposal(CallTransportKind.p2p),
          protocolVersion: kCallSignalProtocolVersion,
          sentAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      await pumpEventQueue();
      expect(svc.current?.status, CallStatus.ringing, reason: 'premise');

      final accepting = svc.accept();
      await pumpEventQueue();
      expect(
        reachedTheGap,
        isTrue,
        reason: 'accept never reached the gap — this test proves nothing',
      );

      svc.dispose();
      gate.complete(false);
      await accepting;

      expect(
        messaging.sent.where((s) => s.type == CallSignalType.answer),
        isEmpty,
        reason: 'an answer went out after teardown',
      );
      expect(
        media.startedWith,
        isEmpty,
        reason: 'the microphone was started after teardown',
      );
      expect(svc.current, isNull);
    });
  });
}

/// Records camera/screen toggles; [screenOk] fakes the platform backend
/// accepting or refusing to start the capture.
class _CompactHealthMedia extends _FakeMedia {
  final health = StreamController<CallSignal>.broadcast();
  final compact = <CallSignal>[];
  bool admit = true;
  void Function(CallSignal)? onCompact;

  @override
  Stream<CallSignal> get peerCallControl => health.stream;

  @override
  bool get canReceiveEphemeralHealth => true;

  @override
  bool sendEphemeralCallControl(CallSignal signal) {
    if (!admit) return false;
    compact.add(signal);
    onCompact?.call(signal);
    return true;
  }
}

CallSignal _diagnosticOffer() => CallSignal(
  callId: 'private-call-diagnostic-fixture',
  type: CallSignalType.offer,
  media: const CallMedia(audio: true),
  posture: CallPosture.direct,
  mediaKey: generateCallMediaKeyContribution(),
);

class _FakeMedia extends CallMediaController {
  Future<bool> Function(bool)? screenOperation;
  final cameraFailures = StreamController<String>.broadcast();
  @override
  Stream<String> get cameraUnavailable => cameraFailures.stream;
  @override
  bool startedWithoutCamera = false;
  Future<void> Function(bool)? cameraOperation;
  final microphoneFailures = StreamController<String>.broadcast();
  @override
  Stream<String> get microphoneUnavailable => microphoneFailures.stream;

  Future<bool> Function(bool)? micOperation;
  @override
  Future<bool> setMicMuted(bool muted) async =>
      await micOperation?.call(muted) ?? true;

  @override
  bool startedWithoutMicrophone = false;
  final List<bool> peerAudioCapture = [];

  @override
  void observePeerAudioCapture(bool enabled) => peerAudioCapture.add(enabled);

  bool directPeerAdmitted = true;
  bool? liveDirectAdmission;
  Completer<bool?>? liveAdmissionGate;
  final List<NodeId> liveAdmissionChecks = [];

  @override
  Future<bool?> currentDirectPeerAdmission(Call call) async {
    liveAdmissionChecks.add(call.peerDevice ?? call.peer);
    return await liveAdmissionGate?.future ?? liveDirectAdmission;
  }

  final List<NodeId> admissionChecks = [];
  Completer<bool>? requiredAdmissionGate;

  @override
  Future<bool> isDirectPeerAdmitted(Call call) async {
    admissionChecks.add(call.peerDevice ?? call.peer);
    final gate = requiredAdmissionGate;
    return gate == null ? directPeerAdmitted : await gate.future;
  }

  int signalVersion = kCallSignalProtocolVersion;
  bool screenOk = true;
  bool videoOk = true;
  Completer<bool>? videoGate;
  bool? cameraIntent;
  CallTransportKind? openedTransport;
  CallTransportKind? repairTo;
  DateTime? rxAt;
  bool audioTelemetry = false;
  DateTime? audioRxAt;
  Future<DateTime?> Function()? latestAudioRead;
  int latestAudioReads = 0;

  @override
  Future<DateTime?> readLatestAudioRxAt() async {
    latestAudioReads++;
    return latestAudioRead == null ? audioRxAt : await latestAudioRead!();
  }

  DateTime? receiveStartedAt;
  bool receiveRepairing = false;
  CallAudioPlayoutFeedback? playout;
  final List<CallAudioPlayoutFeedback> peerPlayout = [];
  int repairs = 0;
  int relayRefreshes = 0;
  Future<bool> Function(Future<bool> Function())? relayRefresh;
  Completer<bool>? startGate;
  final List<CallTransportKind> switches = [];
  final List<String> log = [];
  final List<CallTransportKind?> startedWith = [];
  final StreamController<void> screenStops = StreamController.broadcast();
  String? selectedCamera;
  String? selectedMicrophone;
  String? selectedSpeaker;
  String? selectedScreen;

  @override
  int get signalProtocolVersion => signalVersion;

  @override
  Future<List<CallMediaDevice>> listCameras() async => [
    CallMediaDevice(
      id: 'front',
      label: 'Front',
      kind: CallMediaDeviceKind.camera,
      facing: 'front',
      selected: selectedCamera == null || selectedCamera == 'front',
    ),
    CallMediaDevice(
      id: 'back',
      label: 'Back',
      kind: CallMediaDeviceKind.camera,
      facing: 'back',
      selected: selectedCamera == 'back',
    ),
  ];

  @override
  Future<List<CallMediaDevice>> listMicrophones() async => const [
    CallMediaDevice(
      id: 'builtin',
      label: 'Built-in',
      kind: CallMediaDeviceKind.microphone,
      selected: true,
    ),
    CallMediaDevice(
      id: 'usb',
      label: 'USB',
      kind: CallMediaDeviceKind.microphone,
    ),
  ];

  @override
  Future<List<CallMediaDevice>> listScreens() async => const [
    CallMediaDevice(
      id: 'display-1',
      label: 'Main display',
      kind: CallMediaDeviceKind.screen,
      selected: true,
    ),
    CallMediaDevice(
      id: 'display-2',
      label: 'External display',
      kind: CallMediaDeviceKind.screen,
    ),
  ];

  @override
  Future<bool> selectCamera(String id) async {
    selectedCamera = id;
    return true;
  }

  @override
  Future<bool> selectMicrophone(String id) async {
    selectedMicrophone = id;
    return true;
  }

  @override
  Future<bool> selectSpeaker(String id) async {
    selectedSpeaker = id;
    return true;
  }

  @override
  Future<bool> selectScreen(String id) async {
    selectedScreen = id;
    return true;
  }

  @override
  Stream<void> get screenShareStopped => screenStops.stream;

  @override
  CallTransportKind? get activeTransport => openedTransport;

  @override
  DateTime? get lastMediaRxAt => rxAt;

  @override
  bool get hasAudioReceiveTelemetry => audioTelemetry;

  @override
  DateTime? get lastAudioRxAt => audioRxAt;

  @override
  DateTime? get receiveSessionStartedAt => receiveStartedAt;

  @override
  bool get isRepairingReceiveSession => receiveRepairing;

  @override
  CallAudioPlayoutFeedback? get audioPlayoutFeedback => playout;

  @override
  void observePeerAudioPlayout(CallAudioPlayoutFeedback feedback) {
    peerPlayout.add(feedback);
  }

  @override
  Future<bool> start(Call call) async {
    startedWith.add(call.transport);
    return startGate?.future ?? true;
  }

  @override
  Future<void> stop() async {}

  @override
  Future<bool> repairRoute() async {
    repairs++;
    if (repairTo != null) openedTransport = repairTo;
    return true;
  }

  @override
  Future<bool> refreshRelayRoute({
    required Future<bool> Function() canCommit,
  }) async {
    relayRefreshes++;
    return await relayRefresh?.call(canCommit) ?? false;
  }

  @override
  Future<bool> switchRoute(
    CallTransportKind transport, {
    Future<bool> Function()? canCommit,
  }) async {
    switches.add(transport);
    if (canCommit != null && !await canCommit()) return false;
    openedTransport = transport;
    return true;
  }

  @override
  void updateCameraIntent(bool enabled) => cameraIntent = enabled;

  @override
  Future<void> setCameraEnabled(bool enabled) async {
    log.add('cam:$enabled');
    await cameraOperation?.call(enabled);
  }

  @override
  Future<bool> setVideoEnabled(bool enabled) async {
    log.add('video:$enabled');
    return await videoGate?.future ?? videoOk;
  }

  @override
  Future<bool> setScreenShareEnabled(bool enabled) async {
    log.add('screen:$enabled');
    final operation = screenOperation;
    if (operation != null) return operation(enabled);
    return enabled ? screenOk : true;
  }
}

class _GatedRepairMedia extends _FakeMedia {
  final gate = Completer<bool>();

  @override
  Future<bool> repairRoute() {
    repairs++;
    return gate.future;
  }
}

class _RepairThenRelayMedia extends _SnapshotMedia {
  final operations = CallMediaRouteOperations();
  final cameraStopped = Completer<void>();
  bool repairSucceeds = true;
  Completer<bool>? relayGate;

  @override
  Future<bool> repairRoute() => operations.run(() async {
    repairs++;
    receiveRepairing = true;
    openedTransport = null;
    await cameraStopped.future;
    openedTransport = repairSucceeds ? CallTransportKind.p2p : null;
    receiveRepairing = false;
    return repairSucceeds;
  });

  @override
  Future<bool> switchRoute(
    CallTransportKind transport, {
    Future<bool> Function()? canCommit,
  }) => operations.run(() async {
    final gate = relayGate;
    if (gate == null) return super.switchRoute(transport, canCommit: canCommit);
    switches.add(transport);
    final ok = await gate.future;
    openedTransport = ok ? transport : null;
    return ok;
  });
}

class _GatedRelaySwitchMedia extends _FakeMedia {
  final relayGate = Completer<bool>();
  @override
  Future<bool> switchRoute(
    CallTransportKind transport, {
    Future<bool> Function()? canCommit,
  }) async {
    if (transport != CallTransportKind.relay) {
      return super.switchRoute(transport, canCommit: canCommit);
    }
    switches.add(transport);
    // Match native: attempting a second relay switch during rebuilding fails.
    if (switches.length > 1) return false;
    final ok = await relayGate.future;
    if (canCommit != null && !await canCommit()) return false;
    if (ok) openedTransport = transport;
    return ok;
  }
}

class _UnprovenRelayMedia extends _FakeMedia {
  bool candidateProven = false;
  int stops = 0;
  bool retainDirect = true;
  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<bool> switchRoute(
    CallTransportKind transport, {
    Future<bool> Function()? canCommit,
  }) async {
    if (candidateProven) {
      return super.switchRoute(transport, canCommit: canCommit);
    }
    switches.add(transport);
    if (!retainDirect) openedTransport = null;
    return false;
  }
}

class _GatedStartMedia extends _FakeMedia {
  final Completer<bool> initialStart = Completer<bool>();

  @override
  Future<bool> start(Call call) {
    startedWith.add(call.transport);
    return initialStart.future;
  }
}

/// Minimal [MessagingService] stand-in: only the three members [CallService]
/// touches (isAnonymousIdentity, onCallSignal, sendCallSignal) are real;
/// everything else routes to noSuchMethod (never hit by the control-plane FSM).
class _FakeMessaging implements MessagingService {
  bool anon = false;
  @override
  bool backgroundStashPaused = false;
  final List<CallSignal> sent = [];

  /// (peer, signal) pairs — the fan-out tests assert WHERE a signal went,
  /// which [sent] alone cannot answer.
  final List<(NodeId, CallSignal)> sentTo = [];
  final List<(String, NodeId, NodeId)> replyPins = [];

  /// When set, [sendCallSignal] records the signal only after the gate
  /// completes — models the slow durable (encrypted-store) enqueue.
  Completer<void>? sendGate;
  Completer<void>? rejectedHealthCompletion;
  Future<NodeId> Function()? readLocalDevice;

  @override
  bool get isAnonymousIdentity => anon;

  @override
  void Function(NodeId peer, CallSignal signal)? onCallSignal;

  @override
  bool Function(NodeId peer, CallSignal signal)? acceptsCallDeviceSignal;

  @override
  Future<NodeId> localDeviceId() async =>
      readLocalDevice?.call() ?? NodeId.fromHex('f' * 64);

  @override
  void pinCallReplyDevice(String callId, NodeId identity, NodeId device) {
    replyPins.add((callId, identity, device));
  }

  @override
  Future<void> sendCallSignal(NodeId peer, CallSignal signal) =>
      _sendSignal(peer, signal);

  @override
  Future<void> sendCallHealth(
    NodeId peer,
    CallSignal signal, {
    required bool Function() admitTransport,
  }) => _sendSignal(peer, signal, admitTransport: admitTransport);

  Future<void> _sendSignal(
    NodeId peer,
    CallSignal signal, {
    bool Function()? admitTransport,
  }) async {
    final gate = sendGate;
    if (gate != null) await gate.future;
    if (admitTransport?.call() == false) {
      await rejectedHealthCompletion?.future;
      return;
    }
    sent.add(signal);
    sentTo.add((peer, signal));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _GatedSwitchMedia extends _FakeMedia {
  final switchGate = Completer<bool>();
  @override
  Future<bool> switchRoute(
    CallTransportKind transport, {
    Future<bool> Function()? canCommit,
  }) async {
    switches.add(transport);
    if (transport == CallTransportKind.p2p) await switchGate.future;
    if (canCommit != null && !await canCommit()) return false;
    openedTransport = transport;
    return true;
  }
}

class _RejectDirectSwitchMedia extends _FakeMedia {
  bool rejectDirect = true;
  @override
  Future<bool> switchRoute(
    CallTransportKind transport, {
    Future<bool> Function()? canCommit,
  }) async {
    if (rejectDirect && transport == CallTransportKind.p2p) {
      switches.add(transport);
      return false;
    }
    return super.switchRoute(transport, canCommit: canCommit);
  }
}

class _FailOnceDirectSwitchMedia extends _FakeMedia {
  _FailOnceDirectSwitchMedia({required this.throws});
  final bool throws;
  bool failed = false;
  void Function()? onCandidateFailure;

  @override
  Future<bool> switchRoute(
    CallTransportKind transport, {
    Future<bool> Function()? canCommit,
  }) async {
    switches.add(transport);
    if (transport == CallTransportKind.p2p && !failed) {
      failed = true;
      onCandidateFailure?.call();
      if (throws) throw StateError('candidate delivery unconfirmed');
      return false;
    }
    if (canCommit != null && !await canCommit()) return false;
    openedTransport = transport;
    return true;
  }
}

class _ReceiveHistoryMedia extends _FakeMedia {
  final receipts = CallMediaReceiveActivity();

  @override
  DateTime? get lastMediaRxAt => receipts.lastRxAt;

  @override
  Future<DateTime?> readLatestMediaRxAt() async =>
      receiveRepairing ? null : receipts.lastRxAt;
}

class _SnapshotMedia extends _FakeMedia {
  Future<DateTime?> Function()? readSnapshot;
  int snapshotReads = 0;
  @override
  Future<DateTime?> readLatestMediaRxAt() async {
    snapshotReads++;
    return readSnapshot == null ? null : await readSnapshot!();
  }
}

class _ReconnectRelayMedia extends _SnapshotMedia {
  _ReconnectRelayMedia() {
    openedTransport = CallTransportKind.p2p;
  }
  Completer<bool>? firstAttempt;
  Completer<bool>? nextAttempt;
  bool proven = false;
  @override
  Future<bool> switchRoute(
    CallTransportKind transport, {
    Future<bool> Function()? canCommit,
  }) async {
    switches.add(transport);
    final gate = switches.length == 1 ? firstAttempt : nextAttempt;
    nextAttempt = null;
    final ok = gate == null ? proven : await gate.future;
    if (canCommit != null && !await canCommit()) return false;
    if (ok) openedTransport = transport;
    return ok;
  }
}

class _RelayObservationMedia extends _ReconnectRelayMedia {
  final relayProbes = StreamController<Call>.broadcast(sync: true);

  @override
  Stream<Call> get peerRelayProbes => relayProbes.stream;
}
