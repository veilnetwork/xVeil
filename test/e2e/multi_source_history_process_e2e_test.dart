@Timeout(Duration(minutes: 45))
library;

import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/message_batch_store.dart';
import 'device_process_fixture.dart';
import 'e2e_env.dart';
import 'multi_device_process_e2e_test.dart' as base;
import 'crash_retention_oracle.dart';
import '../support/history_archive_fixture.dart';

const _prefix = 'native-overlap-';
final _rows = historyArchiveRows(
  Platform.environment['XVEIL_E2E_HISTORY_OVERLAP_ROWS'],
);
int _nonce = 0;
bool _invalid = false;

Future<Map<String, dynamic>> _inspect(
  ProcessDevice d,
  String peer,
  String asking, {
  bool seed = false,
  String? author,
  List<String>? cursors,
  bool resetTiming = false,
  bool progressOnly = false,
}) async {
  final nonce = 'overlap-${++_nonce}';
  final request = File('${d.dir.path}/storage-inspect.new');
  await request.writeAsString(
    jsonEncode({
      'nonce': nonce,
      'peer': peer,
      'prefix': '',
      'includeRows': !progressOnly,
      if (progressOnly) 'historyProgressOnly': true,
      if (Platform.environment['XVEIL_E2E_STORAGE_TIMING'] == '1') ...{
        'storageTiming': true,
        'resetStorageTiming': resetTiming,
      },
      'includeHistoryWire': !progressOnly,
      if (!progressOnly) 'historyBodyPrefix': _prefix,
      'historyAskingDevice': asking,
      'cursorDevices': ?cursors,
      if (seed) ...{
        'seedSharedHistory': true,
        'sharedRows': _rows,
        'sharedAuthor': author,
      },
    }),
  );
  await request.rename('${d.dir.path}/storage-inspect.json');
  Map<String, dynamic>? answer;
  await waitUntil(
    () async {
      final f = File('${d.dir.path}/storage-inspected.json');
      if (!await f.exists()) return false;
      final value = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      if (value['nonce'] != nonce) return false;
      answer = value;
      if (progressOnly) {
        expect(value['historyProgressOnly'], isTrue);
        expect(
          value.containsKey('rows') ||
              value.containsKey('count') ||
              value.containsKey('historyWire'),
          isFalse,
        );
      } else {
        final rows = value['rows'] as List;
        if (rows.length != value['count'] ||
            rows.map((r) => (r as Map)['id']).toSet().length != rows.length) {
          _invalid = true;
        }
      }
      return true;
    },
    what: '${d.label} returns an atomic live-owner snapshot',
    timeout: seed ? const Duration(minutes: 15) : const Duration(seconds: 90),
    interval: const Duration(milliseconds: 50),
  );
  final evidence = Platform.environment['XVEIL_E2E_EVIDENCE_DIR']!;
  await File(
    '$evidence/overlap-${d.label}-last-private.json',
  ).writeAsString(jsonEncode(answer));
  if (answer!['storageTiming'] case final Map timing) {
    await File(
      '$evidence/history-census-${d.label}-private.jsonl',
    ).writeAsString(
      '${jsonEncode({'nonce': nonce, 'values': timing})}\n',
      mode: FileMode.append,
    );
  }
  return answer!;
}

List<Map<String, dynamic>> _all(Map value) => [
  for (final row in value['rows'] as List)
    Map<String, dynamic>.from(row as Map),
];
List<Map<String, dynamic>> _archive(Map value) =>
    _all(value).where((r) => (r['id'] as String).startsWith(_prefix)).toList();
