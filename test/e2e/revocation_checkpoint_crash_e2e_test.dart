@Timeout(Duration(minutes: 12))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_native.dart';

import 'device_fixture.dart' show E2eIdentity;
import 'device_process_fixture.dart';
import 'e2e_env.dart';
import 'multi_device_process_e2e_test.dart' as base;
import 'relay_cluster.dart';

int _nonce = 0;

Future<Map<String, dynamic>> _authorization(
  ProcessDevice device, {
  required String identity,
  required String physical,
  String? document,
}) async {
  final nonce = 'revocation-crash-${++_nonce}';
  final request = File('${device.dir.path}/storage-inspect.new');
  await request.writeAsString(
    jsonEncode({
      'nonce': nonce,
      'peer': identity,
      'prefix': '',
      'authorizationOnly': true,
      'identity': identity,
      'physical': physical,
      'authorizationDocument': ?document,
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
      result = Map<String, dynamic>.from(value['authorization'] as Map);
      return true;
    },
    what: 'live owner reports its revocation checkpoint',
    timeout: const Duration(seconds: 20),
    describe: device.tail,
  );
  return result!;
}

Future<void> _vmGone(int vm) => waitUntil(
  () async {
    final result = await Process.run('ps', ['-p', '$vm', '-o', 'state=']);
    final state = '${result.stdout}'.trim();
    return state.isEmpty || state.startsWith('Z');
  },
  what: 'actual receiver VM exited before opening its container',
  timeout: const Duration(seconds: 10),
);

void main() {
  final gate = E2eGate.read();
  test(
    'revocation checkpoint survives receiver SIGKILL without author or old relays',
    () async {
      final evidence = Platform.environment['XVEIL_E2E_EVIDENCE_DIR'];
      expect(evidence, isNotNull);
      expect(
        ensureHiddenVolumeLoaded(dylibPath: gate.hiddenVolumeDylib),
        isTrue,
      );
      final f = await ProcessFleet.start(gate);
      addTearDown(f.dispose);
      final a = f.a, b = f.b, c = f.c;
      await base.introduceProcesses(a, c);
      await base.linkProcesses(a, b);
      final ai = (await base.deviceInfo(a))['identity'] as String;
      final ci = (await base.deviceInfo(c))['identity'] as String;
      final aNode = (await base.deviceInfo(a))['nodeId'] as String;
      final bNode = (await base.deviceInfo(b))['nodeId'] as String;
      await b.checked(
        '/send_message',
        query: {'peer': ci, 'text': 'revocation-crash-before'},
      );
      await base.hasBody(c, ai, 'revocation-crash-before');
      expect(
        (await _authorization(
          c,
          identity: ai,
          physical: bNode,
        ))['identityDeviceAllowed'],
        isTrue,
        reason: 'the receiver must genuinely authorize B before revoke',
      );
      final beforeCall = await b.checked('/call_place', query: {'peer': ci});
      final beforeCallId = (beforeCall['call'] as Map)['callId'];
      await waitUntil(() async {
        final call = (await c.checked('/call_state'))['call'] as Map?;
        return call?['callId'] == beforeCallId && call?['status'] == 'ringing';
      }, what: 'B really rings C before revoke');
      await c.checked('/call_reject');
      await waitUntil(() async {
        final call = (await b.checked('/call_state'))['call'] as Map?;
        return call == null || call['status'] == 'ended';
      }, what: 'positive-control call ended on B');
      await b.stop();
      final revoked = await a.checked(
        '/device_revoke',
        query: {'peer': bNode},
        body: E2eIdentity.x.phrase,
      );
      expect(revoked['docRevoked'], isTrue);
      final key = (await a.admin(gate.veilCli!, [
        'identity',
        'dht-key',
        ai,
      ])).trim();
      final dump = await a.admin(gate.veilCli!, ['node', 'dht', 'get', key]);
      final hex = RegExp(
        r'^value: ([0-9a-f]+)$',
        multiLine: true,
      ).firstMatch(dump)!.group(1)!;
      final document = base64Encode([
        for (var i = 0; i < hex.length; i += 2)
          int.parse(hex.substring(i, i + 2), radix: 16),
      ]);
      await a.checked(
        '/send_message',
        query: {'peer': ci, 'text': 'revocation-crash-document-control'},
      );
      await base.hasBody(c, ai, 'revocation-crash-document-control');
      Map<String, dynamic>? checkpoint;
      await waitUntil(
        () async {
          checkpoint = await _authorization(
            c,
            identity: ai,
            physical: bNode,
            document: document,
          );
          return checkpoint!['identityDeviceAllowed'] == false &&
              checkpoint!['storedDocumentMatches'] == true;
        },
        what:
            'C refuses B and durably stores the exact current signed document',
        describe: () => '$checkpoint',
      );
      final vm = checkpoint!['processId'] as int;
      final group = await Process.run('ps', ['-p', '$vm', '-o', 'pgid=']);
      expect(int.parse('${group.stdout}'.trim()), c.ownedPids.last);
      await c.stop(crash: true);
      expect(c.lastExitCode, -ProcessSignal.sigkill.signalNumber);
      await _vmGone(vm);
      await a.stop();
      await f.cluster.dispose();

      final cold = HiddenVolumeStorage.async(
        workerSpaceOpener('${c.dir.path}/store.hv'),
      );
      try {
        expect(await cold.open(password: 'e2e-C-password'), isTrue);
        final entries = await cold.loadPeerAuthorization();
        expect(
          base64Encode(
            entries.singleWhere((entry) => entry.peer == ai).document,
          ),
          document,
        );
      } finally {
        await cold.close();
      }
      // Only the encrypted checkpoint may carry C's learned revocation across
      // this restart; discard the killed node's private runtime/cache files.
      await Directory('${c.dir.path}/runtime').delete(recursive: true);
      E2eLog.line('REVOCATION_CRASH_COLD_CHECKPOINT_PASS');

      // No author or pre-crash DHT/transport queue may repair this test.
      final fresh = await RelayCluster.start(
        veilCliPath: gate.veilCli!,
        root: Directory('${f.root.path}/fresh-relays'),
      );
      addTearDown(fresh.dispose);
      for (final device in [a, b, c]) {
        device.peers
          ..clear()
          ..addAll(fresh.bootstrapPeers);
      }
      await c.start(); // B and A are both still stopped.
      final restored = await _authorization(
        c,
        identity: ai,
        physical: bNode,
        document: document,
      );
      expect(restored['storedDocumentMatches'], isTrue);
      expect(restored['identityDeviceAllowed'], isFalse);
      expect(
        (await _authorization(
          c,
          identity: ai,
          physical: aNode,
        ))['identityDeviceAllowed'],
        isTrue,
        reason: 'restore must preserve A, not deny the whole identity',
      );
      await b.start();
      expect((await base.deviceInfo(b))['nodeId'], bNode);
      await base.join(b, c);
      await base.join(c, b);
      const attack = 'revocation-crash-rejected-old-B';
      await b.checked('/send_message', query: {'peer': ci, 'text': attack});
      await b.checked('/call_place', query: {'peer': ci});
      final watch = Stopwatch()..start();
      var observations = 0;
      do {
        expect(
          (await base.rows(c, ai)).any((row) => row['body'] == attack),
          isFalse,
        );
        final call = (await c.checked('/call_state'))['call'] as Map?;
        expect(call == null || call['status'] == 'ended', isTrue);
        observations++;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      } while (watch.elapsed < const Duration(seconds: 60));
      watch.stop();
      expect(
        (await _authorization(
          c,
          identity: ai,
          physical: bNode,
        ))['identityDeviceAllowed'],
        isFalse,
      );
      await b.checked('/call_hangup');
      E2eLog.line('REVOCATION_CRASH_STALE_DEVICE_REJECTED_PASS');

      // End with positive controls in both directions on the restored ratchet.
      await a.start();
      await base.join(a, c);
      await base.join(c, a);
      await a.checked(
        '/send_message',
        query: {'peer': ci, 'text': 'revocation-crash-author-returned'},
      );
      await base.hasBody(c, ai, 'revocation-crash-author-returned');
      await c.checked(
        '/send_message',
        query: {'peer': ai, 'text': 'revocation-crash-receiver-reply'},
      );
      await base.hasBody(a, ci, 'revocation-crash-receiver-reply');
      expect(
        (await base.rows(
          b,
          ci,
        )).any((row) => row['body'] == 'revocation-crash-receiver-reply'),
        isFalse,
      );
      await File('$evidence/revocation-crash-summary.json').writeAsString(
        jsonEncode({
          'positiveBeforeRevoke': true,
          'exactCheckpointObservedBeforeKill': true,
          'receiverExitCode': -9,
          'coldCheckpointMatched': true,
          'restoredBeforeAuthorOrStaleDeviceReturned': true,
          'freshRelayState': true,
          'oldDeviceMessagesAndCallsRejected': true,
          'negativeObservationMs': watch.elapsedMilliseconds,
          'negativeObservations': observations,
          'authorizedRatchetBidirectionalAfterRestart': true,
        }),
      );
    },
    skip: !gate.enabled
        ? gate.skip
        : Platform.isWindows
        ? 'requires Unix process groups and SIGKILL'
        : false,
  );
}
