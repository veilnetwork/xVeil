/// Native startup reports capture and playout separately even when its combined
/// result is false. A missing input must not discard a working receive path.
enum CallAudioStartState { ready, receiveOnly, failed }

CallAudioStartState callAudioStartState({
  required bool started,
  required Map<String, dynamic> stats,
}) {
  if (started) return CallAudioStartState.ready;
  if (stats['audio_capture_start_result'] == 0 &&
      stats['audio_playout_start_result'] == 1) {
    return CallAudioStartState.receiveOnly;
  }
  return CallAudioStartState.failed;
}
