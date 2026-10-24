@Timeout(Duration(minutes: 12))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'device_fixture.dart' show E2eIdentity;
import 'device_process_fixture.dart';
import 'e2e_env.dart';
import 'multi_device_process_e2e_test.dart'
    show deviceInfo, hasBody, introduceProcesses, join, linkProcesses, rows;

void main() {
  final gate = E2eGate.read();
  test(
    'revoked offline device cannot ring a warm contact or receive a new call',
    () async {
      final fleet = await ProcessFleet.start(gate);
      addTearDown(fleet.dispose);
      final evidence = Platform.environment['XVEIL_REVOKED_CALL_EVIDENCE'];
      if (evidence != null) {
        await File('$evidence/fleet-private.json').writeAsString(
          jsonEncode({'root': fleet.root.path, 'runnerPid': pid}),
        );
      }
      final a = fleet.a, b = fleet.b, c = fleet.c;
      await introduceProcesses(a, c);
      await linkProcesses(a, b);
      final ai = (await deviceInfo(a))['identity'] as String;
      final ci = (await deviceInfo(c))['identity'] as String;
      final oldDevice = (await deviceInfo(b))['nodeId'] as String;
      for (final (device, peer) in [(a, ci), (b, ci), (c, ai)]) {
        await device.checked(
          '/contact_set',
          query: {'peer': peer, 'p2p': 'deny'},
        );
      }
      Future<Map<String, dynamic>?> state(ProcessDevice d) async =>
          (await d.checked('/call_state'))['call'] as Map<String, dynamic>?;
      bool live(Map<String, dynamic>? call) =>
          call != null && call['status'] != 'ended';
      Future<void> idle() => waitUntil(
        () async =>
            !(await Future.wait([state(a), state(b), state(c)])).any(live),
        what: 'all three call slots are no longer live',
        timeout: const Duration(seconds: 15),
      );
      Future<void> ring(ProcessDevice d, String callId) async {
        Map<String, dynamic>? last;
        await waitUntil(
          () async {
            last = await state(d);
            return last?['callId'] == callId && last?['status'] == 'ringing';
          },
          what: '${d.label} rings for the exact current call',
          describe: () =>
              'status=${last?['status']} direction=${last?['direction']}',
          timeout: const Duration(seconds: 40),
        );
      }

      String callId(Map<String, dynamic> response) =>
          (response['call'] as Map<String, dynamic>)['callId'] as String;

      await b.checked(
        '/send_message',
        query: {'peer': ci, 'text': 'call-revoke-proof-before'},
      );
      await hasBody(c, ai, 'call-revoke-proof-before');
      final incoming = callId(
        await c.checked('/call_place', query: {'peer': ai}),
      );
      await Future.wait([ring(a, incoming), ring(b, incoming)]);
      await c.checked('/call_hangup');
      await idle();
      final outgoing = callId(
        await b.checked('/call_place', query: {'peer': ci}),
      );
      await ring(c, outgoing);
      await c.checked('/call_reject');
      await idle();
      final warmC = List<int>.of(c.ownedPids);
      await b.stop();
      final revoked = await a.checked(
        '/device_revoke',
        query: {'peer': oldDevice},
        body: E2eIdentity.x.phrase,
      );
      expect(revoked['docRevoked'], isTrue);
      final key = (await a.admin(gate.veilCli!, [
        'identity',
        'dht-key',
        ai,
      ])).trim();
      Future<String?> document(ProcessDevice device) async {
        final raw = await device.admin(gate.veilCli!, [
          'node',
          'dht',
          'get',
          key,
        ]);
        return RegExp(
          r'^value: ([0-9a-f]+)$',
          multiLine: true,
        ).firstMatch(raw)?.group(1);
      }

      final current = await document(a);
      expect(current, isNotNull);
      await a.checked(
        '/send_message',
        query: {'peer': ci, 'text': 'call-revoke-document-control'},
      );
      await hasBody(c, ai, 'call-revoke-document-control');
      await waitUntil(
        () async => await document(c) == current,
        what: 'warm C has the current signed revocation',
      );
      await b.start();
      expect((await deviceInfo(b))['nodeId'], oldDevice);
      await join(b, c);

      // The new offer uses the identity's normal recipient resolution. The
      // fixture never gives B a call id or a media key from this new call.
      final fresh = callId(await c.checked('/call_place', query: {'peer': ai}));
      await ring(a, fresh);
      var rounds = 0;
      var oldDeviceRang = false;
      final incomingWatch = Stopwatch()..start();
      while (incomingWatch.elapsed < const Duration(seconds: 8)) {
        final old = await state(b);
        oldDeviceRang |= old?['callId'] == fresh && live(old);
        rounds++;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      await c.checked('/call_hangup');
      await idle();

      const attackBody = 'call-revoke-old-B-after-current-document';
      await b.call('/send_message', query: {'peer': ci, 'text': attackBody});
      final attackCall = callId(
        await b.checked('/call_place', query: {'peer': ci}),
      );
      var oldOfferAccepted = false;
      var oldMessageAccepted = false;
      final watch = Stopwatch()..start();
      while (watch.elapsed < const Duration(seconds: 60)) {
        oldOfferAccepted |= live(await state(c));
        oldMessageAccepted |= (await rows(
          c,
          ai,
        )).any((row) => row['body'] == attackBody);
        rounds++;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      final deniedWindowMs = watch.elapsedMilliseconds;
      final oldJournal = (await b.checked('/call_log'))['entries'] as List;
      final recipientJournal =
          (await c.checked('/call_log'))['entries'] as List;
      final newCallLeaked = oldJournal.any((row) => row['id'] == fresh);
      final attackJournaled = recipientJournal.any(
        (row) => row['id'] == attackCall,
      );
      await b.call('/call_hangup');
      // Controls after the denial window distinguish authorization refusal
      // from an unavailable recipient, disconnected island or dead call FSM.
      await a.checked(
        '/send_message',
        query: {'peer': ci, 'text': 'call-revoke-final-message-control'},
      );
      await hasBody(c, ai, 'call-revoke-final-message-control');
      final finalCall = callId(
        await c.checked('/call_place', query: {'peer': ai}),
      );
      await ring(a, finalCall);
      await c.checked('/call_hangup');
      await idle();
      expect(c.ownedPids, warmC);
      if (evidence != null) {
        await File('$evidence/result.json').writeAsString(
          jsonEncode({
            'devices': 3,
            'same_identity_devices_before_revoke': 2,
            'pre_revoke_both_siblings_ring': true,
            'pre_revoke_B_can_ring_C': true,
            'current_document_barrier_observed': true,
            'revoked_device_key_preserved': true,
            'recipient_process_not_restarted': true,
            'unrevoked_sibling_receives_fresh_offer': true,
            'revoked_device_received_fresh_offer': oldDeviceRang,
            'revoked_device_offer_accepted': oldOfferAccepted,
            'revoked_device_message_accepted': oldMessageAccepted,
            'outgoing_denial_observation_ms': deniedWindowMs,
            'revoked_device_has_fresh_call_record': newCallLeaked,
            'revoked_offer_in_recipient_call_journal': attackJournaled,
            'observation_rounds': rounds,
            'final_message_control': true,
            'final_call_control': true,
            'media_started': false,
          }),
        );
      }
      expect(oldDeviceRang, isFalse);
      expect(oldOfferAccepted, isFalse);
      expect(oldMessageAccepted, isFalse);
      expect(newCallLeaked, isFalse);
      expect(attackJournaled, isFalse);
    },
    skip: gate.skip,
  );
}
