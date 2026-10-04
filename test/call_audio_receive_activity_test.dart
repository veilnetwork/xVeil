import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/call_audio_receive_activity.dart';

void main() {
  final start = DateTime.utc(2026, 10, 5);

  test('video and RTCP ingress cannot advance accepted audio activity', () {
    final activity = CallAudioReceiveActivity();
    activity.observe({
      'rx_pkts': 10,
      'audio_rx_pkts': 3,
      'worker_stalled': 0,
    }, start);
    activity.observe({
      'rx_pkts': 900,
      'audio_rx_pkts': 3,
      'worker_stalled': 0,
    }, start.add(const Duration(seconds: 12)));
    expect(activity.supported, isTrue);
    expect(activity.lastRxAt, start);
    activity.observe({
      'audio_rx_pkts': 4,
      'worker_stalled': 0,
    }, start.add(const Duration(seconds: 13)));
    expect(activity.lastRxAt, start.add(const Duration(seconds: 13)));
  });

  test('worker timeout defaults cannot reset the accepted audio counter', () {
    final activity = CallAudioReceiveActivity();
    activity.observe({'audio_rx_pkts': 30, 'worker_stalled': 0}, start);
    final stalledAt = start.add(const Duration(seconds: 5));
    activity.observe({'audio_rx_pkts': 0, 'worker_stalled': 1}, stalledAt);
    activity.observe({
      'audio_rx_pkts': 0,
      'worker_stalled': 1,
    }, stalledAt.add(const Duration(seconds: 11)));
    expect(activity.workerStalledSince, stalledAt);
    activity.observe({
      'audio_rx_pkts': 30,
      'worker_stalled': 0,
    }, start.add(const Duration(seconds: 17)));
    expect(activity.lastRxAt, start);
    expect(activity.workerStalledSince, isNull);
  });

  test('unknown snapshots break evidence of a continuously stalled worker', () {
    final activity = CallAudioReceiveActivity();
    activity.observe({'rx_pkts': 900}, start);
    expect(activity.supported, isFalse);
    activity.observe({'audio_rx_pkts': 0, 'worker_stalled': 1}, start);
    activity.observe({}, start.add(const Duration(seconds: 5)));
    final again = start.add(const Duration(seconds: 9));
    activity.observe({'audio_rx_pkts': 0, 'worker_stalled': 1}, again);
    expect(activity.workerStalledSince, again);
    expect(activity.lastRxAt, isNull);
  });

  test('replacement session resets support and counter baselines', () {
    final activity = CallAudioReceiveActivity();
    activity.observe({'audio_rx_pkts': 3000, 'worker_stalled': 0}, start);
    activity.reset();
    expect(activity.supported, isFalse);
    expect(activity.lastRxAt, isNull);
    final restart = start.add(const Duration(seconds: 30));
    activity.observe({'audio_rx_pkts': 1, 'worker_stalled': 0}, restart);
    expect(activity.lastRxAt, restart);
  });
}
