@Timeout(Duration(minutes: 20))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'device_process_fixture.dart';
import 'e2e_env.dart';
import 'multi_device_process_e2e_test.dart'
    show contactStatus, deviceInfo, introduceProcesses, linkProcesses;

Future<List<Map<String, dynamic>>> rows(
  ProcessDevice device,
  String peer,
  Set<String> baseline,
) async {
  final response = await device.checked(
    '/messages',
    query: {'peer': peer, 'limit': '1000'},
  );
  final messages = (response['messages'] as List)
      .map((row) => Map<String, dynamic>.from(row as Map))
      .toList();
  // The hook returns at most 1000 rows. Check total too, so an extra duplicate
  // outside that window cannot hide behind a complete-looking tail.
  expect(response['total'], lessThanOrEqualTo(1000 + baseline.length));
  return messages.where((row) => !baseline.contains(row['id'])).toList();
}

void main() {
  final gate = E2eGate.read();
  test(
    'isolated A/B/C: 1000 offline messages survive B crash and restart',
    () async {
      final fleet = await ProcessFleet.start(gate);
      addTearDown(fleet.dispose);
      final a = fleet.a, b = fleet.b, c = fleet.c;
      final evidence = Platform.environment['XVEIL_BACKLOG_EVIDENCE'];
      if (evidence != null) {
        await File('$evidence/fleet-private.json').writeAsString(
          jsonEncode({'root': fleet.root.path, 'runnerPid': pid}),
        );
      }
      final result = <String, Object?>{
        'devices': 3,
        'same_identity_devices': 2,
        'requested_messages': 1000,
        'separate_processes': true,
        'local_network_only': true,
        'production_fault_switch_added': false,
      };
      Future<void> save() async {
        if (evidence != null) {
          await File('$evidence/result.json').writeAsString(jsonEncode(result));
        }
      }

      try {
        await introduceProcesses(a, c);
        await linkProcesses(a, b);
        final ai = (await deviceInfo(a))['identity'] as String;
        final ci = (await deviceInfo(c))['identity'] as String;
        await waitUntil(
          () async => await contactStatus(b, ci) == 'accepted',
          what: 'B learns C contact before going offline',
        );
        // The accepted request already left its greeting in the conversation.
        final before = await a.checked('/messages', query: {'peer': ci});
        final baseline = {
          for (final row in before['messages'] as List) row['id'] as String,
        };
        expect(before['total'], baseline.length);
        result['baseline_rows'] = baseline.length;
        await b.stop();
        final sending = Stopwatch()..start();
        for (var i = 0; i < 1000; i++) {
          await a.checked(
            '/send_message',
            query: {
              'peer': ci,
              'text': 'backlog-${i.toString().padLeft(4, '0')}',
            },
          );
          if ((i + 1) % 100 == 0) {
            result['acknowledged_send_requests'] = i + 1;
            await save();
            E2eLog.line('BACKLOG_REQUESTS=${i + 1}');
          }
        }
        result['send_seconds'] = sending.elapsedMilliseconds / 1000;
        final original = await rows(a, ci, baseline);
        expect(original, hasLength(1000));
        final ids = original.map((m) => m['id']).toList();
        expect(ids.toSet(), hasLength(1000));
        final expectedBodies = {
          for (var i = 0; i < 1000; i++)
            'backlog-${i.toString().padLeft(4, '0')}',
        };
        expect(original.map((m) => m['body']).toSet(), expectedBodies);
        bool matches(List<Map<String, dynamic>> actual) =>
            actual.length == ids.length &&
            actual.map((m) => m['id']).join('|') == ids.join('|') &&
            actual.map((m) => m['body']).toSet().containsAll(expectedBodies);
        var cRows = <Map<String, dynamic>>[];
        await waitUntil(
          () async => matches(cRows = await rows(c, ai, baseline)),
          what: 'C receives all 1000 messages once in A order',
          describe: () => 'count=${cRows.length}',
          timeout: const Duration(minutes: 3),
        );
        result['c_rows_before_offline'] = cRows.length;
        await c.stop();
        result['c_offline_during_catchup'] = true;
        final catchup = Stopwatch()..start();
        await b.start();
        var partial = <Map<String, dynamic>>[];
        await waitUntil(
          () async => (partial = await rows(b, ci, baseline)).length >= 250,
          what: 'B receives at least 250 rows before interruption',
          describe: () => 'count=${partial.length}',
          interval: const Duration(milliseconds: 50),
          timeout: const Duration(minutes: 3),
        );
        result['rows_at_interrupt'] = partial.length;
        result['partial_catchup_observed'] = partial.length < 1000;
        await save();
        // A successful atomic/fast catch-up is not evidence of resuming a
        // partial one. Keep this distinction even if the scheduler misses it.
        E2eLog.line(
          partial.length < 1000
              ? 'BACKLOG_PARTIAL_CATCHUP_OBSERVED'
              : 'BACKLOG_CASE16_NOT_EXERCISED',
        );
        await b.stop(crash: true);
        await b.start();
        var bRows = <Map<String, dynamic>>[];
        await waitUntil(
          () async => matches(bRows = await rows(b, ci, baseline)),
          what:
              'restarted B recovers all 1000 IDs and their order with C offline',
          describe: () => 'count=${bRows.length}',
          timeout: const Duration(minutes: 5),
        );
        result['catchup_seconds_including_restart'] =
            catchup.elapsedMilliseconds / 1000;
        result['b_rows_after_recovery'] = bRows.length;
        result['same_order'] = matches(bRows);
        result['duplicate_ids'] =
            bRows.length - bRows.map((m) => m['id']).toSet().length;
        await a.stop();
        await b.restart();
        expect(matches(await rows(b, ci, baseline)), isTrue);
        result['retained_after_restart_without_other_devices'] = true;
        result['passed'] = true;
      } finally {
        await save();
      }
    },
    skip: gate.skip,
  );
}
