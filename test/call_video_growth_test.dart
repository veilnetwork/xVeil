import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/call_bitrate_adapter.dart';

typedef Budget = ({int maxBitrateKbps, double maxFps});

void main() {
  void sample(
    CallBitrateAdapter a, {
    bool held = false,
    bool known = true,
    bool loss = false,
    int rtt = 80,
    DateTime? at,
  }) => a.onSample(
    sampledAt: at,
    rttMs: rtt,
    txJitterMs: 1,
    txLossPct: 0,
    txDrops: 0,
    sourceBudgetPressured: held,
    feedbackAvailable: known,
    audioNetworkLossObserved: loss,
  );

  CallBitrateAdapter beforeUpshift({int rtt = 80, bool lowRate = true}) {
    final a = CallBitrateAdapter(
      baseBitrateKbps: 900,
      baseFps: 15,
      initialLevel: 1,
      supportsLowRateVideo: lowRate,
    );
    a.applyPendingTarget((_) => true);
    for (var i = 0; i < CallBitrateAdapter.recoverAfter; i++) {
      sample(a, rtt: rtt);
    }
    expect(a.level, 0);
    expect(a.target, (maxBitrateKbps: 900, maxFps: 15.0));
    return a;
  }

  test(
    'earned doubled rung grows actual budget one bounded step per sample',
    () {
      final a = beforeUpshift();
      Budget? actual;
      expect(
        a.applyPendingTarget((value) {
          actual = value;
          return true;
        }),
        isTrue,
      );
      expect(actual, (maxBitrateKbps: 495, maxFps: 8.5));
      expect(
        a.applyPendingTarget((_) => throw StateError('same observation')),
        isNull,
      );
      for (var i = 0; i < 40 && actual != a.target; i++) {
        final previous = actual!;
        sample(a);
        a.applyPendingTarget((value) {
          actual = value;
          return true;
        });
        expect(
          actual!.maxBitrateKbps,
          lessThanOrEqualTo(previous.maxBitrateKbps * 1.1 + 1),
        );
        expect(actual!.maxFps, lessThanOrEqualTo(previous.maxFps + 1.000001));
        expect(actual!.maxBitrateKbps, lessThanOrEqualTo(900));
        expect(actual!.maxFps, lessThanOrEqualTo(15));
      }
      expect(
        actual,
        a.target,
        reason: 'healthy capacity can recover the full profile',
      );
    },
  );

  test(
    'refused retune spends no step; held or missing quality cannot grow it',
    () {
      final a = beforeUpshift();
      final proposals = <Budget>[];
      for (var i = 0; i < 2; i++) {
        expect(
          a.applyPendingTarget((v) {
            proposals.add(v);
            return false;
          }),
          isFalse,
        );
      }
      expect(proposals[0], proposals[1]);
      a.applyPendingTarget((v) {
        proposals.add(v);
        return true;
      });
      expect(proposals.last, proposals.first);
      sample(a, held: true);
      expect(
        a.applyPendingTarget((_) => throw StateError('source held')),
        isNull,
      );
      sample(a, known: false);
      expect(
        a.applyPendingTarget((_) => throw StateError('quality unknown')),
        isNull,
      );
      for (var i = 0; i < CallBitrateAdapter.recoverAfter - 1; i++) {
        sample(a);
        expect(
          a.applyPendingTarget((_) => throw StateError('recovery pending')),
          isNull,
        );
      }
      sample(a);
      expect(
        a.applyPendingTarget((v) {
          proposals.add(v);
          return true;
        }),
        isTrue,
      );
      expect(proposals.last.maxFps, greaterThan(proposals.first.maxFps));
    },
  );

  test(
    'partial ramp cannot bank more rungs and a fresh loss cuts immediately',
    () {
      final a = CallBitrateAdapter(
        baseBitrateKbps: 900,
        baseFps: 60,
        initialLevel: 3,
      );
      a.applyPendingTarget((_) => true);
      for (var i = 0; i < CallBitrateAdapter.recoverAfter; i++) {
        sample(a);
      }
      expect(a.level, 2);
      a.applyPendingTarget((_) => true);
      for (var i = 0; i < 100; i++) {
        sample(a);
      }
      expect(a.level, 2, reason: 'request is not measured traffic');
      sample(a, held: true, loss: true);
      expect(a.level, 4);
      Budget? actual;
      a.applyPendingTarget((v) {
        actual = v;
        return true;
      });
      expect(actual, (maxBitrateKbps: 15, maxFps: 1.0));
    },
  );

  test(
    'replacement stream restores acknowledged step instead of nominal ceiling',
    () {
      final a = beforeUpshift();
      a.applyPendingTarget((_) => true);
      final acknowledged = a.targetForStart;
      a.invalidateAppliedState();
      expect(a.targetForStart, acknowledged);
      Budget? restored;
      a.applyPendingTarget((v) {
        restored = v;
        return true;
      });
      expect(restored, acknowledged);
      expect(a.target.maxFps, 15);
      expect(
        a.applyPendingTarget((_) => throw StateError('no fresh quality')),
        isNull,
      );
    },
  );

  test('constant 120ms propagation still permits bounded recovery', () {
    final a = beforeUpshift(rtt: 120);
    Budget? actual;
    a.applyPendingTarget((v) {
      actual = v;
      return true;
    });
    expect(actual, (maxBitrateKbps: 495, maxFps: 8.5));
  });

  test('a refused initial budget cannot bank unmeasured promotions', () {
    final a = CallBitrateAdapter(
      baseBitrateKbps: 900,
      baseFps: 15,
      initialLevel: 1,
    );
    final initial = a.target;
    a.applyPendingTarget((_) => false);
    for (var i = 0; i < 100; i++) {
      sample(a);
      a.applyPendingTarget((v) {
        expect(v, initial);
        return false;
      });
    }
    expect(a.level, 1);
    a.applyPendingTarget((v) {
      expect(v, initial);
      return true;
    });
    for (var i = 0; i < CallBitrateAdapter.recoverAfter; i++) {
      sample(a);
    }
    a.applyPendingTarget((v) {
      expect(v, (maxBitrateKbps: 495, maxFps: 8.5));
      return true;
    });
  });

  test('older engine growth remains integer cadence and within the route', () {
    final a = beforeUpshift(lowRate: false);
    Budget? actual;
    a.applyPendingTarget((v) {
      actual = v;
      return true;
    });
    expect(actual!.maxFps, 9);
    expect(actual!.maxBitrateKbps, 528);
  });

  test('fast polls and clock corrections cannot bank growth credit', () {
    final a = beforeUpshift();
    var calls = 0;
    void apply() => a.applyPendingTarget((_) {
      calls++;
      return true;
    });
    DateTime at(int ms) => DateTime.fromMillisecondsSinceEpoch(ms);
    sample(a, at: at(1000));
    apply();
    expect(calls, 1);
    for (var t = 1100; t < 1900; t += 100) {
      sample(a, at: at(t));
      apply();
    }
    expect(calls, 1);
    sample(a, at: at(2000));
    apply();
    expect(calls, 2);
    sample(a, at: at(0));
    apply();
    expect(calls, 2);
    sample(a, at: at(1000));
    apply();
    expect(calls, 3);
    sample(a, at: at(100000));
    apply();
    apply();
    expect(calls, 4);
  });
}
