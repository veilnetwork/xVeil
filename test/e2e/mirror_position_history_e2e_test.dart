@Timeout(Duration(minutes: 15))
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'device_process_fixture.dart';
import 'e2e_env.dart';
import 'multi_device_process_e2e_test.dart' as base;

void main() {
  final gate = E2eGate.read();
  test(
    'verified message positions survive compaction and linking a third own device',
    () async {
      final f = await ProcessFleet.start(
        gate,
        labels: const ['A', 'B', 'C', 'E'],
      );
      addTearDown(f.dispose);
      final a = f.a, b = f.b, c = f.c, e = f.devices['E']!;
      await base.introduceProcesses(a, c);
      final gid = await base.linkProcesses(a, b);
      final peer = (await base.deviceInfo(c))['identity'] as String;
      final identity = (await base.deviceInfo(a))['identity'] as String;

      for (var i = 0; i < 2; i++) {
        await a.checked(
          '/send_message',
          query: {'peer': peer, 'text': 'position-history-$i'},
        );
        await base.hasBody(c, identity, 'position-history-$i');
        await base.hasBody(b, peer, 'position-history-$i');
      }
      final sourceRows = (await base.rows(
        a,
        peer,
      )).where((m) => '${m['body']}'.startsWith('position-history-')).toList();
      expect(sourceRows, hasLength(2));
      final initial = (await a.checked('/device_events'))['events'] as Map;
      final expected = <String, Map<String, dynamic>>{};
      for (var i = 0; i < sourceRows.length; i++) {
        final id = sourceRows[i]['id'] as String;
        final event = Map<String, dynamic>.from(
          initial['msgMirror|$id'] as Map,
        );
        final payload = Map<String, dynamic>.from(event['payload'] as Map);
        expect(
          payload['pv'],
          isTrue,
          reason: 'original send must record its provenance',
        );
        expected[id] = event;
        // A controlled older-schema / explicit peer-echo backfill, published by
        // an authorised own writer through the existing debug API. Its message
        // time is NEWER than the original and its temporary position differs.
        // No production-only test hook or storage/cache mutation is used.
        final provisional = Map<String, dynamic>.from(payload)
          ..['au'] = identity
          ..['sq'] = 900 + i
          ..remove('pv');
        if (i == 1) provisional['pv'] = false;
        await a.checked(
          '/device_post_event',
          query: {'kind': 'msgMirror', 'key': id, 'p': jsonEncode(provisional)},
        );
      }
      // Advance the writer's chain head, so it cannot incidentally retain a
      // losing copy and make the compaction assertions vacuous.
      await a.checked(
        '/device_post_event',
        query: {
          'kind': 'settingSet',
          'key': 'position-test-head',
          'v': 'after-history',
        },
      );
      final compacted = await a.checked(
        '/group_compact',
        query: {'group': gid},
      );
      final sizes = compacted['messages'] as List;
      expect(
        sizes[1] as int,
        lessThan(sizes[0] as int),
        reason: 'real pruning is required',
      );
      E2eLog.line('PROCESS_POSITION_HISTORY_REAL_COMPACTION');

      Future<void> verify(ProcessDevice device) async {
        await waitUntil(
          () async {
            final events =
                (await device.checked('/device_events'))['events'] as Map;
            for (final entry in expected.entries) {
              final held = events['msgMirror|${entry.key}'];
              if (held is! Map || jsonEncode(held) != jsonEncode(entry.value)) {
                return false;
              }
            }
            final rows = (await base.rows(
              device,
              peer,
            )).where((m) => expected.containsKey(m['id'])).toList();
            if (rows.length != expected.length) return false;
            for (var i = 0; i < sourceRows.length; i++) {
              for (final field in [
                'id',
                'direction',
                'body',
                'timestamp',
                'seq',
              ]) {
                if (rows[i][field] != sourceRows[i][field]) return false;
              }
            }
            return true;
          },
          what:
              'canonical journal positions and ordered history on ${device.label}',
          timeout: const Duration(minutes: 3),
        );
      }

      await verify(a);
      // The new device must obtain history from A; neither B nor the contact is
      // available to mask a lost position in A's compacted device journal.
      await b.stop();
      await c.stop();
      await base.linkProcesses(a, e);
      await verify(e);
      E2eLog.line('PROCESS_POSITION_HISTORY_THIRD_DEVICE_FROM_A_ONLY');
      await e.restart();
      await base.join(e, a);
      await base.join(a, e);
      await verify(e);
      E2eLog.line('PROCESS_POSITION_HISTORY_COMPACTION_LINK_RESTART_PASS');
    },
    skip: gate.skip,
  );
}
