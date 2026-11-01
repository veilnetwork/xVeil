import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/call_media_receive_activity.dart';

void main() {
  final start = DateTime.utc(2026, 1, 1);
  Map<String, Object?> stats(int packets) => {
    'rx_pkts': packets,
    'worker_stalled': 0,
  };

  test('only a growing accepted-media counter renews liveness', () {
    final activity = CallMediaReceiveActivity();
    expect(activity.observe(stats(0), start), isNull);
    expect(activity.observe(stats(3), start), start);
    final later = start.add(const Duration(seconds: 25));
    expect(activity.observe(stats(3), later), start);
    expect(activity.observe(stats(4), later), later);
  });

  test('a failed worker cannot rebase and replay an old receipt', () {
    final activity = CallMediaReceiveActivity();
    activity.observe(stats(100), start);
    final later = start.add(const Duration(seconds: 25));
    expect(
      activity.observe({'rx_pkts': 0, 'worker_stalled': 1}, later),
      isNull,
    );
    expect(activity.lastRxAt, start);
    expect(activity.observe(stats(100), later), start);
  });

  test('lower counters do not turn an old engine snapshot into new life', () {
    final activity = CallMediaReceiveActivity();
    activity.observe(stats(100), start);
    final later = start.add(const Duration(seconds: 25));
    expect(activity.observe(stats(10), later), start);
    expect(activity.observe(stats(11), later), start);
    expect(activity.observe(stats(101), later), later);
  });

  test(
    'reset isolates a new receive engine and allows its smaller counter',
    () {
      final activity = CallMediaReceiveActivity();
      activity.observe(stats(100), start);
      activity.reset();
      expect(activity.lastRxAt, isNull);
      expect(activity.observe(stats(0), start), isNull);
      final later = start.add(const Duration(seconds: 25));
      expect(activity.observe(stats(1), later), later);
    },
  );

  test('legacy snapshots may omit the worker flag', () {
    final activity = CallMediaReceiveActivity();
    expect(activity.observe({'rx_pkts': 1}, start), start);
  });

  test(
    'same-call counter rebase keeps history without minting new activity',
    () {
      final activity = CallMediaReceiveActivity();
      activity.observe(stats(100), start);
      activity.reset(preserveLastRxAt: true);
      final later = start.add(const Duration(seconds: 15));
      expect(activity.lastRxAt, start);
      expect(activity.observe(stats(0), later), start);
      expect(
        activity.observe({'rx_pkts': 0, 'worker_stalled': 1}, later),
        isNull,
      );
      expect(activity.lastRxAt, start);
      expect(activity.observe(stats(1), later), later);
      activity.reset();
      expect(activity.lastRxAt, isNull);
    },
  );

  test('malformed counters are unavailable and preserve the receipt floor', () {
    final activity = CallMediaReceiveActivity();
    activity.observe(stats(10), start);
    final later = start.add(const Duration(seconds: 25));
    for (final value in [null, -1, 10.5, double.nan, double.infinity, '100']) {
      expect(
        activity.observe({'rx_pkts': value, 'worker_stalled': 0}, later),
        isNull,
      );
      expect(activity.lastRxAt, start);
    }
    expect(activity.observe(stats(10), later), start);
  });
}
