import 'dart:convert';
import 'dart:io';
import 'package:xveil/state/call_bitrate_adapter.dart';
import 'package:xveil/state/call_audio_receive_activity.dart';
import 'package:xveil/state/call_peer_audio_playout.dart';
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
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final req = jsonDecode(line) as Map<String, dynamic>;
    final i = req['index'] as int;
    final a = adapters[i];
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
      sendAudioExpected: true,
      requireAudioReceivePlayout: true,
      receiveAudioExpected: true,
      peerAudioDelayMs: peer[i].delayMs(now),
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
        'feedback': activity[i].playoutFeedback(now).toJson(),
        'pause': pause,
        'budget': budget,
        'target': {'kbps': target.maxBitrateKbps, 'fps': target.maxFps},
        'audioReserve': a.audioReserve,
        'peerDelay': peer[i].delayMs(now),
      }),
    );
  }
}
