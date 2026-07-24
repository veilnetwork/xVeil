// VideoPlayerScreen platform fork: the SAME screen drives video_player on the
// mainstream platforms and the native brick pair on Linux. The native branch
// is forced via debugUseNative and driven with the vnote-style fakes; controls
// (play/pause + scrubber) are asserted, plus the honest unsupported-format
// message for what the codec-stripped native layer cannot decode.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veil_media/veil_media.dart' show VeilVideoFrame;
import 'package:xveil/features/chat/video_player_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/vnote_play_controller.dart';
import 'package:xveil/state/voice_play_controller.dart';

import 'support/fake_hv_container.dart';
import 'support/webm_test_builder.dart';

class _FakeFrames implements VnoteFramePlayer {
  bool disposed = false;
  @override
  int get durationMs => 240;
  @override
  Uint8List? audio() => null;
  @override
  VeilVideoFrame? frameAt(int ms) =>
      VeilVideoFrame(rgba: Uint8List(2 * 2 * 4), width: 2, height: 2);
  @override
  void dispose() => disposed = true;
}

Future<Widget> _host(Uint8List blob) async {
  final storage = FakeHvContainer().storage();
  await storage.open(password: 'pw', createIfMissing: true);
  await storage.storeFile('vid', blob, name: 'clip.webm');
  return ProviderScope(
    overrides: [
      singleSpaceStorageProvider.overrideWithValue(storage),
      vnoteFramePlayerFactoryProvider.overrideWithValue((_) => _FakeFrames()),
      voicePlayerFactoryProvider.overrideWithValue((_) async => null),
    ],
    child: const MaterialApp(
      localizationsDelegates: AppL10n.localizationsDelegates,
      supportedLocales: AppL10n.supportedLocales,
      home: VideoPlayerScreen(fileKey: 'vid', name: 'clip.webm'),
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  // The native player runs a periodic poll — pumpAndSettle would never settle.
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  setUp(() => VideoPlayerScreen.debugUseNative = true);
  tearDown(() => VideoPlayerScreen.debugUseNative = null);

  testWidgets('native branch: surface, scrubber and transport controls', (
    tester,
  ) async {
    final host = await _host(buildStandardWebm(frameCount: 6, keyEvery: 3));
    await tester.pumpWidget(host);
    await _settle(tester);

    expect(find.byKey(const ValueKey('native-video-surface')), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);
    // Autoplaying → the pause affordance is up.
    expect(find.byIcon(Icons.pause), findsOneWidget);
    expect(find.textContaining('/ 00:00'), findsOneWidget);

    // Tap the surface: pause.
    await tester.tap(find.byKey(const ValueKey('native-video-surface')));
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);

    // The transport button resumes.
    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.byIcon(Icons.pause), findsOneWidget);

    await tester.pumpWidget(const SizedBox()); // unmount → dispose the player
  });

  testWidgets('a silent clip runs to its end and offers replay', (
    tester,
  ) async {
    final host = await _host(buildStandardWebm(frameCount: 6, keyEvery: 3));
    await tester.pumpWidget(host);
    await _settle(tester);
    // The silent clock is a REAL Stopwatch — let wall time cross the 240 ms
    // end, then pump so the poll tick observes it.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 450)),
    );
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.byIcon(Icons.replay), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('unsupported bytes show the honest Linux codec message', (
    tester,
  ) async {
    final host = await _host(Uint8List.fromList(List.filled(80, 3)));
    await tester.pumpWidget(host);
    await _settle(tester);
    expect(
      find.text(
        "This format can't be played here. On Linux only WebM (VP8) videos play.",
      ),
      findsOneWidget,
    );
    expect(find.byType(Slider), findsNothing);
  });

  testWidgets('the plugin branch stays the default off-Linux', (tester) async {
    VideoPlayerScreen.debugUseNative = false;
    final host = await _host(buildStandardWebm(frameCount: 6, keyEvery: 3));
    await tester.pumpWidget(host);
    // The loopback server is real IO — let it run outside the fake clock.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    // No video_player implementation under flutter_test → the generic error
    // state, never the native surface (proves the fork boundary).
    expect(find.text('Could not play this video'), findsOneWidget);
    expect(find.byKey(const ValueKey('native-video-surface')), findsNothing);
  });

  test('engine pick routes WebM to the native layer off-Android', () {
    bool pick(String name, {bool linux = false, bool android = false}) =>
        VideoPlayerScreen.prefersNativeEngine(
          name: name,
          isLinux: linux,
          isAndroid: android,
        );
    // Linux is always native (no plugin exists there at all).
    expect(pick('movie.mp4', linux: true), isTrue);
    // Apple/Windows: AVFoundation/WMF cannot decode VP8 — WebM/MKV go native,
    // OS-native containers stay on the plugin.
    expect(pick('clip.webm'), isTrue);
    expect(pick('CLIP.MKV'), isTrue);
    expect(pick('movie.mp4'), isFalse);
    // Android ExoPlayer decodes WebM natively — plugin everywhere.
    expect(pick('clip.webm', android: true), isFalse);
    // The test override wins over any platform reasoning.
    expect(
      VideoPlayerScreen.prefersNativeEngine(
        name: 'clip.webm',
        isLinux: false,
        isAndroid: false,
        override: false,
      ),
      isFalse,
    );
  });
}
