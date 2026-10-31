import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/call_audio_start_state.dart';

void main() {
  test('a failed microphone leaves a working output usable', () {
    expect(
      callAudioStartState(
        started: false,
        stats: {
          'audio_capture_start_result': 0,
          'audio_playout_start_result': 1,
        },
      ),
      CallAudioStartState.receiveOnly,
    );
  });

  test(
    'unknown startup and failed output cannot masquerade as receive-only',
    () {
      for (final stats in <Map<String, dynamic>>[
        {},
        {'audio_capture_start_result': 1, 'audio_playout_start_result': 0},
        {'audio_capture_start_result': 0, 'audio_playout_start_result': 0},
        {'audio_capture_start_result': -1, 'audio_playout_start_result': 1},
        {'audio_capture_start_result': '0', 'audio_playout_start_result': 1},
      ]) {
        expect(
          callAudioStartState(started: false, stats: stats),
          CallAudioStartState.failed,
        );
      }
      expect(
        callAudioStartState(started: true, stats: {}),
        CallAudioStartState.ready,
      );
    },
  );
}
