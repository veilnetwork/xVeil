import 'call_bitrate_adapter.dart';
import 'call_audio_buffer_window.dart';

/// Endpoint measurements for the shared source budget, including audio-only
/// calls. The node receives only a generic, expiring pressure observation.
class CallAudioSourcePressure {
  // Use the video ladder's buffer rails and sustained recovery. A retained
  // peak is not the current source pressure.
  static const int playoutDegradeMs = CallAudioBufferWindow.ceilingMs;
  static const int playoutRecoverMs = CallBitrateAdapter.playoutRecoverMs;
  bool _pressured = true;
  int _healthy = 0;
  int? _lastAudioDrops;
  final _peerBuffer = CallAudioBufferWindow();
  final _receiveBuffer = CallAudioBufferWindow();

  /// Null means no source or no verdict: stop refreshing the node lease.
  /// Freshness of peer and receive measurements is enforced by their trackers.
  bool? observe({
    required bool sendExpected,
    required bool receiveExpected,
    required bool requirePeerPlayout,
    required int? peerDelayMs,
    int? peerCurrentDelayMs,
    int? peerTargetDelayMs,
    int? peerSampleSequence,
    bool? peerBufferGrowing,
    required int? receiveDelayMs,
    int? receiveTargetDelayMs,
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
    final hasCurrentPeerDelay =
        valid(peerDelayMs) &&
        valid(peerCurrentDelayMs) &&
        peerCurrentDelayMs! <= peerDelayMs!;
    final peerDelay = hasCurrentPeerDelay ? peerCurrentDelayMs : peerDelayMs;
    final peerNeeded = sendExpected && requirePeerPlayout;
    final unknown =
        (peerNeeded && !valid(peerDelay)) ||
        (receiveExpected && (!valid(receiveDelayMs) || !valid(receiveAgeMs)));
    final peerPressure = _peerBuffer.observe(
      peerNeeded ? peerDelay : null,
      sequence: peerSampleSequence,
      measuredGrowing: peerNeeded && hasCurrentPeerDelay
          ? peerBufferGrowing
          : null,
    );
    final receivePressure = _receiveBuffer.observe(
      receiveExpected ? receiveDelayMs : null,
    );
    // Competing sources honor fresh audio loss and the video buffer trigger.
    // Transport estimates or unknown feedback alone cannot cut this budget.
    final peerTarget =
        peerNeeded && valid(peerDelay) && valid(peerTargetDelayMs)
        ? peerTargetDelayMs
        : null;
    final receiveTarget =
        receiveExpected && valid(receiveDelayMs) && valid(receiveTargetDelayMs)
        ? receiveTargetDelayMs
        : null;
    final bad =
        newDrop ||
        interrupted ||
        peerPressure ||
        receivePressure ||
        (peerTarget != null && peerTarget >= playoutDegradeMs) ||
        (receiveTarget != null && receiveTarget >= playoutDegradeMs);
    final good =
        !bad &&
        !unknown &&
        !interrupted &&
        !newDrop &&
        (peerTarget == null || peerTarget < playoutRecoverMs) &&
        (receiveTarget == null || receiveTarget < playoutRecoverMs) &&
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
    // Unknown/marginal measurements cannot authorize producer growth, but
    // must not renew a congestion lease after measured pressure has cleared.
    return _pressured ? true : (good ? false : null);
  }

  void reset() {
    _pressured = true;
    _healthy = 0;
    _lastAudioDrops = null;
    _peerBuffer.reset();
    _receiveBuffer.reset();
  }
}