List<CrashRetentionRow> _retentionRows(List<Map<String, dynamic>> rows) => [
  for (final row in rows)
    CrashRetentionRow(
      id: row['id'] as String,
      delivered: row['status'] == 'delivered',
      orderAuthor: row['orderAuthor'] as String?,
      orderSeq: row['orderSeq'] as int?,
      bodyTag: sha256.convert(utf8.encode(row['body'] as String)).toString(),
    ),
];
Map<String, Object> _compare(
  List<Map<String, dynamic>> expected,
  List<Map<String, dynamic>> actual,
) => crashRetentionOf(
  expected: _retentionRows(expected),
  actual: _retentionRows(actual),
  allowedIds: {for (final row in expected) row['id'] as String},
);
bool _ordered(List<Map<String, dynamic>> a, List<Map<String, dynamic>> b) =>
    a.length == b.length &&
    List.generate(a.length, (i) => a[i]['id'] == b[i]['id']).every((v) => v);

File _gate(ProcessDevice d, String kind, String suffix) =>
    File('${d.dir.path}/history-overlap-$kind-$suffix');
Future<void> _entered(ProcessDevice d, String kind) => waitUntil(
  () => _gate(d, kind, 'entered.json').exists(),
  what: '${d.label} reaches $kind barrier',
  timeout: const Duration(seconds: 45),
  interval: const Duration(milliseconds: 50),
);

