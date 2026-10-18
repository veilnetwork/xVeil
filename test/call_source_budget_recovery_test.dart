import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/call_bitrate_adapter.dart';

void main() {
  CallBitrateAdapter adapter() =>
      CallBitrateAdapter(baseBitrateKbps: 900, baseFps: 60, initialLevel: 4);

  void native(CallBitrateAdapter a, {required bool pressured}) {
    a.applyPendingTarget((_) => true);
    a.applyPendingPause((_) => true);
    a.onNativeStats({
      'worker_stalled': 0,
      'video_worker_stalled': 0,
      'audio_feedback_reports': 1,
      'rtt_ms': 80,
      'tx_jitter_ms': 1,
      'tx_loss_pct': 0,
      'audio_tx_rtp_drops': 0,
      'tx_drops': 0,
    }, sourceBudgetPressured: pressured);
  }

  test(
    'native video cannot grow while own source budget is held for audio',
    () {
      final a = adapter();
      for (var i = 0; i < 30; i++) {
        native(a, pressured: true);
      }
      expect(a.target.maxFps, 1);
      expect(a.audioReserve, isFalse);
    },
  );

  test('held source samples do not bank recovery credit for lease release', () {
    final a = adapter();
    for (var i = 0; i < 11; i++) {
      native(a, pressured: true);
    }
    native(a, pressured: false);
    expect(a.target.maxFps, 1);
    for (var i = 1; i < CallBitrateAdapter.recoverAfter; i++) {
      native(a, pressured: false);
    }
    expect(a.target.maxFps, 6);
  });

  test('source hold preserves prompt degradation for fresh audio loss', () {
    final a = CallBitrateAdapter(
      baseBitrateKbps: 900,
      baseFps: 60,
      initialLevel: 2,
    );
    a.onSample(
      sourceBudgetPressured: true,
      rttMs: 80,
      txJitterMs: 1,
      txLossPct: 0,
      txDrops: 0,
      audioNetworkLossObserved: true,
    );
    expect(a.target.maxFps, 1);
  });

  test(
    'source hold still permits the measured one-fps audio recovery probe',
    () {
      final a = adapter();
      var sequence = 0;
      void sample({bool loss = false}) => a.onSample(
        sourceBudgetPressured: true,
        rttMs: 80,
        txJitterMs: 1,
        txLossPct: 0,
        txDrops: 0,
        audioTxDrops: 0,
        audioNetworkLossObserved: loss,
        requireAudioReceive: true,
        audioReceiveAgeMs: 10,
        requireAudioReceivePlayout: true,
        audioReceiveDelayMs: 60,
        requirePeerAudioPlayout: true,
        peerAudioDelayMs: 60,
        peerCurrentAudioDelayMs: 60,
        peerAudioSampleSequence: ++sequence,
      );
      for (var i = 0; i < CallBitrateAdapter.degradeAfter; i++) {
        sample(loss: true);
      }
      expect(a.audioReserve, isTrue);
      for (var i = 0; i < CallBitrateAdapter.probeResumeAfter; i++) {
        sample();
      }
      expect(a.audioReserve, isFalse);
      expect(a.target.maxFps, 1);
    },
  );
}
