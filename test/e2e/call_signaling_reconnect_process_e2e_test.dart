@Timeout(Duration(minutes: 9))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/call_signal.dart';

import 'device_process_fixture.dart';
import 'e2e_env.dart';
import 'multi_device_process_e2e_test.dart' as base;

void main() {
  final gate = E2eGate.read();
  test(
    'anonymous call signaling survives sibling restart and primary offline',
    () async {
      final fleet = await ProcessFleet.start(gate);
      addTearDown(fleet.dispose);
      final a = fleet.a, b = fleet.b, c = fleet.c;
      final evidence = Platform.environment['XVEIL_PEER_ECHO_EVIDENCE'];
      final result = <String, Object?>{
        'devices': 3,
        'anonymous': true,
        'mediaAcceptanceTested': false,
        'passed': false,
      };
      if (evidence != null) {
        await File('$evidence/fleet-private.json').writeAsString(
          jsonEncode({'root': fleet.root.path, 'runnerPid': pid}),
        );
      }
      Future<Map?> state(ProcessDevice device) async =>
          (await device.checked('/call_state'))['call'] as Map?;
      Future<String> place(ProcessDevice device, String peer) async {
        final value = await device.checked(
          '/call_place',
          query: {'peer': peer},
        );
        final call = value['call'] as Map;
        expect(call['status'], 'dialing');
        return call['callId'] as String;
      }

      Future<void> rings(List<ProcessDevice> devices, String id) async {
        await waitUntil(
          () async {
            for (final device in devices) {
              final call = await state(device);
              if (call?['callId'] != id || call?['status'] != 'ringing') {
                return false;
              }
            }
            return true;
          },
          what: 'the exact new call rings every selected device',
          describe: () async => jsonEncode({
            for (final device in devices) device.label: await state(device),
          }),
          timeout: const Duration(seconds: 60),
        );
      }

      var sequence = 0;
      Future<Map> diagnostics(ProcessDevice device) async {
        final nonce = 'call-diagnostic-${++sequence}';
        final request = File('${device.dir.path}/storage-inspect.new');
        await request.writeAsString(
          jsonEncode({'nonce': nonce, 'callDiagnostics': true}),
        );
        await request.rename('${device.dir.path}/storage-inspect.json');
        Map? response;
        await waitUntil(() async {
          final file = File('${device.dir.path}/storage-inspected.json');
          if (!await file.exists()) return false;
          final value = jsonDecode(await file.readAsString()) as Map;
          if (value['nonce'] != nonce) return false;
          response = value['diagnostics'] as Map;
          return true;
        }, what: 'owned worker returns the normal diagnostic snapshot');
        expect(response!['enabled'], true);
        return response!;
      }

      Future<void> finish(
        ProcessDevice actor,
        String action,
        List<ProcessDevice> devices,
        String id,
        CallEndReason reason,
      ) async {
        final before = <ProcessDevice, int>{};
        for (final device in devices) {
          before[device] =
              ((await diagnostics(device))['counts'] as Map)['callEnded']
                  as int? ??
              0;
        }
        await actor.checked(action);
        await waitUntil(
          () async {
            for (final device in devices) {
              final current = await state(device);
              if (current != null && current['status'] != 'ended') return false;
              final report = await diagnostics(device);
              if (((report['counts'] as Map)['callEnded'] as int? ?? 0) <=
                  before[device]!) {
                return false;
              }
              final terminal = report['last_call_end'] as Map?;
              if ((terminal?['values'] as Map?)?['endReason'] != reason.index) {
                return false;
              }
              final entries =
                  (await device.checked('/call_log'))['entries'] as List;
              final exact = entries
                  .where((entry) => entry['id'] == id)
                  .toList();
              if (exact.length != 1) return false;
              final entry = exact.single as Map;
              final outcome = reason == CallEndReason.cancelled
                  ? (entry['out'] == true ? 'cancelled' : 'missed')
                  : 'declined';
              if (entry['o'] != outcome) return false;
            }
            return true;
          },
          what:
              'fresh terminal evidence and one durable row for the exact call',
          describe: () async => jsonEncode({
            for (final device in devices) device.label: await state(device),
          }),
          timeout: const Duration(seconds: 30),
        );
      }

      try {
        await base.introduceProcesses(a, c);
        final ai = (await base.deviceInfo(a))['identity'] as String;
        final ci = (await base.deviceInfo(c))['identity'] as String;
        await base.linkProcesses(a, b);
        await waitUntil(
          () async => await base.contactStatus(b, ci) == 'accepted',
          what: 'B has the committed contact consent before calling',
        );

        result['stage'] = 'both-online';
        final firstSentAt = DateTime.now().millisecondsSinceEpoch;
        var id = await place(c, ai);
        final firstId = id;
        await rings([a, b], id);
        await finish(c, '/call_hangup', [a, b, c], id, CallEndReason.cancelled);
        E2eLog.line('PROCESS_SIGNAL_BOTH_ONLINE_PASS');

        result['stage'] = 'sibling-cold-restart';
        await b.restart();
        late Map boot;
        await waitUntil(() async {
          boot = await diagnostics(b);
          final restore =
              (boot['last_evidence'] as Map)['callHistoryRestore'] as Map?;
          final values = restore?['values'] as Map?;
          return values?['success'] == 1 &&
              (values?['sources'] as int? ?? 0) > 0;
        }, what: 'B restores a nonempty durable finished-call floor');
        expect(
          (boot['counts'] as Map)['callState'] ?? 0,
          0,
          reason: 'no old call may briefly ring before the cold API is ready',
        );
        final rejectedBefore =
            (boot['counts'] as Map)['callReplayRejected'] as int? ?? 0;
        final nonce = 'call-replay-${++sequence}';
        final replay = File('${a.dir.path}/storage-inspect.new');
        await replay.writeAsString(
          jsonEncode({
            'nonce': nonce,
            'replayFinishedOffer': true,
            'peer': (await base.deviceInfo(b))['nodeId'] as String,
            'onBehalfOf': ci,
            'callId': firstId,
            'sentAtMs': firstSentAt,
          }),
        );
        await replay.rename('${a.dir.path}/storage-inspect.json');
        await waitUntil(() async {
          final file = File('${a.dir.path}/storage-inspected.json');
          if (!await file.exists()) return false;
          final value = jsonDecode(await file.readAsString()) as Map;
          return value['nonce'] == nonce && value['sourceAccepted'] == true;
        }, what: 'A accepts a controlled authenticated sibling-offer replay');
        await waitUntil(
          () async =>
              (((await diagnostics(b))['counts'] as Map)['callReplayRejected']
                      as int? ??
                  0) >
              rejectedBefore,
          what: 'B actually rejects a delivered replay using restored history',
        );
        final afterReplay = await diagnostics(b);
        expect((afterReplay['counts'] as Map)['callState'] ?? 0, 0);
        expect((afterReplay['counts'] as Map)['callEnded'] ?? 0, 0);
        expect(await state(b), isNull);
        E2eLog.line('PROCESS_SIGNAL_RESTORED_REPLAY_REJECTED_PASS');
        id = await place(c, ai);
        await rings([a, b], id);
        await finish(b, '/call_reject', [a, b, c], id, CallEndReason.declined);
        E2eLog.line('PROCESS_SIGNAL_COLD_SIBLING_REJECT_PASS');

        result['stage'] = 'primary-offline';
        await a.stop();
        id = await place(c, ai);
        await rings([b], id);
        await finish(b, '/call_reject', [b, c], id, CallEndReason.declined);
        E2eLog.line('PROCESS_SIGNAL_PRIMARY_OFFLINE_PASS');

        result['stage'] = 'sibling-outgoing';
        id = await place(b, ci);
        await rings([c], id);
        await finish(c, '/call_reject', [b, c], id, CallEndReason.declined);
        E2eLog.line('PROCESS_SIGNAL_SIBLING_OUTGOING_PASS');

        result['stage'] = 'sibling-joins-ringing';
        await b.stop();
        id = await place(c, ai);
        expect((await state(c))?['callId'], id);
        await b.start();
        await rings([b], id);
        await finish(b, '/call_reject', [b, c], id, CallEndReason.declined);
        E2eLog.line('PROCESS_SIGNAL_JOIN_RINGING_PASS');
        result['passed'] = true;
        E2eLog.line('PROCESS_CALL_SIGNALING_RECONNECT_PASS');
      } finally {
        if (evidence != null) {
          await File('$evidence/result.json').writeAsString(jsonEncode(result));
        }
      }
    },
    skip: gate.enabled && Platform.environment['XVEIL_E2E_ANONYMOUS'] != '1'
        ? 'requires XVEIL_E2E_ANONYMOUS=1'
        : gate.enabled && Platform.environment['XVEIL_E2E_DIAGNOSTICS'] != '1'
        ? 'requires XVEIL_E2E_DIAGNOSTICS=1'
        : gate.skip,
  );
}
