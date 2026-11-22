@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'device_process_fixture.dart';
import 'e2e_env.dart';
import 'multi_device_process_e2e_test.dart' as base;

void main() {
  final gate = E2eGate.read();
  final env = Platform.environment;
  final syntheticMedia =
      Platform.isMacOS &&
      gate.mediaDylib != null &&
      env['XVEIL_E2E_SYNTHETIC_MEDIA'] == '1' &&
      env['VEIL_MEDIA_TEST_VIDEO'] == '1';
  test(
    'one active video call carries media through P2P, relay and back',
    () async {
      final fleet = await ProcessFleet.start(gate, labels: ['A', 'C']);
      addTearDown(fleet.dispose);
      final a = fleet.a;
      final c = fleet.c;
      final aInfo = await base.deviceInfo(a);
      final cInfo = await base.deviceInfo(c);
      final ai = aInfo['identity'] as String;
      final ci = cInfo['identity'] as String;
      await base.introduceProcesses(a, c);
      for (final (device, peer) in [(a, ci), (c, ai)]) {
        await device.checked(
          '/contact_set',
          query: {'peer': peer, 'p2p': 'allow'},
        );
      }
      Future<Map?> state(ProcessDevice d) async =>
          (await d.checked('/call_state'))['call'] as Map?;
      int count(Map? s) =>
          (s?['mediaStats'] as Map?)?['audio_rx_pkts'] as int? ?? 0;
      int video(Map? s) =>
          (s?['mediaStats'] as Map?)?['remote_frames'] as int? ?? 0;
      int epoch(Map? s) =>
          (s?['mediaStats'] as Map?)?['audio_rtt_route_epoch'] as int? ?? -1;
      Future<String> describe() async => jsonEncode([
        for (final d in [a, c])
          await state(d).then(
            (s) => {
              'transport': s?['transport'],
              'status': s?['status'],
              'rx': count(s),
              'epoch': epoch(s),
              'localPosture': s?['localPosture'],
              'video': video(s),
            },
          ),
      ]);
      final placed = await c.checked(
        '/call_place',
        query: {'peer': ai, 'media': 'video'},
      );
      final id = (placed['call'] as Map)['callId'];
      await waitUntil(
        () async => (await state(a))?['status'] == 'ringing',
        what: 'the receiver rings with the direct call',
        describe: describe,
      );
      await a.checked('/call_accept');
      bool active(Map? s) => s?['callId'] == id && s?['status'] == 'active';
      bool inMode(Map? s, String transport) =>
          active(s) && s?['transport'] == transport;
      await waitUntil(
        () async {
          final left = await state(a), right = await state(c);
          return inMode(left, 'p2p') &&
              inMode(right, 'p2p') &&
              count(left) >= 10 &&
              count(right) >= 10 &&
              video(left) > 0 &&
              video(right) > 0;
        },
        what:
            'both endpoints receive synthetic audio and video over verified direct media',
        describe: describe,
      );
      E2eLog.line('DIRECT_INITIAL ${await describe()}');
      final initialA = count(await state(a));
      final initialC = count(await state(c));
      final watch = Stopwatch()..start();
      final recovery = await c.call('/call_relay_recovery');
      expect(recovery['ok'], isTrue);
      E2eLog.line(
        'RELAY_COMMIT ${watch.elapsedMilliseconds} ${await describe()}',
      );
      await waitUntil(
        () async =>
            inMode(await state(a), 'relay') && inMode(await state(c), 'relay'),
        what: 'both endpoints are on the relay in the original call',
        describe: describe,
      );
      final relayLeft = await state(a), relayRight = await state(c);
      await waitUntil(
        () async {
          final left = await state(a), right = await state(c);
          return inMode(left, 'relay') &&
              inMode(right, 'relay') &&
              count(left) > count(relayLeft) &&
              count(right) > count(relayRight) &&
              video(left) > video(relayLeft) &&
              video(right) > video(relayRight);
        },
        what:
            'audio and decoded video continue on the relay in both directions',
        describe: describe,
      );
      E2eLog.line(
        'RELAY_MEDIA ${watch.elapsedMilliseconds} ${await describe()}',
      );
      await waitUntil(
        () async {
          final left = await state(a), right = await state(c);
          return inMode(left, 'p2p') &&
              inMode(right, 'p2p') &&
              count(left) > initialA &&
              count(right) > initialC &&
              epoch(left) >= 2 &&
              epoch(right) >= 2;
        },
        what: 'both endpoints return to direct without a media engine restart',
        describe: describe,
      );
      final returnedLeft = await state(a), returnedRight = await state(c);
      final returnMs = watch.elapsedMilliseconds;
      E2eLog.line('DIRECT_RESTORED $returnMs ${await describe()}');
      await waitUntil(
        () async {
          final left = await state(a), right = await state(c);
          return inMode(left, 'p2p') &&
              inMode(right, 'p2p') &&
              count(left) > count(returnedLeft) &&
              count(right) > count(returnedRight) &&
              video(left) > video(returnedLeft) &&
              video(right) > video(returnedRight);
        },
        what: 'decoded video and audio continue after return',
        describe: describe,
      );
      E2eLog.line(
        'DIRECT_MEDIA ${watch.elapsedMilliseconds} ${await describe()}',
      );
      await c.checked('/call_hangup');
    },
    skip: gate.enabled && !syntheticMedia
        ? 'needs the macOS synthetic media test-hook build'
        : gate.skip,
  );
}
