import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/call_bitrate_adapter.dart';

void main() {
  CallBitrateAdapter direct() =>
      CallBitrateAdapter(baseBitrateKbps: 900, baseFps: 20);

  ({int maxBitrateKbps, int maxFps})? good(CallBitrateAdapter a) =>
      a.onSample(rttMs: 80, txJitterMs: 10, txLossPct: 0, txDrops: 0);

  ({int maxBitrateKbps, int maxFps})? lossy(CallBitrateAdapter a) =>
      a.onSample(rttMs: 80, txJitterMs: 10, txLossPct: 12, txDrops: 0);

  test('stays at full budget on a healthy link', () {
    final a = direct();
    for (var i = 0; i < 60; i++) {
      expect(good(a), isNull);
    }
    expect(a.level, 0);
    expect(a.target, (maxBitrateKbps: 900, maxFps: 20));
  });

  test('one bad sample does not degrade (hysteresis)', () {
    final a = direct();
    expect(lossy(a), isNull);
    expect(good(a), isNull);
    expect(a.level, 0);
  });

  test('sustained loss walks down the ladder one rung per streak', () {
    final a = direct();
    expect(lossy(a), isNull);
    final first = lossy(a);
    expect(first, isNotNull);
    expect(a.level, 1);
    expect(first!.maxBitrateKbps, 675);
    expect(first.maxFps, 20);

    expect(lossy(a), isNull);
    final second = lossy(a);
    expect(a.level, 2);
    expect(second!.maxBitrateKbps, 450);
  });

  test('bottom rung also reduces fps and never goes lower', () {
    final a = direct();
    ({int maxBitrateKbps, int maxFps})? last;
    for (var i = 0; i < 20; i++) {
      last = lossy(a) ?? last;
    }
    expect(a.level, CallBitrateAdapter.ladder.length - 1);
    expect(last!.maxBitrateKbps, 270);
    expect(last.maxFps, 13); // 20 * 2/3 rounded
    // Further bad samples keep the floor.
    for (var i = 0; i < 10; i++) {
      expect(lossy(a), isNull);
    }
    expect(a.level, CallBitrateAdapter.ladder.length - 1);
  });

  test('recovery needs a long good streak and climbs one rung at a time', () {
    final a = direct();
    lossy(a);
    lossy(a);
    expect(a.level, 1);
    // One bad sample resets the recovery clock.
    for (var i = 0; i < CallBitrateAdapter.recoverAfter - 1; i++) {
      expect(good(a), isNull);
    }
    expect(lossy(a), isNull);
    for (var i = 0; i < CallBitrateAdapter.recoverAfter - 1; i++) {
      expect(good(a), isNull);
    }
    final up = good(a);
    expect(up, isNotNull);
    expect(a.level, 0);
    expect(up!.maxBitrateKbps, 900);
  });

  test('high RTT degrades, unknown RTT (0) does not', () {
    final a = direct();
    ({int maxBitrateKbps, int maxFps})? r;
    for (var i = 0; i < 3; i++) {
      r = a.onSample(rttMs: 500, txJitterMs: 5, txLossPct: 0, txDrops: 0) ?? r;
    }
    expect(a.level, 1);
    expect(r, isNotNull);

    final b = direct();
    for (var i = 0; i < 5; i++) {
      expect(
        b.onSample(rttMs: 0, txJitterMs: 5, txLossPct: 0, txDrops: 0),
        isNull,
      );
    }
    expect(b.level, 0);
  });

  test('growing local tx drops degrade; a stable counter does not', () {
    final a = direct();
    expect(
      a.onSample(rttMs: 50, txJitterMs: 5, txLossPct: 0, txDrops: 10),
      isNull, // first sample only records the baseline
    );
    expect(
      a.onSample(rttMs: 50, txJitterMs: 5, txLossPct: 0, txDrops: 11),
      isNull,
    );
    final r = a.onSample(rttMs: 50, txJitterMs: 5, txLossPct: 0, txDrops: 12);
    expect(r, isNotNull);
    expect(a.level, 1);
    // Counter stops growing → link is judged healthy again.
    for (var i = 0; i < CallBitrateAdapter.recoverAfter - 1; i++) {
      expect(
        a.onSample(rttMs: 50, txJitterMs: 5, txLossPct: 0, txDrops: 12),
        isNull,
      );
    }
    final up =
        a.onSample(rttMs: 50, txJitterMs: 5, txLossPct: 0, txDrops: 12);
    expect(up, isNotNull);
    expect(a.level, 0);
  });

  test('marginal samples hold the rung and restart the recovery clock', () {
    final a = direct();
    lossy(a);
    lossy(a);
    expect(a.level, 1);
    for (var i = 0; i < 100; i++) {
      // jitter 60 is neither bad (>=80) nor good (<40).
      expect(
        a.onSample(rttMs: 100, txJitterMs: 60, txLossPct: 0, txDrops: 0),
        isNull,
      );
    }
    expect(a.level, 1);
  });

  test('anonymous profile never exceeds its route budget', () {
    final a = CallBitrateAdapter(baseBitrateKbps: 150, baseFps: 15);
    lossy(a);
    lossy(a);
    expect(a.target.maxBitrateKbps, lessThan(150));
    for (var i = 0; i < 200; i++) {
      good(a);
    }
    expect(a.level, 0);
    expect(a.target, (maxBitrateKbps: 150, maxFps: 15));
  });
}
