import 'call_bitrate_adapter.dart';

/// Endpoint measurements for the shared source budget, including audio-only
/// calls. The node receives only a generic, expiring pressure observation.
class CallAudioSourcePressure {
  // Retain conservative thresholds and sustained recovery. A recent peak is
  // useful for video growth decisions, but is not the current source pressure.
  static const int playoutDegradeMs = 160;
  static const int playoutRecoverMs = 120;
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
    int? peerCurrentDelayMs,
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
    // A current sample belongs to the same fresh, authenticated report as its
    // peak. It cannot make an absent/invalid report healthy or exceed the peak.
    // Older peers retain their peak-only behavior.
    final peerDelay =
        valid(peerDelayMs) &&
            valid(peerCurrentDelayMs) &&
            peerCurrentDelayMs! <= peerDelayMs!
        ? peerCurrentDelayMs
        : peerDelayMs;
    final peerNeeded = sendExpected && requirePeerPlayout;
    final unknown =
        (peerNeeded && !valid(peerDelay)) ||
        (receiveExpected && (!valid(receiveDelayMs) || !valid(receiveAgeMs)));
    final bad =
        unknown ||
        interrupted ||
        newDrop ||
        (peerNeeded && peerDelay! >= playoutDegradeMs) ||
        (receiveExpected &&
            (receiveDelayMs! >= playoutDegradeMs ||
                receiveAgeMs! >= CallBitrateAdapter.audioReceivePauseMs));
    final good =
        !bad &&
        (!peerNeeded || peerDelay! < playoutRecoverMs) &&
        (!receiveExpected ||
            (receiveDelayMs! < playoutRecoverMs &&
                receiveAgeMs! < CallBitrateAdapter.audioReceiveRecoverMs));
    if (bad) {
      _pressured = true;
      _healthy = 0;
    } else if (good) {
      if (++_healthy >= CallBitrateAdapter.recoverAfter) _pressured = false;
    } else {
      _healthy = 0;
    }
    // A released hysteresis latch does not prove that the current sample is
    // healthy. The node uses false to grow other producers' byte allowance;
    // intermediate measurements must not authorize that growth. Keep the
    // latch intact so a brief intermediate sample does not require another
    // full recovery streak once measurements are good again.
    return _pressured || !good;
  }

  void reset() {
    _pressured = true;
    _healthy = 0;
    _lastAudioDrops = null;
  }
}
