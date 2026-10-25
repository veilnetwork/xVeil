@Timeout(Duration(minutes: 7))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'device_process_fixture.dart';
import 'e2e_env.dart';
import 'multi_device_process_e2e_test.dart' as base;

void main() {
  final gate = E2eGate.read();
  test(
    'anonymous incoming calls reach siblings with and without the primary',
    () async {
      final fleet = await ProcessFleet.start(gate);
      addTearDown(fleet.dispose);
      final a = fleet.a, b = fleet.b, c = fleet.c;
      final evidence = Platform.environment['XVEIL_PEER_ECHO_EVIDENCE'];
      final result = <String, Object?>{
        'devices': 3,
        'same_identity_devices': 2,
        'anonymous': true,
        'explicit_c_b_join': false,
        'media_acceptance_tested': false,
        'passed': false,
      };
      if (evidence != null) {
        await File('$evidence/fleet-private.json').writeAsString(
          jsonEncode({'root': fleet.root.path, 'runnerPid': pid}),
        );
      }
      Future<String?> status(ProcessDevice device) async =>
          ((await device.checked('/call_state'))['call'] as Map?)?['status']
              as String?;
      Future<void> snapshot() async {
        if (evidence == null) return;
        await File('$evidence/calls-private.json').writeAsString(
          jsonEncode({
            for (final device in [b, c])
              device.label: await device.checked('/call_state'),
          }),
        );
      }

      try {
        await base.introduceProcesses(a, c);
        final ai = (await base.deviceInfo(a))['identity'] as String;
        await base.linkProcesses(a, b);
        var watch = Stopwatch()..start();
        await c.checked('/call_place', query: {'peer': ai});
        await waitUntil(
          () async =>
              await status(a) == 'ringing' && await status(b) == 'ringing',
          what: 'C rings both anonymous online devices of X',
          describe: () async =>
              'A=${await status(a)}, B=${await status(b)}, C=${await status(c)}',
          timeout: const Duration(seconds: 60),
        );
        result['both_online_ring_ms'] = watch.elapsedMilliseconds;
        await c.checked('/call_hangup');
        await waitUntil(
          () async =>
              await status(a) != 'ringing' && await status(b) != 'ringing',
          what: 'caller cancellation silences both devices',
          timeout: const Duration(seconds: 25),
          describe: () async => 'A=${await status(a)}, B=${await status(b)}',
        );
        result['both_online_cancellation'] = true;
        await a.stop();
        watch = Stopwatch()..start();
        await c.checked('/call_place', query: {'peer': ai});
        await waitUntil(
          () async => await status(b) == 'ringing',
          what: 'C rings anonymous B while A is offline',
          describe: () async => 'B=${await status(b)}, C=${await status(c)}',
          timeout: const Duration(seconds: 45),
        );
        result['a_offline_b_ring_ms'] = watch.elapsedMilliseconds;
        await c.checked('/call_hangup');
        await waitUntil(
          () async => await status(b) != 'ringing',
          what: 'caller cancellation silences B without A',
          timeout: const Duration(seconds: 25),
          describe: () async => 'B=${await status(b)}',
        );
        result['a_offline_b_cancellation'] = true;
        result['passed'] = true;
      } finally {
        await snapshot();
        if (evidence != null) {
          await File('$evidence/result.json').writeAsString(jsonEncode(result));
        }
      }
    },
    skip: gate.enabled && Platform.environment['XVEIL_E2E_ANONYMOUS'] != '1'
        ? 'requires XVEIL_E2E_ANONYMOUS=1'
        : gate.skip,
  );
}
