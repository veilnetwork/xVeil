import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/call.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/state/call_service.dart';
import 'package:xveil/state/messaging.dart';

void main() {
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

    test('mixed (anon ↔ direct) → relay, both orderings', () {
      expect(
        negotiateCallTransport(
          local: CallPosture.anonymous,
          peer: CallPosture.direct,
        ),
        CallTransportKind.relay,
      );
      expect(
        negotiateCallTransport(
          local: CallPosture.direct,
          peer: CallPosture.anonymous,
        ),
        CallTransportKind.relay,
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

    test('outgoing direct call proposes p2p only when local policy and '
        'reachability allow it', () async {
      final fake = _FakeMessaging();
      final svc = CallService(
        fake,
        localAllowsP2P: (_) async => true,
        peerReachableForP2P: (_) async => true,
      )..start();

      await svc.placeCall(peer, const CallMedia(audio: true, video: true));

      expect(fake.sent.single.type, CallSignalType.offer);
      expect(fake.sent.single.transport?.kind, CallTransportKind.p2p);
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
    });

    test('incoming p2p offer is accepted as p2p only with local consent and '
        'reachability', () async {
      final fake = _FakeMessaging();
      final svc = CallService(
        fake,
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

      await svc.accept();

      expect(svc.current?.transport, CallTransportKind.p2p);
      expect(fake.sent.single.type, CallSignalType.answer);
      expect(fake.sent.single.transport?.kind, CallTransportKind.p2p);
    });

    test(
      'incoming p2p offer falls back to relay when local policy denies',
      () async {
        final fake = _FakeMessaging();
        final svc = CallService(
          fake,
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

        expect(svc.current?.transport, CallTransportKind.relay);
        expect(fake.sent.single.transport?.kind, CallTransportKind.relay);
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

        // Peer never sends anything again → past the deadline it tears down.
        async.elapse(const Duration(seconds: 30));
        async.flushMicrotasks();

        expect(svc.current, isNull); // slot cleared
        final terminal = seen.lastWhere(
          (c) => c?.status == CallStatus.ended,
          orElse: () => null,
        );
        expect(terminal?.endReason, CallEndReason.timeout);
      });
    });

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
        expect(media.log, ['screen:true', 'screen:false', 'cam:true'],
            reason: 'cameraOn stayed true → the share hand-back restores it');
      });
    });

    test('a failed capture start leaves the call in camera state', () {
      fakeAsync((async) {
        final (svc, media) = liveVideoCall(async);
        media.screenOk = false;

        svc.setScreenShareEnabled(true);
        async.flushMicrotasks();
        expect(svc.current?.screenOn, isFalse,
            reason: 'no backend / capture failed — nothing changed');
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
        expect(media.log, isEmpty,
            reason: 'the share owns the single video source');

        svc.setScreenShareEnabled(false);
        async.flushMicrotasks();
        expect(media.log, ['screen:false'],
            reason: 'cameraOn=false → nothing to restore');
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
}

/// Records camera/screen toggles; [screenOk] fakes the platform backend
/// accepting or refusing to start the capture.
class _FakeMedia extends CallMediaController {
  bool screenOk = true;
  final List<String> log = [];

  @override
  Future<bool> start(Call call) async => true;

  @override
  Future<void> stop() async {}

  @override
  Future<void> setCameraEnabled(bool enabled) async {
    log.add('cam:$enabled');
  }

  @override
  Future<bool> setScreenShareEnabled(bool enabled) async {
    log.add('screen:$enabled');
    return enabled ? screenOk : true;
  }
}

/// Minimal [MessagingService] stand-in: only the three members [CallService]
/// touches (isAnonymousIdentity, onCallSignal, sendCallSignal) are real;
/// everything else routes to noSuchMethod (never hit by the control-plane FSM).
class _FakeMessaging implements MessagingService {
  bool anon = false;
  final List<CallSignal> sent = [];

  @override
  bool get isAnonymousIdentity => anon;

  @override
  void Function(NodeId peer, CallSignal signal)? onCallSignal;

  @override
  Future<void> sendCallSignal(NodeId peer, CallSignal signal) async {
    sent.add(signal);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
