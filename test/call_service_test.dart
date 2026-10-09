import 'dart:async';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/call.dart';
import 'package:xveil/domain/call_log.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/state/call_service.dart';
import 'package:xveil/state/call_media_route_operations.dart';
import 'package:xveil/state/call_slot.dart';
import 'package:xveil/state/messaging.dart';
import 'package:xveil/state/veil_call_media.dart';

void main() {
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
        expect(fake.sent.single.type, CallSignalType.health);
        final back = CallSignal.tryDecode(fake.sent.single.encode())!;
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
          fake.onCallSignal!(peer, offer('playout-auth'));
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
          svc.hangup();
          async.flushMicrotasks();
          fake.onCallSignal!(peer, health);
          expect(
            media.peerPlayout.length,
            1,
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

    for (final outcome in [
      'resumed',
      'unavailable',
      'failed',
      'timeout',
      'stopped',
    ]) {
      test('cached direct outage rechecks native audio: $outcome', () {
        fakeAsync((async) {
          final fake = _FakeMessaging();
          final media = _FakeMedia()
            ..liveDirectAdmission = true
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
            media.rxAt = clock.now(); // Other ingress and the parent stay live.
            async.elapse(const Duration(milliseconds: 500));
            async.flushMicrotasks();
          }
          expect(
            media.switches,
            outcome == 'stopped' ? [CallTransportKind.relay] : isEmpty,
            reason: 'only a confirmed current audio outage abandons P2P',
          );
          expect(
            svc.current?.transport,
            outcome == 'stopped'
                ? CallTransportKind.relay
                : CallTransportKind.p2p,
          );
          expect(media.latestAudioReads, greaterThan(0));
          if (outcome != 'stopped') {
            expect(
              fake.sent.where((s) => s.type == CallSignalType.transportInfo),
              isEmpty,
            );
          }
          svc.dispose();
          if (outcome == 'timeout') {
            pending.complete(media.audioRxAt);
            async.flushMicrotasks();
            expect(media.switches, isEmpty, reason: 'late read after disposal');
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
              .where((s) => s.type == CallSignalType.transportInfo)
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
      expect(fake.sent, isEmpty);
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

    test('identity control survives a forked device answer and route change', () {
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
        expect(svc.current?.transport, CallTransportKind.relay);

        // Knowing a call id does not make another identity a readiness source.
        fake.onCallSignal!(stranger, ready(id));
        async.flushMicrotasks();
        expect(media.switches, isEmpty);
        fake.onCallSignal!(peer, ready(id));
        async.flushMicrotasks();
        expect(media.switches, [CallTransportKind.p2p]);
        expect(media.admissionChecks, everyElement(device));
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

    test(
      'native admission loss announces relay and does not keep retrying',
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
class _FakeMedia extends CallMediaController {
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

  @override
  Future<bool> isDirectPeerAdmitted(Call call) async {
    admissionChecks.add(call.peerDevice ?? call.peer);
    return directPeerAdmitted;
  }

  int signalVersion = kCallSignalProtocolVersion;
  bool screenOk = true;
  bool videoOk = true;
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
  Future<bool> switchRoute(CallTransportKind transport) async {
    switches.add(transport);
    openedTransport = transport;
    return true;
  }

  @override
  void updateCameraIntent(bool enabled) => cameraIntent = enabled;

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

class _RepairThenRelayMedia extends _FakeMedia {
  final operations = CallMediaRouteOperations();
  final cameraStopped = Completer<void>();

  @override
  Future<bool> repairRoute() => operations.run(() async {
    repairs++;
    receiveRepairing = true;
    openedTransport = null;
    await cameraStopped.future;
    openedTransport = CallTransportKind.p2p;
    receiveRepairing = false;
    return true;
  });

  @override
  Future<bool> switchRoute(CallTransportKind transport) =>
      operations.run(() => super.switchRoute(transport));
}

class _GatedRelaySwitchMedia extends _FakeMedia {
  final relayGate = Completer<bool>();
  @override
  Future<bool> switchRoute(CallTransportKind transport) async {
    switches.add(transport);
    // Match native: attempting a second switch during rebuilding fails.
    if (switches.length > 1) return false;
    final ok = await relayGate.future;
    if (ok) openedTransport = transport;
    return ok;
  }
}

class _UnprovenRelayMedia extends _FakeMedia {
  int stops = 0;
  bool retainDirect = true;
  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<bool> switchRoute(CallTransportKind transport) async {
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

  /// When set, [sendCallSignal] records the signal only after the gate
  /// completes — models the slow durable (encrypted-store) enqueue.
  Completer<void>? sendGate;

  @override
  bool get isAnonymousIdentity => anon;

  @override
  void Function(NodeId peer, CallSignal signal)? onCallSignal;

  @override
  bool Function(NodeId peer, CallSignal signal)? acceptsCallDeviceSignal;

  @override
  Future<NodeId> localDeviceId() async => NodeId.fromHex('f' * 64);

  @override
  void pinCallReplyDevice(String callId, NodeId identity, NodeId device) {}

  @override
  Future<void> sendCallSignal(NodeId peer, CallSignal signal) async {
    final gate = sendGate;
    if (gate != null) await gate.future;
    sent.add(signal);
    sentTo.add((peer, signal));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _GatedSwitchMedia extends _FakeMedia {
  final switchGate = Completer<bool>();
  @override
  Future<bool> switchRoute(CallTransportKind transport) async {
    switches.add(transport);
    if (transport == CallTransportKind.p2p) await switchGate.future;
    openedTransport = transport;
    return true;
  }
}

class _RejectDirectSwitchMedia extends _FakeMedia {
  @override
  Future<bool> switchRoute(CallTransportKind transport) async {
    switches.add(transport);
    return false;
  }
}
