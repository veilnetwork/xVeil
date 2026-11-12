import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/domain/chat.dart';

import 'support/fake_hv_container.dart';
import 'support/private_message_status_gate.dart';

void main() {
  test(
    'status checkpoint follows storage commit and precedes caller resume',
    () async {
      final dir = Directory.systemTemp.createTempSync('message-status-unit-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final fake = FakeHvContainer();
      final storage = PrivateMessageStatusGate(
        syncWrappedSpaceOpener(fake.passwordOpener),
        directory: dir,
      );
      expect(
        await storage.open(password: 'fixture', createIfMissing: true),
        isTrue,
      );
      const peer =
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
      const id = 'status-boundary-unit';
      await storage.appendMessage(
        Message(
          id: id,
          conversationId: peer,
          direction: MessageDirection.outgoing,
          body: 'fixture',
          timestamp: DateTime.utc(2026),
          status: MessageStatus.sent,
          author:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          seq: 1,
        ),
      );
      File('${dir.path}/message-status-arm.json').writeAsStringSync(
        jsonEncode({'nonce': 'unit-status', 'peer': peer, 'id': id}),
      );
      var returned = false;
      final update = storage
          .markMessageStatus(peer, id, MessageStatus.delivered)
          .then((moved) {
            returned = true;
            return moved;
          });
      try {
        await Future.any<void>([
          storage.reached,
          update.then<void>(
            (_) => throw StateError('status returned before checkpoint'),
          ),
        ]);
        expect(returned, isFalse);
        expect(
          (await storage.loadMessageById(peer, id))!.status,
          MessageStatus.delivered,
        );
        final marker =
            jsonDecode(
                  File(
                    '${dir.path}/message-status-reached.json',
                  ).readAsStringSync(),
                )
                as Map;
        expect(marker['storedDelivered'], isTrue);
        expect(marker['id'], id);
        expect(marker['nonce'], 'unit-status');
      } finally {
        storage.release();
        expect(await update, isTrue);
        await storage.close();
      }
    },
  );
}
