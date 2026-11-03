@Timeout(Duration(minutes: 12))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'device_process_fixture.dart';
import 'e2e_env.dart';
import 'multi_device_process_e2e_test.dart' as base;

int _request = 0;
Future<Map<String, dynamic>> _probe(
  ProcessDevice device,
  String operation,
) async {
  final nonce = 'room-${++_request}';
  final request = File('${device.dir.path}/storage-inspect.new');
  await request.writeAsString(
    jsonEncode({'nonce': nonce, 'historyRoom': operation}),
  );
  await request.rename('${device.dir.path}/storage-inspect.json');
  Map<String, dynamic>? result;
  await waitUntil(
    () async {
      final response = File('${device.dir.path}/storage-inspected.json');
      if (!await response.exists()) return false;
      final value =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      if (value['nonce'] != nonce) return false;
      result = value;
      return true;
    },
    what: 'linked source returns its history-room probe',
    timeout: const Duration(seconds: 90),
    interval: const Duration(milliseconds: 100),
  );
  return result!..remove('nonce');
}

void main() {
  final gate = E2eGate.read();
  test('linked source checks the actual master Outbox queue', () async {
    final fleet = await ProcessFleet.start(gate);
    addTearDown(fleet.dispose);
    await base.linkProcesses(fleet.a, fleet.b);
    final masterInfo = await _probe(fleet.a, 'info');
    Map<String, dynamic>? linkedInfo;
    await waitUntil(
      () async {
        linkedInfo = await _probe(fleet.b, 'info');
        final evidence = Platform.environment['XVEIL_E2E_EVIDENCE_DIR'];
        if (evidence != null) {
          await File('$evidence/history-room-preconditions.json').writeAsString(
            jsonEncode({'master': masterInfo, 'linked': linkedInfo}),
          );
        }
        return linkedInfo!['ready'] == true;
      },
      what: 'B resolves master device separately from its registry identity',
      describe: () async => '$linkedInfo',
    );
    await fleet.a.stop();
    final result = await _probe(fleet.b, 'fill-and-check');
    final evidence = Platform.environment['XVEIL_E2E_EVIDENCE_DIR'];
    if (evidence != null) {
      await File('$evidence/history-room-summary.json').writeAsString(
        jsonEncode({
          'schema': 'xveil-history-room-stand/1',
          'sourceLinked': true,
          'masterStoppedBeforeEnqueue': true,
          ...result,
        }),
      );
    }
    expect(result['actualPending'], greaterThanOrEqualTo(128));
    expect(result['durableActualPending'], greaterThanOrEqualTo(128));
    expect(result['aliasPending'], lessThan(128));
    expect(
      result['sawActual'],
      isTrue,
      reason: 'history room must inspect the full physical master queue',
    );
    expect(result['sawAlias'], isFalse);
    expect(
      result['returnedBeforeCancel'],
      isFalse,
      reason: 'the empty identity queue must not release a full device queue',
    );
    expect(result['cancelledCleanly'], isTrue);
  }, skip: gate.skip);
}
