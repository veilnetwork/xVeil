@Timeout(Duration(minutes: 9))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'device_process_fixture.dart';
import 'e2e_env.dart';
import 'multi_device_process_e2e_test.dart' as base;

void main() {
  final gate = E2eGate.read();
  test(
    'anonymous call startup separates answer delivery from media reception',
    () async {
      final fleet = await ProcessFleet.start(gate);
      addTearDown(fleet.dispose);
      final a = fleet.a, b = fleet.b, c = fleet.c;
      final primaryAnswers =
          Platform.environment['XVEIL_E2E_PRIMARY_ANSWERS'] == '1';
      final evidence = Platform.environment['XVEIL_PEER_ECHO_EVIDENCE'];
      final result = <String, Object?>{
        'devices': 3,
        'same_identity_devices': 2,
        'anonymous': true,
        'explicit_c_b_join': false,
        'live_speech_quality_tested': false,
        'receive_counter': 'audio_rx_pkts',
        'online_answerer': primaryAnswers ? 'A' : 'B',
        'passed': false,
      };
      final startupSamples = <Map<String, Object?>>[];
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
      try {
        await base.introduceProcesses(a, c);
        final ai = (await base.deviceInfo(a))['identity'] as String;
        await base.linkProcesses(a, b);
        for (final primaryOnline in [true, false]) {
          if (!primaryOnline) await a.stop();
          final phase = primaryOnline ? 'primary_online' : 'primary_offline';
          final receiver = primaryOnline && primaryAnswers ? a : b;
          final other = receiver == a ? b : a;
          final receiverLabel = receiver.label.toLowerCase();
          result['${phase}_answerer'] = receiver.label;
          Future<String> describe() async => jsonEncode({
            for (final d in [receiver, c])
              d.label: {
                'status': (await call(d))?['status'],
                'transport': (await call(d))?['transport'],
                'rx': rx(await call(d)),
              },
          });
          result['stage'] = '$phase:ringing';
          final watch = Stopwatch()..start();
          await c.checked('/call_place', query: {'peer': ai});
          await waitUntil(
            () async =>
                (await call(b))?['status'] == 'ringing' &&
                (!primaryOnline || (await call(a))?['status'] == 'ringing'),
            what: '$phase: C rings every online device of X',
            describe: describe,
            timeout: const Duration(seconds: 60),
          );
          result['${phase}_ring_ms'] = watch.elapsedMilliseconds;
          result['stage'] = '$phase:answer';
          watch.reset();
          void sampleMedia(Map<String, dynamic>? rc, Map<String, dynamic>? cc) {
            final elapsed = watch.elapsedMilliseconds;
            for (final entry in {receiverLabel: rc, 'c': cc}.entries) {
              if (rx(entry.value) >= 5) {
                result.putIfAbsent(
                  '${phase}_first_five_rx_${entry.key}_ms',
                  () => elapsed,
                );
              }
            }
            startupSamples.add({
              'phase': phase,
              'elapsed_ms': elapsed,
              for (final entry in {receiverLabel: rc, 'c': cc}.entries)
                entry.key: {
                  'status': entry.value?['status'],
                  'transport': entry.value?['transport'],
                  'rx': rx(entry.value),
                  'all_rx': (entry.value?['mediaStats'] as Map?)?['rx_pkts'],
                  'tx': (entry.value?['mediaStats'] as Map?)?['tx_pkts'],
                },
            });
          }

          await receiver.checked('/call_accept');
          await waitUntil(
            () async {
              final rc = await call(receiver), cc = await call(c);
              sampleMedia(rc, cc);
              return cc?['status'] == 'connecting' || cc?['status'] == 'active';
            },
            what: '$phase: C observes the answer from ${receiver.label}',
            describe: describe,
            timeout: const Duration(seconds: 40),
          );
          final answerObservedMs = watch.elapsedMilliseconds;
          result['${phase}_answer_observed_ms'] = answerObservedMs;
          final mediaBudgetMs = 40000 - watch.elapsedMilliseconds;
          expect(mediaBudgetMs, greaterThan(0));
          await waitUntil(
            () async {
              final rc = await call(receiver), cc = await call(c);
              sampleMedia(rc, cc);
              return live(rc) &&
                  live(cc) &&
                  rc?['transport'] == 'onion' &&
                  cc?['transport'] == 'onion' &&
                  rx(rc) >= 5 &&
                  rx(cc) >= 5 &&
                  (!primaryOnline || !live(await call(other)));
            },
            what:
                '$phase: ${receiver.label} alone answers and exchanges onion audio RTP with C',
            describe: describe,
            timeout: Duration(milliseconds: mediaBudgetMs),
          );
          result['${phase}_answer_media_ms'] = watch.elapsedMilliseconds;
          result['${phase}_media_after_answer_ms'] =
              watch.elapsedMilliseconds - answerObservedMs;
          final beforeReceiver = rx(await call(receiver)),
              beforeC = rx(await call(c));
          result['stage'] = '$phase:continuous-media';
          await Future<void>.delayed(const Duration(seconds: 5));
          final afterReceiver = await call(receiver), afterC = await call(c);
          expect(live(afterReceiver) && live(afterC), isTrue);
          expect(rx(afterReceiver), greaterThan(beforeReceiver));
          expect(rx(afterC), greaterThan(beforeC));
          result['${phase}_media_rx_delta_$receiverLabel'] =
              rx(afterReceiver) - beforeReceiver;
          result['${phase}_media_rx_delta_c'] = rx(afterC) - beforeC;
          await receiver.checked('/call_hangup');
          await waitUntil(
            () async => !live(await call(receiver)) && !live(await call(c)),
            what: '$phase: ${receiver.label} hangup reaches C',
            describe: describe,
            timeout: const Duration(seconds: 25),
          );
          result['${phase}_hangup'] = true;
        }
        result['passed'] = true;
      } finally {
        if (evidence != null) {
          await File(
            '$evidence/startup-samples-private.json',
          ).writeAsString(jsonEncode(startupSamples));
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
