@Timeout(Duration(minutes: 12))
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/sovereign_identity_material.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_native.dart';

import 'device_fixture.dart' show E2eIdentity;
import 'device_process_fixture.dart';
import 'e2e_env.dart';
import 'multi_device_process_e2e_test.dart' as base;
import 'relay_cluster.dart';

Future<String?> _document(ProcessDevice device, String cli, String key) async {
  final dump = await device.admin(cli, ['node', 'dht', 'get', key]);
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

Future<void> _vmGone(int vm) => waitUntil(
  () async {
    final result = await Process.run('ps', ['-p', '$vm', '-o', 'state=']);
    final state = '${result.stdout}'.trim();
    return state.isEmpty || state.startsWith('Z');
  },
  what: 'the author VM exits before reading its encrypted storage',
  timeout: const Duration(seconds: 10),
);

int _probeNonce = 0;
Future<Map> _checkpoint(
  ProcessDevice device,
  String identity,
  String physical,
  String document,
) async {
  final nonce = 'author-checkpoint-${++_probeNonce}';
  final request = File('${device.dir.path}/storage-inspect.new');
  await request.writeAsString(
    jsonEncode({
      'nonce': nonce,
      'peer': identity,
      'prefix': '',
      'authorizationOnly': true,
      'identity': identity,
      'physical': physical,
      'authorizationDocument': document,
    }),
  );
  await request.rename('${device.dir.path}/storage-inspect.json');
  Map? value;
  await waitUntil(
    () async {
      final response = File('${device.dir.path}/storage-inspected.json');
      if (!await response.exists()) return false;
      final result = jsonDecode(await response.readAsString()) as Map;
      if (result['nonce'] != nonce) return false;
      value = result['authorization'] as Map;
      return true;
    },
    what: 'the live contact reports its saved authorization checkpoint',
    timeout: const Duration(seconds: 20),
  );
  return value!;
}

void main() {
  final gate = E2eGate.read();
  test(
    'author SIGKILL after durable revoke republishes tombstone without manual retry',
    () async {
      final evidence = Platform.environment['XVEIL_E2E_EVIDENCE_DIR'];
      expect(evidence, isNotNull);
      expect(
        ensureHiddenVolumeLoaded(dylibPath: gate.hiddenVolumeDylib),
        isTrue,
      );
      final fleet = await ProcessFleet.start(gate);
      addTearDown(fleet.dispose);
      final a = fleet.a, b = fleet.b, c = fleet.c;
      await base.introduceProcesses(a, c);
      await base.linkProcesses(a, b);
      final originalA = await base.deviceInfo(a);
      final ai = originalA['identity'] as String;
      final ci = (await base.deviceInfo(c))['identity'] as String;
      final oldDevice = (await base.deviceInfo(b))['nodeId'] as String;
      await b.checked(
        '/send_message',
        query: {'peer': ci, 'text': 'author-crash-before-revoke'},
      );
      await base.hasBody(c, ai, 'author-crash-before-revoke');
      final initialCall =
          (await b.checked('/call_place', query: {'peer': ci}))['call'] as Map;
      await waitUntil(() async {
        final call = (await c.checked('/call_state'))['call'] as Map?;
        return call?['callId'] == initialCall['callId'] &&
            call?['status'] == 'ringing';
      }, what: 'B genuinely rings C before the durable revoke');
      await c.checked('/call_reject');
      await waitUntil(() async {
        final call = (await b.checked('/call_state'))['call'] as Map?;
        return call == null || call['status'] == 'ended';
      }, what: 'positive-control call ends');
      final key = (await a.admin(gate.veilCli!, [
        'identity',
        'dht-key',
        ai,
      ])).trim();
      final before = await _document(a, gate.veilCli!, key);
      expect(before, isNotNull);
      await b.stop();
      await c.stop();

      const nonce = 'revocation-author-crash';
      final arm = File('${a.dir.path}/sovereign-write-arm.json');
      await arm.writeAsString(jsonEncode({'nonce': nonce}));
      final result = await a.call(
        '/device_revoke',
        query: {'peer': oldDevice},
        body: E2eIdentity.x.phrase,
      );
      expect(result['ok'], isFalse);
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
        await _document(a, gate.veilCli!, key),
        before,
        reason:
            'the crash window is before the running node publishes the durable tombstone',
      );
      await arm.delete(); // Do not re-arm the synthetic one-shot fault on boot.
      final vm = marker['processId'] as int;
      final group = await Process.run('ps', ['-p', '$vm', '-o', 'pgid=']);
      expect(int.parse('${group.stdout}'.trim()), a.ownedPids.last);
      await a.stop(crash: true);
      expect(a.lastExitCode, -ProcessSignal.sigkill.signalNumber);
      await _vmGone(vm);
      await fleet.cluster.dispose();

      final container = File('${a.dir.path}/store.hv');
      final coldHash = await sha256.bind(container.openRead()).first;
      final cold = HiddenVolumeStorage.async(workerSpaceOpener(container.path))
        ..useOnDiskTier(Directory('${a.dir.path}/blobs'));
      try {
        expect(await cold.open(password: 'e2e-A-password'), isTrue);
        final encoded = await readSovereignMaterial(cold);
        expect(encoded, isNotNull);
        final material = decodeSovereignIdentity(encoded!)!;
        expect(base64Encode(material[kIdentityDocumentFile]!), saved);
        // Deliberately corrupt only the disposable stand to prove the later
        // publication oracle rejects a restored old document. Never app code.
        if (Platform.environment['XVEIL_E2E_REVOKE_AUTHOR_ORACLE'] ==
            'old-document') {
          material[kIdentityDocumentFile] = base64Decode(before!);
          await writeSovereignMaterial(cold, encodeSovereignIdentity(material));
        }
      } finally {
        await cold.close();
      }
      if (Platform.environment['XVEIL_E2E_REVOKE_AUTHOR_ORACLE'] !=
          'old-document') {
        expect(
          await sha256.bind(container.openRead()).first,
          coldHash,
          reason:
              'the cold inspection must not repair or rewrite the checkpoint',
        );
      }
      for (final device in [a, c]) {
        await Directory('${device.dir.path}/runtime').delete(recursive: true);
      }
      final fresh = await RelayCluster.start(
        veilCliPath: gate.veilCli!,
        root: Directory('${fleet.root.path}/fresh-relays'),
      );
      addTearDown(fresh.dispose);
      for (final device in [a, b, c]) {
        device.peers
          ..clear()
          ..addAll(fresh.bootstrapPeers);
      }
      // Only A is online. No contact, stale device or old relay can provide a
      // document that makes this startup publication check pass.
      await a.start();
      final reopenedA = await base.deviceInfo(a);
      expect(reopenedA['identity'], ai);
      expect(reopenedA['nodeId'], originalA['nodeId']);
      await waitUntil(
        () async => await _document(a, gate.veilCli!, key) == saved,
        what:
            'cold author publishes its durable tombstone without a revoke retry',
        timeout: const Duration(seconds: 15),
      );

      await c.start();
      await base.join(a, c);
      await base.join(c, a);
      await a.checked(
        '/send_message',
        query: {'peer': ci, 'text': 'author-crash-after-reopen'},
      );
      await base.hasBody(c, ai, 'author-crash-after-reopen');
      await waitUntil(
        () async => await _document(c, gate.veilCli!, key) == saved,
        what: 'C learns the republished durable tombstone before denial checks',
      );
      await waitUntil(() async {
        final checkpoint = await _checkpoint(c, ai, oldDevice, saved);
        return checkpoint['identityDeviceAllowed'] == false &&
            checkpoint['storedDocumentMatches'] == true;
      }, what: 'the exact learned revocation is durable and rejects B');
      await b.start();
      expect((await base.deviceInfo(b))['nodeId'], oldDevice);
      await base.join(b, c);
      const attack = 'author-crash-revoked-device-attempt';
      await b.checked('/send_message', query: {'peer': ci, 'text': attack});
      await b.checked('/call_place', query: {'peer': ci});
      var rounds = 0;
      final watch = Stopwatch()..start();
      do {
        expect(
          (await base.rows(c, ai)).any((row) => row['body'] == attack),
          isFalse,
        );
        final call = (await c.checked('/call_state'))['call'] as Map?;
        expect(call == null || call['status'] == 'ended', isTrue);
        rounds++;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      } while (watch.elapsed < const Duration(seconds: 30));
      watch.stop();
      await b.checked('/call_hangup');
      await c.checked(
        '/send_message',
        query: {'peer': ai, 'text': 'author-crash-authorized-reply'},
      );
      await base.hasBody(a, ci, 'author-crash-authorized-reply');
      final validCall =
          (await c.checked('/call_place', query: {'peer': ai}))['call'] as Map;
      await waitUntil(() async {
        final call = (await a.checked('/call_state'))['call'] as Map?;
        return call?['callId'] == validCall['callId'] &&
            call?['status'] == 'ringing';
      }, what: 'the non-revoked author can still receive a new call');
      final outgoingWatch = Stopwatch()..start();
      do {
        final oldCall = (await b.checked('/call_state'))['call'] as Map?;
        expect(
          oldCall?['callId'],
          isNot(validCall['callId']),
          reason: 'the fresh offer must not leak to the revoked device',
        );
        expect(
          (await base.rows(
            b,
            ci,
          )).any((row) => row['body'] == 'author-crash-authorized-reply'),
          isFalse,
          reason:
              'neither family send nor the stale sibling roster may leak the reply',
        );
        await Future<void>.delayed(const Duration(milliseconds: 250));
      } while (outgoingWatch.elapsed < const Duration(seconds: 8));
      outgoingWatch.stop();
      final journal = (await b.checked('/call_log'))['entries'] as List;
      expect(
        journal.any((entry) => entry['id'] == validCall['callId']),
        isFalse,
      );
      await c.checked('/call_hangup');
      await File(
        '$evidence/revocation-author-crash-summary.json',
      ).writeAsString(
        jsonEncode({
          'firstWriteDurableButCompletionLost': true,
          'firstCallerFailed': true,
          'authorKilledBeforeLivePublication': true,
          'actualAuthorVmGoneBeforeColdRead': true,
          'exactColdDocumentMatched': true,
          'coldReadDidNotRepairStorage': true,
          'oldRelaysAndAuthorRuntimeRemoved': true,
          'authorRepublishedWithoutManualRevokeRetry': true,
          'sameAuthorIdentityAndDevice': true,
          'contactLearnedCurrentDocument': true,
          'contactDurableCheckpointObserved': true,
          'revokedDeviceRejected': true,
          'negativeObservationMs': watch.elapsedMilliseconds,
          'negativeObservationRounds': rounds,
          'freshOfferAndReplyExcludedRevokedDevice': true,
          'freshOfferObservationMs': outgoingWatch.elapsedMilliseconds,
          'authorizedBidirectionalMessagesAndCallSignal': true,
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
