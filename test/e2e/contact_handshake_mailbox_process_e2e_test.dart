@Timeout(Duration(minutes: 12))
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_test/flutter_test.dart';
import 'package:veil_flutter/veil_flutter.dart' show VeilClient, VeilPeerState;
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/veil_native.dart';
import 'package:xveil/data/transport/relay_key_cache.dart';
import 'package:xveil/data/transport/veil_mailbox_network.dart';

import 'device_process_fixture.dart';
import 'e2e_env.dart';
import 'multi_device_process_e2e_test.dart' as base;

void _testRelayKeyRotation(E2eGate gate, {required bool advertised}) {
  test(
    '${advertised ? 'advertised' : 'remembered'} offline mailbox accepts a '
    'deposit after relay key rotation',
    () async {
      final fleet = await ProcessFleet.start(
        gate,
        labels: [if (advertised) 'A', 'C'],
      );
      addTearDown(fleet.dispose);
      final relay = fleet.cluster.mailbox;
      final relayId = NodeId.fromHex(relay.nodeIdHex!);
      final recipient = advertised
          ? NodeId.fromHex(
              (await base.deviceInfo(fleet.a))['identity'] as String,
            )
          : NodeId(Uint8List.fromList(List.filled(32, 0x71)));
      final content = NodeId(Uint8List.fromList(List.filled(32, 0xb6)));
      final ipc = await Directory('${fleet.c.dir.path}/runtime')
          .list(recursive: true, followLinks: false)
          .where((entry) => entry.path.endsWith('/app.sock'))
          .single;
      expect(ensureVeilClientLoaded(dylibPath: gate.veilDylib), isTrue);
      final client = await VeilClient.connect(ipc.path);
      addTearDown(client.close);
      final sender = NodeId(await client.nodeId());
      final cache = InMemoryRelayKeyCache();

      Future<Uint8List> currentRelayKey() async {
        final holder = await VeilClient.connect(relay.socketPath);
        try {
          return (await holder.getRelayX25519Pubkey())!;
        } finally {
          await holder.close();
        }
      }

      await waitUntil(() async {
        return (await client.peers()).any(
          (peer) =>
              peer.state == VeilPeerState.active &&
              NodeId(peer.nodeId) == relayId,
        );
      }, what: 'the sender connects to the original mailbox relay');
      final old = await currentRelayKey();
      final signed = await client.lookupRelayX25519(relayId.bytes);
      expect(signed?.key, old);
      if (advertised) {
        await waitUntil(() async {
          final ads = await client.mailbox.lookupRendezvousReplicas(
            recipient.bytes,
          );
          return ads.any(
            (ad) =>
                NodeId(ad.relayNodeId) == relayId &&
                listEquals(ad.rendezvousKemPk, old),
          );
        }, what: 'the sender resolves the old key in a signed mailbox ad');
        await fleet.a.stop();
        expect(fleet.a.lastExitCode, 0);
        expect(await cache.getPeerRelays(recipient), isEmpty);
        // Signed publication times have one-second resolution. Ensure even
        // the receiver's last possible ad predates the replacement record.
        final stoppedAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        await waitUntil(
          () async => DateTime.now().millisecondsSinceEpoch ~/ 1000 > stoppedAt,
          what: 'the next signed publication second',
        );
      } else {
        // Synthetic receiver with no ad. Seed the information the sender
        // would have retained from the last successful ad lookup.
        await cache.setPeerRelays(recipient, [relayId]);
        await cache.put(relayId, old);
        expect(
          await client.mailbox.lookupRendezvousReplicas(recipient.bytes),
          isEmpty,
        );
      }

      await fleet.cluster.restartWithRotatedMailboxKey();
      expect(relay.nodeIdHex, relayId.hex);
      final rotated = await currentRelayKey();
      expect(rotated, isNot(equals(old)));
      await waitUntil(() async {
        final table = await fleet.cluster.admin(relay, [
          'sessions',
          'list',
          '-v',
        ]);
        return table.contains(sender.hex);
      }, what: 'the replacement relay session admits the sender');

      final app = await client.bind(
        namespace: 'xveil',
        name: 'mailbox-rotation',
        endpointId: 0,
      );
      addTearDown(app.close);
      final mailbox = VeilNetworkMailboxRelay(
        client: client,
        fetchApp: app,
        srcApp: app,
        replyEndpointId: 0,
        relayKeyCache: cache,
      );
      await mailbox.put(
        receiver: recipient,
        contentId: content.bytes,
        sender: sender,
        blob: Uint8List.fromList([1, 2, 3]),
      );
      final receipt =
          'PUT stored (recv=${recipient.hex.substring(0, 16)} '
          'cid=${content.hex.substring(0, 16)} ';
      await waitUntil(
        () async {
          return (await File(relay.logPath).readAsString()).contains(receipt);
        },
        what: 'the rotated mailbox opens and stores the deposit',
        timeout: const Duration(seconds: 20),
      );
      if (advertised) {
        expect(await cache.getPeerRelays(recipient), contains(relayId));
      } else {
        expect(await cache.get(relayId), rotated);
        expect(await cache.getPeerRelays(recipient), [relayId]);
      }
      E2eLog.line('ROTATED_MAILBOX_KEY_DEPOSIT_STORED');
    },
    skip: gate.enabled && Platform.environment['XVEIL_E2E_ANONYMOUS'] != '1'
        ? 'requires XVEIL_E2E_ANONYMOUS=1'
        : gate.skip,
  );
}

