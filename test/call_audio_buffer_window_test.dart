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
}
