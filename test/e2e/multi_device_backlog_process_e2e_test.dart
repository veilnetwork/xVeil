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
final _statuses = <String, Map<String, int>>{};
final _storageTimings = <String, Map<String, dynamic>>{};
final _positions = <String, Map<String, Map<String, dynamic>>>{};
bool get _withPositions =>
    Platform.environment['XVEIL_E2E_STORAGE_POSITIONS'] == '1';

Future<void> _positionEvidence(String label, String stage) async {
  final dir = Platform.environment['XVEIL_E2E_EVIDENCE_DIR'];
  if (!_withPositions || dir == null) return;
  await Directory(dir).create(recursive: true);
  await File(
    '$dir/initial-$label-$stage-private.json',
  ).writeAsString(jsonEncode(_positions[label]));
}

Future<List<String>> _ids(
  ProcessDevice device,
  String peer,
  String bodyPrefix, {
  bool resetStorageTiming = false,
}) async {
  final nonce = '${device.label}-${++_request}';
  final request = File('${device.dir.path}/storage-inspect.new');
  await request.writeAsString(
    jsonEncode({
      'nonce': nonce,
      'peer': peer,
      'prefix': '',
      'bodyPrefix': bodyPrefix,
      'includeIds': true,
      if (_withPositions) 'includePositions': true,
      if (Platform.environment['XVEIL_E2E_STORAGE_TIMING'] == '1') ...{
        'storageTiming': true,
        'resetStorageTiming': resetStorageTiming,
      },
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
      if (_withPositions) {
        final raw = Map<String, dynamic>.from(value['positions'] as Map);
        expect(raw, hasLength(count!));
        _positions[device.label] = {
          for (final entry in raw.entries)
            entry.key: Map<String, dynamic>.from(entry.value as Map),
        };
      }
      _statuses[device.label] = Map<String, int>.from(
        value['statusCounts'] as Map,
      );
      if (value['storageTiming'] is Map) {
        _storageTimings[device.label] = Map<String, dynamic>.from(
          value['storageTiming'] as Map,
        );
      }
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
  final migrationOnly = Platform.environment['XVEIL_E2E_MIGRATION_ONLY'] == '1';
  test(
    migrationOnly
        ? 'isolated A/B/C: initial history migration only'
        : 'isolated A/B/C: 100 offline mirrors after five minutes with aged history',
    () async {
      _observedInvalidSnapshot = false;
      _statuses.clear();
      _storageTimings.clear();
      _positions.clear();
      final baseRows = int.parse(
        Platform.environment['XVEIL_E2E_BACKLOG_BASE_ROWS'] ?? '2000',
      );
      expect(baseRows, inInclusiveRange(migrationOnly ? 1 : 0, 3000));
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
      await waitUntil(
        () async {
          await _ids(a, ci, 'backlog-base-');
          return _statuses['A']?['delivered'] == baseRows;
        },
        what:
            'A has durable delivery confirmation for the entire initial history',
        timeout: const Duration(minutes: 2),
        interval: const Duration(seconds: 2),
      );
      if (Platform.environment['XVEIL_E2E_STORAGE_TIMING'] == '1') {
        await _ids(a, ci, 'backlog-base-', resetStorageTiming: true);
        await _ids(b, ci, 'backlog-base-', resetStorageTiming: true);
      }
      final expectedPositions = _positions['A'];
      if (_withPositions) expect(expectedPositions, hasLength(baseRows));
      await _positionEvidence('A', 'before-link');
      await base.linkProcesses(a, b);
      var initialBCount = 0;
      int? initialCountCompleteMs;
      var initialOrderMismatchObservations = 0;
      var initialPositionMismatchObservations = 0;
      var initialOrderMatches = false, initialPositionsMatch = false;
      final initialHistory = Stopwatch()..start();
      try {
        await waitUntil(
          () async {
            final got = await _ids(b, ci, 'backlog-base-');
            initialBCount = got.length;
            final complete = initialBCount == baseRows;
            initialOrderMatches =
                complete &&
                List.generate(
                  baseRows,
                  (i) => got[i] == expectedBase[i],
                ).every((matches) => matches);
            final held = _positions['B'];
            initialPositionsMatch =
                !_withPositions ||
                (held != null &&
                    expectedPositions!.entries.every(
                      (entry) =>
                          held[entry.key]?['orderAuthor'] ==
                              entry.value['orderAuthor'] &&
                          held[entry.key]?['orderSeq'] ==
                              entry.value['orderSeq'],
                    ));
            if (complete) {
              initialCountCompleteMs ??= initialHistory.elapsedMilliseconds;
              if (!initialOrderMatches) initialOrderMismatchObservations++;
              if (!initialPositionsMatch) initialPositionMismatchObservations++;
              if ((!initialOrderMatches || !initialPositionsMatch) &&
                  initialOrderMismatchObservations +
                          initialPositionMismatchObservations <=
                      2) {
                await _positionEvidence('B', 'first-full-mismatch');
              }
            }
            E2eLog.line(
              'BACKLOG_INITIAL count=$initialBCount '
              'elapsedMs=${initialHistory.elapsedMilliseconds} '
              'orderMatch=$initialOrderMatches positionsMatch=$initialPositionsMatch '
              'delivered=${_statuses['B']?['delivered']}',
            );
            return complete &&
                initialOrderMatches &&
                initialPositionsMatch &&
                _statuses['B']?['delivered'] == baseRows;
          },
          what:
              'new sibling B converges initial history IDs, order and delivery',
          describe: () =>
              'stored=$initialBCount expected=$baseRows '
              'order=$initialOrderMatches positions=$initialPositionsMatch '
              'delivered=${_statuses['B']?['delivered']}',
          timeout: const Duration(minutes: 6),
          interval: const Duration(seconds: 5),
        );
      } finally {
        initialHistory.stop();
        await _positionEvidence('B', 'last-observed');
      }
      expect(await _ids(b, ci, 'backlog-base-'), expectedBase);
      final initialBStatuses = Map<String, int>.of(_statuses['B']!);
      final initialLog = await File(b.logPath).readAsString();
      expect(
        initialLog,
        contains('[timeline]:'),
        reason: 'the passive retry observer must actually be enabled',
      );
      final completedIds = expectedBase.toSet();
      final completedHistoryRetries = RegExp(r'\[timeline\]: retry id=(\S+) ')
          .allMatches(initialLog)
          .where((match) => completedIds.contains(match.group(1)))
          .length;
      E2eLog.line(
        'BACKLOG_INITIAL_COMPLETED_HISTORY_RETRIES=$completedHistoryRetries',
      );
      expect(
        completedHistoryRetries,
        0,
        reason: 'all source rows were delivered before linking B',
      );
      expect(
        initialBStatuses['delivered'],
        baseRows,
        reason:
            'completed history must not be reintroduced as outgoing retry work',
      );
      E2eLog.line(
        'BACKLOG_BASE_READY=$baseRows elapsedMs=${seed.elapsedMilliseconds}',
      );

      if (migrationOnly) {
        expect(await _ids(a, ci, 'backlog-base-'), expectedBase);
        expect(await _ids(c, ai, 'backlog-base-'), expectedBase);
        if (Platform.environment['XVEIL_E2E_STORAGE_TIMING'] == '1') {
          await _ids(a, ci, 'backlog-base-');
          for (final label in ['A', 'B']) {
            expect(_storageTimings[label], isNotNull);
            expect(_storageTimings[label]!['keyLimitReached'], isFalse);
          }
        }
        expect(_observedInvalidSnapshot, isFalse);
        final evidence = Platform.environment['XVEIL_E2E_EVIDENCE_DIR'];
        if (evidence != null) {
          await Directory(evidence).create(recursive: true);
          await File('$evidence/migration-summary.json').writeAsString(
            jsonEncode({
              'migrationOnly': true,
              'baseRows': baseRows,
              'initialHistoryMs': initialHistory.elapsedMilliseconds,
              'initialCountCompleteMs': initialCountCompleteMs,
              'initialOrderMismatchObservations':
                  initialOrderMismatchObservations,
              'initialPositionMismatchObservations':
                  initialPositionMismatchObservations,
              'initialPositionsCompared': _withPositions,
              'initialBStatuses': initialBStatuses,
              'completedHistoryRetries': completedHistoryRetries,
              'convergedIdsAndOrder': true,
              'invalidSnapshotObserved': _observedInvalidSnapshot,
              'offlineScenarioExecuted': false,
              if (_storageTimings.isNotEmpty) 'storageTiming': _storageTimings,
              if (_storageTimings.isNotEmpty)
                'storageTimingResetBeforeLink': ['A', 'B'],
            }),
          );
        }
        E2eLog.line(
          'MIGRATION_ONLY rows=$baseRows elapsedMs=${initialHistory.elapsedMilliseconds}',
        );
        return;
      }

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
        () async {
          await _ids(a, ci, 'backlog-offline-');
          return _statuses['A']?['delivered'] == 100;
        },
        what:
            'A has durable delivery confirmation for all 100 offline messages',
        timeout: const Duration(minutes: 2),
        interval: const Duration(seconds: 2),
      );
      final expectedOfflinePositions = _positions['A'];
      if (_withPositions) expect(expectedOfflinePositions, hasLength(100));
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
      int? allDeliveryObservedAt;
      final evidence = Platform.environment['XVEIL_E2E_EVIDENCE_DIR'];
      try {
        await waitUntil(
          () async {
            final query = Stopwatch()..start();
            final found = await _ids(b, ci, 'backlog-offline-');
            final idsComplete =
                found.length == 100 && equals(expected).matches(found, {});
            final positions = _positions['B'];
            final positionsComplete = !_withPositions ||
                (positions != null &&
                    positions.length == 100 &&
                    expectedOfflinePositions!.entries.every((entry) =>
                        positions[entry.key]?['orderAuthor'] ==
                            entry.value['orderAuthor'] &&
                        positions[entry.key]?['orderSeq'] ==
                            entry.value['orderSeq']));
            final delivered = _statuses['B']?['delivered'] ?? 0;
            final complete = idsComplete && positionsComplete && delivered == 100;
            samples.add({
              'elapsedMs': recovery.elapsedMilliseconds,
              'fromLaunchMs': launched.elapsedMilliseconds,
              'count': found.length,
              'queryMs': query.elapsedMilliseconds,
              'delivered': delivered,
              'idsComplete': idsComplete ? 1 : 0,
              'positionsComplete': positionsComplete ? 1 : 0,
              'complete': complete ? 1 : 0,
            });
            E2eLog.line(
              'BACKLOG_RECOVERY count=${found.length} elapsedMs=${recovery.elapsedMilliseconds} queryMs=${query.elapsedMilliseconds} delivered=$delivered',
            );
            if (found.length > 100) _observedInvalidSnapshot = true;
            if (complete) {
              allDeliveryObservedAt = DateTime.now().millisecondsSinceEpoch;
            }
            return complete;
          },
          what:
              'B recovers all 100 outgoing mirrors AND delivery states with C offline',
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
              'initialCountCompleteMs': initialCountCompleteMs,
              'initialOrderMismatchObservations':
                  initialOrderMismatchObservations,
              'initialPositionMismatchObservations':
                  initialPositionMismatchObservations,
              'positionsCompared': _withPositions,
              'initialBStatuses': initialBStatuses,
              'initialBCompletedHistoryRetries': completedHistoryRetries,
              'backlogRows': 100,
              'offlineUntilReadyMs': offline.elapsedMilliseconds,
              'readyMsFromLaunch': readyMs,
              'recovered': recovered,
              if (recovered)
                'firstCompleteObservationMs': samples.last['elapsedMs'],
              if (samples.any((s) => s['idsComplete'] == 1))
                'firstCompleteIdsObservationMs': samples.firstWhere(
                  (s) => s['idsComplete'] == 1,
                )['elapsedMs'],
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
      final finalLog = await File(b.logPath).readAsString();
      final liveIds = expected.toSet();
      final retries = RegExp(r'\[timeline\]: retry id=(\S+) t=(\d+)')
          .allMatches(finalLog)
          .where((m) => liveIds.contains(m.group(1)))
          .toList();
      final lateRetries = retries
          .where((m) => int.parse(m.group(2)!) > allDeliveryObservedAt!)
          .length;
      E2eLog.line(
        'BACKLOG_LIVE_COPY_RETRIES=${retries.length} AFTER_DELIVERED=$lateRetries',
      );
      expect(
        lateRetries,
        0,
        reason: 'observed durable delivery must stop later retry attempts',
      );
      if (evidence != null) {
        await File('$evidence/live-copy-retries.json').writeAsString(
          jsonEncode({
            'retryAttempts': retries.length,
            'distinctRetriedMessages': retries
                .map((m) => m.group(1))
                .toSet()
                .length,
            'attemptsAfterAllDeliveryObserved': lateRetries,
          }),
        );
      }
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
