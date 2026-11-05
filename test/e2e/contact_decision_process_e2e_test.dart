@Timeout(Duration(minutes: 15))
library;

import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/domain/chat.dart';
import 'device_process_fixture.dart';
import 'e2e_env.dart';
import 'multi_device_process_e2e_test.dart' as base;

int _sequence = 0;
Future<int> pending(ProcessDevice d) async {
  final nonce = 'contact-decisions-${++_sequence}';
  final request = File('${d.dir.path}/storage-inspect.new');
  await request.writeAsString(
    jsonEncode({'nonce': nonce, 'contactDecisions': true}),
  );
  await request.rename('${d.dir.path}/storage-inspect.json');
  int? count;
  await waitUntil(() async {
    final f = File('${d.dir.path}/storage-inspected.json');
    if (!await f.exists()) return false;
    final data = jsonDecode(await f.readAsString()) as Map;
    if (data['nonce'] != nonce) return false;
    count = data['pending'] as int;
    return true;
  }, what: 'live owner inspects durable contact obligations');
  return count!;
}

Future<int?> eventTime(ProcessDevice d, String peer, String status) async {
  final events = (await d.checked('/device_events'))['events'] as Map;
  final event = events['contactUp|s:$peer'];
  return event is Map && (event['payload'] as Map)['status'] == status
      ? event['ts'] as int
      : null;
}

