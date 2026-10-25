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
    'anonymous sibling adopts the device group after identity replacement',
    () async {
      final fleet = await ProcessFleet.start(gate, labels: ['A', 'B']);
      addTearDown(fleet.dispose);
      final evidence = Platform.environment['XVEIL_PEER_ECHO_EVIDENCE'];
      final result = <String, Object?>{
        'devices': 2,
        'anonymous': true,
        'passed': false,
      };
      if (evidence != null) {
        await File('$evidence/fleet-private.json').writeAsString(
          jsonEncode({'root': fleet.root.path, 'runnerPid': pid}),
        );
      }
      Future<void> snapshot(String stage) async {
        if (evidence == null) return;
        final state = <String, Object?>{};
        for (final device in [fleet.a, fleet.b]) {
          state[device.label] = {
            'info': await base.deviceInfo(device),
            'devices': await device.checked('/devices'),
            'dht': await device.admin(gate.veilCli!, ['node', 'dht', 'list']),
          };
        }
        // Public signed ads still identify endpoints; keep them private.
        await File(
          '$evidence/ads-$stage-private.json',
        ).writeAsString(jsonEncode(state));
      }

      try {
        await snapshot('before');
        await base.linkProcesses(
          fleet.a,
          fleet.b,
          afterSnapshotSent: () => snapshot('after-restart'),
        );
        await snapshot('adopted');
        result['passed'] = true;
      } catch (_) {
        await snapshot('failed');
        rethrow;
      } finally {
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
