import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/call_bitrate_adapter.dart';

final _epoch = DateTime.utc(2026, 10, 25);

Map<String, dynamic> _decoder(int n) => {
  'origin': 1,
  'sample_us': n * 1000000,
  'arrival_us': n * 1000000 + 120000,
  'bytes': n * 1200,
  'frames': n,
  'timestamp': n * 90000,
  'sent_timestamp': n * 90000,
  'sent_bytes': n * 1200,
  'sent_timestamp_valid': true,
  'delay_ms': 60,
};

void _sample(
  CallBitrateAdapter a,
  int n, {
  int rtt = 295,
  int? receiveDelay = 60,
  int? peerDelay = 60,
  int? peerCurrentDelay,
  int? peerSequence,
  int receiveTarget = 60,
  int peerTarget = 60,
  bool peerGrowing = false,
  int loss = 0,
  int audioLoss = 0,
  int audioDrops = 0,
  bool sourcePressure = false,
  bool videoExpected = true,
  bool interrupted = false,
  bool workerStalled = false,
  int expectedReceivers = 1,
  Map<String, dynamic>? decoder,
  bool apply = true,
  Map<String, dynamic> extra = const {},
}) {
  a.onNativeStats(
    {
      'worker_stalled': workerStalled ? 1 : 0,
      'video_worker_stalled': 0,
      'audio_feedback_reports': 1,
      'video_feedback_reports': 1,
      'rtt_ms': rtt,
      'tx_loss_pct': loss,
      'tx_jitter_ms': 10,
      'audio_rx_pkts': n * 10,
      'audio_rx_native_age_ms': 10,
      'audio_delay_ms': ?receiveDelay,
      'audio_jb_target_ms': receiveTarget,
      'audio_tx_rtp_drops': audioDrops,
      'audio_loss_report_us': audioLoss,
      'audio_peer_soft_loss_duration_supported': 1,
      'audio_peer_soft_loss_report_us': 0,
      'audio_soft_loss_duration_supported': 1,
      'audio_local_soft_loss_report_us': 0,
      'video_tx_rtp_drops': 0,
      'tx_drops': 0,
      'video_tx_frames': n,
      'video_delivery_peers': {'p': decoder ?? _decoder(n)},
      ...extra,
    },
    sampledAt: _epoch.add(Duration(seconds: n)),
    sourceBudgetPressured: sourcePressure,
    videoSendExpected: videoExpected,
    requireAudioReceivePlayout: true,
    requirePeerAudioPlayout: true,
    receiveAudioExpected: true,
    audioReceiveDelayMs: receiveDelay,
    audioReceiveTargetDelayMs: receiveTarget,
    peerAudioDelayMs: peerDelay,
    peerCurrentAudioDelayMs: peerCurrentDelay ?? peerDelay,
    peerTargetAudioDelayMs: peerTarget,
    peerAudioSampleSequence: peerSequence ?? n,
    peerAudioBufferGrowing: peerGrowing,
    audioInterrupted: interrupted,
    expectedVideoFeedbackReports: expectedReceivers,
    expectedAudioFeedbackReports: expectedReceivers,
  );
  if (apply) a.applyPendingTarget((_) => true);
}

CallBitrateAdapter _started() {
  final a = CallBitrateAdapter(baseBitrateKbps: 900, baseFps: 60);
  a.applyPendingTarget((_) => true);
  a.applyPendingPause((_) => true);
  _sample(a, 1, rtt: 100);
  _sample(a, 2, rtt: 100);
  expect(a.acknowledgedTarget, (maxBitrateKbps: 30, maxFps: 2.0));
  return a;
}

