import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/domain/chat.dart';

import 'support/fake_hv_container.dart';
import 'support/private_message_append_gate.dart';

void main() {
  for (final authorized in [false, true]) {
    test('resuming append requires matching release: $authorized', () async {
      final dir = Directory.systemTemp.createTempSync('message-resume-unit-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final fake = FakeHvContainer();
      final storage = PrivateMessageAppendGate(
        syncWrappedSpaceOpener(fake.passwordOpener),
        directory: dir,
      );
      await storage.open(password: 'fixture', createIfMissing: true);
      const peer =
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
      File('${dir.path}/message-append-arm.json').writeAsStringSync(
        jsonEncode({
          'nonce': 'resume-unit',
          'body': 'resumable',
          'phase': 'before',
          'allowResume': true,
        }),
      );
      File(
        '${dir.path}/message-append-resume',
      ).writeAsStringSync(authorized ? 'resume-unit' : 'another-run');
      final append = storage.appendMessage(
        Message(
          id: 'resume-id',
          conversationId: peer,
          direction: MessageDirection.incoming,
          body: 'resumable',
          timestamp: DateTime.utc(2026),
          status: MessageStatus.delivered,
          author: peer,
          seq: 1,
        ),
      );
      try {
        if (authorized) {
          await append;
        } else {
          await expectLater(append, throwsStateError);
        }
        expect(
          await storage.loadMessageById(peer, 'resume-id'),
          authorized ? isNotNull : isNull,
        );
      } finally {
        storage.release();
        await storage.close();
      }
    });
  }
  for (final phase in ['before', 'after']) {
    test('message gate $phase brackets the actual append', () async {
      final dir = Directory.systemTemp.createTempSync('message-append-unit-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final fake = FakeHvContainer();
      final storage = PrivateMessageAppendGate(
        syncWrappedSpaceOpener(fake.passwordOpener),
        directory: dir,
      );
      expect(
        await storage.open(password: 'fixture', createIfMissing: true),
        isTrue,
      );
      const peer =
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
      const body = 'crash-boundary-unit';
      File('${dir.path}/message-append-arm.json').writeAsStringSync(
        jsonEncode({'nonce': 'fixture-$phase', 'body': body, 'phase': phase}),
      );
      final append = storage.appendMessage(
        Message(
          id: 'fixture-message',
          conversationId: peer,
          direction: MessageDirection.incoming,
          body: body,
          timestamp: DateTime.utc(2026),
          status: MessageStatus.delivered,
          author: peer,
          seq: 1,
        ),
      );
      var returned = false;
      final completed = append.then((value) {
        returned = true;
        return value;
      });
      final marker = File('${dir.path}/message-append-reached.json');
      try {
        await Future.any<void>([
          storage.reached,
          completed.then<void>(
            (_) => throw StateError('append returned before gate'),
          ),
        ]);
        expect(returned, isFalse);
        final stored = await storage.loadMessageById(peer, 'fixture-message');
        expect(stored != null, phase == 'after');
        final witness = jsonDecode(marker.readAsStringSync()) as Map;
        expect(witness['nonce'], 'fixture-$phase');
        expect(witness['appendReturned'], phase == 'after');
      } finally {
        storage.release();
        await completed;
        await storage.close();
      }
    });
  }
}
