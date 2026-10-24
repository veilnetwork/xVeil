@Timeout(Duration(minutes: 12))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/log.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/device_sync.dart';

import 'device_fixture.dart';
import 'e2e_env.dart';

void main() {
  final gate = E2eGate.read();
  test(
    'pending peer unsend reaches offline sibling after the peer leaves',
    () async {
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
          reason:
              'a finished native case must not hide read-after-close errors',
        );
      });
      final evidence = Platform.environment['XVEIL_PENDING_MUTATION_EVIDENCE'];
      if (evidence != null) {
        await File('$evidence/fleet-private.json').writeAsString(
          jsonEncode({'root': fleet.root.path, 'workerPid': pid}),
        );
      }
      final a = fleet.a, b = fleet.b, c = fleet.c;
      await fleet.linkDevice(master: a, target: b);
      await fleet.introduce(a, c);
      final peer = c.identityNodeId;
      await waitUntil(
        () async =>
            (await b.storage.getContact(peer))?.status ==
            ContactStatus.accepted,
        what: 'B learns the accepted contact before going offline',
      );
      await b.stop();

      const id = 'pending-native-unsend', fid = 'pending-native-unsend-frame';
      // Controlled ordering through the REAL encrypted native transport. No fake
      // receive callback or device-journal injection. The one-shot low-level
      // send deliberately has no application retry that could later publish the
      // missing tombstone and mask a receiver-side failure.
      await c.stack.transport.send(
        a.identityNodeId,
        const WireEnvelope.del(id).withFrameId(fid).encode(),
      );
      int receipts() => devLogSnapshot(limit: 20000).lines
          .where(
            (line) =>
                line.contains('xVeil[recv]: del ') && line.contains('fid=$fid'),
          )
          .length;
      await waitUntil(
        () => receipts() == 1,
        what: 'A receives the authenticated delete before the post',
      );
      expect(await a.storage.loadMessageById(peer.hex, id), isNull);
      expect(await a.storage.isMessageDeleted(peer.hex, id), isFalse);
      final post = await c.storage.appendMessage(
        Message(
          id: id,
          conversationId: a.identityNodeId.hex,
          direction: MessageDirection.outgoing,
          body: 'pending fixture post',
          timestamp: DateTime.now(),
          author: await c.messaging.savedSelfHex(),
        ),
      );
      await c.stack.transport.send(
        a.identityNodeId,
        WireEnvelope.message(
          post.body,
          id: id,
          seq: post.seq,
          sentAtMs: post.timestamp.millisecondsSinceEpoch,
        ).encode(),
      );
      await waitUntil(
        () => a.storage.isMessageDeleted(peer.hex, id),
        what: 'A applies the pending unsend to the delayed post',
      );
      expect(await c.groups!.deviceGroupIdHex(), isNull);
      await c.messaging.deleteMessageLocally(id);
      expect(
        await c.storage.isMessageDeleted(a.identityNodeId.hex, id),
        isTrue,
      );
      await c.stop();
      expect(
        receipts(),
        1,
        reason:
            'a second peer mutation must not mask the missing own-device event',
      );
      await waitUntil(
        () async => (await a.groups!.deviceSyncState()).containsKey((
          DeviceSyncKind.msgGone,
          id,
        )),
        what:
            'A durably publishes the applied pending deletion to its own device log',
        timeout: const Duration(seconds: 20),
      );
      E2eLog.line('PENDING_UNSEND_OWN_JOURNAL_PASS');

      await b.start();
      await waitUntil(
        () => b.storage.isMessageDeleted(peer.hex, id),
        what: 'B learns the deletion with C unavailable',
        timeout: const Duration(minutes: 2),
      );
      expect(await b.storage.loadMessageById(peer.hex, id), isNull);
      await b.restart();
      expect(await b.storage.isMessageDeleted(peer.hex, id), isTrue);
      expect(await b.storage.loadMessageById(peer.hex, id), isNull);
      expect(await a.storage.loadMessageById(peer.hex, id), isNull);
      if (evidence != null) {
        await File('$evidence/result.json').writeAsString(
          jsonEncode({
            'native_peer_delete_receipts': receipts(),
            'peer_offline_during_sibling_recovery': !c.up,
            'source_deleted': true,
            'own_journal_tombstone': true,
            'sibling_deleted': true,
            'sibling_restart_retained_delete': true,
          }),
        );
      }
      E2eLog.line('PENDING_UNSEND_OFFLINE_SIBLING_RESTART_PASS');
    },
    skip: gate.skip,
  );
}