void main() {
  Map<String, dynamic> videoTiming() => {
    'rtt_ms': 0,
    'audio_feedback_reports': 0,
    'audio_rtt_route_epoch': 0,
    'video_rtt_route_epoch': 0,
    'video_feedback_rtt_ms': 12,
    'video_feedback_loss_pct': 0,
  };

  test('measured video RTT can fund startup before audio RR timing', () {
    final a = CallBitrateAdapter(baseBitrateKbps: 900, baseFps: 60);
    a.applyPendingTarget((_) => true);
    a.applyPendingPause((_) => true);
    for (var n = 1; n <= 8; n++) {
      _sample(a, n, extra: videoTiming());
    }
    expect(a.acknowledgedTarget!.maxFps, greaterThanOrEqualTo(30));
    expect(a.acknowledgedTarget!.maxBitrateKbps, lessThanOrEqualTo(900));
    expect(a.audioReserve, isFalse);
  });

  test(
    'a handover needs a new audio playout report before borrowing video RTT',
    () {
      final a = CallBitrateAdapter(baseBitrateKbps: 900, baseFps: 60);
      a.applyPendingTarget((_) => true);
      a.applyPendingPause((_) => true);
      _sample(a, 1, extra: videoTiming());
      _sample(a, 2, extra: videoTiming());
      final before = a.acknowledgedTarget!;
      expect(before.maxFps, 2);
      final newRoute = {
        ...videoTiming(),
        'audio_rtt_route_epoch': 1,
        'video_rtt_route_epoch': 1,
      };
      for (var n = 3; n <= 6; n++) {
        _sample(a, n, peerSequence: 2, extra: newRoute);
        expect(
          a.acknowledgedTarget,
          before,
          reason: 'cached audio health belongs to the previous route',
        );
      }
      _sample(a, 7, peerSequence: 3, extra: newRoute);
      expect(a.acknowledgedTarget!.maxFps, greaterThan(before.maxFps));
      expect(
        a.acknowledgedTarget!.maxFps,
        lessThanOrEqualTo(before.maxFps * 2),
      );
      a.invalidateAppliedState();
      a.applyPendingTarget((_) => true);
      a.applyPendingPause((_) => true);
      _sample(a, 1, extra: videoTiming());
      _sample(a, 2, extra: videoTiming());
      expect(
        a.bufferDiagnostics['latest'],
        containsPair('video_timing_fallback', true),
        reason: 'a replacement engine must not inherit an old route baseline',
      );
    },
  );

  for (final fault in [
    'unknown video RTT',
    'missing video RR',
    'video worker stalled',
    'audio worker stalled',
    'missing route epoch',
    'different route epoch',
    'missing local playout',
    'missing peer playout',
    'receive outage',
    'local buffer pressure',
    'peer buffer pressure',
    'audio loss',
    'audio drops',
    'video loss',
    'audio jitter',
    'severe audio RTT',
    'peer buffer growing',
    'high peer target',
    'cached decoder ACK',
    'inconsistent peer current',
    'partial receiver reports',
    'missing decoder reports',
  ]) {
    test('video timing preserves the $fault guard', () {
      final a = CallBitrateAdapter(baseBitrateKbps: 900, baseFps: 60);
      a.applyPendingTarget((_) => true);
      a.applyPendingPause((_) => true);
      for (var n = 1; n <= 4; n++) {
        _sample(
          a,
          n,
          receiveDelay: fault == 'missing local playout'
              ? null
              : fault == 'local buffer pressure'
              ? 500
              : 60,
          peerDelay: fault == 'missing peer playout'
              ? null
              : fault == 'peer buffer pressure'
              ? 500
              : 60,
          peerCurrentDelay: fault == 'inconsistent peer current' ? 900 : null,
          expectedReceivers: fault == 'partial receiver reports' ? 2 : 1,
          peerTarget: fault == 'high peer target' ? 500 : 60,
          peerGrowing: fault == 'peer buffer growing',
          audioLoss: fault == 'audio loss' ? n : 0,
          audioDrops: fault == 'audio drops' ? n : 0,
          decoder: fault == 'cached decoder ACK' ? _decoder(1) : null,
          extra: {
            ...videoTiming(),
            if (fault == 'partial receiver reports')
              'video_delivery_peers': {'p': _decoder(n), 'q': _decoder(n)},
            if (fault == 'missing decoder reports')
              'video_delivery_peers': <String, dynamic>{},
            if (fault == 'unknown video RTT') 'video_feedback_rtt_ms': 0,
            if (fault == 'missing video RR') 'video_feedback_reports': 0,
            if (fault == 'video worker stalled') 'video_worker_stalled': 1,
            if (fault == 'audio worker stalled') 'worker_stalled': 1,
            if (fault == 'missing route epoch') 'audio_rtt_route_epoch': null,
            if (fault == 'different route epoch') 'video_rtt_route_epoch': 1,
            if (fault == 'receive outage') 'audio_rx_native_age_ms': 1500,
            if (fault == 'video loss') 'video_feedback_loss_pct': 20,
            if (fault == 'audio jitter' || fault == 'severe audio RTT')
              'audio_feedback_reports': 1,
            if (fault == 'audio jitter') 'tx_jitter_ms': 90,
            if (fault == 'severe audio RTT') 'rtt_ms': 2000,
          },
        );
        expect(
          a.acknowledgedTarget!.maxFps,
          lessThanOrEqualTo(1),
          reason: fault,
        );
      }
    });
  }

  CallBitrateAdapter highBaseline() {
    final a = CallBitrateAdapter(baseBitrateKbps: 900, baseFps: 60);
    a.applyPendingTarget((_) => true);
    a.applyPendingPause((_) => true);
    _sample(a, 1, rtt: 420);
    _sample(a, 2, rtt: 420);
    return a;
  }

  test('a healthy high-baseline route earns bounded causal probes', () {
    final a = highBaseline();
    expect(a.acknowledgedTarget, (maxBitrateKbps: 19, maxFps: 1.25));
    _sample(a, 3, rtt: 450);
    expect(a.acknowledgedTarget, (maxBitrateKbps: 24, maxFps: 1.5625));
    _sample(a, 4, rtt: 410);
    expect(a.acknowledgedTarget, (maxBitrateKbps: 30, maxFps: 1.953125));
  });

  for (final failure in [
    'cached decoder',
    'unknown audio',
    'buffer growth',
    'loss',
    'queueing above baseline',
    'multi-second RTT',
  ]) {
    test('a high-baseline probe still refuses $failure', () {
      final a = highBaseline();
      final before = a.acknowledgedTarget!;
      for (var n = 3; n <= 7; n++) {
        _sample(
          a,
          n,
          rtt: failure == 'multi-second RTT'
              ? 2000
              : failure == 'queueing above baseline'
              ? 700
              : 420,
          peerDelay: failure == 'unknown audio' ? null : 60,
          peerGrowing: failure == 'buffer growth',
          loss: failure == 'loss' ? 1 : 0,
          decoder: failure == 'cached decoder' ? _decoder(2) : null,
        );
      }
      expect(a.acknowledgedTarget!.maxFps, lessThanOrEqualTo(before.maxFps));
      expect(
        a.acknowledgedTarget!.maxBitrateKbps,
        lessThanOrEqualTo(before.maxBitrateKbps),
      );
    });
  }

  test('a cautious sparse probe cannot double cadence from one FPS', () {
    final a = CallBitrateAdapter(baseBitrateKbps: 900, baseFps: 60);
    a.applyPendingTarget((_) => true);
    a.applyPendingPause((_) => true);
    _sample(a, 1, rtt: 100);
    _sample(a, 2);
    expect(a.acknowledgedTarget, (maxBitrateKbps: 19, maxFps: 1.25));
  });

  test('engines without causal delivery telemetry retain their RTT gate', () {
    final a = CallBitrateAdapter(
      baseBitrateKbps: 900,
      baseFps: 60,
      supportsLowRateVideo: false,
    );
    a.applyPendingTarget((_) => true);
    a.applyPendingPause((_) => true);
    final before = a.acknowledgedTarget;
    _sample(a, 1, rtt: 100);
    for (var n = 2; n <= 7; n++) {
      _sample(a, n);
    }
    expect(a.acknowledgedTarget, before);
  });

  test('cautious RTT decoder probes preserve a live healthy audio path', () {
    final a = _started();
    _sample(a, 3);
    expect(a.acknowledgedTarget, (maxBitrateKbps: 38, maxFps: 2.5));

    for (var n = 4; n <= 6; n++) {
      _sample(a, n, decoder: _decoder(3));
    }
    expect(
      a.acknowledgedTarget,
      (maxBitrateKbps: 38, maxFps: 2.5),
      reason: 'a timer and cached pre-probe frames cannot fund another probe',
    );
    _sample(a, 7);
    expect(a.acknowledgedTarget, (maxBitrateKbps: 48, maxFps: 3.125));
    _sample(a, 8, rtt: 100);
    expect(
      a.acknowledgedTarget,
      (maxBitrateKbps: 96, maxFps: 6.25),
      reason: 'fresh healthy RTT restores the ordinary acknowledged startup',
    );
  });

  test('fresh causal RTT ACKs fund one bounded step per observation', () {
    final a = _started();
    _sample(a, 3);
    expect(a.acknowledgedTarget, (maxBitrateKbps: 38, maxFps: 2.5));
    _sample(a, 4);
    expect(a.acknowledgedTarget, (maxBitrateKbps: 48, maxFps: 3.125));
    _sample(a, 5);
    expect(a.acknowledgedTarget, (maxBitrateKbps: 60, maxFps: 3.90625));
  });

  test('a busy native worker cannot spend or bank a cautious probe', () {
    final a = _started();
    _sample(a, 3, apply: false);
    expect(a.applyPendingTarget((_) => false), isFalse);
    expect(a.acknowledgedTarget, (maxBitrateKbps: 30, maxFps: 2.0));
    _sample(a, 4, peerDelay: null);
    expect(a.acknowledgedTarget, (maxBitrateKbps: 30, maxFps: 2.0));
    _sample(a, 5);
    expect(a.acknowledgedTarget, (maxBitrateKbps: 38, maxFps: 2.5));
  });

  test('a rising local buffer withholds probes below the hard ceiling', () {
    final a = _started();
    final before = a.acknowledgedTarget;
    for (var n = 3; n <= 5; n++) {
      _sample(a, n, receiveDelay: 20 * n + 20, sourcePressure: true);
    }
    _sample(a, 6, receiveDelay: 140);
    expect(a.acknowledgedTarget, before);
    _sample(a, 7, receiveDelay: 150);
    expect(a.acknowledgedTarget, before);
  });

  test('a fresh receiver growth verdict withholds a cautious probe', () {
    final a = _started();
    final before = a.acknowledgedTarget!;
    for (var n = 3; n <= 7; n++) {
      _sample(a, n, peerGrowing: true);
      expect(a.acknowledgedTarget!.maxFps, lessThanOrEqualTo(before.maxFps));
    }
  });

  for (final failure in [
    'receive unknown',
    'peer unknown',
    'receive pressure',
    'peer pressure',
    'requested receive buffer',
    'requested peer buffer',
    'RTT failure',
    'reported loss',
    'fresh RTP loss',
    'audio admission drop',
    'source pressure',
    'camera off',
    'interruption',
    'worker stalled',
    'missing receiver',
    'cached decoder',
    'pre-probe decoder',
  ]) {
    test('RTT probe cannot bypass $failure', () {
      final a = _started();
      final before = a.acknowledgedTarget!;
      for (var n = 3; n <= 7; n++) {
        _sample(
          a,
          n,
          rtt: failure == 'RTT failure' ? 400 : 295,
          receiveDelay: failure == 'receive unknown'
              ? null
              : failure == 'receive pressure'
              ? 300
              : 60,
          peerDelay: failure == 'peer unknown'
              ? null
              : failure == 'peer pressure'
              ? 300
              : 60,
          receiveTarget: failure == 'requested receive buffer' ? 200 : 60,
          peerTarget: failure == 'requested peer buffer' ? 200 : 60,
          loss: failure == 'reported loss' ? 1 : 0,
          audioLoss: failure == 'fresh RTP loss' ? n * 1000000 : 0,
          audioDrops: failure == 'audio admission drop' ? n : 0,
          sourcePressure: failure == 'source pressure',
          videoExpected: failure != 'camera off',
          interrupted: failure == 'interruption',
          workerStalled: failure == 'worker stalled',
          expectedReceivers: failure == 'missing receiver' ? 2 : 1,
          decoder: failure == 'cached decoder'
              ? _decoder(2)
              : failure == 'pre-probe decoder'
              ? {..._decoder(n), 'timestamp': 2 * 90000}
              : null,
        );
      }
      expect(a.acknowledgedTarget!.maxFps, lessThanOrEqualTo(before.maxFps));
      expect(
        a.acknowledgedTarget!.maxBitrateKbps,
        lessThanOrEqualTo(before.maxBitrateKbps),
      );
    });
  }
}
