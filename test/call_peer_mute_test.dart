import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/call.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/features/calls/call_overlay.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/call_service.dart';
import 'package:xveil/state/messaging.dart';

/// A peer muting its microphone is invisible to the other side unless it is
/// SENT: the media layer simply stops emitting packets, which on the receiving
/// end is indistinguishable from a call that has broken. These tests are about
/// the sentence the call screen puts on the glass, not about a field.

NodeId _peer() => NodeId.fromHex('b' * 64);

/// A ready session, so the call overlay is allowed to engage at all.
class _ReadyAppController extends AppController {
  @override
  AppState build() => AppState(
    AppPhase.ready,
    identity: Identity(nodeId: NodeId(Uint8List(32))),
  );
}

/// Media that comes up, so the call reaches [CallStatus.active] — the only
/// status at which a peer's posture is worth reporting.
class _UpMedia extends CallMediaController {
  @override
  Future<bool> start(Call call) async => true;

  @override
  Future<void> stop() async {}
}

class _FakeMessaging implements MessagingService {
  @override
  bool backgroundStashPaused = false;
  final List<CallSignal> sent = [];

  @override
  bool get isAnonymousIdentity => false;

  @override
  void Function(NodeId peer, CallSignal signal)? onCallSignal;

  @override
  Future<void> sendCallSignal(NodeId peer, CallSignal signal) async {
    sent.add(signal);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Drive a real [CallService] to a live, active audio call with [_peer].
///
/// Inside `testWidgets` this MUST run under `tester.runAsync`: the fixture
/// waits on the real event queue, which never drains in the fake-async zone a
/// widget test runs in — it hangs rather than fails.
Future<CallService> _activeCall(_FakeMessaging messaging) async {
  final svc = CallService(messaging, media: _UpMedia())..start();
  messaging.onCallSignal!(
    _peer(),
    const CallSignal(
      callId: 'peer-mute',
      type: CallSignalType.offer,
      media: CallMedia(audio: true),
      posture: CallPosture.direct,
    ),
  );
  await pumpEventQueue();
  await svc.accept();
  await pumpEventQueue();
  return svc;
}

void main() {
  testWidgets('the call screen says when the peer mutes, and unsays it', (
    tester,
  ) async {
    final messaging = _FakeMessaging();
    late CallService svc;
    await tester.runAsync(() async => svc = await _activeCall(messaging));
    addTearDown(svc.dispose);
    expect(
      svc.current?.status,
      CallStatus.active,
      reason: 'the fixture must reach the status the label depends on',
    );

    late AppL10n l;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appControllerProvider.overrideWith(_ReadyAppController.new),
          callServiceProvider.overrideWith((ref) => svc),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          theme: ThemeData.dark(),
          home: Stack(
            children: [
              Builder(
                builder: (context) {
                  l = AppL10n.of(context);
                  return const SizedBox.shrink();
                },
              ),
              const CallOverlay(),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Before the peer says anything, the screen must not accuse them.
    expect(find.text(l.callActive), findsWidgets);
    expect(find.text(l.callPeerMicOff), findsNothing);

    // The peer mutes. Their posture rides the heartbeat.
    messaging.onCallSignal!(
      _peer(),
      const CallSignal(
        callId: 'peer-mute',
        type: CallSignalType.health,
        capture: CallMedia(),
        sentAtMs: 1000,
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(l.callPeerMicOff),
      findsWidgets,
      reason: 'the person must be told the silence is deliberate',
    );
    expect(find.text(l.callActive), findsNothing);

    // …and unmutes. The screen must go back, not stay accusing them.
    messaging.onCallSignal!(
      _peer(),
      const CallSignal(
        callId: 'peer-mute',
        type: CallSignalType.health,
        capture: CallMedia(audio: true),
        sentAtMs: 2000,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(l.callPeerMicOff), findsNothing);
    expect(find.text(l.callActive), findsWidgets);
  });

  testWidgets('a peer that never reports a posture is not called muted', (
    tester,
  ) async {
    final messaging = _FakeMessaging();
    late CallService svc;
    await tester.runAsync(() async => svc = await _activeCall(messaging));
    addTearDown(svc.dispose);

    late AppL10n l;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appControllerProvider.overrideWith(_ReadyAppController.new),
          callServiceProvider.overrideWith((ref) => svc),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          theme: ThemeData.dark(),
          home: Stack(
            children: [
              Builder(
                builder: (context) {
                  l = AppL10n.of(context);
                  return const SizedBox.shrink();
                },
              ),
              const CallOverlay(),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // An older build heartbeats without the posture key at all.
    messaging.onCallSignal!(
      _peer(),
      const CallSignal(
        callId: 'peer-mute',
        type: CallSignalType.health,
        sentAtMs: 1000,
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(l.callPeerMicOff),
      findsNothing,
      reason: 'silence about posture is not a claim that the mic is off',
    );
    expect(find.text(l.callActive), findsWidgets);
  });

  test('muting tells the peer instead of just going quiet', () async {
    final messaging = _FakeMessaging();
    final svc = await _activeCall(messaging);
    addTearDown(svc.dispose);
    messaging.sent.clear();

    await svc.setMicEnabled(false);

    final posture = messaging.sent
        .where((s) => s.capture != null)
        .toList(growable: false);
    expect(
      posture,
      isNotEmpty,
      reason: 'the mute must leave this endpoint, or the peer cannot show it',
    );
    expect(posture.last.capture!.audio, isFalse);

    messaging.sent.clear();
    await svc.setMicEnabled(true);
    final back = messaging.sent
        .where((s) => s.capture != null)
        .toList(growable: false);
    expect(back, isNotEmpty);
    expect(back.last.capture!.audio, isTrue);
  });

  test('a late older heartbeat does not un-mute the peer', () async {
    final messaging = _FakeMessaging();
    final svc = await _activeCall(messaging);
    addTearDown(svc.dispose);

    messaging.onCallSignal!(
      _peer(),
      const CallSignal(
        callId: 'peer-mute',
        type: CallSignalType.health,
        capture: CallMedia(),
        sentAtMs: 5000,
      ),
    );
    await pumpEventQueue();
    expect(svc.current!.peerMicOff, isTrue);

    // A beat the peer sent BEFORE muting, overtaken on the overlay.
    messaging.onCallSignal!(
      _peer(),
      const CallSignal(
        callId: 'peer-mute',
        type: CallSignalType.health,
        capture: CallMedia(audio: true),
        sentAtMs: 4000,
      ),
    );
    await pumpEventQueue();
    expect(
      svc.current!.peerMicOff,
      isTrue,
      reason: 'a stale beat must not put a microphone back on',
    );
  });

  test('an all-off posture survives the wire', () {
    // CallMedia encodes false flags by OMITTING them, so a fully muted posture
    // is the empty object. Dropping it as "empty" would delete exactly the
    // posture that matters.
    final wire = const CallSignal(
      callId: 'w',
      type: CallSignalType.health,
      capture: CallMedia(),
    ).encode();
    final back = CallSignal.tryDecode(wire);
    expect(back, isNotNull);
    expect(
      back!.capture,
      isNotNull,
      reason: 'an all-off posture must arrive as a posture, not as silence',
    );
    expect(back.capture!.audio, isFalse);

    // A signal from a build that predates the key stays posture-less.
    final old = CallSignal.tryDecode(
      const CallSignal(callId: 'w', type: CallSignalType.health).encode(),
    );
    expect(old!.capture, isNull);
  });
}
