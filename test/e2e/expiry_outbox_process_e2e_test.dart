@Timeout(Duration(minutes: 12))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import '../support/queued_snapshot_probe.dart';
import 'device_process_fixture.dart';
import 'e2e_env.dart';
import 'multi_device_process_e2e_test.dart' as base;

const _keep = 'stand.ttl.keep';
int _sequence = 0;
Future<Map<String, dynamic>> _probe(
  ProcessDevice d,
  Set<String> ids, {
  String? queueFor,
}) async {
  final nonce = 'ttl-queue-${++_sequence}';
  final request = File('${d.dir.path}/storage-inspect.new');
  await request.writeAsString(
    jsonEncode({
      'nonce': nonce,
      'outboxExpiryIds': ids.toList(),
      'keepKey': _keep,
      if (queueFor != null) ...{'queueFullSnapshot': true, 'target': queueFor},
    }),
  );
  await request.rename('${d.dir.path}/storage-inspect.json');
  Map<String, dynamic>? result;
  await waitUntil(
    () async {
      final response = File('${d.dir.path}/storage-inspected.json');
      if (!await response.exists()) return false;
      final value =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      if (value['nonce'] != nonce) return false;
      result = value;
      return true;
    },
    what: 'live owner inspects queued snapshot bytes',
    timeout: const Duration(seconds: 60),
    interval: const Duration(milliseconds: 100),
  );
  return result!;
}

void main() {
  final gate = E2eGate.read();
  test(
    'expired Outbox snapshots are rewritten, survive restart and retain live state',
    () async {
      final f = await ProcessFleet.start(gate);
      addTearDown(f.dispose);
      final a = f.a, b = f.b, c = f.c;
      await base.introduceProcesses(a, c);
      await base.linkProcesses(a, b);
      final ai = (await base.deviceInfo(a))['identity'] as String;
      final ci = (await base.deviceInfo(c))['identity'] as String;
      final bDevice = (await base.deviceInfo(b))['nodeId'] as String;
      await a.checked('/disappearing', query: {'peer': ci, 'set': '30'});
      await waitUntil(
        () async =>
            (await b.checked(
                  '/disappearing',
                  query: {'peer': ci},
                ))['ttlSeconds'] ==
                30 &&
            (await c.checked(
                  '/disappearing',
                  query: {'peer': ai},
                ))['ttlSeconds'] ==
                30,
        what: 'real TTL policy is present before B goes offline',
      );
      await b.stop();
      const bodies = ['outbox-ttl-incoming', 'outbox-ttl-outgoing'];
      await c.checked('/send_message', query: {'peer': ai, 'text': bodies[0]});
      await a.checked('/send_message', query: {'peer': ci, 'text': bodies[1]});
      for (final body in bodies) {
        await base.hasBody(a, ci, body);
        await base.hasBody(c, ai, body);
      }
      final source = (await base.rows(
        a,
        ci,
      )).where((r) => bodies.contains(r['body'])).toList();
      expect(source, hasLength(2));
      final ids = source.map((r) => r['id'] as String).toSet();
      expect(ids, hasLength(2));
      final expiry = source
          .map(
            (r) => DateTime.parse(
              r['timestamp'] as String,
            ).add(const Duration(seconds: 30)),
          )
          .reduce((a, b) => a.isAfter(b) ? a : b);
      await a.checked(
        '/device_post_event',
        query: {'kind': 'settingSet', 'key': _keep, 'v': 'retained'},
      );
      final before = await _probe(a, ids, queueFor: bDevice);
      expect(before['matchingIds'], 2);
      expect(
        before['mixedTransfers'],
        greaterThan(0),
        reason:
            'a complete queued snapshot must really contain both expired-to-be bodies and live state',
      );
      expect(DateTime.now().isBefore(expiry), isTrue);
      E2eLog.line('PROCESS_TTL_OUTBOX_LIVE_MIXED_COPY_CONFIRMED');
      await waitUntil(
        () => !DateTime.now().isBefore(expiry),
        what: 'original TTL expires with B offline',
        timeout: const Duration(seconds: 40),
      );
      Map<String, dynamic>? after;
      await waitUntil(
        () async {
          after = await _probe(a, ids);
          return after!['matchingIds'] == 0 &&
              after!['partialTransfers'] == 0 &&
              after!['malformedTransfers'] == 0 &&
              after!['keepRows'] > 0 &&
              after!['cleanupPending'] == false;
        },
        what:
            'background sweep retires old queued plaintext and finishes vacuum',
        timeout: const Duration(seconds: 60),
        describe: () async => '$after',
      );
      final gid = after!['groupId'] as String;
      E2eLog.line('PROCESS_TTL_OUTBOX_LIVE_OWNER_CLEAN');
      await a.stop();
      expect(
        ensureHiddenVolumeLoaded(dylibPath: gate.hiddenVolumeDylib),
        isTrue,
      );
      final raw = (await workerSpaceOpener('${a.dir.path}/store.hv')(
        password: Uint8List.fromList(utf8.encode('e2e-A-password')),
        create: false,
      ))!;
      try {
        final disk = await stoppedOutboxStats(raw, gid, ids, keepKey: _keep);
        expect(disk['matchingIds'], 0);
        expect(disk['partialTransfers'], 0);
        expect(disk['malformedTransfers'], 0);
        expect(disk['orphanPayloadRows'], 0);
        expect(disk['cleanupPending'], 0);
        expect(disk['keepRows'], greaterThan(0));
      } finally {
        await raw.close();
      }
      E2eLog.line('PROCESS_TTL_OUTBOX_RAW_NATIVE_ROOTS_CLEAN');
      await a.start();
      await b.start();
      await waitUntil(() async {
        final events = (await b.checked('/device_events'))['events'] as Map;
        return events['settingSet|$_keep'] is Map &&
            ((events['settingSet|$_keep'] as Map)['payload'] as Map)['v'] ==
                'retained';
      }, what: 'B receives the retained signed state after A restarts');
      Future<void> noExpired() async {
        final events = (await b.checked('/device_events'))['events'] as Map;
        final messages = await base.rows(b, ci);
        for (final id in ids) {
          expect(events.containsKey('msgMirror|$id'), isFalse);
          expect(messages.any((m) => m['id'] == id), isFalse);
        }
      }

      await noExpired();
      await a.checked(
        '/send_message',
        query: {'peer': ci, 'text': 'outbox-ttl-fresh'},
      );
      await base.hasBody(b, ci, 'outbox-ttl-fresh');
      await base.hasBody(c, ai, 'outbox-ttl-fresh');
      E2eLog.line('PROCESS_TTL_OUTBOX_REPLACEMENT_AND_FRESH_DELIVERY_PASS');
      await c.stop();
      await a.stop();
      await b.restart();
      await noExpired();
      final held = (await b.checked('/device_events'))['events'] as Map;
      expect(held.containsKey('settingSet|$_keep'), isTrue);
      E2eLog.line('PROCESS_TTL_OUTBOX_COLD_SIBLING_RETENTION_PASS');
    },
    skip: gate.skip,
  );
}
