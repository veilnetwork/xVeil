@Timeout(Duration(minutes: 12))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import '../support/queued_snapshot_probe.dart';
import 'device_process_fixture.dart';
import 'e2e_env.dart';
import 'multi_device_process_e2e_test.dart' as base;

int _nonce = 0;
Future<Map<String, dynamic>> _probe(
  ProcessDevice device,
  String peer,
  String target, {
  int? seq,
}) async {
  final nonce = 'expired-edit-${++_nonce}';
  final file = File('${device.dir.path}/storage-inspect.new');
  await file.writeAsString(
    jsonEncode({
      'nonce': nonce,
      'directEditTarget': target,
      'peer': peer,
      'seq': ?seq,
    }),
  );
  await file.rename('${device.dir.path}/storage-inspect.json');
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
    what: 'private owner probe observes queued edit',
    timeout: const Duration(seconds: 60),
  );
  return result!;
}

void main() {
  final gate = E2eGate.read();
  test(
    'direct edit expires offline, raw roots stay clean and void is durably ACKed',
    () async {
      final fleet = await ProcessFleet.start(gate);
      addTearDown(fleet.dispose);
      final a = fleet.a, b = fleet.b, c = fleet.c;
      await base.introduceProcesses(a, c);
      await base.linkProcesses(a, b);
      final ai = (await base.deviceInfo(a))['identity'] as String;
      final ci = (await base.deviceInfo(c))['identity'] as String;
      await a.checked('/disappearing', query: {'peer': ci, 'set': '30'});
      await waitUntil(
        () async =>
            (await c.checked(
              '/disappearing',
              query: {'peer': ai},
            ))['ttlSeconds'] ==
            30,
        what: 'peer has shared TTL before going offline',
      );
      await b.stop();
      await a.checked(
        '/send_message',
        query: {'peer': ci, 'text': 'original-ttl-edit'},
      );
      await base.hasBody(a, ci, 'original-ttl-edit');
      await base.hasBody(c, ai, 'original-ttl-edit');
      final original = (await base.rows(
        a,
        ci,
      )).singleWhere((r) => r['body'] == 'original-ttl-edit');
      final id = original['id'] as String;
      await c.stop();
      await a.checked(
        '/edit_message',
        query: {'id': id, 'text': 'private-offline-ttl-edit'},
      );
      final before = await _probe(a, ci, id);
      expect(before['targetedEdits'], 1);
      final seq = before['editSeq'] as int;
      expect(seq, greaterThan(0));
      E2eLog.line('PROCESS_EXPIRED_EDIT_LIVE_QUEUE_CONFIRMED');
      Map<String, dynamic>? cleaned;
      await waitUntil(
        () async {
          cleaned = await _probe(a, ci, id, seq: seq);
          return cleaned!['targetedEdits'] == 0 &&
              cleaned!['voidSlots'] == 1 &&
              cleaned!['cleanupPending'] == false;
        },
        what:
            'ordinary background sweep replaces expired edit while C stays offline',
        timeout: const Duration(seconds: 75),
        describe: () async => '$cleaned',
      );
      E2eLog.line('PROCESS_EXPIRED_EDIT_BACKGROUND_CLEAN');
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
        final frames = <OutboxFrame>[];
        final stats = await stoppedOutboxStats(
          raw,
          'ab' * 32,
          {},
          keepKey: 'unused',
          inspectFrames: frames.addAll,
        );
        expect(stats['orphanPayloadRows'], 0);
        expect(stats['cleanupPending'], 0);
        final peerFrames = [
          for (final frame in frames)
            if (frame.peerHex == ci) WireEnvelope.decode(frame.wire),
        ];
        expect(
          peerFrames.any((e) => e.kind == WireKind.edit && e.id == id),
          isFalse,
        );
        final slot = peerFrames.singleWhere(
          (e) => e.kind == WireKind.voidSeq && e.seq == seq,
        );
        expect(slot.body, isEmpty);
        expect(slot.id, isNull);
      } finally {
        await raw.close();
      }
      E2eLog.line('PROCESS_EXPIRED_EDIT_RAW_ROOTS_CLEAN');
      await a.start();
      final restarted = Stopwatch()..start();
      await c.start();
      final firstRead = await base.rows(c, ai);
      expect(firstRead.any((r) => r['id'] == id), isFalse);
      expect(
        restarted.elapsed,
        lessThan(const Duration(seconds: 30)),
        reason: 'qualification must precede the old first periodic sweep',
      );
      E2eLog.line(
        'PROCESS_STARTUP_TTL_FIRST_READ_PASS ready_ms=${restarted.elapsedMilliseconds}',
      );
      await waitUntil(
        () async {
          final receiver = await _probe(c, ai, id, seq: seq);
          final sender = await _probe(a, ci, id, seq: seq);
          return receiver['peerHighWater'] >= seq &&
              sender['voidSlots'] == 0 &&
              sender['targetedEdits'] == 0;
        },
        what: 'receiver stores void slot before its ACK retires sender queue',
        timeout: const Duration(minutes: 2),
      );
      await a.checked(
        '/send_message',
        query: {'peer': ci, 'text': 'fresh-after-expired-edit'},
      );
      await base.hasBody(c, ai, 'fresh-after-expired-edit');
      expect((await base.rows(c, ai)).any((r) => r['id'] == id), isFalse);
      E2eLog.line('PROCESS_EXPIRED_EDIT_ACK_AND_FRESH_DELIVERY_PASS');
    },
    skip: gate.skip,
  );
}
