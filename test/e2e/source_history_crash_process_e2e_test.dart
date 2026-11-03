@Timeout(Duration(minutes: 15))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'device_process_fixture.dart';
import 'e2e_env.dart';
import 'multi_device_process_e2e_test.dart' as base;
import 'offline_backlog_process_e2e_test.dart' as observer;

int _historyInspection = 0;

Future<Map<String, dynamic>> _historyState(
  ProcessDevice device,
  String peer,
  String askingDevice,
) async {
  final nonce = 'source-history-${++_historyInspection}';
  final request = File('${device.dir.path}/storage-inspect.new');
  await request.writeAsString(
    jsonEncode({
      'nonce': nonce,
      'peer': peer,
      'prefix': '',
      'historyBodyPrefix': 'source-crash-',
      'historyAskingDevice': askingDevice,
    }),
  );
  await request.rename('${device.dir.path}/storage-inspect.json');
  Map<String, dynamic>? result;
  await waitUntil(() async {
    final response = File('${device.dir.path}/storage-inspected.json');
    if (!await response.exists()) return false;
    final value = jsonDecode(await response.readAsString()) as Map;
    if (value['nonce'] != nonce) return false;
    result = Map<String, dynamic>.from(value['historyState'] as Map);
    return true;
  }, what: 'A reports committed history mirrors before SIGKILL');
  return result!;
}

void main() {
  final gate = E2eGate.read();
  test(
    'history converges after source crashes during initial backfill',
    () async {
      final fleet = await ProcessFleet.start(gate);
      addTearDown(fleet.dispose);
      final a = fleet.a, b = fleet.b, c = fleet.c;
      final evidence = Platform.environment['XVEIL_BACKLOG_EVIDENCE'];
      final result = <String, Object?>{
        'devices': 3,
        'requestedMessages': 1000,
        'sourceCrash': true,
        'localNetworkOnly': true,
      };
      Future<void> save() async {
        if (evidence != null) {
          await File('$evidence/result.json').writeAsString(jsonEncode(result));
        }
      }

      try {
        await base.introduceProcesses(a, c);
        final ai = (await base.deviceInfo(a))['identity'] as String;
        final ci = (await base.deviceInfo(c))['identity'] as String;
        final baseline = {
          for (final row in await observer.rows(a, ci, const {}))
            row['id'] as String,
        };
        for (var i = 0; i < 1000; i++) {
          await a.checked(
            '/send_message',
            query: {
              'peer': ci,
              'text': 'source-crash-${i.toString().padLeft(4, '0')}',
            },
          );
          if ((i + 1) % 100 == 0) {
            result['acknowledgedSendRequests'] = i + 1;
            await save();
          }
        }
        final source = (await observer.rows(
          a,
          ci,
          baseline,
        )).where((row) => !baseline.contains(row['id'])).toList();
        expect(source, hasLength(1000));
        expect(source.map((row) => row['id']).toSet(), hasLength(1000));
        expect(source.map((row) => row['body']).toSet(), {
          for (var i = 0; i < 1000; i++)
            'source-crash-${i.toString().padLeft(4, '0')}',
        });
        expect(
          source.every(
            (row) => row['orderAuthor'] is String && row['orderSeq'] is int,
          ),
          isTrue,
        );
        final ids = source.map((row) => row['id']).toList();
        final expected = {for (final row in source) row['id']: row};
        bool complete(List<Map<String, dynamic>> all, {bool sibling = false}) {
          final fresh = all
              .where((row) => !baseline.contains(row['id']))
              .toList();
          return all.length == 1000 + baseline.length &&
              all.map((row) => row['id']).toSet().containsAll(baseline) &&
              fresh.map((row) => row['id']).join('|') == ids.join('|') &&
              fresh.every(
                (row) =>
                    row['body'] == expected[row['id']]!['body'] &&
                    row['orderSeq'] == expected[row['id']]!['orderSeq'] &&
                    (!sibling ||
                        (row['orderAuthor'] ==
                                expected[row['id']]!['orderAuthor'] &&
                            row['status'] == 'delivered')),
              );
        }

        await waitUntil(
          () async => complete(await observer.rows(c, ai, baseline)),
          what: 'C has the full source history before being stopped',
        );
        await waitUntil(() async {
          final all = await observer.rows(a, ci, baseline);
          return complete(all, sibling: true);
        }, what: 'A has durable delivered outcomes before linking B');
        await c.stop();
        result['cOfflineBeforeLink'] = true;
        final recovery = Stopwatch();
        await base.linkProcesses(
          a,
          b,
          afterSnapshotSent: () async {
            final state = await _historyState(
              a,
              ci,
              (await base.deviceInfo(b))['nodeId'] as String,
            );
            final mirrors = state['mirrors'] as int;
            result['sourceJournalMirrorsAtCrash'] = mirrors;
            result['sourceServedRequestsAtCrash'] = state['servedRequests'];
            final held = await observer.rows(b, ci, baseline);
            final count = held
                .where((row) => !baseline.contains(row['id']))
                .length;
            result['bMessagesAtCrash'] = count;
            await save();
            expect(
              mirrors,
              inExclusiveRange(0, 1000),
              reason:
                  'source must not have finished its durable history journal',
            );
            expect(state['servedRequests'], greaterThan(0));
            expect(
              count,
              lessThan(1000),
              reason: 'B must still need missing history when A crashes',
            );
            await a.stop(crash: true);
            recovery.start();
            await a.start();
          },
        );
        var last = <Map<String, dynamic>>[];
        await waitUntil(
          () async {
            last = await observer.rows(b, ci, baseline);
            result['bLatestMessages'] = last.length - baseline.length;
            await save();
            return complete(last, sibling: true);
          },
          what: 'B recovers history never published before A crashed',
          describe: () => '${result['bLatestMessages']} of 1000',
          timeout: const Duration(minutes: 4),
        );
        result['recoverySecondsIncludingSourceStart'] =
            recovery.elapsedMilliseconds / 1000;
        result['bRecoveredMessages'] = last.length - baseline.length;
        result['duplicateIds'] =
            last.length - last.map((row) => row['id']).toSet().length;
        result['sameOrderPositionsAndDelivered'] = true;
        result['sourceJournalMirrorsAfterRecovery'] = (await _historyState(
          a,
          ci,
          (await base.deviceInfo(b))['nodeId'] as String,
        ))['mirrors'];
        await a.stop();
        await b.restart();
        expect(
          complete(await observer.rows(b, ci, baseline), sibling: true),
          isTrue,
        );
        result['retainedWithoutSource'] = true;
        result['passed'] = true;
      } finally {
        await save();
      }
    },
    skip: gate.skip,
  );
}
