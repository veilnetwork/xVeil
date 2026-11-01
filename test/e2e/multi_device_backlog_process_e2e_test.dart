@Timeout(Duration(minutes: 35))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'device_process_fixture.dart';
import 'e2e_env.dart';
import 'multi_device_process_e2e_test.dart' as base;

// Read through the live worker, never by opening its container in the parent.
// Unlike /messages' deliberately bounded tail, this verifies all history IDs.
int _request = 0;
bool _observedInvalidSnapshot = false;
Future<List<String>> _ids(
  ProcessDevice device,
  String peer,
  String bodyPrefix,
) async {
  final nonce = '${device.label}-${++_request}';
  final request = File('${device.dir.path}/storage-inspect.new');
  await request.writeAsString(
    jsonEncode({
      'nonce': nonce,
      'peer': peer,
      'prefix': '',
      'bodyPrefix': bodyPrefix,
      'includeIds': true,
    }),
  );
  await request.rename('${device.dir.path}/storage-inspect.json');
  List<String>? ids;
  int? count;
  await waitUntil(
    () async {
      final response = File('${device.dir.path}/storage-inspected.json');
      if (!await response.exists()) return false;
      final value = jsonDecode(await response.readAsString()) as Map;
      if (value['nonce'] != nonce) return false;
      ids = List<String>.from(value['ids'] as List);
      count = value['count'] as int;
      return true;
    },
    what: '${device.label} returns its current stored history IDs',
    timeout: const Duration(seconds: 90),
    interval: const Duration(milliseconds: 100),
  );
  if (ids!.length != count || ids!.toSet().length != ids!.length) {
    _observedInvalidSnapshot = true;
  }
  return ids!;
}

