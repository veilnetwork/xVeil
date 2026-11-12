@Timeout(Duration(minutes: 12))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'device_fixture.dart' show E2eIdentity;
import 'device_process_fixture.dart';
import 'e2e_env.dart';
import 'multi_device_process_e2e_test.dart' as base;

void main() {
  final gate = E2eGate.read();
  test(
    'retry publishes a revocation whose durable write completion was lost',
    () async {
      final evidence = Platform.environment['XVEIL_E2E_EVIDENCE_DIR'];
      expect(evidence, isNotNull);
      final f = await ProcessFleet.start(gate);
      addTearDown(f.dispose);
      final a = f.a, b = f.b, c = f.c;
      await base.introduceProcesses(a, c);
      await base.linkProcesses(a, b);
      final ai = (await base.deviceInfo(a))['identity'] as String;
      final ci = (await base.deviceInfo(c))['identity'] as String;
      final oldDevice = (await base.deviceInfo(b))['nodeId'] as String;
      await b.checked(
        '/send_message',
        query: {'peer': ci, 'text': 'revoke-write-before'},
      );
      await base.hasBody(c, ai, 'revoke-write-before');
      final key = (await a.admin(gate.veilCli!, [
        'identity',
        'dht-key',
        ai,
      ])).trim();
      Future<String?> document(ProcessDevice device) async {
        final dump = await device.admin(gate.veilCli!, [
          'node',
          'dht',
          'get',
          key,
        ]);
        final hex = RegExp(
          r'^value: ([0-9a-f]+)$',
          multiLine: true,
        ).firstMatch(dump)?.group(1);
        if (hex == null) return null;
        return base64Encode([
          for (var i = 0; i < hex.length; i += 2)
            int.parse(hex.substring(i, i + 2), radix: 16),
        ]);
      }

      final before = await document(a);
      expect(before, isNotNull);
      await b.stop();
      const nonce = 'revocation-write-retry';
      await File(
        '${a.dir.path}/sovereign-write-arm.json',
      ).writeAsString(jsonEncode({'nonce': nonce}));
      final first = await a.call(
        '/device_revoke',
        query: {'peer': oldDevice},
        body: E2eIdentity.x.phrase,
      );
      expect(first['ok'], isFalse);
      final marker =
          jsonDecode(
                await File(
                  '${a.dir.path}/sovereign-write-reached.json',
                ).readAsString(),
              )
              as Map;
      expect(marker['nonce'], nonce);
      expect(marker['storeReturned'], isTrue);
      final saved = marker['document'] as String;
      expect(saved, isNot(before));
      expect(
        await document(a),
        before,
        reason: 'first failed caller did not refresh the live document',
      );
      final aPids = List<int>.of(a.ownedPids);
      final retry = await a.checked(
        '/device_revoke',
        query: {'peer': oldDevice},
        body: E2eIdentity.x.phrase,
      );
      expect(
        retry['docRevoked'],
        isFalse,
        reason: 'this is an already-tombstoned retry, not a second rewrite',
      );
      await waitUntil(
        () async => await document(a) == saved,
        what: 'successful retry publishes the saved tombstone on the live node',
        timeout: const Duration(seconds: 5),
      );
      expect(a.ownedPids, aPids, reason: 'retry repairs without restarting A');
      await a.checked(
        '/send_message',
        query: {'peer': ci, 'text': 'revoke-write-after-retry'},
      );
      await base.hasBody(c, ai, 'revoke-write-after-retry');
      await waitUntil(
        () async => await document(c) == saved,
        what: 'contact receives the repaired signed document',
      );
      await b.start();
      await base.join(b, c);
      const attack = 'revoke-write-old-B-attempt';
      await b.checked('/send_message', query: {'peer': ci, 'text': attack});
      await b.checked('/call_place', query: {'peer': ci});
      final watch = Stopwatch()..start();
      do {
        expect(
          (await base.rows(c, ai)).any((m) => m['body'] == attack),
          isFalse,
        );
        final call = (await c.checked('/call_state'))['call'] as Map?;
        expect(call == null || call['status'] == 'ended', isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 500));
      } while (watch.elapsed < const Duration(seconds: 30));
      watch.stop();
      await b.checked('/call_hangup');
      await c.checked(
        '/send_message',
        query: {'peer': ai, 'text': 'revoke-write-valid-reply'},
      );
      await base.hasBody(a, ci, 'revoke-write-valid-reply');
      await File('$evidence/revocation-write-retry-summary.json').writeAsString(
        jsonEncode({
          'firstWriteDurableButCompletionLost': true,
          'firstCallerFailed': true,
          'alreadyTombstonedRetrySucceeded': true,
          'liveDocumentMatchedDurableDocument': true,
          'noAuthorRestart': true,
          'contactLearnedRepairedDocument': true,
          'oldDeviceRejected': true,
          'negativeObservationMs': watch.elapsedMilliseconds,
          'authorizedBidirectionalMessages': true,
        }),
      );
    },
    skip: !gate.enabled
        ? gate.skip
        : Platform.environment['XVEIL_E2E_SOVEREIGN_WRITE_FAULT'] != '1'
        ? 'set XVEIL_E2E_SOVEREIGN_WRITE_FAULT=1'
        : false,
  );
}
