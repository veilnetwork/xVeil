import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veil_media/veil_media.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/domain/call.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/features/calls/call_lifecycle_bridge.dart'
    show callPipMode;
import 'package:xveil/features/calls/call_overlay.dart';
import 'package:xveil/features/calls/call_surface.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/android_native_call_video.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/call_service.dart';
import 'package:xveil/state/messaging.dart';
import 'package:xveil/state/providers.dart' show storageProvider;
import 'package:xveil/state/veil_call_media.dart'
    show localVideoFrame, remoteVideoFrame;

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

  @override
  Future<bool> setScreenShareEnabled(bool enabled) async => true;
}

class _SwitchCameraMedia extends _UpMedia {
  final pendingDevices = Completer<List<CallMediaDevice>>();
  final selected = <String>[];

  @override
  Future<List<CallMediaDevice>> listCameras() => pendingDevices.future;

  @override
  Future<bool> selectCamera(String id) async {
    selected.add(id);
    return true;
  }

  void finishListing() => pendingDevices.complete(const [
    CallMediaDevice(
      id: 'front',
      label: 'Front',
      kind: CallMediaDeviceKind.camera,
      facing: 'front',
      selected: true,
    ),
    CallMediaDevice(
      id: 'back',
      label: 'Back',
      kind: CallMediaDeviceKind.camera,
      facing: 'back',
    ),
  ]);
}

class _DevicePickerMedia extends _UpMedia {
  final microphoneLists = <Completer<List<CallMediaDevice>>>[];
  final screens = Completer<List<CallMediaDevice>>();
  final screenSelected = Completer<bool>();
  final selectedScreens = <String>[];
  final screenCapture = <bool>[];

  @override
  Future<List<CallMediaDevice>> listMicrophones() {
    final request = Completer<List<CallMediaDevice>>();
    microphoneLists.add(request);
    return request.future;
  }

  @override
  Future<List<CallMediaDevice>> listScreens() => screens.future;

  @override
  Future<bool> selectScreen(String id) async {
    selectedScreens.add(id);
    return screenSelected.future;
  }

  @override
  Future<bool> setScreenShareEnabled(bool enabled) async {
    screenCapture.add(enabled);
    return true;
  }
}