void main() {
  final gate = E2eGate.read();
  test(
    'isolated A/B/C: 100 offline mirrors after five minutes with aged history',
    () async {
      _observedInvalidSnapshot = false;
      final baseRows = int.parse(
        Platform.environment['XVEIL_E2E_BACKLOG_BASE_ROWS'] ?? '2000',
      );
      expect(baseRows, inInclusiveRange(0, 3000));
      final f = await ProcessFleet.start(gate);
      addTearDown(f.dispose);
      final a = f.a, b = f.b, c = f.c;
      await base.introduceProcesses(a, c);
      final ai = (await base.deviceInfo(a))['identity'] as String;
      final ci = (await base.deviceInfo(c))['identity'] as String;
      final seed = Stopwatch()..start();
      for (var i = 0; i < baseRows; i++) {
        await a.checked(
          '/send_message',
          query: {'peer': ci, 'text': 'backlog-base-$i'},
        );
        if ((i + 1) % 100 == 0) {
          E2eLog.line(
            'BACKLOG_BASE_SENT=${i + 1} elapsedMs=${seed.elapsedMilliseconds}',
          );
        }
      }
      final expectedBase = await _ids(a, ci, 'backlog-base-');
      expect(expectedBase, hasLength(baseRows));
      await waitUntil(
        () async => (await _ids(c, ai, 'backlog-base-')).length == baseRows,
        what: 'C has the entire initial history',
        timeout: const Duration(minutes: 6),
        interval: const Duration(seconds: 5),
      );
      expect(await _ids(c, ai, 'backlog-base-'), expectedBase);
      await base.linkProcesses(a, b);
      var initialBCount = 0;
      final initialHistory = Stopwatch()..start();
      await waitUntil(
        () async {
          initialBCount = (await _ids(b, ci, 'backlog-base-')).length;
          E2eLog.line(
            'BACKLOG_INITIAL count=$initialBCount '
            'elapsedMs=${initialHistory.elapsedMilliseconds}',
          );
          return initialBCount == baseRows;
        },
        what: 'new sibling B has the entire initial history',
        describe: () => 'stored=$initialBCount expected=$baseRows',
        timeout: const Duration(minutes: 6),
        interval: const Duration(seconds: 5),
      );
      initialHistory.stop();
      expect(await _ids(b, ci, 'backlog-base-'), expectedBase);
      E2eLog.line(
        'BACKLOG_BASE_READY=$baseRows elapsedMs=${seed.elapsedMilliseconds}',
      );

      await b.stop();
      final offline = Stopwatch()..start();
      for (var i = 0; i < 100; i++) {
        await a.checked(
          '/send_message',
          query: {'peer': ci, 'text': 'backlog-offline-$i'},
        );
      }
      final expected = await _ids(a, ci, 'backlog-offline-');
      expect(expected, hasLength(100));
      await waitUntil(
        () async => (await _ids(c, ai, 'backlog-offline-')).length == 100,
        what: 'C has all 100 messages sent while B is offline',
        timeout: const Duration(minutes: 4),
        interval: const Duration(seconds: 5),
      );
      expect(await _ids(c, ai, 'backlog-offline-'), expected);
      await waitUntil(
        () => offline.elapsed >= const Duration(minutes: 5),
        what: 'B stays offline for at least five real minutes',
        describe: () => 'offlineMs=${offline.elapsedMilliseconds}',
        timeout: const Duration(minutes: 6),
        interval: const Duration(seconds: 1),
      );
      await c.stop();
      expect(await portAnswers(c.port), isFalse);
      final launched = Stopwatch()..start();
      await b.start();
      final health = await b.checked('/health');
      expect(health['realStack'], isTrue);
      expect(health['ready'], isTrue);
      offline.stop();
      final readyMs = launched.elapsedMilliseconds;
      final recovery = Stopwatch()..start();
      final samples = <Map<String, int>>[];
      var recovered = false;
      final evidence = Platform.environment['XVEIL_E2E_EVIDENCE_DIR'];
      try {
        await waitUntil(
          () async {
            final query = Stopwatch()..start();
            final found = await _ids(b, ci, 'backlog-offline-');
            final complete =
                found.length == 100 && equals(expected).matches(found, {});
            samples.add({
              'elapsedMs': recovery.elapsedMilliseconds,
              'fromLaunchMs': launched.elapsedMilliseconds,
              'count': found.length,
              'queryMs': query.elapsedMilliseconds,
              'complete': complete ? 1 : 0,
            });
            E2eLog.line(
              'BACKLOG_RECOVERY count=${found.length} elapsedMs=${recovery.elapsedMilliseconds} queryMs=${query.elapsedMilliseconds}',
            );
            if (found.length > 100) _observedInvalidSnapshot = true;
            return complete;
          },
          what: 'B recovers all 100 outgoing mirrors with C offline',
          timeout: const Duration(minutes: 5),
          interval: const Duration(seconds: 5),
        );
        recovered = true;
      } finally {
        if (evidence != null) {
          await Directory(evidence).create(recursive: true);
          await File('$evidence/backlog-summary.json').writeAsString(
            jsonEncode({
              'baseRows': baseRows,
              'initialHistoryMs': initialHistory.elapsedMilliseconds,
              'backlogRows': 100,
              'offlineUntilReadyMs': offline.elapsedMilliseconds,
              'readyMsFromLaunch': readyMs,
              'recovered': recovered,
              if (recovered)
                'firstCompleteObservationMs': samples.last['elapsedMs'],
              'samples': samples,
            }),
          );
        }
      }
      expect(await _ids(b, ci, 'backlog-base-'), expectedBase);
      await c.start();
      expect(await _ids(c, ai, 'backlog-offline-'), expected);
      expect(await _ids(c, ai, 'backlog-base-'), expectedBase);
      expect(await _ids(a, ci, 'backlog-offline-'), expected);
      expect(
        _observedInvalidSnapshot,
        isFalse,
        reason:
            'convergence must not erase an earlier duplicate/count mismatch',
      );
      E2eLog.line('PROCESS_BACKLOG_100_EXACT_IDS_ORDER_PASS');
    },
    skip: gate.skip,
  );
}
