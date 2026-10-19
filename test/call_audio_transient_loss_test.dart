import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/call_audio_transient_loss.dart';

void main() {
  final start = DateTime(2026, 10, 19);

  test('one event holds growth for time, never repeated polls', () {
    final window = CallAudioTransientLoss();
    expect(window.observe(true, sampledAt: start), isFalse);
    for (var ms = 1; ms < 3000; ms += 10) {
      expect(
        window.observe(false, sampledAt: start.add(Duration(milliseconds: ms))),
        isFalse,
      );
      expect(window.holdingGrowth, isTrue);
    }
    expect(
      window.observe(false, sampledAt: start.add(const Duration(seconds: 3))),
      isFalse,
    );
    expect(window.holdingGrowth, isFalse);
  });

  test('only another fresh event inside six seconds confirms loss', () {
    final window = CallAudioTransientLoss();
    expect(window.observe(true, sampledAt: start), isFalse);
    expect(
      window.observe(false, sampledAt: start.add(const Duration(seconds: 5))),
      isFalse,
    );
    expect(
      window.observe(true, sampledAt: start.add(const Duration(seconds: 6))),
      isTrue,
    );
    expect(
      window.observe(false, sampledAt: start.add(const Duration(seconds: 7))),
      isFalse,
    );
    expect(
      window.observe(true, sampledAt: start.add(const Duration(seconds: 13))),
      isFalse,
    );
  });

  test('clock rollback and reset cannot join old events to a new episode', () {
    final window = CallAudioTransientLoss();
    expect(window.observe(true, sampledAt: start), isFalse);
    expect(
      window.observe(
        true,
        sampledAt: start.subtract(const Duration(seconds: 1)),
      ),
      isFalse,
    );
    window.reset();
    expect(window.holdingGrowth, isFalse);
    expect(window.observe(true, sampledAt: start), isFalse);
  });
}
