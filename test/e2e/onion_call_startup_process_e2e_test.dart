@Timeout(Duration(minutes: 9))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'device_process_fixture.dart';
import 'e2e_env.dart';
import 'multi_device_process_e2e_test.dart' as base;

void main() {
  final gate = E2eGate.read();
  final holdSeconds = int.tryParse(
    Platform.environment['XVEIL_E2E_CALL_HOLD_SECONDS'] ?? '5',
  );
  if (holdSeconds == null || holdSeconds < 5 || holdSeconds > 720) {
    throw ArgumentError('XVEIL_E2E_CALL_HOLD_SECONDS must be 5..720');
  }
  final fileBytes = int.tryParse(
    Platform.environment['XVEIL_E2E_CALL_FILE_BYTES'] ?? '0',
  );
  if (fileBytes == null ||
      fileBytes < 0 ||
      fileBytes > 16 * 1024 * 1024 ||
      (fileBytes > 0 && fileBytes < 3 * 1024 * 1024)) {
    throw ArgumentError('XVEIL_E2E_CALL_FILE_BYTES must be 0 or 3..16 MiB');
  }
  // Own DATA can be paced to 1 KiB per 200 ms while a primary is active.
  // A fixed 90-second total deadline cannot qualify a multi-MiB transfer.
  // Allow bounded completion time for that policy, but detect actual stalls
  // independently from the verified piece writes below.
  final fileBudget = Duration(seconds: 90 + (fileBytes / 4096).ceil());
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
              // Private evidence only: align this answer-relative sample with
              // SDK/relay event clocks without adding a production test hook.
              'sample_unix_ms': DateTime.now().millisecondsSinceEpoch,
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

          Future<int> observeAnswer() async {
            await waitUntil(
              () async {
                // Observe the caller independently of the accept API and the
                // answerer's media diagnostics. Either may finish after the
                // answer has already reached the caller.
                final cc = await call(c);
                sampleMedia(null, cc);
                return cc?['status'] == 'connecting' ||
                    cc?['status'] == 'active';
              },
              what: '$phase: C observes the answer from ${receiver.label}',
              describe: describe,
              timeout: const Duration(seconds: 40),
            );
            return watch.elapsedMilliseconds;
          }

          // Attach both futures immediately and await both on failure too;
          // do not leave an accept request running during fleet teardown.
          final answerResults = await Future.wait<Object?>([
            receiver.checked('/call_accept'),
            observeAnswer(),
          ]);
          final answerObservedMs = answerResults[1] as int;
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
          // An optional long first call crosses the relay's receive-binding
          // lifetime. Keep observing packet progress instead of sleeping once
          // and allowing an early stall/reconnect to masquerade as continuity.
          final hold = Stopwatch()..start();
          final duration = Duration(seconds: primaryOnline ? holdSeconds : 5);
          var previousReceiver = beforeReceiver, previousC = beforeC;
          while (hold.elapsed < duration) {
            await Future<void>.delayed(const Duration(seconds: 5));
            final currentReceiver = await call(receiver),
                currentC = await call(c);
            expect(live(currentReceiver) && live(currentC), isTrue);
            expect(rx(currentReceiver), greaterThan(previousReceiver));
            expect(rx(currentC), greaterThan(previousC));
            previousReceiver = rx(currentReceiver);
            previousC = rx(currentC);
            result['${phase}_continuous_ms'] = hold.elapsedMilliseconds;
            result['${phase}_media_rx_delta_$receiverLabel'] =
                previousReceiver - beforeReceiver;
            result['${phase}_media_rx_delta_c'] = previousC - beforeC;
            if (evidence != null) {
              await File(
                '$evidence/result.json',
              ).writeAsString(jsonEncode(result));
            }
          }
          final afterReceiver = await call(receiver), afterC = await call(c);
          expect(live(afterReceiver) && live(afterC), isTrue);
          expect(rx(afterReceiver), greaterThan(beforeReceiver));
          expect(rx(afterC), greaterThan(beforeC));
          result['${phase}_media_rx_delta_$receiverLabel'] =
              rx(afterReceiver) - beforeReceiver;
          result['${phase}_media_rx_delta_c'] = rx(afterC) - beforeC;
          if (primaryOnline && fileBytes > 0) {
            // Own the whole transfer before hangup/teardown. An external probe
            // could still be reading when the short second call ends.
            result['stage'] = '$phase:file-during-call';
            result['file_started_after_hold_ms'] = hold.elapsedMilliseconds;
            if (evidence != null) {
              await File(
                '$evidence/result.json',
              ).writeAsString(jsonEncode(result));
            }
            final ci = (await base.deviceInfo(c))['identity'] as String;
            final peers = {receiver: ci, c: ai};
            final policies = <ProcessDevice, String>{};
            String? cid;
            var downloaded = false;
            try {
              for (final entry in peers.entries) {
                final info = await entry.key.checked(
                  '/contact_info',
                  query: {'peer': entry.value},
                );
                policies[entry.key] = info['p2pOverride'] as String;
                await entry.key.checked(
                  '/contact_set',
                  query: {'peer': entry.value, 'p2p': 'deny'},
                );
              }
              final body = Uint8List(fileBytes);
              for (var i = 0; i < body.length; i++) {
                body[i] = (i * 17 + 31) & 255;
              }
              final source = File('${fleet.root.path}/call-file-source.bin');
              final target = File(
                '${receiver.dir.path}/call-file-received.bin',
              );
              await source.writeAsBytes(body, flush: true);
              final sent = await c.checked(
                '/send_file',
                query: {
                  'peer': ai,
                  'path': source.path,
                  'name': 'call-file-probe.bin',
                },
              );
              cid = sent['contentId'] as String;
              await waitUntil(() async {
                final rows = await receiver.checked(
                  '/messages',
                  query: {'peer': ci, 'limit': '100'},
                );
                return (rows['messages'] as List).any(
                  (row) => (row as Map)['fileContentId'] == cid,
                );
              }, what: 'file offer reaches the call answerer');
              expect(
                (await receiver.checked(
                  '/has_file',
                  query: {'cid': cid},
                ))['hasFile'],
                isFalse,
              );
              final transfer = Stopwatch()..start();
              var lastFileProgressMs = 0, savedBytes = 0;
              var finished = false;
              final download = receiver
                  .call(
                    '/download_file',
                    query: {
                      'peer': ci,
                      'cid': cid,
                      'path': target.path,
                      'expect_size': '$fileBytes',
                      'timeout_ms': '${fileBudget.inMilliseconds}',
                    },
                    timeout: fileBudget + const Duration(seconds: 10),
                  )
                  .whenComplete(() => finished = true);
              final observe =
                  () async {
                    var previousReceiver = rx(await call(receiver)),
                        previousC = rx(await call(c));
                    while (!finished) {
                      await Future<void>.delayed(const Duration(seconds: 5));
                      if (finished) break;
                      final rc = await call(receiver), cc = await call(c);
                      expect(live(rc) && live(cc), isTrue);
                      expect(rx(rc), greaterThan(previousReceiver));
                      expect(rx(cc), greaterThan(previousC));
                      previousReceiver = rx(rc);
                      previousC = rx(cc);
                      // The sink writes only verified pieces. Never publish the
                      // private path, content ID, source bytes or their hash.
                      await for (final entry in target.parent.list()) {
                        if (entry is! File ||
                            !entry.path.startsWith('${target.path}.part-')) {
                          continue;
                        }
                        final length = (await entry.stat()).size;
                        if (length > savedBytes) {
                          savedBytes = length;
                          lastFileProgressMs = transfer.elapsedMilliseconds;
                        }
                      }
                      expect(
                        transfer.elapsedMilliseconds - lastFileProgressMs,
                        lessThan(120000),
                        reason: 'verified file writes stopped for two minutes',
                      );
                      result['file_wait_ms'] = transfer.elapsedMilliseconds;
                      result['file_saved_bytes'] = savedBytes;
                      if (evidence != null) {
                        await File(
                          '$evidence/result.json',
                        ).writeAsString(jsonEncode(result));
                      }
                    }
                  }().catchError((Object error, StackTrace stack) async {
                    await receiver.call(
                      '/download_cancel',
                      query: {'cid': cid!},
                    );
                    Error.throwWithStackTrace(error, stack);
                  });
              final replies = await Future.wait<Object?>([
                download,
                observe,
              ], eagerError: true);
              expect((replies.first as Map)['ok'], isTrue);
              final received = await target.readAsBytes();
              expect(received.length, body.length);
              expect(
                sha256.convert(received).toString() ==
                    sha256.convert(body).toString(),
                isTrue,
              );
              downloaded = true;
              result['file_bytes'] = fileBytes;
              result['file_elapsed_ms'] = transfer.elapsedMilliseconds;
              result['file_sha256_matches'] = true;
            } finally {
              if (!downloaded && cid != null) {
                await receiver.call('/download_cancel', query: {'cid': cid});
              }
              for (final entry in policies.entries) {
                await entry.key.checked(
                  '/contact_set',
                  query: {'peer': peers[entry.key]!, 'p2p': entry.value},
                );
              }
            }
          }
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
    timeout: Timeout(
      Duration(seconds: holdSeconds + 540) +
          (fileBytes > 0 ? fileBudget : Duration.zero),
    ),
    skip: gate.enabled && Platform.environment['XVEIL_E2E_ANONYMOUS'] != '1'
        ? 'requires XVEIL_E2E_ANONYMOUS=1'
        : gate.mediaSkip,
  );
}
