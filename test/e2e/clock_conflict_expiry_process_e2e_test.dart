@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'device_process_fixture.dart';
import 'e2e_env.dart';
import 'multi_device_process_e2e_test.dart' as base;

void main() {
  final gate = E2eGate.read();
  test(
    'old signed mirror clock keeps live history and edit for an offline sibling',
    () async {
      final fleet = await ProcessFleet.start(gate);
      addTearDown(fleet.dispose);
      final a = fleet.a, b = fleet.b, c = fleet.c;
      await base.introduceProcesses(a, c);
      await base.linkProcesses(a, b);
      final ai = (await base.deviceInfo(a))['identity'] as String;
      final ci = (await base.deviceInfo(c))['identity'] as String;
      await a.checked('/disappearing', query: {'peer': ci, 'set': '300'});
      await waitUntil(
        () async =>
            (await b.checked(
                  '/disappearing',
                  query: {'peer': ci},
                ))['ttlSeconds'] ==
                300 &&
            (await c.checked(
                  '/disappearing',
                  query: {'peer': ai},
                ))['ttlSeconds'] ==
                300,
        what: 'all devices hold the real TTL before B goes offline',
      );
      await b.stop();
      const original = 'clock-conflict-live-original';
      const edited = 'clock-conflict-live-edited';
      await a.checked('/send_message', query: {'peer': ci, 'text': original});
      await base.hasBody(a, ci, original);
      await base.hasBody(c, ai, original);
      final id =
          (await base.rows(
                a,
                ci,
              )).singleWhere((m) => m['body'] == original)['id']
              as String;
      await a.checked('/edit_message', query: {'id': id, 'text': edited});
      await base.hasBody(a, ci, edited);
      await base.hasBody(c, ai, edited);
      await c.stop();
      // Post through the real signer and GroupService in A, with a synthetic
      // old event clock. No OS wall clock or production code is changed.
      final request = File('${a.dir.path}/storage-inspect.new');
      await request.writeAsString(
        jsonEncode({
          'nonce': 'clock-conflict',
          'peer': ci,
          'conflictingMirrorTarget': id,
        }),
      );
      await request.rename('${a.dir.path}/storage-inspect.json');
      Map<String, dynamic>? inspected;
      await waitUntil(() async {
        final response = File('${a.dir.path}/storage-inspected.json');
        if (!await response.exists()) return false;
        final value =
            jsonDecode(await response.readAsString()) as Map<String, dynamic>;
        if (value['nonce'] != 'clock-conflict') return false;
        inspected = value;
        return true;
      }, what: 'live owner posts the conflicting signed mirror and compacts');
      expect(inspected!['canonicalWasLive'], isTrue);
      expect(inspected!['injectedClockWasExpired'], isTrue);
      expect(inspected!['accepted'], isTrue);
      expect(inspected!['mirrors'], greaterThan(0));
      expect(inspected!['edits'], greaterThan(0));
      expect(inspected!['allRowsVerify'], isTrue);
      expect(inspected!['staleBodies'], 0);
      expect(inspected!['canonicalDeleted'], isFalse);
      expect(inspected!['scrubPending'], isFalse);
      E2eLog.line('PROCESS_CLOCK_CONFLICT_SIGNED_LIVE_ROWS_PRESERVED');
      await base.hasBody(a, ci, edited);
      await b.start();
      await base.hasBody(b, ci, edited);
      final matching = (await base.rows(
        b,
        ci,
      )).where((m) => m['id'] == id).toList();
      expect(matching, hasLength(1));
      expect(matching.single['body'], edited);
      E2eLog.line('PROCESS_CLOCK_CONFLICT_OFFLINE_SIBLING_RECOVERED');
      await a.stop();
      await b.restart();
      await base.hasBody(b, ci, edited);
      final cold = (await base.rows(
        b,
        ci,
      )).where((m) => m['id'] == id).toList();
      expect(cold, hasLength(1));
      expect(cold.single['body'], edited);
      E2eLog.line('PROCESS_CLOCK_CONFLICT_COLD_RETENTION_PASS');
    },
    skip: gate.skip,
  );
}
