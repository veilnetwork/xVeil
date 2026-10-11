import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/call_audio_receive_activity.dart';

void main() {
  final start = DateTime.utc(2026, 10, 5);

  test('fresh native arrival read preserves pending interruption feedback', () {
    final activity = CallAudioReceiveActivity();
    final stats = <String, Object?>{
      'audio_rx_pkts': 30,
      'audio_rx_native_age_ms': 10,
      'worker_stalled': 0,
      'audio_delay_ms': 60,
      'audio_interruption_count': 4,
    };
    activity.observe(stats, start);
    activity.observe({...stats, 'audio_interruption_count': 5}, start);
    final cached = activity.lastRxAt;
    final sampledAt = start.add(const Duration(seconds: 3));
    expect(
      CallAudioReceiveActivity.nativeLastRxAt({
        ...stats,
        'audio_rx_pkts': 31,
        'audio_rx_native_age_ms': 2,
      }, sampledAt),
      sampledAt.subtract(const Duration(milliseconds: 2)),
    );
    expect(activity.lastRxAt, cached);
    expect(activity.interrupted, isTrue);
    expect(activity.playoutFeedback(start).interruptionCount, 1);
    for (final invalid in <Map<String, Object?>>[
      {'worker_stalled': 1},
      {'worker_stalled': null},
      {'audio_rx_pkts': 0},
      {'audio_rx_pkts': double.nan},
      {'audio_rx_native_age_ms': -1},
      {'audio_rx_native_age_ms': null},
      {'audio_rx_native_age_ms': double.infinity},
      {'audio_rx_native_age_ms': 60001},
    ]) {
      expect(
        CallAudioReceiveActivity.nativeLastRxAt({
          ...stats,
          ...invalid,
        }, sampledAt),
        isNull,
      );
    }
  });

  test('current buffer growth reaches feedback before filtered delay', () {
    final activity = CallAudioReceiveActivity();
    final stats = <String, Object?>{
      'audio_rx_pkts': 100,
      'audio_rx_native_age_ms': 10,
      'worker_stalled': 0,
      'audio_delay_ms': 53,
      'audio_jb_ms': 163,
    };
    activity.observe(stats, start);
    expect(activity.playoutFeedback(start).delayMs, 163);
    activity.observe({...stats, 'audio_delay_ms': 180}, start);
    expect(activity.playoutFeedback(start).delayMs, 180);
    for (final buffer in [null, -1, double.nan, double.infinity, 60001]) {
      activity.observe({...stats, 'audio_jb_ms': buffer}, start);
      expect(activity.playoutFeedback(start).delayMs, 53);
    }
    activity.observe({...stats, 'worker_stalled': 1}, start);
    expect(activity.playoutFeedback(start).delayMs, isNull);
    activity.observe({...stats, 'audio_delay_ms': null}, start);
    expect(activity.playoutFeedback(start).delayMs, isNull);
  });

  test(
    'outgoing heartbeat preserves an intervening peak and then expires it',
    () {
      final activity = CallAudioReceiveActivity();
      void sample(int second, int delay) => activity.observe({
        'audio_rx_pkts': 100 + second,
        'audio_rx_native_age_ms': 10,
        'worker_stalled': 0,
        'audio_delay_ms': delay,
        'audio_interruption_count': 0,
      }, start.add(Duration(seconds: second)));
      sample(0, 60);
      sample(1, 196); // The next heartbeat is not sent until second five.
      for (var second = 2; second <= 5; second++) {
        sample(second, 60);
      }
      final sentAt = start.add(const Duration(seconds: 5));
      expect(activity.playoutFeedback(sentAt).delayMs, 60);
      final report = activity.outgoingPlayoutFeedback(sentAt);
      expect(report.delayMs, 196);
      expect(report.sequence, activity.playoutFeedback(sentAt).sequence);
      expect(report.interruptionCount, 0);
      // Reading for capture announcements or a failed send cannot consume it.
      expect(activity.outgoingPlayoutFeedback(sentAt).delayMs, 196);
      sample(7, 60);
      expect(
        activity
            .outgoingPlayoutFeedback(start.add(const Duration(seconds: 7)))
            .delayMs,
        60,
      );
    },
  );

  test('expiry preserves a smaller peak sampled within the same second', () {
    final activity = CallAudioReceiveActivity();
    void sample(int milliseconds, int delay) => activity.observe({
      'audio_rx_pkts': 100,
      'audio_rx_native_age_ms': 10,
      'worker_stalled': 0,
      'audio_delay_ms': delay,
    }, start.add(Duration(milliseconds: milliseconds)));
    sample(100, 300);
    sample(800, 196);
    sample(5500, 60);
    expect(
      activity
          .outgoingPlayoutFeedback(
            start.add(const Duration(milliseconds: 5500)),
          )
          .delayMs,
      196,
    );
    sample(6000, 60);
    expect(
      activity
          .outgoingPlayoutFeedback(start.add(const Duration(seconds: 6)))
          .delayMs,
      60,
    );
  });

  test('an old feedback peak cannot replace an unknown current sample', () {
    final activity = CallAudioReceiveActivity();
    final stats = <String, Object?>{
      'audio_rx_pkts': 100,
      'audio_rx_native_age_ms': 10,
      'worker_stalled': 0,
      'audio_delay_ms': 196,
    };
    activity.observe(stats, start);
    expect(
      activity
          .outgoingPlayoutFeedback(start.add(const Duration(seconds: 4)))
          .delayMs,
      isNull,
    );
    final now = start.add(const Duration(seconds: 2));
    for (final unknown in <Map<String, Object?>>[
      {'worker_stalled': 1},
      {'audio_delay_ms': null},
      {'audio_rx_native_age_ms': 4000},
    ]) {
      activity.observe({...stats, ...unknown}, now);
      expect(activity.outgoingPlayoutFeedback(now).delayMs, isNull);
    }
  });

  test(
    'feedback peaks do not survive a repair or a backwards clock change',
    () {
      final activity = CallAudioReceiveActivity();
      void sample(DateTime now, int delay) => activity.observe({
        'audio_rx_pkts': 100,
        'audio_rx_native_age_ms': 10,
        'worker_stalled': 0,
        'audio_delay_ms': delay,
      }, now);
      sample(start, 196);
      activity.reset();
      sample(start.add(const Duration(seconds: 1)), 60);
      expect(
        activity
            .outgoingPlayoutFeedback(start.add(const Duration(seconds: 1)))
            .delayMs,
        60,
      );
      sample(start.add(const Duration(seconds: 2)), 196);
      sample(start.add(const Duration(seconds: 1)), 60);
      expect(
        activity
            .outgoingPlayoutFeedback(start.add(const Duration(seconds: 1)))
            .delayMs,
        60,
      );
    },
  );

  test('interruption feedback survives repairs without inventing outages', () {
    final activity = CallAudioReceiveActivity();
    void sample(int count, {int stalled = 0}) => activity.observe({
      'audio_rx_pkts': 20,
      'audio_rx_native_age_ms': 10,
      'worker_stalled': stalled,
      'audio_delay_ms': 60,
      'audio_interruption_count': count,
    }, start);
    sample(40); // Historical counters are a baseline, not a new outage.
    expect(activity.interrupted, isFalse);
    expect(activity.playoutFeedback(start).interruptionCount, 0);
    sample(41);
    expect(activity.interrupted, isTrue);
    expect(activity.playoutFeedback(start).interruptionCount, 1);
    sample(0, stalled: 1); // Native timeout defaults must not rebase.
    expect(activity.interrupted, isFalse);
    expect(activity.playoutFeedback(start).interruptionCount, isNull);
    sample(42);
    expect(activity.interrupted, isTrue);
    expect(activity.playoutFeedback(start).interruptionCount, 2);
    activity.reset();
    sample(0);
    expect(activity.interrupted, isFalse);
    expect(activity.playoutFeedback(start).interruptionCount, 2);
    sample(1);
    expect(activity.playoutFeedback(start).interruptionCount, 3);
    sample(1);
    expect(activity.interrupted, isFalse);
    expect(
      activity
          .playoutFeedback(start.add(const Duration(seconds: 4)))
          .interruptionCount,
      isNull,
    );
  });

  test('native arrival time excludes a delayed host timer', () {
    final activity = CallAudioReceiveActivity();
    activity.observe({
      'audio_rx_pkts': 30,
      'audio_rx_native_age_ms': 20,
      'worker_stalled': 0,
    }, start);
    final delayed = start.add(const Duration(seconds: 3));
    activity.observe({
      'audio_rx_pkts': 180,
      'audio_rx_native_age_ms': 15,
      'worker_stalled': 0,
    }, delayed);
    expect(
      activity.lastRxAt,
      delayed.subtract(const Duration(milliseconds: 15)),
    );
    // RTCP/video alone cannot refresh a native arrival timestamp.
    activity.observe({
      'audio_rx_pkts': 180,
      'audio_rx_native_age_ms': 4015,
      'worker_stalled': 0,
    }, delayed.add(const Duration(seconds: 4)));
    expect(
      activity.lastRxAt,
      delayed.subtract(const Duration(milliseconds: 15)),
    );
  });

  test('an unknown native timestamp cannot pretend audio just arrived', () {
    final activity = CallAudioReceiveActivity();
    activity.observe({
      'audio_rx_pkts': 30,
      'audio_rx_native_age_ms': -1,
      'worker_stalled': 0,
    }, start);
    expect(activity.lastRxAt, isNull);
    activity.observe({
      'audio_rx_pkts': 31,
      'audio_rx_native_age_ms': 25,
      'worker_stalled': 0,
    }, start);
    activity.observe({
      'audio_rx_pkts': 0,
      'audio_rx_native_age_ms': -1,
      'worker_stalled': 1,
    }, start.add(const Duration(seconds: 4)));
    expect(activity.lastRxAt, start.subtract(const Duration(milliseconds: 25)));
  });

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
