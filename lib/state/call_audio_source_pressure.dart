import 'call_bitrate_adapter.dart';

/// Endpoint measurements for the shared source budget, including audio-only
/// calls. The node receives only a generic, expiring pressure observation.
class CallAudioSourcePressure {
  bool _pressured = true;
  int _healthy = 0;
  int? _lastAudioDrops;

  /// Null means no audio source is expected: stop refreshing the node lease.
  /// Freshness of peer and receive measurements is enforced by their trackers.
  bool? observe({
    required bool sendExpected,
    required bool receiveExpected,
    required bool requirePeerPlayout,
    required int? peerDelayMs,
    required int? receiveDelayMs,
    required int? receiveAgeMs,
    required bool interrupted,
    required int? audioTxDrops,
  }) {
    final drops = audioTxDrops != null && audioTxDrops >= 0
        ? audioTxDrops
        : null;
    final newDrop =
        sendExpected &&
        drops != null &&
        _lastAudioDrops != null &&
        drops > _lastAudioDrops!;
    _lastAudioDrops = sendExpected ? drops : null;
    if (!sendExpected && !receiveExpected) {
      reset();
      return null;
    }
    bool valid(int? n) => n != null && n >= 0 && n <= 60000;
    final peerNeeded = sendExpected && requirePeerPlayout;
    final unknown =
        (peerNeeded && !valid(peerDelayMs)) ||
        (receiveExpected && (!valid(receiveDelayMs) || !valid(receiveAgeMs)));
    final bad =
        unknown ||
        interrupted ||
        newDrop ||
        (peerNeeded && peerDelayMs! >= CallBitrateAdapter.playoutDegradeMs) ||
        (receiveExpected &&
            (receiveDelayMs! >= CallBitrateAdapter.playoutDegradeMs ||
                receiveAgeMs! >= CallBitrateAdapter.audioReceivePauseMs));
    final good =
        !bad &&
        (!peerNeeded || peerDelayMs! < CallBitrateAdapter.playoutRecoverMs) &&
        (!receiveExpected ||
            (receiveDelayMs! < CallBitrateAdapter.playoutRecoverMs &&
                receiveAgeMs! < CallBitrateAdapter.audioReceiveRecoverMs));
    if (bad) {
      _pressured = true;
      _healthy = 0;
    } else if (good) {
      if (++_healthy >= CallBitrateAdapter.recoverAfter) _pressured = false;
    } else {
      _healthy = 0;
    }
    return _pressured;
  }

  void reset() {
    _pressured = true;
    _healthy = 0;
    _lastAudioDrops = null;
  }
}
