// Compile with dart compile exe to check the real product-mode branch.
import 'package:xveil/state/call_bitrate_adapter.dart';

void main(List<String> args) {
  final expectDiagnostics = args.single == 'diagnostics';
  final adapter = CallBitrateAdapter(baseBitrateKbps: 900, baseFps: 60);
  adapter.applyPendingTarget((_) => true);
  for (var second = 1; second <= 40; second++) {
    adapter.onNativeStats(
      {
        'worker_stalled': 0,
        'video_worker_stalled': 0,
        'audio_feedback_reports': 1,
        'video_feedback_reports': 1,
        'rtt_ms': 10,
        'tx_jitter_ms': 1,
        'tx_loss_pct': 0,
        'tx_drops': 0,
        'audio_tx_rtp_drops': 0,
        'audio_rx_pkts': second * 50,
        'audio_rx_native_age_ms': 1,
        'audio_delay_ms': 40,
        'video_tx_frames': second,
      },
      sampledAt: DateTime(2026, 10, 21).add(Duration(seconds: second)),
      receiveAudioExpected: true,
      requireAudioReceivePlayout: true,
      requirePeerAudioPlayout: true,
      peerAudioDelayMs: 40,
      peerAudioSampleSequence: second ~/ 5,
    );
    adapter.applyPendingTarget((_) => true);
  }
  if (adapter.acknowledgedTarget != (maxBitrateKbps: 900, maxFps: 60.0)) {
    throw StateError('Removing diagnostics changed video growth');
  }
  if (adapter.bufferDiagnostics.isNotEmpty != expectDiagnostics) {
    throw StateError('Unexpected diagnostic exposure');
  }
  // CLI probe output, never called by the app.
  // ignore: avoid_print
  print(
    'PASS: full native target; diagnostics=$expectDiagnostics; '
    'product=${const bool.fromEnvironment('dart.vm.product')}',
  );
}
