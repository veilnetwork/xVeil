import 'call_rtcp_loss.dart';

/// Native per-decoder duration windows cover non-silent concealment and
/// discarded speech. Missing/partial/older snapshots retain event fallback.
class CallAudioSoftLoss {
  // The native six-second window starts reporting sustained damage at
  // 120 ms. Use the full window here, including previously reported damage.
  static bool? bothWindowsBelowThreshold(Map<String, dynamic>? stats) {
    num? valid(Object? ms) => ms is num && ms.isFinite && ms >= 0 ? ms : null;
    final peer = valid(stats?['audio_peer_soft_loss_window_ms']);
    final local = valid(stats?['audio_local_soft_loss_window_ms']);
    if (peer == null || local == null) return null;
    return peer < 120 && local < 120;
  }

  final _send = CallRtcpLoss();
  final _receive = CallRtcpLoss();

  ({bool? send, bool? receive}) observe(
    Map<String, dynamic>? stats, {
    required bool sending,
    required bool receiving,
  }) {
    final tx = stats?['audio_peer_soft_loss_report_us'];
    final rx = stats?['audio_local_soft_loss_report_us'];
    final sendKnown =
        stats?['audio_peer_soft_loss_duration_supported'] == 1 &&
        tx is int &&
        tx >= 0;
    final receiveKnown =
        stats?['audio_soft_loss_duration_supported'] == 1 &&
        rx is int &&
        rx >= 0;
    final send = _send
        .observe(
          audioReportUs: tx,
          audioExpected: sending && sendKnown,
          videoExpected: false,
        )
        .audio;
    final receive = _receive
        .observe(
          audioReportUs: rx,
          audioExpected: receiving && receiveKnown,
          videoExpected: false,
        )
        .audio;
    return (
      send: sendKnown ? send : null,
      receive: receiveKnown ? receive : null,
    );
  }

  void reset() {
    _send.reset();
    _receive.reset();
  }
}
