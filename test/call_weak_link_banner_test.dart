import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/call.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/features/calls/call_overlay.dart' show WeakLinkBanner;
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/call_service.dart';
import 'package:xveil/state/call_video_prompt.dart';
import 'package:xveil/state/messaging_core.dart';

class _FakeMessaging implements MessagingService {
  @override
  bool backgroundStashPaused = false;
  final List<(NodeId, CallSignal)> sentTo = [];

  @override
  bool get isAnonymousIdentity => false;

  @override
  void Function(NodeId, CallSignal)? onCallSignal;

  @override
  bool Function(NodeId, CallSignal)? acceptsCallDeviceSignal;

  @override
  Future<void> sendCallSignal(NodeId peer, CallSignal signal) async {
    sentTo.add((peer, signal));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final peer = NodeId.fromHex('a' * 64);

  Call videoCall({bool cameraOn = true}) => Call(
    callId: 'weak-link',
    peer: peer,
    direction: CallDirection.outgoing,
    media: const CallMedia(audio: true, video: true),
    status: CallStatus.active,
    localPosture: CallPosture.direct,
    startedAt: DateTime.fromMillisecondsSinceEpoch(1),
    cameraOn: cameraOn,
  );

  Future<void> pump(WidgetTester tester, Call call, CallService svc) =>
      tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: Scaffold(
            body: WeakLinkBanner(call: call, svc: svc),
          ),
        ),
      );

  late _FakeMessaging messaging;
  late CallService svc;

  setUp(() {
    callVideoPrompt.value = null;
    callVideoSendPausedForAudio.value = false;
    messaging = _FakeMessaging();
    svc = CallService(messaging)..start();
  });
  tearDown(() {
    callVideoPrompt.value = null;
    callVideoSendPausedForAudio.value = false;
    svc.dispose();
  });

  testWidgets('shows nothing until something raises the offer', (tester) async {
    await pump(tester, videoCall(), svc);
    expect(find.byType(TextButton), findsNothing);
  });

  testWidgets('shows confirmed pause and clears it live on resume', (
    tester,
  ) async {
    await pump(tester, videoCall(), svc);
    final l = AppL10n.of(tester.element(find.byType(WeakLinkBanner)));
    expect(find.text(l.callVideoPausedForAudioTitle), findsNothing);
    callVideoSendPausedForAudio.value = true;
    await tester.pump();
    expect(find.text(l.callVideoPausedForAudioTitle), findsOneWidget);
    expect(find.text(l.callVideoPausedForAudioBody), findsOneWidget);
    expect(find.byType(TextButton), findsNothing);
    callVideoSendPausedForAudio.value = false;
    await tester.pump();
    expect(find.text(l.callVideoPausedForAudioTitle), findsNothing);
  });

  testWidgets('dismissing a suggestion cannot hide an ongoing video pause', (
    tester,
  ) async {
    callVideoSendPausedForAudio.value = true;
    callVideoPrompt.value = CallVideoPromptCause.linkFailing;
    await pump(tester, videoCall(), svc);
    final l = AppL10n.of(tester.element(find.byType(WeakLinkBanner)));
    expect(find.text(l.callWeakLinkBodyLocal), findsNothing);
    await tester.tap(find.text(l.callWeakLinkDismiss));
    await tester.pump();
    expect(find.text(l.callVideoPausedForAudioBody), findsOneWidget);
    expect(find.byType(TextButton), findsNothing);
    expect(callVideoSendPausedForAudio.value, isTrue);
    expect(messaging.sentTo, isEmpty);
  });

  testWidgets('pause status fits a narrow Russian call screen', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    callVideoSendPausedForAudio.value = true;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ru'),
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: Scaffold(
          body: WeakLinkBanner(call: videoCall(), svc: svc),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    final l = AppL10n.of(tester.element(find.byType(WeakLinkBanner)));
    expect(find.text(l.callVideoPausedForAudioTitle), findsOneWidget);
  });

  testWidgets('no video pause status when capture is off', (tester) async {
    callVideoSendPausedForAudio.value = true;
    await pump(tester, videoCall(cameraOn: false), svc);
    final l = AppL10n.of(tester.element(find.byType(WeakLinkBanner)));
    expect(find.text(l.callVideoPausedForAudioTitle), findsNothing);
  });

  testWidgets('a local measurement offers to ask the peer as well', (
    tester,
  ) async {
    callVideoPrompt.value = CallVideoPromptCause.linkFailing;
    await pump(tester, videoCall(), svc);
    final l = AppL10n.of(tester.element(find.byType(WeakLinkBanner)));
    expect(find.text(l.callWeakLinkBodyLocal), findsOneWidget);
    expect(find.text(l.callWeakLinkAskPeer), findsOneWidget);
  });

  testWidgets('a peer who already asked is not offered a request back', (
    tester,
  ) async {
    callVideoPrompt.value = CallVideoPromptCause.peerAsked;
    await pump(tester, videoCall(), svc);
    final l = AppL10n.of(tester.element(find.byType(WeakLinkBanner)));
    expect(find.text(l.callWeakLinkBodyPeer), findsOneWidget);
    // Offering it here is how two sides ping-pong the same request at each
    // other while neither one's camera ever goes off.
    expect(find.text(l.callWeakLinkAskPeer), findsNothing);
    expect(find.text(l.callWeakLinkTurnOffVideo), findsOneWidget);
  });

  testWidgets('offers nothing when the camera is already off', (tester) async {
    callVideoPrompt.value = CallVideoPromptCause.linkFailing;
    await pump(tester, videoCall(cameraOn: false), svc);
    expect(find.byType(TextButton), findsNothing);
  });

  testWidgets('keeping video only dismisses, it changes no capture', (
    tester,
  ) async {
    callVideoPrompt.value = CallVideoPromptCause.linkFailing;
    await pump(tester, videoCall(), svc);
    final l = AppL10n.of(tester.element(find.byType(WeakLinkBanner)));
    await tester.tap(find.text(l.callWeakLinkDismiss));
    await tester.pump();
    expect(callVideoPrompt.value, isNull);
    expect(messaging.sentTo, isEmpty);
  });
}
