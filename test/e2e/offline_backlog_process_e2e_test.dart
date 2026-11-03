@Timeout(Duration(minutes: 20))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'device_process_fixture.dart';
import 'e2e_env.dart';
import 'multi_device_process_e2e_test.dart'
    show contactStatus, deviceInfo, introduceProcesses, linkProcesses;

int _inspection = 0;

Future<List<Map<String, dynamic>>> rows(
  ProcessDevice device,
  String peer,
  Set<String> baseline,
) async {
  final nonce = 'backlog-${++_inspection}';
  final request = File('${device.dir.path}/storage-inspect.new');
  await request.writeAsString(
    jsonEncode({
      'nonce': nonce,
      'peer': peer,
      'prefix': '',
      'includeRows': true,
    }),
  );
  await request.rename('${device.dir.path}/storage-inspect.json');
  List<Map<String, dynamic>>? result;
  await waitUntil(
    () async {
      final file = File('${device.dir.path}/storage-inspected.json');
      if (!await file.exists()) return false;
      final response = jsonDecode(await file.readAsString()) as Map;
      if (response['nonce'] != nonce) return false;
      final evidence = Platform.environment['XVEIL_BACKLOG_EVIDENCE'];
      if (evidence != null) {
        await File(
          '$evidence/${device.label}-last-rows-private.json',
        ).writeAsString(jsonEncode(response));
      }
      result = [
        for (final row in response['rows'] as List)
          Map<String, dynamic>.from(row as Map),
      ];
      expect(result, hasLength(response['count'] as int));
      expect(
        result!.map((row) => row['id']).toSet(),
        hasLength(result!.length),
        reason: 'all stored rows, including baseline, must have distinct IDs',
      );
      expect(result!.length, lessThanOrEqualTo(1000 + baseline.length));
      return true;
    },
    what: '${device.label} returns all rows from its live storage owner',
    interval: const Duration(milliseconds: 50),
    timeout: const Duration(seconds: 90),
  );
  return result!;
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
        final before = await rows(a, ci, const {});
        final baseline = {for (final row in before) row['id'] as String};
        expect(before.length, baseline.length);
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
        final original = (await rows(
          a,
          ci,
          baseline,
        )).where((row) => !baseline.contains(row['id'])).toList();
        expect(original, hasLength(1000));
        final ids = original.map((m) => m['id']).toList();
        expect(ids.toSet(), hasLength(1000));
        final expectedBodies = {
          for (var i = 0; i < 1000; i++)
            'backlog-${i.toString().padLeft(4, '0')}',
        };
        expect(original.map((m) => m['body']).toSet(), expectedBodies);
        final expectedPositions = {for (final row in original) row['id']: row};
        expect(
          original.every(
            (row) => row['orderAuthor'] is String && row['orderSeq'] is int,
          ),
          isTrue,
          reason:
              'fresh sends must have actual source positions, not null equality',
        );
        bool matches(List<Map<String, dynamic>> all, {bool ownDevice = false}) {
          final actual = all
              .where((row) => !baseline.contains(row['id']))
              .toList();
          return all.length == ids.length + baseline.length &&
              all.map((row) => row['id']).toSet().containsAll(baseline) &&
              actual.length == ids.length &&
              actual.map((m) => m['id']).join('|') == ids.join('|') &&
              actual
                  .map((m) => m['body'])
                  .toSet()
                  .containsAll(expectedBodies) &&
              actual.every(
                (row) =>
                    row['body'] == expectedPositions[row['id']]!['body'] &&
                    row['orderSeq'] ==
                        expectedPositions[row['id']]!['orderSeq'] &&
                    (!ownDevice ||
                        row['orderAuthor'] ==
                            expectedPositions[row['id']]!['orderAuthor']),
              );
        }

        bool delivered(List<Map<String, dynamic>> all) => all
            .where((row) => !baseline.contains(row['id']))
            .every((row) => row['status'] == 'delivered');
        Map<String, int> observed(
          List<Map<String, dynamic>> all, {
          bool ownDevice = false,
        }) {
          final fresh = all
              .where((row) => !baseline.contains(row['id']))
              .toList();
          return {
            'allRows': all.length,
            'newRows': fresh.length,
            'delivered': fresh
                .where((row) => row['status'] == 'delivered')
                .length,
            'unknownIds': fresh
                .where((row) => !expectedPositions.containsKey(row['id']))
                .length,
            'positionMismatches': fresh.where((row) {
              final expected = expectedPositions[row['id']];
              return expected != null &&
                  ((ownDevice &&
                          row['orderAuthor'] != expected['orderAuthor']) ||
                      row['orderSeq'] != expected['orderSeq']);
            }).length,
          };
        }

        var cRows = <Map<String, dynamic>>[];
        await waitUntil(
          () async => matches(cRows = await rows(c, ai, baseline)),
          what: 'C receives all 1000 messages once in A order',
          describe: () => '${observed(cRows)}',
          timeout: const Duration(minutes: 3),
        );
        result['c_rows_before_offline'] = cRows.length - baseline.length;
        await waitUntil(() async {
          final source = await rows(a, ci, baseline);
          return matches(source) && delivered(source);
        }, what: 'A has all 1000 durable delivered states before B reconnects');
        await c.stop();
        result['c_offline_during_catchup'] = true;
        final catchup = Stopwatch()..start();
        await b.start();
        var partial = <Map<String, dynamic>>[];
        await waitUntil(
          () async {
            final all = await rows(b, ci, baseline);
            partial = all
                .where((row) => !baseline.contains(row['id']))
                .toList();
            return partial.length >= 250;
          },
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
          () async {
            bRows = await rows(b, ci, baseline);
            return matches(bRows, ownDevice: true) && delivered(bRows);
          },
          what:
              'restarted B recovers all 1000 IDs and their order with C offline',
          describe: () => '${observed(bRows, ownDevice: true)}',
          timeout: const Duration(minutes: 5),
        );
        result['catchup_seconds_including_restart'] =
            catchup.elapsedMilliseconds / 1000;
        result['b_rows_after_recovery'] = bRows.length - baseline.length;
        result['delivered_after_recovery'] = delivered(bRows);
        result['same_order'] = matches(bRows, ownDevice: true);
        result['source_positions_compared'] = true;
        result['duplicate_ids'] =
            bRows.length - bRows.map((m) => m['id']).toSet().length;
        await a.stop();
        await b.restart();
        final alone = await rows(b, ci, baseline);
        expect(matches(alone, ownDevice: true), isTrue);
        expect(delivered(alone), isTrue);
        result['retained_after_restart_without_other_devices'] = true;
        result['passed'] = true;
      } finally {
        await save();
      }
    },
    skip: gate.skip,
  );
}
