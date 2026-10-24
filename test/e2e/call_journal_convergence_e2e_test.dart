@Timeout(Duration(minutes: 12))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'device_process_fixture.dart';
import 'e2e_env.dart';
import 'multi_device_process_e2e_test.dart'
    show deviceInfo, introduceProcesses, linkProcesses;

void main() {
  final gate = E2eGate.read();
  test(
    'independent call journals converge after offline writes and restart',
    () async {
      final fleet = await ProcessFleet.start(gate);
      addTearDown(fleet.dispose);
      final evidence = Platform.environment['XVEIL_CALL_JOURNAL_EVIDENCE'];
      if (evidence != null) {
        await File('$evidence/fleet-private.json').writeAsString(
          jsonEncode({'root': fleet.root.path, 'runnerPid': pid}),
        );
      }
      final a = fleet.a, b = fleet.b, c = fleet.c;
      await introduceProcesses(a, c);
      await linkProcesses(a, b);
      final peer = (await deviceInfo(c))['identity'] as String;
      const shared = 'journal-offline-same-call';
      Future<List<Map<String, dynamic>>> journal(
        ProcessDevice d,
        String id,
      ) async {
        final rows = (await d.checked('/call_log'))['entries'] as List;
        return rows
            .map((e) => Map<String, dynamic>.from(e as Map))
            .where((e) => e['id'] == id)
            .toList();
      }

      Future<Map<String, dynamic>?> folded(ProcessDevice d, String id) async {
        final events = (await d.checked('/device_events'))['events'] as Map;
        final row = events['callLog|$id'] as Map?;
        return row == null
            ? null
            : Map<String, dynamic>.from(row['payload'] as Map);
      }

      await b.stop();
      await a.checked(
        '/call_log_add',
        query: {'id': shared, 'peer': peer, 'outcome': 'completed', 'dur': '0'},
      );
      await a.stop();
      await b.start();
      await b.checked(
        '/call_log_add',
        query: {
          'id': shared,
          'peer': peer,
          'outcome': 'completed',
          'dur': '75',
        },
      );
      await a.start();
      await waitUntil(
        () async =>
            (await folded(a, shared))?['dur'] == 75 &&
            (await folded(b, shared))?['dur'] == 75,
        what: 'both encrypted device logs contain the final duration',
      );
      var local = await journal(a, shared), remote = await journal(b, shared);
      var converged = false;
      try {
        await waitUntil(
          () async {
            local = await journal(a, shared);
            remote = await journal(b, shared);
            return local.length == 1 &&
                remote.length == 1 &&
                local.single['dur'] == 75 &&
                remote.single['dur'] == 75 &&
                jsonEncode(local.single) == jsonEncode(remote.single);
          },
          what: 'visible call journals converge to one final row',
          describe: () =>
              'A duration=${local.singleOrNull?['dur'] ?? 0}, '
              'B duration=${remote.singleOrNull?['dur'] ?? 0}',
          timeout: const Duration(seconds: 12),
        );
        converged = true;
      } finally {
        if (evidence != null) {
          await File('$evidence/offline-result.json').writeAsString(
            jsonEncode({
              'device_logs_converged': true,
              'visible_journals_converged': converged,
              'A_duration_seconds': local.singleOrNull?['dur'] ?? 0,
              'B_duration_seconds': remote.singleOrNull?['dur'] ?? 0,
              'A_rows': local.length,
              'B_rows': remote.length,
            }),
          );
        }
      }
      await b.stop();
      await a.stop();
      await a.start();
      await b.start();
      expect(await journal(a, shared), await journal(b, shared));
      expect((await journal(a, shared)).single['dur'], 75);

      // The existing generic device-event API supplies the sibling's early
      // record. No new production hook, media engine or OS-clock change is used.
      const failed = 'journal-final-setup-failure';
      final earlyAt = DateTime.now().millisecondsSinceEpoch + 120000;
      await a.checked(
        '/device_post_event',
        query: {
          'kind': 'callLog',
          'key': failed,
          'p': jsonEncode({
            'id': failed,
            'peer': peer,
            'out': false,
            'vid': false,
            'o': 'completed',
            'at': earlyAt,
            'provisional': true,
          }),
        },
      );
      await waitUntil(
        () async =>
            (await journal(b, failed)).singleOrNull?['provisional'] == true,
        what: 'B receives the signed provisional call record',
      );
      await b.checked(
        '/call_log_add',
        query: {'id': failed, 'peer': peer, 'outcome': 'failed', 'dur': '0'},
      );
      await waitUntil(
        () async =>
            (await folded(a, failed))?['o'] == 'failed' &&
            (await folded(b, failed))?['o'] == 'failed' &&
            (await journal(a, failed)).singleOrNull?['o'] == 'failed' &&
            (await journal(b, failed)).singleOrNull?['o'] == 'failed',
        what:
            'the actual failed endpoint supersedes a future-dated placeholder',
      );
      final failedA = await journal(a, failed),
          failedB = await journal(b, failed);
      expect(failedA, failedB);
      expect(failedA.single['provisional'], isNull);
      if (evidence != null) {
        await File('$evidence/result.json').writeAsString(
          jsonEncode({
            'devices': 3,
            'same_identity_devices': 2,
            'offline_first_writers_converged': true,
            'final_duration_seconds': 75,
            'rows_per_call': 1,
            'process_restart_preserved_result': true,
            'future_placeholder_offset_ms': 120000,
            'final_failure_won_device_fold': true,
            'final_failure_won_both_visible_journals': true,
            'new_debug_hooks_added': false,
            'media_started': false,
          }),
        );
      }
    },
    skip: gate.skip,
  );
}
