import 'dart:convert';
import 'dart:io';
import 'package:xveil/state/call_bitrate_adapter.dart';
import 'package:xveil/state/call_audio_receive_activity.dart';
import 'package:xveil/state/call_peer_audio_playout.dart';
import 'package:xveil/state/call_audio_source_pressure.dart';
import 'package:xveil/state/call_audio_feedback_schedule.dart';
import 'package:xveil/domain/call_signal.dart';

Future<void> main() async {
  final adapters = List.generate(
    2,
    (_) => CallBitrateAdapter(
      baseBitrateKbps: 900,
      baseFps: 15,
      supportsLowRateVideo: true,
    ),
  );
  final activity = List.generate(2, (_) => CallAudioReceiveActivity());
  final peer = List.generate(2, (_) => CallPeerAudioPlayout());
  final sourcePressure = List.generate(2, (_) => CallAudioSourcePressure());
  final feedbackSchedule = List.generate(2, (_) => CallAudioFeedbackSchedule());
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final req = jsonDecode(line) as Map<String, dynamic>;
    final i = req['index'] as int;
    final a = adapters[i];
    if (req['op'] == 'feedbackAttempt') {
      feedbackSchedule[i].recordAttempt(
        CallAudioPlayoutFeedback.fromJson(req['feedback']),
        DateTime.fromMillisecondsSinceEpoch(req['now'] as int),
      );
      stdout.writeln('{}');
      continue;
    }
    if (req['op'] == 'ack') {
      a.applyPendingPause((_) => req['pauseOk'] == true);
      a.applyPendingTarget((_) => req['budgetOk'] == true);
      stdout.writeln('{}');
      continue;
    }
    final now = DateTime.fromMillisecondsSinceEpoch(req['now'] as int);
    for (final row in req['feedback'] as List) {
      final f = CallAudioPlayoutFeedback.fromJson(row['value']);
      if (f != null) {
        peer[i].observe(
          f,
          DateTime.fromMillisecondsSinceEpoch(row['at'] as int),
        );
      }
    }
    final stats = (req['stats'] as Map).cast<String, dynamic>();
    activity[i].observe(stats, now);
    final peerInterrupted = peer[i].takeInterruption();
    final interrupted = activity[i].interrupted || peerInterrupted;
    final sourcePressured = sourcePressure[i].observe(
      sendExpected: true,
      receiveExpected: true,
      requirePeerPlayout: true,
      peerDelayMs: peer[i].delayMs(now),
      peerCurrentDelayMs: peer[i].currentDelayMs(now),
      peerSampleSequence: peer[i].sampleSequence,
      peerBufferGrowing: peer[i].bufferGrowing(now),
      receiveDelayMs: activity[i].playoutFeedback(now).delayMs,
      receiveAgeMs: activity[i].lastRxAt == null
          ? null
          : now.difference(activity[i].lastRxAt!).inMilliseconds,
      interrupted: interrupted,
      audioTxDrops: stats['audio_tx_rtp_drops'] is int
          ? stats['audio_tx_rtp_drops'] as int
          : null,
    );
    if (req['prepare'] == true) {
      a.prepareVideoSend(
        stats,
        sendAudioExpected: true,
        requireAudioReceivePlayout: true,
        receiveAudioExpected: true,
        peerAudioDelayMs: peer[i].delayMs(now),
        requirePeerAudioPlayout: true,
        audioInterrupted: interrupted,
      );
    }
    a.onNativeStats(
      stats,
      videoSendExpected: req['videoSendExpected'] == true,
      sendAudioExpected: true,
      requireAudioReceivePlayout: true,
      receiveAudioExpected: true,
      peerAudioDelayMs: peer[i].delayMs(now),
      peerCurrentAudioDelayMs: peer[i].currentDelayMs(now),
      peerAudioSampleSequence: peer[i].sampleSequence,
      peerAudioBufferGrowing: peer[i].bufferGrowing(now),
      requirePeerAudioPlayout: true,
      audioInterrupted: interrupted,
    );
    final target = a.target;
    bool? pause;
    Map<String, Object>? budget;
    a.applyPendingPause((v) {
      pause = v;
      return false;
    });
    a.applyPendingTarget((v) {
      budget = {'kbps': v.maxBitrateKbps, 'fps': v.maxFps};
      return false;
    });
    stdout.writeln(
      jsonEncode({
        'feedback': activity[i].outgoingPlayoutFeedback(now).toJson(),
        'urgentFeedback': feedbackSchedule[i].shouldSendUrgent(
          activity[i].outgoingPlayoutFeedback(now),
          now,
        ),
        'feedbackRecentlyAttempted': feedbackSchedule[i].attemptedRecently(now),
        'pause': pause,
        'budget': budget,
        'target': {'kbps': target.maxBitrateKbps, 'fps': target.maxFps},
        'audioReserve': a.audioReserve,
        'peerDelay': peer[i].delayMs(now),
        'peerCurrentDelay': peer[i].currentDelayMs(now),
        'peerSampleSequence': peer[i].sampleSequence,
        'peerBufferGrowing': peer[i].bufferGrowing(now),
        'sourcePressured': sourcePressured,
      }),
    );
  }
}