Future<void> _crashAndRecover({
  required ProcessFleet fleet,
  required String peer,
  required String receiver,
  required String source,
  required List<Map<String, dynamic>> expected,
  required Map<String, dynamic> held,
  required Map<String, Object?> result,
  required Future<void> Function() save,
  bool beforeApply = true,
  Map<String, String> cursorsBeforeCrash = const {},
}) async {
  final a = fleet.a, b = fleet.b, e = fleet.devices['E']!;
  final evidence = Platform.environment['XVEIL_E2E_EVIDENCE_DIR']!;
  final before = _all(held);
  expect(before, isNotEmpty);
  final archivedBefore = _archive(held);
  if (beforeApply) {
    expect(archivedBefore, isEmpty);
    expect(expected.length, _rows + before.length);
  } else {
    expect(archivedBefore.length, inInclusiveRange(1, _rows - 1));
    final archive = expected.where(
      (row) => (row['id'] as String).startsWith(_prefix),
    ).toList();
    expect(_compare(archive.take(archivedBefore.length).toList(), archivedBefore)
        ['passed'], isTrue);
    expect(_ordered(archive.take(archivedBefore.length).toList(), archivedBefore),
        isTrue);
    expect(before.length - archivedBefore.length, expected.length - _rows);
    expect(cursorsBeforeCrash, hasLength(2));
  }

  Future<int> witness(List<Map<String, dynamic>> rows,
      {Map<String, String> cursors = const {}}) async {
    final value = ++_nonce;
    await File('${b.dir.path}/history-overlap-witness.json').writeAsString(
      jsonEncode({
        'witness': value,
        if (cursors.isNotEmpty) 'expectedCursors': cursors,
        'allowedIds': expected.map((row) => row['id']).toList(),
        'expectedRows': [
          for (final row in _retentionRows(rows))
            {
              'id': row.id,
              'delivered': row.delivered,
              'orderAuthor': row.orderAuthor,
              'orderSeq': row.orderSeq,
              'bodyTag': row.bodyTag,
            },
        ],
      }),
      flush: true,
    );
    return value;
  }

  Future<Map> boot(int value) async =>
      (await File(
            '$evidence/overlap-B-before-network-private.jsonl',
          ).readAsLines())
          .map((line) => jsonDecode(line) as Map)
          .singleWhere((row) => row['witness'] == value);

  final beforeWitness = await witness(before, cursors: cursorsBeforeCrash);
  await b.stop(crash: true);
  expect(b.lastExitCode, -9);
  await a.stop();
  await e.stop();
  result[beforeApply ? 'receiverKilledBeforeApply' : 'receiverKilledDuringApply'] = true;
  result['receiverCrashExitCode'] = b.lastExitCode;
  result['bothRepliesReceivedBeforeCrash'] = true;
  result['archiveRowsAtCrash'] = archivedBefore.length;
  await save();
  await b.start();
  final initialBoot = await boot(beforeWitness);
  expect((initialBoot['retention'] as Map)['passed'], isTrue);
  expect(initialBoot['rows'], before.length);
  if (cursorsBeforeCrash.isNotEmpty) {
    expect((initialBoot['cursorRetention'] as Map)['passed'], isTrue);
    expect((initialBoot['cursorRetention'] as Map)['expectedRows'], 2);
    result['cursorRetentionBeforeNetworkAfterCrash'] =
        initialBoot['cursorRetention'];
  }
  final offline = await _inspect(b, peer, receiver);
  expect(_compare(before, _all(offline))['passed'], isTrue);
  expect(_archive(offline).length, archivedBefore.length);
  result['retentionBeforeNetworkAfterCrash'] = initialBoot['retention'];
  result['initialArchiveRowsWithAllSourcesOffline'] = archivedBefore.length;

  final recovery = Stopwatch()..start();
  await a.start();
  Map<String, dynamic>? recovered;
  await waitUntil(
    () async {
      recovered = await _inspect(b, peer, receiver, cursors: [source],
          progressOnly: _rows > 10000);
      final cursors = recovered!['historyCursors'] as Map;
      if (cursors.length != 1 || cursors.values.single is! String) return false;
      final cursor = jsonDecode(cursors.values.single as String) as Map;
      if (cursor.containsKey('peer') ||
          (cursor.isNotEmpty && cursor['after'] != peer)) {
        return false;
      }
      if (_rows > 10000) {
        recovered = await _inspect(b, peer, receiver, cursors: [source]);
      }
      if (_compare(expected, _all(recovered!))['passed'] != true ||
          !_ordered(expected, _all(recovered!))) {
        return false;
      }
      return true;
    },
    what: 'one returning source repairs both interrupted history replies',
    timeout: Duration(minutes: _rows > 10000 ? 20 : 3),
    interval: Duration(milliseconds: _rows > 10000 ? 5000 : 250),
  );
  result['singleSourceStartToConvergenceMs'] = recovery.elapsedMilliseconds;
  result['recoveredWithOneSource'] = true;
  final authenticatedParts = (recovered!['historyWire'] as List).where(
    (row) => row['kind'] == 'part' && row['fromDevice'] == source &&
        row['authenticated'] == true,
  ).length;
  expect(authenticatedParts, greaterThan(0));
  result['authenticatedRecoveryParts'] = authenticatedParts;
  result['historyFailuresAfterRestart'] = recovered!['historyFailures'];
  result['fullHistoryConvergence'] = _compare(expected, _all(recovered!));
  result['archiveConvergence'] = _compare(
    expected.where((row) => (row['id'] as String).startsWith(_prefix)).toList(),
    _archive(recovered!),
  );
  expect(_archive(recovered!).length, _rows);
  expect(
    ((await _inspect(a, peer, receiver))['historyState'] as Map)['mirrors'],
    0,
  );
  result['sourceDeviceJournalArchiveMirrors'] = 0;
  final finalSnapshot = cursorsBeforeCrash.isEmpty ? recovered! :
      await _inspect(b, peer, receiver, cursors: cursorsBeforeCrash.keys.toList());
  final finalCursors = cursorsBeforeCrash.isEmpty ? const <String, String>{} :
      Map<String, String>.from(finalSnapshot['historyCursors'] as Map);
  final finalWitness = await witness(_all(finalSnapshot), cursors: finalCursors);
  await a.stop();
  await b.stop();
  await b.start();
  final finalBoot = await boot(finalWitness);
  expect((finalBoot['retention'] as Map)['passed'], isTrue);
  expect(finalBoot['rows'], expected.length);
  if (finalCursors.isNotEmpty) {
    expect((finalBoot['cursorRetention'] as Map)['passed'], isTrue);
    result['finalCursorRetentionBeforeNetwork'] = finalBoot['cursorRetention'];
  }
  final finalRows = _all(await _inspect(b, peer, receiver));
  expect(_compare(expected, finalRows)['passed'], isTrue);
  expect(_ordered(expected, finalRows), isTrue);
  expect(_invalid, isFalse);
  result['retentionBeforeNetwork'] = finalBoot['retention'];
  result['finalRows'] = finalRows.length;
  result['retainedWithAllSourcesOffline'] = true;
  result['invalidSnapshotObserved'] = _invalid;
  result['passed'] = true;
}

