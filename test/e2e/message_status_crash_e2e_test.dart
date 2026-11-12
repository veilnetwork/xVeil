@Timeout(Duration(minutes: 12))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/domain/chat.dart';

import 'device_process_fixture.dart';
import 'e2e_env.dart';
import 'multi_device_process_e2e_test.dart' as base;
import 'relay_cluster.dart';

Future<Map<String, dynamic>> _row(
  ProcessDevice d,
  String peer,
  String body,
) async => (await base.rows(d, peer)).singleWhere((m) => m['body'] == body);

Future<void> _suspended(ProcessDevice device, int vmPid) async {
  final group = await Process.run('ps', ['-p', '$vmPid', '-o', 'pgid=']);
  expect(int.parse('${group.stdout}'.trim()), device.ownedPids.last);
  await waitUntil(
    () async {
      final state = await Process.run('ps', ['-p', '$vmPid', '-o', 'state=']);
      return '${state.stdout}'.trim().startsWith('T');
    },
    what: 'owned VM actually suspended',
    timeout: const Duration(seconds: 5),
  );
}

Future<void> _exited(int vmPid) => waitUntil(
  () async {
    final state = await Process.run('ps', ['-p', '$vmPid', '-o', 'state=']);
    final value = '${state.stdout}'.trim();
    return value.isEmpty || value.startsWith('Z');
  },
  what: 'actual VM exited before cold read',
  timeout: const Duration(seconds: 10),
);

void main() {
  final gate = E2eGate.read();
  final enabled =
      Platform.environment['XVEIL_E2E_STATUS_PUBLICATION_CRASH'] == '1';
  test(
    'sender crash after delivered commit converges status without recipient',
    () async {
      final evidence = Platform.environment['XVEIL_E2E_EVIDENCE_DIR'];
      expect(evidence, isNotNull);
      expect(Platform.environment['XVEIL_E2E_STORAGE_TIMING'], isNot('1'));
      expect(
        ensureHiddenVolumeLoaded(dylibPath: gate.hiddenVolumeDylib),
        isTrue,
      );
      final f = await ProcessFleet.start(gate);
      addTearDown(f.dispose);
      final a = f.a, b = f.b, c = f.c;
      await base.introduceProcesses(a, c);
      await base.linkProcesses(a, b);
      final ci = (await base.deviceInfo(c))['identity'] as String;
      const body = 'status-publication-crash-target';
      const nonce = 'status-crash-fixture';
      final appendArm = File('${c.dir.path}/message-append-arm.json');
      await appendArm.writeAsString(
        jsonEncode({
          'nonce': nonce,
          'phase': 'before',
          'body': body,
          'allowResume': true,
        }),
      );
      await a.checked('/send_message', query: {'peer': ci, 'text': body});
      final appendMarker = File('${c.dir.path}/message-append-reached.json');
      await waitUntil(
        () => appendMarker.exists(),
        what: 'C paused before storing target',
      );
      final receiver = jsonDecode(await appendMarker.readAsString()) as Map;
      expect(receiver['nonce'], nonce);
      expect(receiver['appendReturned'], isFalse);
      final cVm = receiver['processId'] as int;
      await _suspended(c, cVm);
      await base.hasBody(b, ci, body);
      final sent = await _row(a, ci, body);
      final id = sent['id'] as String;
      expect(receiver['messageId'], id);
      expect(sent['status'], 'sent');
      expect((await _row(b, ci, body))['status'], 'sent');
      await b.stop();
      final statusArm = File('${a.dir.path}/message-status-arm.json');
      await statusArm.writeAsString(
        jsonEncode({'nonce': nonce, 'peer': ci, 'id': id}),
      );
      await File('${c.dir.path}/message-append-resume').writeAsString(nonce);
      expect(Process.killPid(cVm, ProcessSignal.sigcont), isTrue);
      final statusMarker = File('${a.dir.path}/message-status-reached.json');
      await waitUntil(
        () => statusMarker.exists(),
        what: 'A committed delivered before publication',
        timeout: const Duration(minutes: 2),
        describe: a.tail,
      );
      final checkpoint = jsonDecode(await statusMarker.readAsString()) as Map;
      expect(checkpoint['nonce'], nonce);
      expect(checkpoint['id'], id);
      expect(checkpoint['storedDelivered'], isTrue);
      final aVm = checkpoint['processId'] as int;
      await _suspended(a, aVm);
      await File(
        '$evidence/status-checkpoint-private.json',
      ).writeAsString(jsonEncode(checkpoint));
      await a.stop(crash: true);
      expect(a.lastExitCode, -ProcessSignal.sigkill.signalNumber);
      await _exited(aVm);
      await c.stop();
      final cold = HiddenVolumeStorage.async(
        workerSpaceOpener('${a.dir.path}/store.hv'),
      );
      try {
        expect(await cold.open(password: 'e2e-A-password'), isTrue);
        final stored = await cold.loadMessageById(ci, id);
        expect(stored, isNotNull);
        expect(stored!.status, MessageStatus.delivered);
      } finally {
        await cold.close();
      }
      final siblingCold = HiddenVolumeStorage.async(
        workerSpaceOpener('${b.dir.path}/store.hv'),
      );
      try {
        expect(await siblingCold.open(password: 'e2e-B-password'), isTrue);
        expect(
          (await siblingCold.loadMessageById(ci, id))!.status,
          MessageStatus.sent,
        );
      } finally {
        await siblingCold.close();
      }
      // No pre-crash network queue may heal the status for us. Use new relay
      // processes, sockets and empty state directories while C stays stopped.
      await f.cluster.dispose();
      final recoveredCluster = await RelayCluster.start(
        veilCliPath: gate.veilCli!,
        root: Directory('${f.root.path}/fresh-relays'),
      );
      addTearDown(recoveredCluster.dispose);
      for (final device in [a, b]) {
        device.peers
          ..clear()
          ..addAll(recoveredCluster.bootstrapPeers);
      }
      await statusArm.delete();
      await a.start();
      await b.start();
      await base.join(a, b);
      await base.join(b, a);
      await waitUntil(
        () async => (await _row(b, ci, body))['status'] == 'delivered',
        what: 'B recovers delivered from A while C remains offline',
        timeout: const Duration(minutes: 2),
        describe: () async =>
            '${await base.rows(a, ci)} / ${await base.rows(b, ci)}',
      );
      final mirrored = await _row(b, ci, body);
      expect(mirrored['id'], id);
      expect(
        (await base.rows(b, ci)).where((m) => m['id'] == id),
        hasLength(1),
      );
      await a.stop();
      await b.stop();
      try {
        expect(await siblingCold.open(password: 'e2e-B-password'), isTrue);
        final row = await siblingCold.loadMessageById(ci, id);
        expect(row!.status, MessageStatus.delivered);
        expect(row.body, body);
      } finally {
        await siblingCold.close();
      }
      await File('$evidence/status-crash-summary.json').writeAsString(
        jsonEncode({
          'senderActuallySuspended': true,
          'senderExitCode': -9,
          'coldSenderDelivered': true,
          'siblingInitiallySent': true,
          'recipientOfflineDuringRecovery': true,
          'relayStateFreshDuringRecovery': true,
          'siblingRecoveredDelivered': true,
          'coldSiblingDeliveredAfterRecovery': true,
        }),
      );
    },
    skip: !gate.enabled
        ? gate.skip
        : !enabled
        ? 'set XVEIL_E2E_STATUS_PUBLICATION_CRASH=1'
        : Platform.isWindows
        ? 'requires Unix process suspension'
        : false,
  );
}
