@Timeout(Duration(minutes: 8))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'device_process_fixture.dart';
import 'e2e_env.dart';
import 'multi_device_process_e2e_test.dart' as base;
import 'offline_backlog_process_e2e_test.dart' as observer;

int _request = 0;
Future<Map<String, dynamic>> _inspect(
  ProcessDevice device,
  String peer,
  String askingDevice, {
  bool seed = false,
}) async {
  final nonce = 'record-native-${++_request}';
  final request = File('${device.dir.path}/storage-inspect.new');
  await request.writeAsString(
    jsonEncode({
      'nonce': nonce,
      'peer': peer,
      'prefix': '',
      'historyBodyPrefix': 'record-stand-',
      'historyAskingDevice': askingDevice,
      if (seed) 'seedOwnHistory': true,
    }),
  );
  await request.rename('${device.dir.path}/storage-inspect.json');
  Map<String, dynamic>? result;
  await waitUntil(
    () async {
      final response = File('${device.dir.path}/storage-inspected.json');
      if (!await response.exists()) return false;
      final value = jsonDecode(await response.readAsString()) as Map;
      if (value['nonce'] != nonce) return false;
      result = Map<String, dynamic>.from(value['historyState'] as Map);
      return true;
    },
    what: 'live storage stages or inspects history outside the device journal',
  );
  return result!;
}

void main() {
  final gate = E2eGate.read();
  test(
    'native siblings recover an oversized event absent from the device journal',
    () async {
      final fleet = await ProcessFleet.start(gate);
      addTearDown(fleet.dispose);
      final a = fleet.a, b = fleet.b, c = fleet.c;
      final evidence = Platform.environment['XVEIL_BACKLOG_EVIDENCE'];
      final result = <String, Object?>{
        'devices': 3,
        'rows': 3,
        'largeBodyBytes': 160015,
      };
      Future<void> save() async {
        if (evidence != null) {
          await File('$evidence/result.json').writeAsString(jsonEncode(result));
        }
      }

      try {
        await base.introduceProcesses(a, c);
        await base.linkProcesses(a, b);
        final ci = (await base.deviceInfo(c))['identity'] as String;
        final bi = (await base.deviceInfo(b))['nodeId'] as String;
        await waitUntil(
          () async => await base.contactStatus(b, ci) == 'accepted',
          what: 'B already has the accepted contact',
        );
        final before = await observer.rows(a, ci, const {});
        final baseline = before.map((row) => row['id'] as String).toSet();
        await b.stop();
        await c.stop();
        final state = await _inspect(a, ci, bi, seed: true);
        expect(state['mirrors'], 0);
        final source = (await observer.rows(
          a,
          ci,
          baseline,
        )).where((row) => !baseline.contains(row['id'])).toList();
        expect(source, hasLength(3));
        expect(source.map((row) => row['id']), [
          'record-stand-0',
          'record-stand-1',
          'record-stand-2',
        ]);
        expect(source[1]['body'], 'record-stand-1:${'x' * 160000}');
        result['sourceMirrorsBefore'] = state['mirrors'];
        final expected = {for (final row in source) row['id']: row};
        bool matches(List<Map<String, dynamic>> all) {
          final fresh = all
              .where((row) => !baseline.contains(row['id']))
              .toList();
          return all.length == baseline.length + 3 &&
              all.map((row) => row['id']).toSet().containsAll(baseline) &&
              fresh.map((row) => row['id']).join('|') ==
                  source.map((row) => row['id']).join('|') &&
              fresh.every(
                (row) =>
                    row['body'] == expected[row['id']]!['body'] &&
                    row['orderAuthor'] is String &&
                    row['orderSeq'] is int &&
                    row['orderAuthor'] == expected[row['id']]!['orderAuthor'] &&
                    row['orderSeq'] == expected[row['id']]!['orderSeq'] &&
                    row['status'] == 'delivered',
              );
        }

        final elapsed = Stopwatch()..start();
        await b.start();
        var held = <Map<String, dynamic>>[];
        await waitUntil(
          () async {
            held = await observer.rows(b, ci, baseline);
            return matches(held);
          },
          what: 'B recovers the full oversized event and its following row',
          describe: () => 'storedRows=${held.length}',
          timeout: const Duration(minutes: 3),
        );
        result['secondsIncludingReceiverStart'] =
            elapsed.elapsedMilliseconds / 1000;
        result['duplicateIds'] =
            held.length - held.map((row) => row['id']).toSet().length;
        result['sourceMirrorsAfter'] = (await _inspect(a, ci, bi))['mirrors'];
        expect(result['sourceMirrorsAfter'], 0);
        await a.stop();
        await b.restart();
        expect(matches(await observer.rows(b, ci, baseline)), isTrue);
        result['retainedWithoutSource'] = true;
        result['passed'] = true;
      } finally {
        await save();
      }
    },
    skip: gate.skip,
  );
}