void main() {
  final gate = E2eGate.read();
  _testRelayKeyRotation(gate, advertised: false);
  _testRelayKeyRotation(gate, advertised: true);

  test(
    'offline acceptance recovers after relay storage loss',
    () async {
      final fleet = await ProcessFleet.start(gate);
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
      await waitUntil(() async {
        final log = await File(requester.logPath).readAsString();
        return log.contains(
          'anonymity.rendezvous_recipient.published_immediate',
        );
      }, what: 'the requester publishes its built-in live relay set');
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

      // Wait for DHT replication from an independent client. The answerer's
      // first deposit must find the signed mailbox ad after the requester
      // stops, without a last-known route seeded by this readiness check.
      final ipc = await Directory('${fleet.b.dir.path}/runtime')
          .list(recursive: true, followLinks: false)
          .where((entry) => entry.path.endsWith('/app.sock'))
          .single;
      expect(ensureVeilClientLoaded(dylibPath: gate.veilDylib), isTrue);
      final client = await VeilClient.connect(ipc.path);
      try {
        final requesterBytes = NodeId.fromHex(requesterId).bytes;
        final mailboxId = fleet.cluster.mailbox.nodeIdHex!;
        await waitUntil(() async {
          final ads = await client.mailbox.lookupRendezvousReplicas(
            requesterBytes,
          );
          return ads.any(
            (ad) =>
                NodeId(ad.relayNodeId).hex == mailboxId &&
                ad.rendezvousKemPk.length == 32,
          );
        }, what: 'a third client resolves the requester’s published mailbox');
      } finally {
        await client.close();
      }
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
      final receipt = RegExp(
        '${RegExp.escape(receiptPrefix)}cid=([0-9a-f]{16}) ',
      );
      String? acceptanceContentPrefix;
      await waitUntil(
        () async {
          final trace = await answerer.checked(
            '/dev_log',
            query: {'grep': 'stash OK', 'limit': '4000'},
          );
          final lines = (trace['lines'] as List).cast<String>();
          acceptanceContentPrefix = receipt
              .firstMatch(await mailboxLog.readAsString())
              ?.group(1);
          return lines.any(
                (line) => line.contains('id=accept:$requesterId:'),
              ) &&
              acceptanceContentPrefix != null;
        },
        what: 'mailbox stores the acceptance while the requester is stopped',
        timeout: const Duration(minutes: 3),
      );
      E2eLog.line('MAILBOX_CONTACT_ACCEPTANCE_DEPOSITED');

      await fleet.cluster.restartWithEmptyMailbox();
      final redriveReceipt = '${receiptPrefix}cid=$acceptanceContentPrefix ';
      await waitUntil(
        () async => (await mailboxLog.readAsString()).contains(redriveReceipt),
        what: 'the same acceptance is stored again on the restarted relay',
        timeout: const Duration(minutes: 3),
      );
      E2eLog.line('MAILBOX_CONTACT_ACCEPTANCE_RESTORED');

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