void main() {
  final gate = E2eGate.read();
  final crashAtRow = historyCrashRow(
    Platform.environment['XVEIL_E2E_HISTORY_OVERLAP_CRASH_AT_ROW'], _rows,
  );
  final crashBeforeApply =
      Platform.environment['XVEIL_E2E_HISTORY_OVERLAP_CRASH_BEFORE_APPLY'] ==
      '1';
  if (crashBeforeApply && crashAtRow != null) {
    throw ArgumentError('choose one synthetic receiver crash point');
  }
  test(
    crashBeforeApply
        ? 'overlapping replies recover after receiver crashes before apply'
        : crashAtRow != null
        ? 'partially published native history recovers after receiver SIGKILL'
        : 'two native sibling sources deliver overlapping archived pages',
    () async {
      expect(Platform.environment['XVEIL_E2E_HISTORY_OVERLAP'], '1');
      expect(Platform.environment['XVEIL_E2E_STORAGE_TIMING'], '1');
      expect(Platform.environment['XVEIL_E2E_HISTORY_WIRE_TRACE'], '1');
      final pollMs = int.parse(
        Platform.environment['XVEIL_E2E_HISTORY_OVERLAP_POLL_MS'] ?? '1000',
      );
      expect(pollMs, inInclusiveRange(50, 5000));
      _invalid = false;
      final fleet = await ProcessFleet.start(
        gate,
        labels: ['A', 'B', 'C', 'E'],
      );
      addTearDown(fleet.dispose);
      final a = fleet.a, b = fleet.b, c = fleet.c, e = fleet.devices['E']!;
      final evidence = Platform.environment['XVEIL_E2E_EVIDENCE_DIR']!;
      await File(
        '$evidence/fleet-private.json',
      ).writeAsString(jsonEncode({'root': fleet.root.path, 'runnerPid': pid}));
      final result = <String, Object?>{
        'devices': 4,
        'ownIdentityDevices': 3,
        'archiveRows': _rows,
        'localNetworkOnly': true,
        'testBarriersEnabled': true,
        'convergencePollMs': pollMs,
        'compactProgressObserver': _rows > 10000,
        'seedBatchRows': _rows > 10000 ? 64 : 16,
        if (crashBeforeApply) 'receiverCrashBeforeApplyRequested': true,
        'receiverCrashAtRowRequested': ?crashAtRow,
      };
      Future<void> save() =>
          File('$evidence/result.json').writeAsString(jsonEncode(result));
      try {
        await base.introduceProcesses(a, c);
        await base.linkProcesses(a, e);
        await base.linkProcesses(a, b);
        final ci = (await base.deviceInfo(c))['identity'] as String;
        final an = (await base.deviceInfo(a))['nodeId'] as String;
        final bn = (await base.deviceInfo(b))['nodeId'] as String;
        final en = (await base.deviceInfo(e))['nodeId'] as String;
        expect({an, bn, en}.length, 3);
        await waitUntil(() async {
          final members = (await e.checked('/devices'))['members'] as List;
          return members.any((m) => m['id'] == bn) &&
              await base.contactStatus(e, ci) == 'accepted' &&
              await base.contactStatus(b, ci) == 'accepted';
        }, what: 'E knows B membership and both linked devices know C');
        final baselineB = _all(await _inspect(b, ci, bn));
        expect(baselineB, isNotEmpty);
        await b.stop();
        await c.stop();
        await e.stop();
        final first = await _inspect(a, ci, bn, seed: true, author: an);
        final expectedArchive = _archive(first);
        expect(expectedArchive.length, _rows);
        expect(
          expectedArchive.asMap().entries.every((entry) {
            final id = '$_prefix${entry.key.toString().padLeft(4, '0')}';
            return entry.value['id'] == id &&
                entry.value['body'] == '$id:archived payload' &&
                entry.value['orderSeq'] == 100001 + entry.key;
          }),
          isTrue,
        );
        expect(
          expectedArchive.every(
            (r) =>
                r['status'] == 'delivered' &&
                r['orderAuthor'] == an &&
                r['orderSeq'] is int,
          ),
          isTrue,
        );
        expect((first['historyState'] as Map)['mirrors'], 0);
        await a.stop();
        await e.start();
        final second = await _inspect(e, ci, bn, seed: true, author: an);
        expect(_compare(expectedArchive, _archive(second))['passed'], isTrue);
        expect(_ordered(expectedArchive, _archive(second)), isTrue);
        expect((second['historyState'] as Map)['mirrors'], 0);
        result['sourceArchivesEqual'] = true;
        expect(first['seededArchiveOrder'], isA<Map>());
        expect(second['seededArchiveOrder'], isA<Map>());
        result['sourceArchiveAppendOrder'] = {
          'A': first['seededArchiveOrder'],
          'E': second['seededArchiveOrder'],
        };
        await _gate(a, 'encode', 'arm').writeAsString('arm');
        await _gate(e, 'encode', 'arm').writeAsString('arm');
        await _gate(b, 'apply', 'arm').writeAsString('arm');
        if (crashAtRow != null) {
          await File('${b.dir.path}/history-midpoint-apply-arm')
              .writeAsString('arm');
        }
        await a.start();
        await b.start();
        await Future.wait([_entered(a, 'encode'), _entered(e, 'encode')]);
        result['bothEncodeGatesEntered'] = true;
        expect(_archive(await _inspect(b, ci, bn)).length, 0);
        final historyElapsed = Stopwatch()..start();
        await _gate(a, 'encode', 'release').writeAsString('release');
        await _gate(e, 'encode', 'release').writeAsString('release');
        await _entered(b, 'apply');
        final sourceSnapshots = [
          await _inspect(a, ci, bn),
          await _inspect(e, ci, bn),
        ];
        final requests = <String, String>{};
        for (var i = 0; i < 2; i++) {
          expect(
            (sourceSnapshots[i]['historyGates'] as Map)['encodeReleased'],
            1,
          );
          expect(
            (sourceSnapshots[i]['historyGates'] as Map)['encodeFailures'],
            0,
          );
          final rows = sourceSnapshots[i]['historyWire'] as List;
          final query =
              rows.firstWhere(
                    (r) =>
                        r['kind'] == 'query' &&
                        r['op'] == 'page' &&
                        r['fromDevice'] == bn &&
                        r['authenticated'] == true,
                  )
                  as Map;
          requests[i == 0 ? an : en] = query['request'] as String;
        }
        expect(requests.length, 2);
        Map<String, dynamic>? held;
        await waitUntil(
          () async {
            held = await _inspect(b, ci, bn);
            final rows = held!['historyWire'] as List;
            for (final pair in requests.entries) {
              final parts = rows
                  .where(
                    (r) =>
                        r['kind'] == 'part' &&
                        r['request'] == pair.value &&
                        r['fromDevice'] == pair.key &&
                        r['authenticated'] == true,
                  )
                  .toList();
              if (parts.isEmpty ||
                  parts.map((r) => r['index']).toSet().length !=
                      parts.first['parts']) {
                return false;
              }
            }
            return true;
          },
          what:
              'both native replies fully arrive while the first apply is held',
          timeout: const Duration(seconds: 30),
          interval: const Duration(milliseconds: 100),
        );
        expect(_archive(held!).length, 0);
        expect((held!['historyGates'] as Map)['applyFirstRowCalls'], 1);
        result['bothRepliesReceivedBeforeApplyRelease'] = true;
        result['authenticatedSources'] = 2;
        result['archiveRowsBeforeApplyRelease'] = 0;
        await save();
        if (crashBeforeApply) {
          await _crashAndRecover(
            fleet: fleet,
            peer: ci,
            receiver: bn,
            source: an,
            expected: _all(first),
            held: held!,
            result: result,
            save: save,
          );
          return;
        }
        await _inspect(b, ci, bn, resetTiming: true);
        final applyElapsed = Stopwatch()..start();
        await _gate(b, 'apply', 'release').writeAsString('release');
        if (crashAtRow != null) {
          final midpoint = File(
            '${b.dir.path}/history-midpoint-apply-entered.json',
          );
          await waitUntil(() => midpoint.exists(),
            what: 'receiver holds durable page data before its checkpoint',
            timeout: Duration(minutes: _rows > 10000 ? 20 : 3),
            interval: const Duration(milliseconds: 100));
          final marker = jsonDecode(await midpoint.readAsString()) as Map;
          expect(marker['matchedRowIndex'], crashAtRow);
          expect(marker['matchedFirstRow'], isFalse);
          final partial = await _inspect(b, ci, bn, cursors: [an, en]);
          final retained = _archive(partial).length;
          expect(retained, (crashAtRow ~/ preparedMessageBatchMaxRows + 1) *
              preparedMessageBatchMaxRows);
          expect(retained, inInclusiveRange(1, _rows - 1));
          final checkpoints = Map<String, String>.from(
            partial['historyCursors'] as Map,
          );
          expect(checkpoints, hasLength(2));
          var dataBeyondCursor = false;
          for (final raw in checkpoints.values) {
            final cursor = jsonDecode(raw) as Map;
            expect(cursor['peer'], ci);
            final position = cursor['cursor'] as List;
            final id = position[1] as String;
            expect(id.startsWith(_prefix), isTrue);
            final index = int.parse(id.substring(_prefix.length));
            expect(index, lessThan(retained));
            dataBeyondCursor |= index + 1 < retained;
          }
          expect(dataBeyondCursor, isTrue,
              reason: 'SIGKILL must precede the durable page checkpoint');
          expect((partial['historyGates'] as Map)['partialApplyRowCalls'], 1);
          expect((partial['historyGates'] as Map)['partialApplyReleased'], 0);
          expect((partial['historyGates'] as Map)['partialApplyFailures'], 0);
          result['unfinishedPageAtCrash'] = true;
          result['crashAfterPublicationBeforeCheckpoint'] = true;
          result['applyReleaseToCrashGateMs'] = applyElapsed.elapsedMilliseconds;
          await _crashAndRecover(
            fleet: fleet, peer: ci, receiver: bn, source: an,
            expected: _all(first), held: partial, result: result, save: save,
            beforeApply: false, cursorsBeforeCrash: checkpoints,
          );
          return;
        }
        Map<String, dynamic>? finalB;
        await waitUntil(
          () async {
            final largeArchive = _rows > 10000;
            final progress = await _inspect(
              b,
              ci,
              bn,
              cursors: [an, en],
              progressOnly: largeArchive,
            );
            final cursors = progress['historyCursors'] as Map;
            if (cursors.length != 2) return false;
            for (final raw in cursors.values) {
              if (raw is! String) return false;
              final cursor = jsonDecode(raw) as Map;
              if (cursor.containsKey('peer') ||
                  (cursor.isNotEmpty && cursor['after'] != ci)) {
                return false;
              }
            }
            finalB = largeArchive
                ? await _inspect(b, ci, bn, cursors: [an, en])
                : progress;
            return _compare(expectedArchive, _archive(finalB!))['passed'] ==
                    true &&
                _ordered(expectedArchive, _archive(finalB!));
          },
          what: 'both source cursors finish and all archived rows converge',
          timeout: Duration(minutes: _rows > 10000 ? 20 : 3),
          interval: Duration(milliseconds: pollMs),
        );
        historyElapsed.stop();
        applyElapsed.stop();
        result['encodeReleaseToConvergenceMs'] =
            historyElapsed.elapsedMilliseconds;
        result['applyReleaseToConvergenceMs'] =
            applyElapsed.elapsedMilliseconds;
        expect((finalB!['historyGates'] as Map)['applyFirstRowCalls'], 2);
        expect((finalB!['historyGates'] as Map)['applyReleased'], 1);
        expect((finalB!['historyGates'] as Map)['applyFailures'], 0);
        expect(finalB!['historyFailures'], 0);
        final baselineIds = {for (final row in baselineB) row['id'] as String};
        final baselineRetained = crashRetentionOf(
          expected: [
            for (final row in _retentionRows(baselineB))
              CrashRetentionRow(
                id: row.id,
                delivered: row.delivered,
                bodyTag: row.bodyTag,
              ),
          ],
          actual: _retentionRows(
            _all(finalB!).where((r) => baselineIds.contains(r['id'])).toList(),
          ),
          allowedIds: baselineIds,
        );
        expect(baselineRetained['passed'], isTrue);
        result['baselineRetained'] = baselineRetained;
        result['archiveConvergence'] = _compare(
          expectedArchive,
          _archive(finalB!),
        );
        result['bothSourceCursorsFinished'] = true;
        result['firstArchiveRowApplications'] = 2;
        result['historyFailures'] = 0;
        result['gatesReleasedWithoutFailure'] = true;
        for (final source in [a, e]) {
          expect(
            ((await _inspect(source, ci, bn))['historyState']
                as Map)['mirrors'],
            0,
          );
        }
        result['sourceDeviceJournalArchiveMirrors'] = 0;
        final allRows = _all(finalB!);
        await a.stop();
        await e.stop();
        await b.stop();
        final witness = ++_nonce;
        await File('${b.dir.path}/history-overlap-witness.json').writeAsString(
          jsonEncode({
            'witness': witness,
            'allowedIds': allRows.map((r) => r['id']).toList(),
            'expectedRows': [
              for (final row in _retentionRows(allRows))
                {
                  'id': row.id,
                  'delivered': row.delivered,
                  'orderAuthor': row.orderAuthor,
                  'orderSeq': row.orderSeq,
                  'bodyTag': row.bodyTag,
                },
            ],
          }),
          flush: true,
        );
        await b.start();
        final boot =
            (await File(
                  '$evidence/overlap-B-before-network-private.jsonl',
                ).readAsLines())
                .map((line) => jsonDecode(line) as Map)
                .singleWhere((row) => row['witness'] == witness);
        expect((boot['retention'] as Map)['passed'], isTrue);
        expect((boot['retention'] as Map)['expectedRows'], allRows.length);
        result['retentionBeforeNetwork'] = boot['retention'];
        final after = _all(await _inspect(b, ci, bn));
        expect(_compare(allRows, after)['passed'], isTrue);
        expect(_ordered(allRows, after), isTrue);
        expect(_invalid, isFalse);
        result['finalRows'] = allRows.length;
        result['retainedWithAllSourcesOffline'] = true;
        result['invalidSnapshotObserved'] = _invalid;
        result['passed'] = true;
      } finally {
        for (final d in [a, b, e]) {
          for (final kind in ['encode', 'apply']) {
            await _gate(d, kind, 'release').writeAsString('cleanup');
          }
          await File('${d.dir.path}/history-midpoint-apply-release')
              .writeAsString('cleanup');
        }
        await save();
      }
    },
    skip: gate.skip,
  );
}
