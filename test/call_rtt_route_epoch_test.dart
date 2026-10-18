import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/call_bitrate_adapter.dart';

void main() {
  CallBitrateAdapter adapter({int level = 4}) => CallBitrateAdapter(
    baseBitrateKbps: 900,
    baseFps: 60,
    initialLevel: level,
  );
  var sequence = 0;
  void sample(
    CallBitrateAdapter a,
    int epoch,
    int rtt, {
    int lossUs = 0,
    bool send = true,
  }) {
    a.applyPendingTarget((_) => true);
    a.applyPendingPause((_) => true);
    a.onNativeStats(
      {
        'worker_stalled': 0,
        'video_worker_stalled': 0,
        'audio_feedback_reports': 1,
        'audio_rtt_route_epoch': epoch,
        'video_rtt_route_epoch': epoch,
        'video_feedback_reports': 1,
        'video_feedback_rtt_ms': rtt,
        'video_feedback_jitter_ms': 5,
        'video_feedback_loss_pct': 0,
        'rtt_ms': rtt,
        'tx_jitter_ms': 5,
        'tx_loss_pct': 0,
        'tx_drops': 0,
        'audio_tx_rtp_drops': 0,
        'video_tx_rtp_drops': 0,
        'audio_rx_pkts': 100 + sequence,
        'audio_rx_native_age_ms': 10,
        'audio_delay_ms': 60,
        'video_tx_frames': ++sequence,
        'audio_loss_report_us': lossUs,
      },
      sendAudioExpected: send,
      receiveAudioExpected: true,
      requireAudioReceivePlayout: true,
      requirePeerAudioPlayout: send,
      peerAudioDelayMs: 60,
      peerCurrentAudioDelayMs: 60,
      peerAudioSampleSequence: sequence,
    );
  }

  test('route epoch permits recovery against the new measured RTT floor', () {
    final a = adapter();
    sample(a, 0, 8);
    for (var i = 0; i < 12; ++i) {
      sample(a, 0, 110);
    }
    expect(a.level, 4);
    expect(a.rttBaselineMs, 8);
    // Native invalidates old-route SR echoes. Unknown RTT earns no growth.
    for (var i = 0; i < 12; ++i) {
      sample(a, 1, 0);
    }
    expect(a.level, 4);
    expect(a.rttBaselineMs, isNull);
    for (var i = 0; i < 12; ++i) {
      sample(a, 1, 110);
    }
    expect(a.rttBaselineMs, 110);
    expect(a.level, 3);
  });

  test('same route retains its floor and withholds growth under bloat', () {
    final a = adapter();
    sample(a, 5, 30);
    for (var i = 0; i < 30; ++i) {
      sample(a, 5, 160);
    }
    expect(a.rttBaselineMs, 30);
    expect(a.level, 4);
  });

  test('older route snapshots cannot reseed a new RTT floor', () {
    final a = adapter();
    sample(a, 0, 8);
    sample(a, 1, 110);
    for (var i = 0; i < 12; ++i) {
      sample(a, 0, 8);
    }
    expect(a.rttBaselineMs, 110);
    expect(a.level, 4);
  });

  test('replacement engine accepts its restarted route numbering', () {
    final a = adapter();
    sample(a, 3, 8);
    a.invalidateAppliedState();
    sample(a, 0, 110);
    expect(a.rttBaselineMs, 110);
  });

  test('new route does not bypass the absolute RTT guard', () {
    final a = adapter();
    sample(a, 0, 8);
    for (var i = 0; i < 20; ++i) {
      sample(a, 1, 2500);
    }
    expect(a.level, 4);
  });

  test('route epoch preserves already consumed and new loss events', () {
    final a = adapter(level: 0);
    sample(a, 0, 8, lossUs: 1000);
    expect(a.level, 2);
    sample(a, 1, 110, lossUs: 1000);
    expect(a.level, 2);
    sample(a, 1, 110, lossUs: 2000);
    expect(a.level, 4);
  });

  test('muted sender uses video RTT from the new route', () {
    final a = adapter();
    sample(a, 0, 8, send: false);
    for (var i = 0; i < 12; ++i) {
      sample(a, 1, 110, send: false);
    }
    expect(a.rttBaselineMs, 110);
    expect(a.level, 3);
  });
}
