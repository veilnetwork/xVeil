import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/state/call_audio_feedback_schedule.dart';

void main() {
  final start = DateTime.fromMillisecondsSinceEpoch(100000);
  CallAudioPlayoutFeedback sample(
    int sequence, {
    int? peak = 170,
    int? current = 170,
    int? target,
    bool? growing = true,
    int? interruptions,
    int? recoveries,
  }) => CallAudioPlayoutFeedback(
    sequence: sequence,
    delayMs: peak,
    currentDelayMs: current,
    targetDelayMs: target,
    bufferGrowing: growing,
    interruptionCount: interruptions,
    recoveryCount: recoveries,
  );

  test('expedites measured growth and the ceiling, not a retained peak', () {
    final schedule = CallAudioFeedbackSchedule();
    expect(schedule.shouldSendUrgent(sample(1), start), isTrue);
    expect(
      schedule.shouldSendUrgent(
        sample(2, peak: 240, current: 80, growing: false),
        start,
      ),
      isFalse,
    );
    expect(
      schedule.shouldSendUrgent(
        sample(3, peak: 300, current: 300, growing: false),
        start,
      ),
      isTrue,
    );
    expect(
      schedule.shouldSendUrgent(
        sample(4, peak: 299, current: 299, growing: false),
        start,
      ),
      isFalse,
    );
  });

  test('caps attempts at one per second and requires a newer sample', () {
    final schedule = CallAudioFeedbackSchedule();
    schedule.recordAttempt(sample(10), start);
    expect(schedule.shouldSendUrgent(sample(11), start), isFalse);
    expect(
      schedule.shouldSendUrgent(
        sample(11),
        start.add(const Duration(milliseconds: 999)),
      ),
      isFalse,
    );
    final next = start.add(const Duration(seconds: 1));
    expect(schedule.shouldSendUrgent(sample(10), next), isFalse);
    expect(schedule.shouldSendUrgent(sample(9), next), isFalse);
    expect(schedule.shouldSendUrgent(sample(11), next), isTrue);
    // A rejected queue still consumes an attempt; a tight retry cannot flood it.
    schedule.recordAttempt(sample(11), next);
    expect(schedule.shouldSendUrgent(sample(12), next), isFalse);
  });

  test('reports a playout interruption before the next heartbeat', () {
    final schedule = CallAudioFeedbackSchedule();
    CallAudioPlayoutFeedback filled(int sequence, int total, int recovered) =>
        sample(
          sequence,
          peak: 440,
          current: 440,
          target: 440,
          growing: false,
          interruptions: total,
          recoveries: recovered,
        );
    schedule.recordAttempt(filled(26, 0, 0), start);
    final event = filled(27, 1, 0);
    final next = start.add(const Duration(seconds: 1));
    expect(schedule.shouldSendUrgent(event, start), isFalse);
    expect(schedule.shouldSendUrgent(filled(26, 1, 0), next), isFalse);
    expect(schedule.shouldSendUrgent(filled(27, 1, 1), next), isFalse);
    expect(schedule.shouldSendUrgent(event, next), isTrue);
    schedule.recordAttempt(event, next);

    final clear = filled(28, 1, 0);
    final afterEvent = next.add(const Duration(seconds: 1));
    expect(schedule.shouldSendUrgent(clear, afterEvent), isTrue);
    schedule.recordAttempt(clear, afterEvent);
    expect(
      schedule.shouldSendUrgent(
        filled(29, 2, 1),
        afterEvent.add(const Duration(seconds: 1)),
      ),
      isFalse,
    );
    expect(
      schedule.shouldSendUrgent(
        filled(30, 2, 1),
        afterEvent.add(const Duration(seconds: 2)),
      ),
      isTrue,
    );
  });

  test('expedites the first call-scoped interruption without a baseline', () {
    final schedule = CallAudioFeedbackSchedule();
    CallAudioPlayoutFeedback report(int total) =>
        CallAudioPlayoutFeedback.fromJson({
          'n': 3,
          'd': 440,
          'cd': 440,
          'td': 440,
          'g': false,
          'i': total,
          'lr': 1,
          'cs': true,
        })!;

    schedule.recordAttempt(const CallAudioPlayoutFeedback(sequence: 1), start);
    final next = start.add(const Duration(seconds: 1));
    expect(schedule.shouldSendUrgent(report(1), next), isFalse);
    expect(schedule.shouldSendUrgent(report(2), start), isFalse);
    expect(schedule.shouldSendUrgent(report(2), next), isTrue);
    schedule.recordAttempt(report(2), next);
    expect(
      schedule.shouldSendUrgent(report(2), next.add(const Duration(seconds: 1))),
      isFalse,
    );
  });

  test('confirms a filled jitter reserve once', () {
    final schedule = CallAudioFeedbackSchedule();
    final high = sample(1, peak: 720, current: 720, target: 500, growing: false);
    expect(schedule.shouldSendUrgent(high, start), isTrue);
    schedule.recordAttempt(high, start);
    final next = start.add(const Duration(seconds: 1));
    final clear = sample(2, peak: 720, current: 520, target: 500, growing: false);
    expect(schedule.shouldSendUrgent(clear, next), isTrue);
    schedule.recordAttempt(clear, next);
    final steady = sample(3, peak: 720, current: 520, target: 500, growing: false);
    final later = next.add(const Duration(seconds: 1));
    expect(schedule.shouldSendUrgent(steady, later), isFalse);
    expect(schedule.urgentDelay(steady, later), const Duration(seconds: 1));
    expect(schedule.urgentDelay(clear, later), isNull);
    expect(
      schedule.shouldSendUrgent(
        sample(3, peak: 720, current: 520, target: 500),
        later,
      ),
      isTrue,
      reason: 'growth remains urgent even with a filled reserve',
    );
    final confirmAt = next.add(const Duration(seconds: 2));
    expect(schedule.shouldSendUrgent(clear, confirmAt), isFalse);
    expect(schedule.shouldSendUrgent(steady, confirmAt), isTrue);
    schedule.recordAttempt(steady, confirmAt);
    expect(
      schedule.shouldSendUrgent(
        sample(4, peak: 520, current: 520, target: 500, growing: false),
        confirmAt.add(const Duration(seconds: 2)),
      ),
      isFalse,
    );
  });

  test('a normal heartbeat can confirm the reserve before the follow-up', () {
    final schedule = CallAudioFeedbackSchedule();
    CallAudioPlayoutFeedback filled(int sequence) =>
        sample(sequence, peak: 520, current: 520, target: 500, growing: false);
    schedule.recordAttempt(sample(1), start);
    schedule.recordAttempt(filled(2), start.add(const Duration(seconds: 1)));
    final confirmation = start.add(const Duration(seconds: 2));
    schedule.recordAttempt(filled(3), confirmation);
    expect(
      schedule.shouldSendUrgent(
        filled(4),
        confirmation.add(const Duration(seconds: 2)),
      ),
      isFalse,
    );
  });

  test('an unknown heartbeat cannot confirm the reserve', () {
    final schedule = CallAudioFeedbackSchedule();
    CallAudioPlayoutFeedback filled(int sequence, bool? trend) =>
        sample(sequence, peak: 520, current: 520, target: 500, growing: trend);
    schedule.recordAttempt(sample(1), start);
    schedule.recordAttempt(
      filled(2, false),
      start.add(const Duration(seconds: 1)),
    );
    final attempted = start.add(const Duration(seconds: 2));
    schedule.recordAttempt(filled(3, null), attempted);
    final due = attempted.add(const Duration(seconds: 2));
    expect(schedule.shouldSendUrgent(filled(4, null), due), isFalse);
    expect(schedule.shouldSendUrgent(filled(4, false), due), isTrue);
  });

  test('a legacy peak or an out-of-range target cannot fund reserve credit', () {
    final schedule = CallAudioFeedbackSchedule();
    expect(
      schedule.shouldSendUrgent(
        sample(1, peak: 520, current: null, target: 500, growing: false),
        start,
      ),
      isTrue,
    );
    expect(
      schedule.shouldSendUrgent(
        sample(2, peak: 520, current: 520, target: 501, growing: false),
        start,
      ),
      isTrue,
    );
  });

  test('reports a measured end of pressure once, not every healthy sample', () {
    final schedule = CallAudioFeedbackSchedule();
    schedule.recordAttempt(sample(1), start);
    final next = start.add(const Duration(seconds: 1));
    final clear = sample(2, peak: 240, current: 80, growing: false);
    expect(schedule.shouldSendUrgent(clear, next), isTrue);
    expect(
      schedule.shouldSendUrgent(sample(2, growing: null), next),
      isFalse,
      reason: 'unknown trend cannot clear measured pressure',
    );
    schedule.recordAttempt(clear, next);
    expect(schedule.shouldSendUrgent(clear, next), isFalse);
    expect(
      schedule.shouldSendUrgent(
        sample(3, growing: false),
        start.add(const Duration(seconds: 2)),
      ),
      isFalse,
    );
  });

  test(
    'periodic health consumes the interval without replaying older data',
    () {
      final schedule = CallAudioFeedbackSchedule();
      schedule.recordAttempt(sample(8, growing: false), start);
      expect(schedule.shouldSendUrgent(sample(9), start), isFalse);
      schedule.recordAttempt(sample(4), start.add(const Duration(seconds: 1)));
      expect(
        schedule.shouldSendUrgent(
          sample(7),
          start.add(const Duration(seconds: 2)),
        ),
        isFalse,
      );
    },
  );

  test('absent, stale and invalid measurements cannot authorize a report', () {
    final schedule = CallAudioFeedbackSchedule();
    for (final feedback in [
      null,
      sample(-1),
      sample(1, peak: null, current: null),
      sample(2, peak: -1, current: -1),
      sample(3, peak: 60001, current: 170),
      sample(4, current: 171),
      sample(5, current: -1),
    ]) {
      expect(schedule.shouldSendUrgent(feedback, start), isFalse);
    }
  });

  test(
    'clock reversal cannot create a burst, a new call resets the schedule',
    () {
      final schedule = CallAudioFeedbackSchedule();
      schedule.recordAttempt(sample(100), start);
      expect(
        schedule.attemptedRecently(start.subtract(const Duration(seconds: 1))),
        isFalse,
        reason: 'clock reversal must not suppress ordinary heartbeats',
      );
      expect(
        schedule.shouldSendUrgent(
          sample(101),
          start.subtract(const Duration(seconds: 1)),
        ),
        isFalse,
      );
      schedule.reset();
      expect(schedule.shouldSendUrgent(sample(1), start), isTrue);
    },
  );
  test(
    'requested buffer ceiling is urgent without relabeling current delay',
    () {
      final schedule = CallAudioFeedbackSchedule();
      final report = CallAudioPlayoutFeedback.fromJson({
        'n': 1,
        'd': 60,
        'cd': 60,
        'g': false,
        'td': 320,
      })!;
      expect(schedule.shouldSendUrgent(report, start), isTrue);
      schedule.recordAttempt(report, start);
      expect(
        schedule.shouldSendUrgent(
          report,
          start.add(const Duration(seconds: 1)),
        ),
        isFalse,
      );
      final clear = CallAudioPlayoutFeedback.fromJson({
        'n': 2,
        'd': 60,
        'cd': 60,
        'g': false,
        'td': 80,
      })!;
      expect(
        schedule.shouldSendUrgent(clear, start.add(const Duration(seconds: 1))),
        isTrue,
      );
      expect(report.delayMs, 60);
    },
  );
}
