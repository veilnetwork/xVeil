@Timeout(Duration(minutes: 9))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/call_service.dart'
    show kCallHeartbeatInterval, kCallLivenessTimeout;

import 'device_process_fixture.dart';
import 'e2e_env.dart';
import 'multi_device_process_e2e_test.dart' as base;

void main() {
  final gate = E2eGate.read();
  test(
    'anonymous sibling carries media through primary crash and answers offline',
    () async {
      final fleet = await ProcessFleet.start(gate);
      addTearDown(fleet.dispose);
      final a = fleet.a, b = fleet.b, c = fleet.c;
      final evidence = Platform.environment['XVEIL_PEER_ECHO_EVIDENCE'];
      final result = <String, Object?>{
        'devices': 3,
        'same_identity_devices': 2,
        'anonymous': true,
        'explicit_c_b_join': false,
        'live_speech_quality_tested': false,
        'receive_counter': 'audio_rx_pkts',
        'passed': false,
      };
      if (evidence != null) {
        await File('$evidence/fleet-private.json').writeAsString(
          jsonEncode({'root': fleet.root.path, 'runnerPid': pid}),
        );
      }
      Future<Map<String, dynamic>?> call(ProcessDevice device) async =>
          (await device.checked('/call_state'))['call']
              as Map<String, dynamic>?;
      bool live(Map<String, dynamic>? state) =>
          state != null && state['status'] != 'ended';
      int rx(Map<String, dynamic>? state) =>
          ((state?['mediaStats'] as Map?)?['audio_rx_pkts'] as num?)?.toInt() ??
          0;
      Future<String> describe() async => jsonEncode({
        for (final d in [b, c])
          d.label: {
            'status': (await call(d))?['status'],
            'transport': (await call(d))?['transport'],
            'rx': rx(await call(d)),
          },
      });
      try {
        await base.introduceProcesses(a, c);
        final ai = (await base.deviceInfo(a))['identity'] as String;
        await base.linkProcesses(a, b);
        final callIds = <String>{};
        for (final primaryOnline in [true, false]) {
          final phase = primaryOnline ? 'primary_online' : 'primary_offline';
          result['stage'] = '$phase:ringing';
          final watch = Stopwatch()..start();
          final placed = await c.checked('/call_place', query: {'peer': ai});
          final callId = (placed['call'] as Map)['callId'] as String;
          expect(callIds.add(callId), isTrue);
          bool carriesCall(Map<String, dynamic>? state) =>
              state?['callId'] == callId &&
              state?['status'] == 'active' &&
              state?['transport'] == 'onion';
          await waitUntil(
            () async {
              final ringing = await call(b);
              if (ringing?['callId'] != callId ||
                  ringing?['status'] != 'ringing') {
                return false;
              }
              if (!primaryOnline) return true;
              final primary = await call(a);
              return primary?['callId'] == callId &&
                  primary?['status'] == 'ringing';
            },
            what: '$phase: C rings every online device of X',
            describe: describe,
            timeout: const Duration(seconds: 60),
          );
          result['${phase}_ring_ms'] = watch.elapsedMilliseconds;
          result['stage'] = '$phase:answer';
          watch.reset();
          await b.checked('/call_accept');
          await waitUntil(
            () async {
              final bc = await call(b), cc = await call(c);
              return carriesCall(bc) &&
                  carriesCall(cc) &&
                  rx(bc) >= 5 &&
                  rx(cc) >= 5 &&
                  (!primaryOnline || !live(await call(a)));
            },
            what:
                '$phase: B alone answers and exchanges onion audio RTP with C',
            describe: describe,
            timeout: const Duration(seconds: 40),
          );
          result['${phase}_answer_media_ms'] = watch.elapsedMilliseconds;
          if (primaryOnline) {
            result['stage'] = '$phase:crash';
            await a.stop(crash: true);
            expect(a.lastExitCode, -ProcessSignal.sigkill.signalNumber);
            result['primary_crash_during_call'] = true;
          }
          final beforeB = await call(b), beforeC = await call(c);
          expect(carriesCall(beforeB) && carriesCall(beforeC), isTrue);
          result['stage'] = '$phase:continuous-media';
          // Keep the original call beyond a full liveness window after the
          // crash, including the tick that can act on the expired window.
          final observation = primaryOnline
              ? kCallLivenessTimeout + kCallHeartbeatInterval
              : kCallHeartbeatInterval;
          await Future<void>.delayed(observation);
          final afterB = await call(b), afterC = await call(c);
          expect(carriesCall(afterB) && carriesCall(afterC), isTrue);
          expect(rx(afterB), greaterThan(rx(beforeB)));
          expect(rx(afterC), greaterThan(rx(beforeC)));
          result['${phase}_observation_seconds'] = observation.inSeconds;
          result['${phase}_media_rx_delta_b'] = rx(afterB) - rx(beforeB);
          result['${phase}_media_rx_delta_c'] = rx(afterC) - rx(beforeC);
          await b.checked('/call_hangup');
          await waitUntil(
            () async => !live(await call(b)) && !live(await call(c)),
            what: '$phase: B hangup reaches C',
            describe: describe,
            timeout: const Duration(seconds: 25),
          );
          result['${phase}_hangup'] = true;
        }
        result['passed'] = true;
      } finally {
        if (evidence != null) {
          await File('$evidence/calls-private.json').writeAsString(
            jsonEncode({
              for (final d in [b, c]) d.label: await call(d),
            }),
          );
          await File('$evidence/result.json').writeAsString(jsonEncode(result));
        }
      }
    },
    skip: gate.enabled && Platform.environment['XVEIL_E2E_ANONYMOUS'] != '1'
        ? 'requires XVEIL_E2E_ANONYMOUS=1'
        : gate.mediaSkip,
  );
}
