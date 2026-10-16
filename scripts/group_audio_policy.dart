// Process-isolated fixture bridge to the production group Opus policy.
// Decisions use native room feedback; decoded measurement tones are not input.
import 'dart:convert';
import 'dart:io';

import 'package:xveil/state/group_call_audio_adapter.dart';

Future<void> main() async {
  final policy = GroupCallAudioAdapter();
  stdout.writeln('{"ready":true}');
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final request = (jsonDecode(line) as Map).cast<String, dynamic>();
    final now = DateTime.fromMillisecondsSinceEpoch(request['now'] as int);
    if (request['op'] == 'ack') {
      policy.applyPending((_) => request['ok'] == true, now);
    } else if (request['op'] == 'poll') {
      policy.observe(
        (request['stats'] as Map).cast<String, dynamic>(),
        now,
        expectedPeers: request['expectedPeers'] as int,
        sending: true,
        receiving: true,
      );
    }
    stdout.writeln(
      jsonEncode({
        'pending': policy.pending,
        'level': policy.level,
        'packet_ms': policy.target.packetMs,
        'payload_bps': policy.target.payloadBps,
      }),
    );
  }
}
