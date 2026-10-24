@Timeout(Duration(minutes: 12))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/device_sync.dart';

import 'device_fixture.dart';
import 'e2e_env.dart';

void main() {
  final gate = E2eGate.read();
  test(
    'peer retry repairs the own-device journal before delivery ACK',
    () async {
      final fleet = await E2eFleet.start(
        gate: gate,
        labels: const ['A', 'B', 'C'],
      );
      addTearDown(() async {
        await fleet.dispose();
        await Future<void>.delayed(Duration.zero);
        expect(
          fleet.devices.values.fold<int>(
            0,
            (sum, d) => sum + d.lateAsyncErrors,
          ),
          0,
        );
      });
      final evidence = Platform.environment['XVEIL_MESSAGE_MIRROR_EVIDENCE'];
      if (evidence != null) {
        await File('$evidence/fleet-private.json').writeAsString(
          jsonEncode({'root': fleet.root.path, 'workerPid': pid}),
        );
      }
      final a = fleet.a, b = fleet.b, c = fleet.c;
      await fleet.linkDevice(master: a, target: b);
      await fleet.introduce(a, c);
      await waitUntil(
        () async =>
            (await b.storage.getContact(c.identityNodeId))?.status ==
            ContactStatus.accepted,
        what: 'B knows the accepted contact before disconnecting',
      );
      await b.stop();
      const body = 'own-journal-ack-recovery-fixture';
      var refusing = true, attempts = 0, successfulPublications = 0;
      final publisher = a.messaging.onMessageStored;
      expect(publisher, isNotNull);
      a.messaging.onMessageStored = (peer, message) async {
        final target = peer == c.identityNodeId && message.body == body;
        if (target) {
          attempts++;
          if (refusing) throw StateError('fixture own-device journal refusal');
        }
        await publisher!(peer, message);
        if (target) successfulPublications++;
      };
      expect(await c.messaging.sendText(a.identityNodeId, body), isTrue);
      final sent = (await c.storage.loadMessages(
        a.identityNodeId.hex,
      )).singleWhere((message) => message.body == body);
      await waitUntil(
        () async =>
            attempts >= 2 ||
            (await c.storage.loadMessageById(
                  a.identityNodeId.hex,
                  sent.id,
                ))?.status ==
                MessageStatus.delivered,
        what:
            'the sender retries and A re-enters the refused journal publication',
        timeout: const Duration(seconds: 30),
      );
      expect(
        attempts,
        greaterThanOrEqualTo(2),
        reason:
            'a duplicate must retry the own journal before the sender can retire it',
      );
      expect(
        (await c.storage.loadMessageById(
          a.identityNodeId.hex,
          sent.id,
        ))!.status,
        isNot(MessageStatus.delivered),
        reason: 'no ACK while the own journal is missing',
      );
      expect(
        (await a.groups!.deviceSyncState())[(
          DeviceSyncKind.msgMirror,
          sent.id,
        )],
        isNull,
      );
      refusing = false;
      await waitUntil(
        () async =>
            (await c.storage.loadMessageById(
              a.identityNodeId.hex,
              sent.id,
            ))?.status ==
            MessageStatus.delivered,
        what: 'delivery is acknowledged after the durable own journal commit',
        timeout: const Duration(minutes: 1),
      );
      expect(
        (await a.groups!.deviceSyncState())[(
          DeviceSyncKind.msgMirror,
          sent.id,
        )],
        isNotNull,
      );
      expect(successfulPublications, 1);
      await c.stop();
      await b.start();
      await waitUntil(
        () => b.storage
            .loadMessageById(c.identityNodeId.hex, sent.id)
            .then((m) => m != null),
        what: 'B recovers the received message from A with C offline',
        timeout: const Duration(minutes: 2),
      );
      await b.restart();
      final source = (await a.storage.loadMessageById(
        c.identityNodeId.hex,
        sent.id,
      ))!;
      final recovered = (await b.storage.loadMessageById(
        c.identityNodeId.hex,
        sent.id,
      ))!;
      expect(recovered.body, body);
      expect(recovered.direction, MessageDirection.incoming);
      expect(recovered.author, source.author);
      expect(recovered.seq, source.seq);
      expect(recovered.timestamp, source.timestamp);
      expect(
        (await b.storage.loadMessages(
          c.identityNodeId.hex,
        )).where((m) => m.id == sent.id),
        hasLength(1),
      );
      if (evidence != null) {
        await File('$evidence/result.json').writeAsString(
          jsonEncode({
            'publication_retry_observed': attempts >= 2,
            'early_ack_withheld': true,
            'own_journal_present_at_ack': true,
            'successful_publications': successfulPublications,
            'peer_offline_during_sibling_recovery': !c.up,
            'sibling_restart_retained_message': true,
            'sibling_message_copies': 1,
            'original_position_preserved': true,
          }),
        );
      }
    },
    skip: gate.skip,
  );
}
