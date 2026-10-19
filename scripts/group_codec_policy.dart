// Pure fixture bridge to the production group audio/video policy classes.
// Native room stats supply the same worst-listener/receiver aggregation as
// VeilGroupCallMediaController. No measurement tone or PCM drives the policy.
import 'dart:convert';
import 'dart:io';
import 'package:xveil/state/call_audio_receive_activity.dart';
import 'package:xveil/state/call_audio_source_pressure.dart';
import 'package:xveil/state/call_bitrate_adapter.dart';
import 'package:xveil/state/group_call_source_priority.dart';

int? measured(Object? value) =>
    value is num && value.isFinite && value >= 0 && value <= 60000
    ? value.toInt()
    : null;

class RoomPolicy {
  final sourcePriority = GroupCallSourcePriority();
  final adapter = CallBitrateAdapter(
    baseBitrateKbps: 150,
    baseFps: 15,
    supportsLowRateVideo: true,
  );
  final source = CallAudioSourcePressure();
  final incoming = <String, CallAudioReceiveActivity>{};
  int? recoveries;
  int playoutPeers = 0;

  Map<String, Object?> poll(Map<String, dynamic> request) {
    final stats = (request['stats'] as Map).cast<String, dynamic>();
    final peers = (request['peers'] as List).cast<String>();
    final now = DateTime.fromMillisecondsSinceEpoch(request['now'] as int);
    final receivers = stats['audio_receivers'];
    var complete = stats['worker_stalled'] == 0;
    var delay = 0, age = 0;
    var interrupted = false;
    for (final peer in peers) {
      final receiver = receivers is Map ? receivers[peer] : null;
      final activity = incoming.putIfAbsent(peer, CallAudioReceiveActivity.new);
      activity.observe({
        'worker_stalled': stats['worker_stalled'],
        if (receiver is Map) ...{
          'audio_rx_pkts': receiver['audio_rx_pkts'],
          'audio_delay_ms': receiver['audio_delay_ms'],
          'audio_pressure_delay_ms': receiver['audio_pressure_delay_ms'],
          'audio_rx_native_age_ms': receiver['audio_rx_native_age_ms'],
          'audio_interruption_count': receiver['audio_interruption_count'],
        },
      }, now);
      interrupted |= activity.interrupted;
      final packets = receiver is Map ? receiver['audio_rx_pkts'] : null;
      final d = receiver is Map
          ? CallAudioReceiveActivity.nativePlayoutDelay({
              'worker_stalled': stats['worker_stalled'],
              'audio_rx_pkts': receiver['audio_rx_pkts'],
              'audio_delay_ms': receiver['audio_delay_ms'],
              'audio_pressure_delay_ms': receiver['audio_pressure_delay_ms'],
            })
          : null;
      final a = receiver is Map
          ? measured(receiver['audio_rx_native_age_ms'])
          : null;
      if (packets is! num || packets <= 0 || d == null || a == null) {
        complete = false;
      } else {
        if (d > delay) delay = d;
        if (a > age) age = a;
      }
    }
    final receiveDelay = complete || delay >= 200 ? delay : null;
    final receiveAge = complete || age >= 2000 ? age : null;
    final count = stats['audio_latency_recovery_count'];
    var recovered = false;
    if (stats['worker_stalled'] == 0 && count is int && count >= 0) {
      recovered = recoveries != null && count > recoveries!;
      recoveries = count;
    }
    final supported = stats['audio_playout_peers'];
    if (supported is int && supported >= 0) playoutPeers = supported;
    final reports = stats['audio_playout_reports'];
    final peerValue = measured(stats['audio_playout_ms']);
    final peerDelay =
        playoutPeers > 0 &&
            reports is num &&
            reports > 0 &&
            peerValue != null &&
            (reports >= playoutPeers || peerValue >= 200)
        ? peerValue
        : null;
    final sourcePeerDelay =
        reports is num && reports >= peers.length ||
            (peerDelay != null && peerDelay >= 200)
        ? peerDelay
        : null;
    final sequence = stats['audio_playout_sequence'];
    final peerSequence = sequence is int && sequence >= 0 ? sequence : null;
    final measuredPressure = source.observe(
      sendExpected: true,
      receiveExpected: true,
      requirePeerPlayout: true,
      peerDelayMs: sourcePeerDelay,
      peerCurrentDelayMs: sourcePeerDelay,
      peerSampleSequence: peerSequence,
      peerBufferGrowing: peerSequence == null ? false : null,
      receiveDelayMs: receiveDelay,
      receiveAgeMs: receiveAge,
      interrupted: interrupted,
      recovered: recovered,
      audioTxDrops: stats['audio_tx_rtp_drops'] is int
          ? stats['audio_tx_rtp_drops'] as int
          : null,
      audioLossReportUs: stats['audio_loss_report_us'],
      peerAudioRecoveryReportUs: stats['audio_peer_recovery_report_us'],
      peerAudioConcealmentReportUs: stats['audio_peer_concealment_report_us'],
    );
    final pressured = sourcePriority.floor ? true : measuredPressure;
    if (request['prepare'] == true) {
      adapter.prepareVideoSend(
        stats,
        sendAudioExpected: true,
        receiveAudioExpected: true,
        requireAudioReceivePlayout: true,
        audioReceiveDelayMs: receiveDelay,
        audioReceiveQuality: (expected: true, ageMs: receiveAge),
        audioInterrupted: interrupted,
        peerAudioDelayMs: peerDelay,
        requirePeerAudioPlayout: playoutPeers > 0,
      );
    } else if (request['video'] == true) {
      adapter.onNativeStats(
        stats,
        sampledAt: now,
        sourceBudgetPressured:
            request['sourceFeedbackQueued'] == true && pressured == true,
        videoSendExpected: true,
        sendAudioExpected: true,
        receiveAudioExpected: true,
        requireAudioReceivePlayout: true,
        audioReceiveDelayMs: receiveDelay,
        audioReceiveQuality: (expected: true, ageMs: receiveAge),
        audioInterrupted: interrupted,
        audioRecoveryObserved: recovered,
        peerAudioDelayMs: peerDelay,
        peerCurrentAudioDelayMs: peerDelay,
        peerAudioSampleSequence: peerSequence,
        peerAudioBufferGrowing: peerSequence == null ? false : null,
        requirePeerAudioPlayout: playoutPeers > 0,
        expectedVideoFeedbackReports: peers.length,
        expectedAudioFeedbackReports: peers.length,
      );
    }
    bool? pause;
    Map<String, Object>? budget;
    adapter.applyPendingPause((value) {
      pause = value;
      return false;
    });
    adapter.applyPendingTarget((value) {
      budget = {'kbps': value.maxBitrateKbps, 'fps': value.maxFps};
      return false;
    });
    return {
      'sourcePressured': pressured,
      'sourceBudgetPressured':
          request['sourceFeedbackQueued'] == true && pressured == true,
      'pause': pause,
      'budget': budget,
      'target': {
        'kbps': adapter.target.maxBitrateKbps,
        'fps': adapter.target.maxFps,
      },
      'audioReserve': adapter.audioReserve,
      'sourcePriority': sourcePriority.diagnostics,
      'audioAdaptation': adapter.bufferDiagnostics,
    };
  }
}

Future<void> main() async {
  final rooms = List.generate(3, (_) => RoomPolicy());
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final request = (jsonDecode(line) as Map).cast<String, dynamic>();
    final room = rooms[request['index'] as int];
    if (request['op'] == 'ack') {
      room.adapter.applyPendingPause((_) => request['pauseOk'] == true);
      room.adapter.applyPendingTarget((_) => request['budgetOk'] == true);
      stdout.writeln('{}');
    } else {
      stdout.writeln(jsonEncode(room.poll(request)));
    }
  }
}
