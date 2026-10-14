import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/call_audio_buffer_window.dart';

void main() {
  test(
    'stable, falling and isolated spikes below the ceiling do not trigger',
    () {
      for (final values in [
        [150, 148, 152, 149, 153, 150, 151],
        [190, 170, 150, 130, 110, 90, 80],
        [60, 60, 60, 190, 60, 60, 60, 60],
        [60, 60, 60, 60, 60, 190, 60, 60],
      ]) {
        final window = CallAudioBufferWindow();
        for (final value in values) {
          expect(window.observe(value), isFalse);
        }
      }
    },
  );

  test('sustained growth triggers before the ceiling, then drains', () {
    final window = CallAudioBufferWindow();
    for (final value in [60, 70, 80, 90, 100]) {
      expect(window.observe(value), isFalse);
    }
    expect(window.observe(110), isTrue);
    for (var i = 0; i < CallAudioBufferWindow.samples; i++) {
      window.observe(80);
    }
    expect(window.observe(80), isFalse);
  });

  test('ceiling triggers without waiting to fill the growth window', () {
    expect(CallAudioBufferWindow().observe(200), isTrue);
    expect(CallAudioBufferWindow().observe(1000), isTrue);
  });

  test('a drained recent rise below the ceiling is not ongoing growth', () {
    final window = CallAudioBufferWindow();
    for (final value in [52, 52, 52, 90, 93]) {
      window.observe(value);
    }
    expect(window.observe(73), isFalse);
    expect(window.observe(73), isFalse);
  });

  test(
    'fresh stable reports clear a step while cached ones retain its verdict',
    () {
      final window = CallAudioBufferWindow();
      for (var i = 0; i < 6; i++) {
        expect(window.observe(60, sequence: i), isFalse);
      }
      expect(window.observe(90, sequence: 6), isFalse);
      expect(window.observe(90, sequence: 7), isTrue);
      for (var i = 0; i < 10; i++) {
        expect(window.observe(90, sequence: 7), isTrue);
      }
      expect(window.observe(90, sequence: 8), isFalse);
    },
  );

  test('recent trend still detects slow and staircase growth', () {
    for (final values in [
      [60, 68, 76, 84, 92, 100],
      [60, 80, 80, 100, 100, 120],
    ]) {
      final window = CallAudioBufferWindow();
      for (final value in values.take(5)) {
        window.observe(value);
      }
      expect(window.observe(values.last), isTrue);
    }
  });

  test('a stable capped buffer remains pressure', () {
    final window = CallAudioBufferWindow();
    for (var i = 0; i < 10; i++) {
      expect(window.observe(200, sequence: i), isTrue);
    }
  });

  test(
    'cached or replayed peer reports cannot manufacture growth or recovery',
    () {
      final window = CallAudioBufferWindow();
      for (var i = 0; i < 5; i++) {
        expect(window.observe(60 + i * 10, sequence: i), isFalse);
      }
      for (var i = 0; i < 30; i++) {
        expect(window.observe(110, sequence: 4), isFalse);
      }
      expect(window.observe(110, sequence: 5), isTrue);
      expect(window.observe(60, sequence: 4), isTrue);
      expect(window.observe(60, sequence: 5), isTrue);
      expect(window.observe(60, sequence: 6), isFalse);
    },
  );

  test('unknown and invalid measurements break the trend window', () {
    for (final invalid in [null, -1, 60001]) {
      final window = CallAudioBufferWindow();
      for (final value in [60, 70, 80, 90, 100]) {
        window.observe(value);
      }
      expect(window.observe(invalid), isFalse);
      expect(window.observe(110), isFalse);
      window.reset();
      expect(window.observe(120), isFalse);
    }
  });
  test(
    'native receiver trend overrides coarse history without bypassing replay or ceiling',
    () {
      final w = CallAudioBufferWindow();
      expect(w.observe(100, sequence: 6, measuredGrowing: true), isTrue);
      expect(w.observe(100, sequence: 6, measuredGrowing: false), isTrue);
      expect(w.observe(80, sequence: 5, measuredGrowing: false), isTrue);
      expect(w.observe(110, sequence: 11, measuredGrowing: false), isFalse);
      expect(w.observe(200, sequence: 12, measuredGrowing: false), isTrue);
      expect(w.observe(110, sequence: 13, measuredGrowing: false), isFalse);
      // Losing support must warm a separate legacy window, not reuse hints.
      expect(w.observe(130, sequence: 14), isFalse);
      expect(w.growing, isNull);
    },
  );
}
