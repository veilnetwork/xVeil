// Process-isolated fixture bridge to the production group Opus policy.
// Decisions use native room feedback; decoded measurement tones are not input.
import 'dart:convert';
import 'dart:io';

import 'package:xveil/state/group_call_audio_adapter.dart';
import 'group_codec_policy.dart' show RoomPolicy;

Future<void> main() async {
  final policy = GroupCallAudioAdapter();
  final room = RoomPolicy();
  stdout.writeln('{"ready":true}');
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final request = (jsonDecode(line) as Map).cast<String, dynamic>();
    final now = DateTime.fromMillisecondsSinceEpoch(request['now'] as int);
    if (request['op'] == 'ack') {
      policy.applyPending((_) => request['ok'] == true, now);
    } else if (request['op'] == 'videoAck') {
      if (request['budgetOk'] == false) {
        room.adapter.invalidateAppliedState();
      } else {
        room.adapter.applyPendingTarget((_) => true);
        room.adapter.applyPendingPause((_) => request['pauseOk'] == true);
        final target = room.adapter.acknowledgedTarget;
        if (target != null && target.maxFps <= 1) {
          room.sourcePriority.acknowledgeFloor(now);
        }
        final paused = room.adapter.acknowledgedPause;
        if (paused != null) room.sourcePriority.acknowledgePause(paused, now);
      }
    } else if (request['op'] == 'poll') {
      room.sourcePriority.observe(
        (request['stats'] as Map).cast<String, dynamic>(),
        now,
        videoExpected: request['video'] == true || request['prepare'] == true,
        appliedAudioMs: policy.applied?.packetMs,
        expectedPeers: request['expectedPeers'] as int,
        audioSending: true,
      );
      policy.observe(
        (request['stats'] as Map).cast<String, dynamic>(),
        now,
        expectedPeers: request['expectedPeers'] as int,
        sending: true,
        receiving: true,
        secondaryYielded: room.sourcePriority.yielded,
      );
      if (policy.needsSecondaryYield) {
        room.sourcePriority.requestYield(
          now,
          transient: policy.secondaryYieldTransient,
        );
      }
      room.adapter.constrainSource(
        floor: room.sourcePriority.floor,
        paused: room.sourcePriority.paused,
      );
      final target = room.adapter.acknowledgedTarget;
      if (target != null && target.maxFps <= 1) {
        room.sourcePriority.acknowledgeFloor(now);
      }
      if (room.adapter.acknowledgedPause == true) {
        room.sourcePriority.acknowledgePause(true, now);
      }
    }
    stdout.writeln(
      jsonEncode({
        'pending': policy.pending,
        'level': policy.level,
        'packet_ms': policy.target.packetMs,
        'payload_bps': policy.target.payloadBps,
        'needs_secondary_yield': policy.needsSecondaryYield,
        'secondary_yield_transient': policy.secondaryYieldTransient,
        if (request['op'] == 'poll' && request['load'] == true)
          'video_policy': room.poll(request),
      }),
    );
  }
}