class _DevicePickerStorage implements Storage {
  @override
  Future<String?> getSetting(String key) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeMessaging implements MessagingService {
  @override
  bool backgroundStashPaused = false;
  final List<CallSignal> sent = [];

  @override
  bool get isAnonymousIdentity => false;

  @override
  Future<NodeId> localDeviceId() async => NodeId(Uint8List(32));

  @override
  void Function(NodeId peer, CallSignal signal)? onCallSignal;

  @override
  bool Function(NodeId, CallSignal)? acceptsCallDeviceSignal;

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
Future<CallService> _activeCall(
  _FakeMessaging messaging, {
  CallMedia media = const CallMedia(audio: true),
  CallMediaController? controller,
}) async {
  final svc = CallService(messaging, media: controller ?? _UpMedia())..start();
  await _acceptOfferedCall(svc, messaging, 'peer-mute', media);
  return svc;
}

Future<void> _acceptOfferedCall(
  CallService svc,
  _FakeMessaging messaging,
  String callId,
  CallMedia media,
) async {
  messaging.onCallSignal!(
    _peer(),
    CallSignal(
      callId: callId,
      type: CallSignalType.offer,
      media: media,
      posture: CallPosture.direct,
    ),
  );
  await pumpEventQueue();
  await svc.accept();
  await pumpEventQueue();
}

void main() {
  for (final (path, replaceCall) in [
    ('settings', true),
    ('screen list', true),
    ('screen selection', true),
    ('screen selection', false),
  ]) {
    testWidgets(
      'call device picker handles $path result with replaceCall=$replaceCall',
      (tester) async {
        final screenAction = path != 'settings';
        final video = CallMedia(audio: true, video: screenAction);
        final messaging = _FakeMessaging();
        final media = _DevicePickerMedia();
        final svc = (await tester.runAsync(
          () => _activeCall(messaging, media: video, controller: media),
        ))!;
        addTearDown(svc.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appControllerProvider.overrideWith(_ReadyAppController.new),
              callServiceProvider.overrideWith((ref) => svc),
              storageProvider.overrideWithValue(_DevicePickerStorage()),
            ],
            child: MaterialApp(
              localizationsDelegates: AppL10n.localizationsDelegates,
              supportedLocales: AppL10n.supportedLocales,
              home: const Scaffold(body: Stack(children: [CallOverlay()])),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final settings = find.byKey(const ValueKey('call-surface-settings'));
        final panel = find.byKey(const ValueKey('call-settings-panel'));
        const primary = CallMediaDevice(
          id: 'primary',
          label: 'Primary screen',
          kind: CallMediaDeviceKind.screen,
        );
        if (screenAction) {
          await tester.tap(find.byKey(const ValueKey('call-screen')));
          await tester.pump();
          if (path == 'screen selection') {
            media.screens.complete(const [
              primary,
              CallMediaDevice(
                id: 'secondary',
                label: 'Secondary screen',
                kind: CallMediaDeviceKind.screen,
              ),
            ]);
            await tester.pumpAndSettle();
            await tester.tap(find.text('Video'));
            await tester.pumpAndSettle();
            await tester.tap(find.text(primary.label));
            expect(media.selectedScreens, [primary.id]);
          } else {
            // Leave selection ready to finish if the stale list is applied.
            media.screenSelected.complete(true);
          }
        } else {
          await tester.tap(settings);
          await tester.pump();
          expect(media.microphoneLists, hasLength(1));
        }

        if (replaceCall) {
          await tester.runAsync(() async {
            await svc.hangup();
            await _acceptOfferedCall(svc, messaging, 'replacement', video);
          });
          expect(svc.current?.callId, 'replacement');
        }
        await tester.pumpAndSettle();
        expect(panel, findsNothing);
        if (path == 'settings') {
          await tester.tap(settings);
          await tester.pump();
          expect(media.microphoneLists, hasLength(2));
          media.microphoneLists.first.complete(const [
            CallMediaDevice(
              id: 'old-mic',
              label: 'Old microphone',
              kind: CallMediaDeviceKind.microphone,
            ),
          ]);
          await tester.pump();
          expect(panel, findsNothing);
          expect(find.byType(CircularProgressIndicator), findsOneWidget);
          media.microphoneLists.last.complete(const [
            CallMediaDevice(
              id: 'new-mic',
              label: 'New microphone',
              kind: CallMediaDeviceKind.microphone,
            ),
          ]);
          await tester.pumpAndSettle();
          expect(find.text('New microphone'), findsOneWidget);
          expect(find.byType(CircularProgressIndicator), findsNothing);
        } else {
          if (path == 'screen list') {
            media.screens.complete(const [primary]);
          } else {
            media.screenSelected.complete(true);
          }
          await tester.pumpAndSettle();
          expect(svc.current?.screenOn, !replaceCall);
          expect(media.screenCapture, [if (!replaceCall) true]);
          expect(media.selectedScreens, [
            if (path == 'screen selection') primary.id,
          ]);
        }
        expect(tester.takeException(), isNull);
      },
      skip: path != 'settings' && !Platform.isMacOS,
    );
  }

  for (final transition in [
    'off and on',
    'screen share',
    'next call',
    'picker',
    'none',
  ]) {
    test('camera switch during enumeration and $transition', () async {
      const video = CallMedia(audio: true, video: true);
      final messaging = _FakeMessaging();
      final media = _SwitchCameraMedia();
      final svc = await _activeCall(messaging, media: video, controller: media);
      addTearDown(svc.dispose);
      expect(svc.current?.cameraOn, isTrue);

      final switching = svc.switchCameraFacing();
      switch (transition) {
        case 'off and on':
          await svc.setCameraEnabled(false);
          await svc.setCameraEnabled(true);
          expect(svc.current?.cameraOn, isTrue);
        case 'screen share':
          await svc.setScreenShareEnabled(true);
          expect(svc.current?.screenOn, isTrue);
        case 'next call':
          await svc.hangup();
          await _acceptOfferedCall(svc, messaging, 'replacement', video);
          expect(svc.current?.callId, 'replacement');
          expect(svc.current?.status, CallStatus.active);
        case 'picker':
          expect(await svc.selectCamera('front'), isTrue);
      }
      media.finishListing();

      expect(await switching, transition == 'none');
      expect(media.selected, [
        if (transition == 'none') 'back',
        if (transition == 'picker') 'front',
      ]);
    });
  }

  for (final nativeTexture in [false, true]) {
    testWidgets(
      'remote video waits after an explicit camera stop ($nativeTexture)',
      (tester) async {
        final messaging = _FakeMessaging();
        late CallService svc;
        await tester.runAsync(() async {
          svc = await _activeCall(
            messaging,
            media: const CallMedia(audio: true, video: true),
          );
        });
        addTearDown(svc.dispose);
        addTearDown(() {
          androidNativeCallVideoTexture.value = null;
          remoteVideoFrame.value = null;
        });
        final image = nativeTexture
            ? find.byType(Texture)
            : find.byType(RawImage);

        void capture(CallMedia value, int at) {
          messaging.onCallSignal!(
            _peer(),
            CallSignal(
              callId: 'peer-mute',
              type: CallSignalType.health,
              capture: value,
              sentAtMs: at,
            ),
          );
        }

        void frame(int count, {int textureId = 21}) {
          if (nativeTexture) {
            androidNativeCallVideoTexture.value = AndroidNativeCallVideoTexture(
              textureId: textureId,
              width: 2,
              height: 2,
              frames: count,
              lastFrameAt: DateTime.now(),
            );
          } else {
            remoteVideoFrame.value = VeilVideoFrame(
              rgba: Uint8List.fromList(List.filled(16, count)),
              width: 2,
              height: 2,
            );
          }
        }

        Future<void> pumpForVideo() async {
          await tester.pump();
          for (var i = 0; i < 20 && image.evaluate().isEmpty; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 5)),
            );
            await tester.pump();
          }
        }

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appControllerProvider.overrideWith(_ReadyAppController.new),
              callServiceProvider.overrideWithValue(svc),
            ],
            child: const MaterialApp(
              localizationsDelegates: AppL10n.localizationsDelegates,
              supportedLocales: AppL10n.supportedLocales,
              home: Stack(children: [CallOverlay()]),
            ),
          ),
        );
        await tester.pumpAndSettle();
        frame(9);
        await pumpForVideo();
        expect(image, findsOneWidget);
        if (nativeTexture) {
          // The Dart fallback can also retain a frame from the prior source.
          remoteVideoFrame.value = VeilVideoFrame(
            rgba: Uint8List(16),
            width: 2,
            height: 2,
          );
        }

