import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/state/call_audio_feedback_schedule.dart';

void main() {
  final start = DateTime.fromMillisecondsSinceEpoch(100000);
  CallAudioPlayoutFeedback sample(
    int sequence, {
    int? peak = 170,
    int? current = 170,
    bool? growing = true,
  }) => CallAudioPlayoutFeedback(
    sequence: sequence,
    delayMs: peak,
    currentDelayMs: current,
    bufferGrowing: growing,
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
        sample(3, peak: 200, current: 200, growing: false),
        start,
      ),
      isTrue,
    );
    expect(
      schedule.shouldSendUrgent(
        sample(4, peak: 199, current: 199, growing: false),
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
}
