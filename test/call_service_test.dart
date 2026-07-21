import 'dart:async';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/call.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/state/call_service.dart';
import 'package:xveil/state/call_slot.dart';
import 'package:xveil/state/messaging.dart';
import 'package:xveil/state/veil_call_media.dart';

void main() {
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
      expect(slot.acquire(CallSlotOwner.group), isTrue);
      final svc = CallService(fake, callSlot: slot)..start();
      addTearDown(svc.dispose);

      await svc.placeCall(peer, const CallMedia(audio: true));
      expect(svc.current, isNull);
      expect(fake.sent, isEmpty);

      slot.release(CallSlotOwner.group);
      await svc.placeCall(peer, const CallMedia(audio: true));
      expect(slot.owner, CallSlotOwner.direct);
      expect(svc.current?.isLive, isTrue);
      await svc.cancel();
      expect(slot.owner, isNull);

      // The same exclusion applies to a later inbound offer.
      fake.sent.clear();
      expect(slot.acquire(CallSlotOwner.group), isTrue);
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

      final callerKeys = deriveRelayMediaKeys(
        call: caller,
        localNodeId: callerNode.bytes,
      )!;
      final calleeKeys = deriveRelayMediaKeys(
        call: callee,
        localNodeId: calleeNode.bytes,
      )!;
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

    test('older native media ABI advertises v2 on offer and answer', () async {
      final outgoingMessaging = _FakeMessaging();
      final outgoingMedia = _FakeMedia()..signalVersion = 2;
      final outgoing = CallService(outgoingMessaging, media: outgoingMedia)
        ..start();

      await outgoing.placeCall(peer, const CallMedia(audio: true, video: true));
      expect(outgoingMessaging.sent.single.protocolVersion, 2);
      expect(outgoingMessaging.sent.single.mediaKey, isNull);
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
      expect(incomingMessaging.sent.single.mediaKey, isNull);
      incoming.dispose();
    });

    test('a stalled P2P probe cannot hold the outgoing offer', () async {
      final fake = _FakeMessaging();
      final probe = Completer<bool>();
      final svc = CallService(
        fake,
        localAllowsP2P: (_) async => true,
        peerReachableForP2P: (_) => probe.future,
      )..start();
      addTearDown(() {
        if (!probe.isCompleted) probe.complete(false);
        svc.dispose();
      });

      await svc
          .placeCall(peer, const CallMedia(audio: true))
          .timeout(const Duration(milliseconds: 500));

      expect(fake.sent.single.type, CallSignalType.offer);
      expect(fake.sent.single.transport?.kind, CallTransportKind.relay);
      expect(probe.isCompleted, isFalse);
    });

    test('outgoing direct call proposes p2p only when local policy and '
        'reachability allow it', () async {
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
    });

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
        expect(fake.sent.single.transport?.kind, CallTransportKind.relay);
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
      expect(fake.sent.single.transport?.kind, CallTransportKind.p2p);
      expect(media.startedWith, [CallTransportKind.p2p]);
    });

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

    test(
      'answer racing a slow durable offer never arms a timer on the active call',
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
      expect(fake.sent, isEmpty);
    });

    test(
      'relay follow supersedes an in-flight P2P start without ending call',
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
        media.initialStart.complete(false);
        await Future<void>.delayed(Duration.zero);

        expect(media.switches, [CallTransportKind.relay]);
        expect(svc.current?.transport, CallTransportKind.relay);
        expect(svc.current?.status, CallStatus.active);
      },
    );
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
}

/// Records camera/screen toggles; [screenOk] fakes the platform backend
/// accepting or refusing to start the capture.
class _FakeMedia extends CallMediaController {
  int signalVersion = kCallSignalProtocolVersion;
  bool screenOk = true;
  bool videoOk = true;
  CallTransportKind? openedTransport;
  CallTransportKind? repairTo;
  DateTime? rxAt;
  int repairs = 0;
  Completer<bool>? startGate;
  final List<CallTransportKind> switches = [];
  final List<String> log = [];
  final List<CallTransportKind?> startedWith = [];
  final StreamController<void> screenStops = StreamController.broadcast();
  String? selectedCamera;
  String? selectedMicrophone;
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
  Future<bool> switchRoute(CallTransportKind transport) async {
    switches.add(transport);
    openedTransport = transport;
    return true;
  }

  @override
  Future<void> setCameraEnabled(bool enabled) async {
    log.add('cam:$enabled');
  }

  @override
  Future<bool> setVideoEnabled(bool enabled) async {
    log.add('video:$enabled');
    return videoOk;
  }

  @override
  Future<bool> setScreenShareEnabled(bool enabled) async {
    log.add('screen:$enabled');
    return enabled ? screenOk : true;
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

  /// When set, [sendCallSignal] records the signal only after the gate
  /// completes — models the slow durable (encrypted-store) enqueue.
  Completer<void>? sendGate;

  @override
  bool get isAnonymousIdentity => anon;

  @override
  void Function(NodeId peer, CallSignal signal)? onCallSignal;

  @override
  Future<void> sendCallSignal(NodeId peer, CallSignal signal) async {
    final gate = sendGate;
    if (gate != null) await gate.future;
    sent.add(signal);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
