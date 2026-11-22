@Timeout(Duration(minutes: 12))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'device_process_fixture.dart';
import 'e2e_env.dart';
import 'multi_device_process_e2e_test.dart' as base;

void main() {
  final gate = E2eGate.read();
  test(
    'mailbox settles offline acceptance and the outbox resumes over live relays',
    () async {
      final fleet = await ProcessFleet.start(gate, labels: ['A', 'C']);
      addTearDown(fleet.dispose);
      final requester = fleet.a, answerer = fleet.c;
      final requesterId =
          (await base.deviceInfo(requester))['identity'] as String;
      final answererId =
          (await base.deviceInfo(answerer))['identity'] as String;
      expect(requesterId, isNot(answererId));
      final relays = fleet.cluster.nodes.map((node) => node.nodeIdHex!).toSet();

      Future<void> expectRelaySessions(ProcessDevice device) async {
        final table = await device.admin(gate.veilCli!, [
          'sessions',
          'list',
          '-v',
        ]);
        final rows = table.trim().split('\n');
        expect(rows.first, startsWith('link_id\tnode_id\t'));
        final authenticatedPeers = rows
            .skip(1)
            .map((row) => row.split('\t')[1])
            .where((id) => id != '-');
        expect(authenticatedPeers, isNotEmpty);
        expect(authenticatedPeers, everyElement(isIn(relays)));
      }

      await expectRelaySessions(requester);
      await expectRelaySessions(answerer);
      final mailboxPrefix = fleet.cluster.mailbox.nodeIdHex!.substring(0, 8);
      for (final device in [requester, answerer]) {
        await waitUntil(() async {
          final trace = await device.checked(
            '/dev_log',
            query: {'grep': 'REGISTERED rendezvous publisher'},
          );
          return (trace['lines'] as List).cast<String>().any(
            (line) => line.contains('relay $mailboxPrefix '),
          );
        }, what: '${device.label} advertises a relay with a mailbox handler');
      }
      await requester.checked('/contact_request', query: {'peer': answererId});
      await waitUntil(
        () async =>
            await base.contactStatus(answerer, requesterId) ==
            'pendingIncoming',
        what: 'the request reaches the answerer through the relay island',
        timeout: const Duration(minutes: 3),
      );
      expect(
        await base.contactStatus(requester, answererId),
        'pendingOutgoing',
      );
      E2eLog.line('MAILBOX_CONTACT_REQUEST_RECEIVED');
      await requester.stop();
      expect(requester.lastExitCode, 0);
      final accepted = await answerer.checked(
        '/contact_accept',
        query: {'peer': requesterId},
      );
      expect(accepted['status'], 'accepted');

      const first = 'mailbox-contact-first-message';
      await answerer.checked(
        '/send_message',
        query: {'peer': requesterId, 'text': first},
      );
      final outgoing = (await base.rows(answerer, requesterId)).singleWhere(
        (row) => row['body'] == first && row['direction'] == 'outgoing',
      );
      final id = outgoing['id'] as String;
      expect(outgoing['status'], isNot('delivered'));
      final mailboxLog = File(fleet.cluster.mailbox.logPath);
      final receiptPrefix = 'PUT stored (recv=${requesterId.substring(0, 16)} ';
      await waitUntil(
        () async {
          final trace = await answerer.checked(
            '/dev_log',
            query: {'grep': 'stash OK', 'limit': '4000'},
          );
          final lines = (trace['lines'] as List).cast<String>();
          return lines.any((line) => line.contains('id=accept:$requesterId:')) &&
              (await mailboxLog.readAsString()).contains(receiptPrefix);
        },
        what: 'mailbox stores the acceptance while the requester is stopped',
        timeout: const Duration(minutes: 3),
      );
      E2eLog.line('MAILBOX_CONTACT_ACCEPTANCE_DEPOSITED');

      // The answerer is stopped, so the acceptance can only come from the
      // mailbox. Ordinary text stays in the answerer's durable Outbox.
      await answerer.stop();
      expect(answerer.lastExitCode, 0);
      await requester.start();
      await expectRelaySessions(requester);
      await waitUntil(
        () async =>
            await base.contactStatus(requester, answererId) == 'accepted',
        what: 'the returning requester admits the saved acceptance',
        timeout: const Duration(minutes: 3),
      );
      expect(
        (await base.rows(
          requester,
          answererId,
        )).where((row) => row['id'] == id),
        isEmpty,
      );
      E2eLog.line('MAILBOX_CONTACT_ACCEPTANCE_DRAINED');

      await answerer.start();
      await expectRelaySessions(answerer);
      expect(await base.contactStatus(answerer, requesterId), 'accepted');
      await base.hasBody(requester, answererId, first);
      final received = (await base.rows(
        requester,
        answererId,
      )).singleWhere((row) => row['body'] == first);
      expect(received['id'], id);
      expect(received['direction'], 'incoming');
      const reply = 'mailbox-contact-first-reply';
      await requester.checked(
        '/send_message',
        query: {'peer': answererId, 'text': reply},
      );
      await base.hasBody(answerer, requesterId, reply);
      await waitUntil(
        () async =>
            (await base.rows(
              answerer,
              requesterId,
            )).any((row) => row['id'] == id && row['status'] == 'delivered') &&
            (await base.rows(requester, answererId)).any(
              (row) => row['body'] == reply && row['status'] == 'delivered',
            ),
        what:
            'both peers have receipts for the messages exchanged over live relays',
      );
      await expectRelaySessions(requester);
      await expectRelaySessions(answerer);
      E2eLog.line('MAILBOX_CONTACT_BIDIRECTIONAL_TEXT_DELIVERED');
    },
    skip: gate.enabled && Platform.environment['XVEIL_E2E_ANONYMOUS'] != '1'
        ? 'requires XVEIL_E2E_ANONYMOUS=1'
        : gate.skip,
  );
}