        capture(const CallMedia(audio: true), 1000);
        await tester.pumpAndSettle();
        expect(image, findsNothing);
        expect(find.text('Camera off'), findsOneWidget);

        capture(const CallMedia(audio: true, video: true), 2000);
        await pumpForVideo();
        expect(image, findsNothing);
        expect(find.byType(RawImage), findsNothing);

        final previousPipMode = callPipMode.value;
        addTearDown(() => callPipMode.value = previousPipMode);
        callPipMode.value = true;
        await pumpForVideo();
        expect(image, findsNothing, reason: 'PiP restored a retired frame');
        callPipMode.value = false;
        await pumpForVideo();
        expect(
          image,
          findsNothing,
          reason: 'full screen restored a retired frame',
        );

        await tester.tap(find.byKey(const ValueKey('call-surface-minimize')));
        await pumpForVideo();
        expect(
          image,
          findsNothing,
          reason: 'the call tile restored a retired frame',
        );
        await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
        await tester.pumpAndSettle();
        expect(find.byIcon(Icons.open_in_full), findsNothing);

        capture(const CallMedia(audio: true), 2200);
        await tester.pump();
        frame(10);
        capture(const CallMedia(audio: true, video: true), 2300);
        await tester.pump();
        await tester.tap(find.byIcon(Icons.videocam));
        await pumpForVideo();
        expect(find.byIcon(Icons.open_in_full), findsOneWidget);
        expect(
          image,
          findsNothing,
          reason: 'video changed sources while the tile was hidden',
        );
        await tester.tap(find.byIcon(Icons.open_in_full));
        await pumpForVideo();
        expect(image, findsNothing);

        frame(1, textureId: 22);
        await pumpForVideo();
        expect(image, findsOneWidget);

