@Timeout(Duration(minutes: 8))
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
  test('local unsend survives journal refusal and source restart', () async {
    final fleet = await E2eFleet.start(
      gate: gate,
      labels: const ['A', 'B', 'C'],
    );
    addTearDown(() async {
      await fleet.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(
        fleet.devices.values.fold<int>(0, (n, d) => n + d.lateAsyncErrors),
        0,
      );
    });
    final evidence = Platform.environment['XVEIL_LOCAL_DELETE_EVIDENCE'];
    if (evidence != null) {
      await File(
        '$evidence/fleet-private.json',
      ).writeAsString(jsonEncode({'root': fleet.root.path, 'workerPid': pid}));
    }
    final a = fleet.a, b = fleet.b, c = fleet.c;
    await fleet.linkDevice(master: a, target: b);
    await fleet.introduce(a, c);
    await waitUntil(
      () async =>
          (await b.storage.getContact(c.identityNodeId))?.status ==
          ContactStatus.accepted,
      what: 'B has the accepted contact',
    );
    const body = 'local-delete-restart-fixture';
    expect(await a.messaging.sendText(c.identityNodeId, body), isTrue);
    final sent = (await a.storage.loadMessages(
      c.identityNodeId.hex,
    )).singleWhere((message) => message.body == body);
    await waitUntil(
      () async =>
          await b.storage.loadMessageById(c.identityNodeId.hex, sent.id) !=
              null &&
          await c.storage.loadMessageById(a.identityNodeId.hex, sent.id) !=
              null,
      what: 'B and C both hold the original message before deletion',
    );
    await b.stop();
    var refused = 0;
    a.messaging.onMessageDeleted = (_, _) async {
      refused++;
      throw StateError('fixture own-device journal refusal');
    };
    await expectLater(a.messaging.deleteForEveryone(sent.id), throwsStateError);
    expect(refused, greaterThanOrEqualTo(1));
    expect(
      await a.storage.loadMessageById(c.identityNodeId.hex, sent.id),
      isNull,
    );
    final pending = (await a.storage.pendingMessageDeletions()).single;
    expect(pending.messageId, sent.id);
    expect(pending.mirrorPending, isTrue);
    expect(pending.peerPending, isFalse);
    expect(
      (await a.groups!.deviceSyncState())[(DeviceSyncKind.msgGone, sent.id)],
      isNull,
    );
    await waitUntil(
      () => c.storage.isMessageDeleted(a.identityNodeId.hex, sent.id),
      what:
          'C receives the durable unsend while own-device publication refuses',
      timeout: const Duration(seconds: 45),
    );
    await c.stop();
    await a.restart();
    await waitUntil(
      () async =>
          (await a.groups!.deviceSyncState())[(
                DeviceSyncKind.msgGone,
                sent.id,
              )] !=
              null &&
          (await a.storage.pendingMessageDeletions()).isEmpty,
      what:
          'A publishes the committed deletion after restart without a source row',
      timeout: const Duration(seconds: 45),
    );
    await b.start();
    await waitUntil(
      () => b.storage.isMessageDeleted(c.identityNodeId.hex, sent.id),
      what: 'B recovers the deletion from A while C is offline',
      timeout: const Duration(minutes: 2),
    );
    await b.restart();
    expect(
      await b.storage.loadMessageById(c.identityNodeId.hex, sent.id),
      isNull,
    );
    expect(
      await b.storage.isMessageDeleted(c.identityNodeId.hex, sent.id),
      isTrue,
    );
    expect(await a.storage.pendingMessageDeletions(), isEmpty);
    expect(
      await b.storage.pendingMessageDeletions(),
      isEmpty,
      reason:
          'mirrored deletion must not create a new local publication intent',
    );
    if (evidence != null) {
      await File('$evidence/result.json').writeAsString(
        jsonEncode({
          'devices': 3,
          'same_identity_devices': 2,
          'initial_message_present_on_all': true,
          'publication_refusal_observed': refused > 0,
          'peer_unsend_independent_of_journal': true,
          'source_restart_recovered_without_message_row': true,
          'peer_offline_during_sibling_recovery': !c.up,
          'sibling_restart_retained_deletion': true,
          'pending_deletion_intents_after_recovery': 0,
          'mirror_echoes': 0,
        }),
      );
    }
  }, skip: gate.skip);
}
