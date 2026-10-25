@Timeout(Duration(minutes: 8))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'device_fixture.dart' show E2eIdentity;
import 'device_process_fixture.dart';
import 'e2e_env.dart';
import 'multi_device_process_e2e_test.dart' as base;

void main() {
  final gate = E2eGate.read();
  test(
    'anonymous C reaches the linked sibling without a direct C-B session',
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
        'passed': false,
      };
      if (evidence != null) {
        await File('$evidence/fleet-private.json').writeAsString(
          jsonEncode({'root': fleet.root.path, 'runnerPid': pid}),
        );
      }
      Future<void> snapshot(String stage) async {
        if (evidence == null) return;
        final states = <String, Object?>{};
        for (final device in [b, c]) {
          states[device.label] = {
            'info': await base.deviceInfo(device),
            'devices': await device.checked('/devices'),
            'contacts': await device.checked('/contacts'),
            'dht': await device.admin(gate.veilCli!, ['node', 'dht', 'list']),
          };
        }
        await File(
          '$evidence/$stage-private.json',
        ).writeAsString(jsonEncode(states));
      }

      Future<int> copies(
        ProcessDevice device,
        String peer,
        String text,
      ) async => (await base.rows(
        device,
        peer,
      )).where((row) => row['body'] == text).length;

      try {
        await base.introduceProcesses(a, c);
        final ai = (await base.deviceInfo(a))['identity'] as String;
        final ci = (await base.deviceInfo(c))['identity'] as String;
        await base.linkProcesses(a, b);
        await a.stop();
        await snapshot('before-first-send');

        const first = 'onion-family-only-sibling';
        final firstDelivery = Stopwatch()..start();
        await c.checked('/send_message', query: {'peer': ai, 'text': first});
        await base.hasBody(b, ci, first);
        result['a_offline_b_receives'] = true;
        result['first_delivery_ms'] = firstDelivery.elapsedMilliseconds;
        await snapshot('sibling-received');

        await a.start();
        await base.join(a, c);
        await base.join(c, a);
        const second = 'onion-family-both-online';
        final secondDelivery = Stopwatch()..start();
        await c.checked('/send_message', query: {'peer': ai, 'text': second});
        await waitUntil(
          () async =>
              await copies(a, ci, second) == 1 &&
              await copies(b, ci, second) == 1,
          what: 'C message appears exactly once on both online devices',
          describe: () async =>
              'A=${await copies(a, ci, second)}, B=${await copies(b, ci, second)}',
          timeout: const Duration(minutes: 3),
        );
        result['both_online_receive_once'] = true;
        result['both_online_delivery_ms'] = secondDelivery.elapsedMilliseconds;
        await b.restart();
        expect(await copies(b, ci, first), 1);
        expect(await copies(b, ci, second), 1);
        result['cold_reopen_preserves_messages'] = true;
        final oldDevice = (await base.deviceInfo(b))['nodeId'] as String;
        await b.stop();
        await c.stop();
        final revoked = await a.checked(
          '/device_revoke',
          query: {'peer': oldDevice},
          body: E2eIdentity.x.phrase,
        );
        expect(revoked['docRevoked'], isTrue);
        await b.start();
        await c.start();
        expect((await base.deviceInfo(b))['nodeId'], oldDevice);
        const afterRevoke = 'onion-family-after-revoke';
        await c.checked(
          '/send_message',
          query: {'peer': ai, 'text': afterRevoke},
        );
        await base.hasBody(a, ci, afterRevoke);
        final observed = Stopwatch()..start();
        while (observed.elapsed < const Duration(seconds: 20)) {
          expect(
            await copies(b, ci, afterRevoke),
            0,
            reason: 'revoked B must not receive new identity traffic',
          );
          await Future<void>.delayed(const Duration(seconds: 1));
        }
        result['stale_c_reconnect_delivers_only_to_active_device'] = true;
        result['revoked_device_observation_ms'] = observed.elapsedMilliseconds;
        await snapshot('after-revoke');
        result['logical_duplicates'] = 0;
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
