import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veil_media/veil_media.dart';
import 'package:xveil/features/calls/video_frame_view.dart';

VeilVideoFrame _frame(int value) => VeilVideoFrame(
  rgba: Uint8List.fromList(List.filled(16, value)),
  width: 2,
  height: 2,
);

Widget _host({
  required ValueNotifier<VeilVideoFrame?> frames,
  required Object source,
  String waiting = 'Waiting',
}) => MaterialApp(
  theme: ThemeData.dark(),
  home: ColoredBox(
    color: Colors.black,
    child: CallVideoFrameView(
      frameListenable: frames,
      freshnessToken: source,
      waitingLabel: waiting,
    ),
  ),
);

Future<void> _settleImageDecode(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
    if (find.byKey(const ValueKey('call-video-frame')).evaluate().isNotEmpty) {
      return;
    }
  }
}

void main() {
  testWidgets('source change hides stale frame until a newer frame arrives', (
    tester,
  ) async {
    final staleCamera = _frame(10);
    final frames = ValueNotifier<VeilVideoFrame?>(staleCamera);
    addTearDown(frames.dispose);

    await tester.pumpWidget(_host(frames: frames, source: 'camera'));
    await _settleImageDecode(tester);
    expect(find.byKey(const ValueKey('call-video-frame')), findsOneWidget);

    await tester.pumpWidget(
      _host(
        frames: frames,
        source: 'screen',
        waiting: 'Waiting for shared screen…',
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('call-video-frame')), findsNothing);
    expect(find.text('Waiting for shared screen…'), findsOneWidget);

    // Re-reading the same object is not evidence that the source switched.
    frames.notifyListeners();
    await tester.pump();
    expect(find.byKey(const ValueKey('call-video-waiting')), findsOneWidget);

    frames.value = _frame(20);
    await _settleImageDecode(tester);
    expect(find.byKey(const ValueKey('call-video-frame')), findsOneWidget);
    expect(find.text('Waiting for shared screen…'), findsNothing);

    await tester.pumpWidget(
      _host(
        frames: frames,
        source: 'camera-again',
        waiting: 'Waiting for video…',
      ),
    );
    await tester.pump();
    expect(find.text('Waiting for video…'), findsOneWidget);
    expect(find.byKey(const ValueKey('call-video-frame')), findsNothing);

    frames.value = _frame(40);
    await _settleImageDecode(tester);
    expect(find.byKey(const ValueKey('call-video-frame')), findsOneWidget);

    frames.value = null;
    await tester.pump();
    expect(find.byKey(const ValueKey('call-video-frame')), findsNothing);
    expect(find.text('Waiting for video…'), findsOneWidget);
  });

  testWidgets('a stalled remote stream badges the frozen frame and recovers', (
    tester,
  ) async {
    final frames = ValueNotifier<VeilVideoFrame?>(null);
    addTearDown(frames.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: ColoredBox(
          color: Colors.black,
          child: CallVideoFrameView(
            frameListenable: frames,
            freshnessToken: 'camera',
            waitingLabel: 'Waiting',
            staleLabel: 'Video paused',
            staleAfter: const Duration(seconds: 3),
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('call-video-waiting')), findsOneWidget);

    frames.value = _frame(10);
    await _settleImageDecode(tester);
    expect(find.byKey(const ValueKey('call-video-frame')), findsOneWidget);
    expect(find.byKey(const ValueKey('call-video-stale')), findsNothing);

    // Frames keep arriving → never stale.
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(seconds: 1));
      frames.value = _frame(20 + i);
      await _settleImageDecode(tester);
    }
    expect(find.byKey(const ValueKey('call-video-stale')), findsNothing);

    // The stream stops (backgrounded peer app / stopped camera): the frozen
    // frame must be badged, not left masquerading as live video.
    await tester.pump(const Duration(seconds: 4));
    expect(find.byKey(const ValueKey('call-video-stale')), findsOneWidget);
    expect(find.text('Video paused'), findsOneWidget);

    // A fresh frame clears the badge at once.
    frames.value = _frame(90);
    await _settleImageDecode(tester);
    expect(find.byKey(const ValueKey('call-video-stale')), findsNothing);

    // The waiting placeholder (no image) never shows the stale badge.
    frames.value = null;
    await tester.pump(const Duration(seconds: 5));
    expect(find.byKey(const ValueKey('call-video-waiting')), findsOneWidget);
    expect(find.byKey(const ValueKey('call-video-stale')), findsNothing);

    // Dispose the view so its 1 s stale timer does not outlive the test.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('new surface accepts an already-confirmed static screen frame', (
    tester,
  ) async {
    final frames = ValueNotifier<VeilVideoFrame?>(_frame(10));
    addTearDown(frames.dispose);

    await tester.pumpWidget(
      _host(
        frames: frames,
        source: 'screen',
        waiting: 'Waiting for shared screen…',
      ),
    );
    await _settleImageDecode(tester);
    expect(find.byKey(const ValueKey('call-video-frame')), findsOneWidget);
    expect(find.text('Waiting for shared screen…'), findsNothing);
  });
}
