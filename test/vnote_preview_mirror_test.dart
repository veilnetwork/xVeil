// The vnote RECORDING self-preview is mirrored like a mirror (Telegram
// behavior: the capture source is always the front-facing lens), while the
// default — playback bubbles — paints frames exactly as recorded. The flip is
// display-only, so these tests pin BOTH sides: mirror:true wraps the frame in
// a horizontal Transform.flip, and the default renders with no flip at all.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veil_media/veil_media.dart';
import 'package:xveil/features/chat/vnote_preview.dart';

VeilVideoFrame _frame() => VeilVideoFrame(
  rgba: Uint8List.fromList(List.filled(16, 128)),
  width: 2,
  height: 2,
);

Widget _host({
  required ValueNotifier<VeilVideoFrame?> frames,
  bool mirror = false,
}) => MaterialApp(
  home: VnotePreview(frameListenable: frames, mirror: mirror),
);

/// decodeImageFromPixels completes off the test's fake-async clock; poll with
/// real waits (same pattern as video_frame_view_test).
Future<void> _settleFrameDecode(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
    if (find.byType(RawImage).evaluate().isNotEmpty) return;
  }
}

void main() {
  testWidgets('recording self-preview mirrors the frame horizontally', (
    tester,
  ) async {
    final frames = ValueNotifier<VeilVideoFrame?>(_frame());
    addTearDown(frames.dispose);

    await tester.pumpWidget(_host(frames: frames, mirror: true));
    await _settleFrameDecode(tester);

    expect(find.byType(RawImage), findsOneWidget);
    final flip = tester.widget<Transform>(
      find.byKey(const ValueKey('vnote-preview-mirror')),
    );
    // A horizontal flip: x is negated, y untouched.
    expect(flip.transform.storage[0], -1.0);
    expect(flip.transform.storage[5], 1.0);
    // The flip wraps the painted frame itself.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('vnote-preview-mirror')),
        matching: find.byType(RawImage),
      ),
      findsOneWidget,
    );
  });

  testWidgets('playback default paints frames unmirrored', (tester) async {
    final frames = ValueNotifier<VeilVideoFrame?>(_frame());
    addTearDown(frames.dispose);

    await tester.pumpWidget(_host(frames: frames));
    await _settleFrameDecode(tester);

    expect(find.byType(RawImage), findsOneWidget);
    expect(find.byKey(const ValueKey('vnote-preview-mirror')), findsNothing);
  });

  testWidgets('mirror placeholder (no frame yet) shows without a flip', (
    tester,
  ) async {
    final frames = ValueNotifier<VeilVideoFrame?>(null);
    addTearDown(frames.dispose);

    await tester.pumpWidget(_host(frames: frames, mirror: true));
    await tester.pump();

    expect(find.byIcon(Icons.videocam), findsOneWidget);
    expect(find.byKey(const ValueKey('vnote-preview-mirror')), findsNothing);
  });
}
