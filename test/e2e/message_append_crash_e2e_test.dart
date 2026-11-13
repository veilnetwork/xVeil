@Timeout(Duration(minutes: 12))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_native.dart';

import 'device_process_fixture.dart';
import 'e2e_env.dart';
import 'multi_device_process_e2e_test.dart' as base;

Future<Map<String, dynamic>> _oneRow(
  ProcessDevice device,
  String peer,
  String body,
) async =>
    (await base.rows(device, peer)).singleWhere((row) => row['body'] == body);

Future<int> _ownedWorkerVm(ProcessDevice device) async {
  final group = device.ownedPids.last;
  final result = await Process.run('ps', ['-ww', '-axo', 'pid=,pgid=,comm=']);
  expect(result.exitCode, 0);
  final candidates = <int>[];
  for (final line in '${result.stdout}'.split('\n')) {
    final match = RegExp(r'^\s*(\d+)\s+(\d+)\s+(.+)$').firstMatch(line);
    if (match == null || int.parse(match[2]!) != group) continue;
    if (match[3]!.trim().split('/').last == 'flutter_tester') {
      candidates.add(int.parse(match[1]!));
    }
  }
  expect(candidates, hasLength(1), reason: 'one VM in this owned worker group');
  return candidates.single;
}

void main() {
  final gate = E2eGate.read();
  final enabled = Platform.environment['XVEIL_E2E_MESSAGE_APPEND_CRASH'] == '1';
  for (final phase in ['before', 'after', 'acknowledged']) {
    final afterReceipt = phase == 'acknowledged';
    test(
      afterReceipt
          ? 'receiver crash after observed delivery ACK preserves data and ratchet'
          : 'receiver crash $phase native message append preserves retry and ratchet',
      () async {
        final evidence = Platform.environment['XVEIL_E2E_EVIDENCE_DIR'];
        expect(evidence, isNotNull);
        expect(
          Platform.environment['XVEIL_E2E_STORAGE_TIMING'],
          isNot('1'),
          reason: 'the append checkpoint requires its native storage adapter',
        );
        expect(
          ensureHiddenVolumeLoaded(dylibPath: gate.hiddenVolumeDylib),
          isTrue,
        );
        final fleet = await ProcessFleet.start(gate);
        addTearDown(fleet.dispose);
        final a = fleet.a, b = fleet.b, c = fleet.c;
        await base.introduceProcesses(a, c);
        await base.linkProcesses(a, b);
        final ai = (await base.deviceInfo(a))['identity'] as String;
        final ci = (await base.deviceInfo(c))['identity'] as String;
        final controlBody = 'crash-control-$phase';
        await a.checked(
          '/send_message',
          query: {'peer': ci, 'text': controlBody},
        );
        await base.hasBody(c, ai, controlBody);
        await base.hasBody(b, ci, controlBody);
        await waitUntil(
          () async =>
              (await _oneRow(a, ci, controlBody))['status'] == 'delivered',
          what: 'control message delivered before arming crash checkpoint',
        );
        final baseline = await base.rows(a, ci);
        expect(baseline, hasLength(2));
        expect(baseline.map((row) => row['body']).toSet(), {
          'hello',
          controlBody,
        });

        final body = 'crash-boundary-$phase';
        final nonce = 'fixture-$phase';
        final arm = File('${c.dir.path}/message-append-arm.json');
        if (!afterReceipt) {
          final temporary = File('${arm.path}.tmp');
          await temporary.writeAsString(
            jsonEncode({'nonce': nonce, 'phase': phase, 'body': body}),
          );
          await temporary.rename(arm.path);
        }
        final marker = File('${c.dir.path}/message-append-reached.json');
        var vmPid = afterReceipt ? await _ownedWorkerVm(c) : 0;
        await a.checked('/send_message', query: {'peer': ci, 'text': body});
        Map checkpoint;
        if (afterReceipt) {
          // Observe the real receipt at A, without replacing transport or
          // allowing a storage gate to manufacture a post-ACK checkpoint.
          await waitUntil(
            () async => (await _oneRow(a, ci, body))['status'] == 'delivered',
            what:
                'sender persisted the real delivery ACK before receiver crash',
            timeout: const Duration(minutes: 2),
            interval: const Duration(milliseconds: 20),
            describe: a.tail,
          );
          checkpoint = {
            'nonce': nonce,
            'phase': phase,
            'processId': vmPid,
            'messageId': (await _oneRow(a, ci, body))['id'],
            'conversationId': ai,
            'checkpointKind': 'observer_after_delivery_ack',
          };
        } else {
          await waitUntil(
            () async => await marker.exists(),
            what: 'receiver reached exact message append checkpoint',
            timeout: const Duration(minutes: 2),
            interval: const Duration(milliseconds: 20),
            describe: c.tail,
          );
          checkpoint = jsonDecode(await marker.readAsString()) as Map;
          expect(checkpoint['nonce'], nonce);
          expect(checkpoint['phase'], phase);
          expect(checkpoint['appendReturned'], phase == 'after');
          expect(checkpoint['conversationId'], ai);
          vmPid = checkpoint['processId'] as int;
        }
        await File(
          '$evidence/message-append-$phase-checkpoint-private.json',
        ).writeAsString(jsonEncode(checkpoint));
        final group = await Process.run('ps', ['-p', '$vmPid', '-o', 'pgid=']);
        expect(int.parse('${group.stdout}'.trim()), c.ownedPids.last);
        if (afterReceipt) {
          expect(Process.killPid(vmPid, ProcessSignal.sigstop), isTrue);
        }
        await waitUntil(
          () async {
            final state = await Process.run('ps', [
              '-p',
              '$vmPid',
              '-o',
              'state=',
            ]);
            return state.exitCode == 0 &&
                '${state.stdout}'.trim().startsWith('T');
          },
          what: 'owned receiver VM is actually SIGSTOP-suspended',
          timeout: const Duration(seconds: 5),
        );
        final sent = await _oneRow(a, ci, body);
        expect(sent['id'], checkpoint['messageId']);
        expect(
          sent['status'],
          afterReceipt ? equals('delivered') : isNot('delivered'),
          reason: 'receipt state must match this checkpoint, not another phase',
        );
        final id = sent['id'] as String;
        await c.stop(crash: true);
        expect(c.lastExitCode, -ProcessSignal.sigkill.signalNumber);
        await waitUntil(
          () async {
            final state = await Process.run('ps', [
              '-p',
              '$vmPid',
              '-o',
              'state=',
            ]);
            final value = '${state.stdout}'.trim();
            return value.isEmpty || value.startsWith('Z');
          },
          what: 'the actual receiver VM has exited and released its handles',
          timeout: const Duration(seconds: 10),
        );
        if (!afterReceipt) await arm.delete();
        final acknowledgedRows = afterReceipt ? await base.rows(a, ci) : null;
        if (afterReceipt) {
          expect(acknowledgedRows, hasLength(3));
          expect(acknowledgedRows!.map((row) => row['body']).toSet(), {
            'hello',
            controlBody,
            body,
          });
          expect(
            acknowledgedRows.map((row) => row['id']).toSet(),
            hasLength(3),
          );
          for (final earlier in baseline) {
            expect(
              acknowledgedRows.singleWhere(
                (row) => row['body'] == earlier['body'],
              )['id'],
              earlier['id'],
            );
          }
          await a.stop();
          await b.stop();
        }

        final reader = HiddenVolumeStorage.async(
          workerSpaceOpener('${c.dir.path}/store.hv'),
        );
        var coldPresent = false;
        try {
          try {
            expect(await reader.open(password: 'e2e-C-password'), isTrue);
          } catch (_) {
            final owners = await Process.run('lsof', [
              '-nP',
              '${c.dir.path}/store.hv',
            ]);
            await File(
              '$evidence/message-append-$phase-open-owners-private.log',
            ).writeAsString('${owners.stdout}\n${owners.stderr}');
            rethrow;
          }
          final cold = await reader.loadMessageById(ai, id);
          coldPresent = cold != null;
          expect(coldPresent, phase != 'before');
          if (cold != null) {
            expect(cold.id, id);
            expect(cold.body, body);
          }
          final matches = (await reader.loadMessages(
            ai,
          )).where((row) => row.body == body).toList();
          expect(matches.length, phase != 'before' ? 1 : 0);
          if (afterReceipt) {
            final coldRows = await reader.loadMessages(ai);
            expect(coldRows, hasLength(3));
            expect(coldRows.map((row) => row.id).toSet(), {
              for (final row in acknowledgedRows!) row['id'],
            });
            expect(
              {for (final row in coldRows) row.id: row.body},
              {for (final row in acknowledgedRows) row['id']: row['body']},
            );
          }
        } finally {
          await reader.close();
        }

        await c.start();
        if (afterReceipt) {
          final retainedBeforeSources = await base.rows(c, ai);
          expect(retainedBeforeSources, hasLength(3));
          expect(retainedBeforeSources.map((row) => row['id']).toSet(), {
            for (final row in acknowledgedRows!) row['id'],
          });
          expect(
            {for (final row in retainedBeforeSources) row['id']: row['body']},
            {for (final row in acknowledgedRows) row['id']: row['body']},
          );
          await a.start();
          await b.start();
        }
        await base.hasBody(c, ai, body);
        await waitUntil(
          () async =>
              (await _oneRow(a, ci, body))['status'] == 'delivered' &&
              (await _oneRow(b, ci, body))['status'] == 'delivered',
          what: afterReceipt
              ? 'original delivery receipt is retained and converges on sibling'
              : 'real outbox retry obtains delivery ACK and mirrors it to B',
          timeout: const Duration(minutes: 3),
          describe: () async =>
              '${await base.rows(a, ci)} / ${await base.rows(b, ci)}',
        );
        expect((await _oneRow(c, ai, body))['id'], id);

        final reply = 'crash-recovered-reply-$phase';
        await c.checked('/send_message', query: {'peer': ai, 'text': reply});
        await base.hasBody(a, ci, reply);
        await base.hasBody(b, ci, reply);
        final followup = 'crash-recovered-next-$phase';
        await a.checked('/send_message', query: {'peer': ci, 'text': followup});
        await base.hasBody(c, ai, followup);
        await waitUntil(
          () async =>
              (await _oneRow(c, ai, reply))['status'] == 'delivered' &&
              (await _oneRow(a, ci, followup))['status'] == 'delivered',
          what:
              'ratchet remains usable in both directions after crash recovery',
        );
        final expectedBodies = {'hello', controlBody, body, reply, followup};
        final aRows = await base.rows(a, ci);
        final expectedIds = {for (final row in aRows) row['id'] as String};
        expect(aRows.map((row) => row['body']).toSet(), expectedBodies);
        expect(aRows, hasLength(5));
        expect(expectedIds, hasLength(5));
        if (afterReceipt) {
          for (final original in acknowledgedRows!) {
            expect(
              aRows.singleWhere((row) => row['id'] == original['id'])['body'],
              original['body'],
            );
          }
        }
        List<Map<String, dynamic>> view(List<Map<String, dynamic>> rows) => [
          for (final row in rows)
            {
              for (final key in ['id', 'direction', 'body', 'status', 'seq'])
                key: row[key],
            },
        ];
        await waitUntil(
          () async =>
              jsonEncode(view(await base.rows(b, ci))) ==
              jsonEncode(view(aRows)),
          what:
              'all five source rows have identical order positions and status on A/B',
        );
        await a.stop();
        await b.stop();
        await c.stop();
        try {
          expect(await reader.open(password: 'e2e-C-password'), isTrue);
          final local = await reader.loadMessages(ai);
          expect(local, hasLength(5));
          expect(local.map((row) => row.id).toSet(), expectedIds);
          expect(local.map((row) => row.body).toSet(), expectedBodies);
        } finally {
          await reader.close();
        }
        await c.start();
        final retained = await base.rows(c, ai);
        expect(retained, hasLength(5));
        expect(retained.map((row) => row['id']).toSet(), expectedIds);
        expect(retained.map((row) => row['body']).toSet(), expectedBodies);
        expect(retained.where((row) => row['body'] == body).single['id'], id);
        await File(
          '$evidence/message-append-$phase-summary.json',
        ).writeAsString(
          jsonEncode({
            'phase': phase,
            'receiverActuallySuspended': true,
            'receiverExitCode': -9,
            'senderHadNoDeliveryAckAtCheckpoint': !afterReceipt,
            'senderHadDeliveryAckAtCheckpoint': afterReceipt,
            'initialColdReadWithSourcesStopped': afterReceipt,
            'coldMessagePresentBeforeNetwork': coldPresent,
            'expectedColdPresence': phase != 'before',
            'sameIdRecoveredExactlyOnce': true,
            'senderAndSiblingDelivered': true,
            'subsequentRatchetBothDirections': true,
            'finalColdRowsWithSourcesStopped': retained.length,
            'finalRowsVerifiedBeforeNodeStart': true,
            'finalIdsAndBodiesMatch': true,
          }),
        );
        E2eLog.line('MESSAGE_APPEND_CRASH_${phase.toUpperCase()}_PASS');
      },
      skip: !gate.enabled
          ? gate.skip
          : !enabled
          ? 'set XVEIL_E2E_MESSAGE_APPEND_CRASH=1 for the owned process gate'
          : Platform.isWindows
          ? 'requires Unix process suspension'
          : false,
    );
  }
}