void main() {
  final gate = E2eGate.read();
  test(
    'a committed decision without a callback is recovered at boot with its original version',
    () async {
      final f = await ProcessFleet.start(gate);
      addTearDown(f.dispose);
      final a = f.a, b = f.b, c = f.c;
      await base.introduceProcesses(a, c);
      await base.linkProcesses(a, b);
      final ci = (await base.deviceInfo(c))['identity'] as String;
      await waitUntil(
        () async => await base.contactStatus(b, ci) == 'accepted',
        what: 'B starts with the accepted contact',
      );
      await a.stop();
      expect(ensureHiddenVolumeLoaded(dylibPath: gate.hiddenVolumeDylib), true);
      final storage = HiddenVolumeStorage.async(
        workerSpaceOpener('${a.dir.path}/store.hv'),
      );
      late int originalTime;
      try {
        expect(await storage.open(password: 'e2e-A-password'), true);
        await storage.setContactStatus(
          NodeId.fromHex(ci),
          ContactStatus.blocked,
        );
        final rows = await storage.pendingContactDecisions();
        final record = rows.singleWhere((r) => r.peer.hex == ci);
        originalTime = record.atMs;
        expect(record.status, ContactStatus.blocked);
      } finally {
        await storage.close();
      }
      // This creates the exact post-commit/pre-callback durable state using the
      // production storage port, rather than claiming to kill at a live UI await.
      expect(await base.contactStatus(b, ci), 'accepted');
      E2eLog.line('PROCESS_CONTACT_UNPUBLISHED_STATE_CONFIRMED');
      await a.start();
      await waitUntil(
        () async =>
            await base.contactStatus(a, ci) == 'blocked' &&
            await base.contactStatus(b, ci) == 'blocked' &&
            await eventTime(a, ci, 'blocked') == originalTime &&
            await eventTime(b, ci, 'blocked') == originalTime &&
            await pending(a) == 0,
        what: 'boot publisher commits the original decision and B applies it',
        timeout: const Duration(minutes: 3),
      );
      E2eLog.line('PROCESS_CONTACT_BOOT_RECOVERY_PASS');
      await a.restart();
      await waitUntil(
        () async =>
            await base.contactStatus(a, ci) == 'blocked' &&
            await eventTime(a, ci, 'blocked') == originalTime &&
            await eventTime(b, ci, 'blocked') == originalTime &&
            await pending(a) == 0,
        what:
            'another boot neither restamps nor republishes an acknowledged decision',
        timeout: const Duration(minutes: 2),
      );
      E2eLog.line('PROCESS_CONTACT_COLD_VERSION_RETENTION_PASS');
      final before = await a.checked('/contact_info', query: {'peer': ci});
      await b.checked('/contact_set', query: {'peer': ci, 'p2p': 'deny'});
      await a.checked(
        '/contact_set',
        query: {
          'peer': ci,
          'name': 'stand-atomic-prefs',
          'pin': '1',
          'arc': '1',
        },
      );
      final observedPrefs = <String, Object?>{};
      Future<bool> prefsMatch(ProcessDevice device, {String? p2p}) async {
        final value = await device.checked(
          '/contact_info',
          query: {'peer': ci},
        );
        observedPrefs[device == a ? 'A' : 'B'] = {
          ...value,
          'decisionTimePreserved':
              await eventTime(device, ci, 'blocked') == originalTime,
        };
        return value['name'] == 'stand-atomic-prefs' &&
            value['pinned'] == true &&
            value['archived'] == true &&
            value['status'] == 'blocked' &&
            (p2p == null || value['p2pOverride'] == p2p) &&
            await eventTime(device, ci, 'blocked') == originalTime;
      }

      await waitUntil(
        () async =>
            await prefsMatch(a, p2p: before['p2pOverride'] as String) &&
            await prefsMatch(b, p2p: 'deny'),
        describe: () => jsonEncode(observedPrefs),
        what:
            'native sibling preference merge preserves the block and local P2P override',
        timeout: const Duration(minutes: 2),
      );
      E2eLog.line('PROCESS_CONTACT_PREFS_PRESERVE_DECISION_PASS');
      await b.restart();
      await waitUntil(
        () async => await prefsMatch(b, p2p: 'deny'),
        describe: () => jsonEncode(observedPrefs),
        what:
            'cold sibling retains contact preferences and independent consent',
        timeout: const Duration(minutes: 2),
      );
      E2eLog.line('PROCESS_CONTACT_PREFS_COLD_PASS');
      // Exact durable post-commit/pre-callback state, with no application
      // running on A. Boot must publish the stored snapshot/version, not mint
      // a fresh version or read an older folded contact projection instead.
      await a.stop();
      final offline = HiddenVolumeStorage.async(
        workerSpaceOpener('${a.dir.path}/store.hv'),
      );
      late int preferenceTime;
      try {
        expect(await offline.open(password: 'e2e-A-password'), true);
        await offline.updateContactPrefs(
          NodeId.fromHex(ci),
          (current) =>
              current.copyWith(name: 'stand-durable-prefs', archived: false),
          queueForSync: true,
        );
        preferenceTime = (await offline.pendingContactPreferences())
            .singleWhere((r) => r.peer.hex == ci)
            .atMs;
      } finally {
        await offline.close();
      }
      E2eLog.line('PROCESS_CONTACT_PREFS_UNPUBLISHED_CONFIRMED');
      await a.start();
      final bootPrefs = <String, Object?>{};
      Future<bool> restoredPrefs(ProcessDevice device) async {
        final value = await device.checked(
          '/contact_info',
          query: {'peer': ci},
        );
        final events =
            (await device.checked('/device_events'))['events'] as Map;
        final event = events['contactUp|$ci'];
        bootPrefs[device == a ? 'A' : 'B'] = value;
        return value['name'] == 'stand-durable-prefs' &&
            value['pinned'] == true &&
            value['archived'] == false &&
            value['status'] == 'blocked' &&
            (device != b || value['p2pOverride'] == 'deny') &&
            event is Map &&
            event['ts'] == preferenceTime &&
            (event['payload'] as Map)['name'] == 'stand-durable-prefs';
      }

      await waitUntil(
        () async => await restoredPrefs(a) && await restoredPrefs(b),
        what:
            'boot publishes the committed preference snapshot with its stored version',
        describe: () => jsonEncode(bootPrefs),
        timeout: const Duration(minutes: 2),
      );
      E2eLog.line('PROCESS_CONTACT_PREFS_BOOT_RECOVERY_PASS');
    },
    skip: gate.skip,
  );
}
