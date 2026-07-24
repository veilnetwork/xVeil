import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:veil_media/veil_media.dart';

void main() {
  final enabled =
      Platform.isMacOS &&
      Platform.environment['VEIL_MEDIA_SCREEN_SOURCES_LIVE'] == '1';

  test(
    'native macOS source list exposes typed unique displays and windows',
    () {
      final sources = listPlatformScreenInputs();
      expect(sources, isNotEmpty);
      expect(sources.where((source) => source.kind == 'screen'), isNotEmpty);
      expect(sources.where((source) => source.kind == 'window'), isNotEmpty);
      expect(
        sources.map((source) => source.id).toSet(),
        hasLength(sources.length),
      );
      for (final source in sources) {
        expect(source.id, anyOf(startsWith('display:'), startsWith('window:')));
        expect(source.label.trim(), isNotEmpty);
        expect(source.label, isNot(contains('\n')));
        expect(source.kind, anyOf('screen', 'window'));
      }
    },
    skip: enabled
        ? false
        : 'set VEIL_MEDIA_SCREEN_SOURCES_LIVE=1 on a macOS GUI session',
  );

  final captureEnabled =
      enabled && Platform.environment['VEIL_MEDIA_SCREEN_CAPTURE_LIVE'] == '1';
  test(
    'selected macOS window produces real local I420 frames',
    () async {
      final sources = listPlatformScreenInputs();
      final windows = sources.where((source) => source.kind == 'window');
      expect(windows, isNotEmpty);
      final preferred = windows.where(
        (source) => source.label.toLowerCase().startsWith('xveil'),
      );
      final source = preferred.isEmpty ? windows.first : preferred.first;
      final engine = VeilGroupMediaEngine.create(
        localId: Uint8List.fromList(List<int>.generate(32, (i) => i + 1)),
      );
      expect(engine, isNotNull);
      try {
        expect(engine!.startVideo(), isTrue);
        expect(engine.startScreen(sourceId: source.id), isTrue);
        VeilVideoFrame? frame;
        final deadline = DateTime.now().add(const Duration(seconds: 8));
        while (DateTime.now().isBefore(deadline)) {
          frame = engine.getLocalVideoFrame();
          if (frame != null) break;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(frame, isNotNull);
        expect(frame!.width, inInclusiveRange(2, 640));
        expect(frame.height, greaterThan(1));
        expect(frame.rgba, hasLength(frame.width * frame.height * 4));
      } finally {
        engine?.stopScreen();
        engine?.stopVideo();
        engine?.dispose();
      }
    },
    skip: captureEnabled
        ? false
        : 'also set VEIL_MEDIA_SCREEN_CAPTURE_LIVE=1 after macOS consent',
  );
}
