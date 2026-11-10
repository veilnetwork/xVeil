import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/message_rows_reader.dart';
import 'package:xveil/data/storage/message_batch_store.dart';
import 'package:xveil/domain/chat.dart';

import '../support/timed_native_store.dart';

void main() {
  test(
    'native indexed windows preserve rewrites metadata and cold reopen',
    () async {
      expect(ensureHiddenVolumeLoaded(), isTrue);
      final directory = await Directory.systemTemp.createTemp(
        'indexed-history-',
      );
      final opener = workerSpaceOpener('${directory.path}/fixture.hv');
      final operations = <String, int>{};
      final storage = HiddenVolumeStorage.async(({
        required password,
        required create,
      }) async {
        final inner = await opener(password: password, create: create);
        return inner == null
            ? null
            : TimedNativeStore(inner, Stopwatch()..start(), (value) {
                operations.update(
                  value['operation'] as String,
                  (n) => n + 1,
                  ifAbsent: () => 1,
                );
              });
      });
      Future<List<Message>> page({int? after, String? id}) =>
          readMessageHistoryWindow(
            storage,
            'peer',
            limit: 32,
            afterTimestampMs: after,
            afterId: id,
          );
      final rows = [
        for (var i = 0; i < 256; i++)
          Message(
            id: 'row-${i.toString().padLeft(4, '0')}',
            conversationId: 'peer',
            direction: MessageDirection.outgoing,
            body: 'payload-$i',
            timestamp: DateTime.fromMillisecondsSinceEpoch(1000 + i),
            status: MessageStatus.sent,
            author: 'author',
            seq: i + 1,
          ),
      ];
      try {
        expect(
          await storage.open(
            password: 'indexed-history-fixture',
            createIfMissing: true,
          ),
          isTrue,
        );
        expect(
          (await storage.appendMissingMessageBatch(
            rows,
            beforeCommit: () async {},
          ))!,
          everyElement(PreparedMessageWrite.appended),
        );
        expect((await page()).map((m) => m.id), rows.take(32).map((m) => m.id));
        operations.clear();
        for (var i = 0; i < 8; i++) {
          final held = await page(after: 1223, id: 'row-0223');
          expect(
            held.map((m) => (m.id, m.body, m.author, m.seq)),
            rows.skip(224).map((m) => (m.id, m.body, m.author, m.seq)),
          );
        }
        expect(
          operations,
          isEmpty,
          reason:
              'a current fold does not re-read or write native records per window',
        );
        final frontier = await storage.getSetting('msg_next_id');
        await storage.deleteMessage('peer', 'row-0224');
        expect(await storage.getSetting('msg_next_id'), frontier);
        await storage.editMessage('peer', 'row-0225', 'edited', seq: 300);
        await storage.markMessageStatus(
          'peer',
          'row-0225',
          MessageStatus.delivered,
        );
        await storage.markMessageSignature(
          'peer',
          'row-0225',
          MessageSignature.verified,
        );
        final warm = await page(after: 1223, id: 'row-0223');
        expect(warm, hasLength(31));
        expect(
          (
            warm.first.id,
            warm.first.body,
            warm.first.status,
            warm.first.signature,
          ),
          (
            'row-0225',
            'edited',
            MessageStatus.delivered,
            MessageSignature.verified,
          ),
        );
        await storage.close();
        expect(await storage.open(password: 'indexed-history-fixture'), isTrue);
        final cold = await page(after: 1223, id: 'row-0223');
        expect(
          cold.map((m) => (m.id, m.body, m.status, m.signature)),
          warm.map((m) => (m.id, m.body, m.status, m.signature)),
        );
        expect(
          (await readMessageHistoryWindow(storage, 'foreign', limit: 32)),
          isEmpty,
        );
        await storage.eraseSpace();
        expect(await page(), isEmpty);
      } finally {
        await storage.close();
        await directory.delete(recursive: true);
      }
    },
    skip: (Platform.environment['XVEIL_HV_DYLIB'] ?? '').isEmpty
        ? 'set a verified hidden-volume library'
        : false,
  );
}