        // Both signals can arrive before Flutter draws another frame.
        capture(const CallMedia(audio: true), 2500);
        capture(const CallMedia(audio: true, video: true), 2600);
        await tester.idle();
        await tester.pumpAndSettle();
        expect(
          image,
          findsNothing,
          reason: 'a quick camera restart kept the old frame',
        );
        frame(2, textureId: 22);
        await pumpForVideo();
        expect(image, findsOneWidget);

        capture(const CallMedia(audio: true, screen: true), 3000);
        await tester.pumpAndSettle();
        expect(image, findsNothing);
        expect(find.text('Waiting for shared screen…'), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 20));
        frame(3, textureId: 22);
        await pumpForVideo();
        expect(image, findsOneWidget);

        // A static screen may not emit another frame after changing surfaces.
        callPipMode.value = true;
        await pumpForVideo();
        expect(image, findsOneWidget);
        callPipMode.value = false;
        await pumpForVideo();
        expect(image, findsOneWidget);

        // The peer switches to camera, then shares a static screen. The first
        // share frame reaches the notifier after the signal but before draw.
        capture(const CallMedia(audio: true, video: true), 4000);
        await tester.pumpAndSettle();
        frame(4, textureId: 22);
        await pumpForVideo();
        expect(image, findsOneWidget);
        capture(const CallMedia(audio: true, screen: true), 5000);
        await tester.idle();
        frame(5, textureId: 22);
        await tester.pumpAndSettle();
        await pumpForVideo();
        expect(
          image,
          findsOneWidget,
          reason: 'the only screen frame was already received',
        );

        // There need not be any cached input at the source change either.
        capture(const CallMedia(audio: true), 6000);
        await tester.pumpAndSettle();
        androidNativeCallVideoTexture.value = null;
        remoteVideoFrame.value = null;
        capture(const CallMedia(audio: true, screen: true), 7000);
        await tester.idle();
        frame(1, textureId: 23);
        await tester.pumpAndSettle();
        await pumpForVideo();
        expect(
          image,
          findsOneWidget,
          reason: 'the first screen frame had no predecessor',
        );
      },
      variant: TargetPlatformVariant({
        nativeTexture ? TargetPlatform.android : TargetPlatform.macOS,
      }),
    );
  }

  test('camera toggles announce capture before the next heartbeat', () async {
    final messaging = _FakeMessaging();
    final svc = await _activeCall(
      messaging,
      media: const CallMedia(audio: true, video: true),
    );
    addTearDown(svc.dispose);
    messaging.sent.clear();
    await svc.setCameraEnabled(false);
    expect(messaging.sent.single.capture?.video, isFalse);
    messaging.sent.clear();
    await svc.setCameraEnabled(true);
    expect(messaging.sent.single.capture?.video, isTrue);
    messaging.sent.clear();
    await svc.setScreenShareEnabled(true);
    final share = messaging.sent.singleWhere(
      (s) => s.type == CallSignalType.renegotiate,
    );
    expect(share.capture?.screen, isTrue);
  });

  testWidgets('self preview follows camera off and screen share in a live call', (
    tester,
  ) async {
    late CallService svc;
    await tester.runAsync(() async {
      svc = await _activeCall(
        _FakeMessaging(),
        media: const CallMedia(audio: true, video: true),
      );
    });
    addTearDown(svc.dispose);
    addTearDown(() => localVideoFrame.value = null);
    expect(svc.current?.status, CallStatus.active);
    expect(svc.current?.cameraOn, isTrue);
    VeilVideoFrame frame(int color) => VeilVideoFrame(
      rgba: Uint8List.fromList(List.filled(16, color)),
      width: 2,
      height: 2,
    );
    final image = find.byType(RawImage);
    final off = find.byIcon(Icons.videocam_off);
    Future<void> showFrame(VeilVideoFrame value) async {
      localVideoFrame.value = value;
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump();
        if (image.evaluate().isNotEmpty) return;
      }
      fail('The local preview did not decode the supplied frame');
    }

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appControllerProvider.overrideWith(_ReadyAppController.new),
          callServiceProvider.overrideWith((ref) => svc),
        ],
        child: MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          theme: ThemeData.dark(),
          home: const Stack(children: [CallOverlay()]),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await showFrame(frame(30));

    Future<void> camera(bool on) async {
      await tester.runAsync(() => svc.setCameraEnabled(on));
      await tester.pumpAndSettle();
      expect(svc.current?.cameraOn, on);
    }

    Future<void> share(bool on) async {
      await tester.runAsync(() => svc.setScreenShareEnabled(on));
      await tester.pumpAndSettle();
      expect(svc.current?.screenOn, on);
    }

    await camera(false);
    final visibleWhileOff = image.evaluate().isNotEmpty;
    await camera(true);
    expect(image, findsNothing, reason: 'old frame returned on camera restart');
    await showFrame(frame(50));
    await camera(false);
    await share(true);
    expect(image, findsNothing, reason: 'camera frame survived screen start');
    await showFrame(frame(80));
    // There is one camera-off icon on the control dock. A second icon would
    // indicate that the thumbnail also treats the actively shared screen as off.
    final offIconsWhileSharing = off.evaluate().length;
    await share(false);
    await camera(true);
    expect(image, findsNothing, reason: 'old screen displayed as camera');
    await showFrame(frame(160));
    expect(visibleWhileOff, isFalse);
    expect(offIconsWhileSharing, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('video call route label moves below the enlarged header', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 830);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    late CallService svc;
    await tester.runAsync(() async {
      svc = await _activeCall(
        _FakeMessaging(),
        media: const CallMedia(audio: true, screen: true),
      );
    });
    addTearDown(svc.dispose);
    expect(svc.current?.status, CallStatus.active);
    expect(svc.current?.transport, CallTransportKind.relay);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appControllerProvider.overrideWith(_ReadyAppController.new),
          callServiceProvider.overrideWith((ref) => svc),
        ],
        child: MaterialApp(
          locale: const Locale('ru'),
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          theme: ThemeData.dark(),
          home: const Stack(children: [CallOverlay()]),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final header = find.byType(CallSurfaceHeader);
    final l = AppL10n.of(tester.element(header));
    final route = find.text(l.callPathRelay);
    expect(route, findsOneWidget);
    expect(
      tester.getRect(route).top,
      greaterThanOrEqualTo(tester.getRect(header).bottom),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('incoming call shows all media labels at large text size', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 830);
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final messaging = _FakeMessaging();
    late CallService svc;
    await tester.runAsync(() async {
      svc = CallService(messaging, media: _UpMedia())..start();
      messaging.onCallSignal!(
        _peer(),
        const CallSignal(
          callId: 'large-text-incoming',
          type: CallSignalType.offer,
          media: CallMedia(audio: true, video: true, screen: true),
          posture: CallPosture.direct,
        ),
      );
    });
    addTearDown(svc.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appControllerProvider.overrideWith(_ReadyAppController.new),
          callServiceProvider.overrideWith((ref) => svc),
        ],
        child: MaterialApp(
          locale: const Locale('ru'),
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          theme: ThemeData.dark(),
          home: const Stack(children: [CallOverlay()]),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(svc.current?.status, CallStatus.ringing);
    final l = AppL10n.of(tester.element(find.byType(CallOverlay)));
    for (final label in [l.callAudio, l.callVideo, l.callScreen]) {
      final chip = find.widgetWithText(Chip, label);
      expect(chip, findsOneWidget);
      final bounds = tester.getRect(chip);
      expect(bounds.left, greaterThanOrEqualTo(0), reason: label);
      expect(bounds.right, lessThanOrEqualTo(390), reason: label);
    }
    expect(tester.takeException(), isNull);

    // Split-screen can reduce the available height while the call is ringing.
    // The actions must stay on screen even if the media labels need scrolling.
    tester.view.physicalSize = const Size(390, 430);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    await tester.pumpAndSettle();
    final screenLabel = find.text(l.callScreen);
    await tester.ensureVisible(screenLabel);
    await tester.pumpAndSettle();
    expect(screenLabel.hitTestable(), findsOneWidget);
    for (final key in ['call-accept', 'call-decline']) {
      final button = find.byKey(ValueKey(key));
      expect(button.hitTestable(), findsOneWidget, reason: key);
      expect(tester.getRect(button).bottom, lessThanOrEqualTo(430));
    }
    expect(tester.takeException(), isNull);
  });

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
