import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/call_audio_buffer_window.dart';

void main() {
  final clocks = Expando<DateTime>();
  bool tick(
    CallAudioBufferWindow window,
    int? delay, {
    int? sequence,
    bool? growing,
    DateTime? at,
  }) {
    final now =
        at ??
        (clocks[window] ?? DateTime(2026, 10, 20)).add(
          const Duration(seconds: 1),
        );
    clocks[window] = now;
    return window.observe(
      delay,
      sequence: sequence,
      measuredGrowing: growing,
      sampledAt: now,
    );
  }

  test('stable buffers and short spikes up to299ms hold video', () {
    for (final values in [
      [120, 120, 120, 120, 120, 120, 120],
      [240, 240, 240, 240, 240, 240, 240],
      [290, 270, 250, 230, 210, 190, 170],
      [60, 60, 60, 299, 60, 60, 60, 60],
      [60, 60, 60, 60, 60, 299, 60, 60],
      [63, 63, 77, 99, 99, 109, 99, 90, 73],
      [36, 56, 36, 36, 56, 56, 36, 56],
      [28, 28, 8, 48, 28, 59],
      [31, 1, 31, 31, 51, 51],
    ]) {
      final window = CallAudioBufferWindow();
      for (final value in values) {
        expect(tick(window, value), isFalse, reason: '$values at$value');
      }
    }
  });

  test('raw trend is reported early but pressure needs three real seconds', () {
    final window = CallAudioBufferWindow();
    for (final value in [20, 40, 60, 80, 100]) {
      expect(tick(window, value), isFalse);
    }
    expect(tick(window, 120), isFalse);
    expect(window.growing, isTrue);
    expect(tick(window, 140), isFalse);
    expect(tick(window, 160), isFalse);
    expect(tick(window, 180), isTrue);
    expect(tick(window, 80), isFalse);
    expect(window.growing, isFalse);
  });

  test('a brief large rise that drains never confirms pressure', () {
    final window = CallAudioBufferWindow();
    for (final value in [20, 20, 20, 80, 100, 120, 100, 80, 20]) {
      expect(tick(window, value), isFalse);
    }
  });

  test('old isolated peak cannot hide continuing growth', () {
    final window = CallAudioBufferWindow();
    var detected = false;
    for (final delay in [
      20,
      270,
      40,
      60,
      80,
      100,
      120,
      140,
      160,
      180,
      200,
      220,
    ]) {
      detected = tick(window, delay) || detected;
    }
    expect(detected, isTrue);
    expect(window.growing, isTrue);
  });

  test('a draining newest sample cannot confirm older growth', () {
    final window = CallAudioBufferWindow();
    for (final value in [20, 20, 28, 101, 128]) {
      tick(window, value);
    }
    expect(tick(window, 110), isFalse);
    expect(window.growing, isFalse);
  });

  test('300ms safety ceiling acts immediately even without a full window', () {
    expect(tick(CallAudioBufferWindow(), 299), isFalse);
    expect(tick(CallAudioBufferWindow(), 300), isTrue);
    expect(tick(CallAudioBufferWindow(), 1000), isTrue);
    final window = CallAudioBufferWindow();
    for (var i = 0; i < 10; i++) {
      expect(tick(window, 300, sequence: i), isTrue);
    }
  });

  test('fast polls and cached reports cannot complete confirmation', () {
    final window = CallAudioBufferWindow();
    final start = DateTime(2026, 10, 20);
    expect(tick(window, 100, growing: true, sequence: 1, at: start), isFalse);
    for (var i = 1; i <= 20; i++) {
      expect(
        tick(
          window,
          100,
          growing: true,
          sequence: i + 1,
          at: start.add(Duration(milliseconds: i * 100)),
        ),
        isFalse,
      );
    }
    // A retained report cannot turn elapsed time into fresh evidence.
    expect(
      tick(
        window,
        100,
        growing: true,
        sequence: 21,
        at: start.add(const Duration(seconds: 3)),
      ),
      isFalse,
    );
    expect(
      tick(
        window,
        100,
        growing: true,
        sequence: 22,
        at: start.add(const Duration(seconds: 3)),
      ),
      isTrue,
    );
    expect(tick(window, 80, growing: false, sequence: 21), isTrue);
    expect(tick(window, 80, growing: false, sequence: 22), isTrue);
    expect(tick(window, 80, growing: false, sequence: 23), isFalse);
  });

  test('same native timestamp cannot add growth evidence', () {
    final window = CallAudioBufferWindow();
    final at = DateTime(2026, 10, 20);
    for (var i = 0; i < 100; i++) {
      expect(tick(window, 100, growing: true, sequence: i, at: at), isFalse);
    }
    expect(
      tick(
        window,
        100,
        growing: true,
        sequence: 101,
        at: at.add(const Duration(seconds: 3)),
      ),
      isTrue,
    );
  });

  test('backwards clocks and observation gaps restart confirmation', () {
    for (final jump in [
      const Duration(seconds: -1),
      const Duration(seconds: 8),
    ]) {
      final window = CallAudioBufferWindow();
      final at = DateTime(2026, 10, 20);
      tick(window, 100, growing: true, sequence: 1, at: at);
      final resetAt = at.add(jump);
      expect(
        tick(window, 100, growing: true, sequence: 2, at: resetAt),
        isFalse,
      );
      expect(
        tick(
          window,
          100,
          growing: true,
          sequence: 3,
          at: resetAt.add(const Duration(seconds: 2)),
        ),
        isFalse,
      );
      expect(
        tick(
          window,
          100,
          growing: true,
          sequence: 4,
          at: resetAt.add(const Duration(seconds: 3)),
        ),
        isTrue,
      );
    }
  });

  test('invalid measurements and mode changes restart confirmation', () {
    for (final invalid in [null, -1, 60001]) {
      final window = CallAudioBufferWindow();
      for (var i = 0; i < 4; i++) {
        tick(window, 100, growing: true, sequence: i);
      }
      expect(tick(window, invalid), isFalse);
      expect(tick(window, 100, growing: true), isFalse);
      expect(tick(window, 130), isFalse);
      expect(window.growing, isNull);
    }
  });

  test('untimed legacy caller requires four fresh growth observations', () {
    final window = CallAudioBufferWindow();
    for (var i = 0; i < 3; i++) {
      expect(window.observe(100, sequence: i, measuredGrowing: true), isFalse);
    }
    for (var i = 0; i < 10; i++) {
      expect(window.observe(100, sequence: 2, measuredGrowing: true), isFalse);
    }
    expect(window.observe(100, sequence: 3, measuredGrowing: true), isTrue);
  });
}
