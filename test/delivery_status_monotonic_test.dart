import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/domain/chat.dart';

Uint8List _bytes(String value) => Uint8List.fromList(utf8.encode(value));
const _conv =
    '1111111111111111111111111111111111111111111111111111111111111111';

Future<HiddenVolumeStorage> _open(FakeKvLogStore kv) async {
  final storage = HiddenVolumeStorage(
    ({required password, required bool create}) => kv,
  );
  await storage.open(password: 'fixture', createIfMissing: true);
  return storage;
}

void main() {
  for (final cold in [false, true]) {
    test(
      'status lookup stays scoped and ignores erased rows, cold=$cold',
      () async {
        final kv = FakeKvLogStore();
        var storage = await _open(kv);
        addTearDown(() => storage.close());
        final other = '22' * 32;
        for (final conversation in [_conv, other]) {
          await storage.appendMessage(
            Message(
              id: 'same-id',
              conversationId: conversation,
              direction: MessageDirection.outgoing,
              body: conversation == _conv ? 'erased' : 'retained',
              timestamp: DateTime.utc(2020),
              status: MessageStatus.sent,
            ),
          );
        }
        await storage.deleteMessage(_conv, 'same-id');
        if (cold) {
          await storage.close();
          storage = await _open(kv);
        }
        final before = kv.commitSeq();
        expect(
          await storage.markMessageStatus(
            _conv,
            'same-id',
            MessageStatus.delivered,
          ),
          isFalse,
        );
        expect(
          await storage.markMessageStatus(
            other,
            'missing',
            MessageStatus.delivered,
          ),
          isFalse,
        );
        expect(
          kv.commitSeq(),
          before,
          reason: 'missing targets must not create orphan status writes',
        );
        expect(
          await storage.markMessageStatus(
            other,
            'same-id',
            MessageStatus.delivered,
          ),
          isTrue,
        );
        expect(await storage.loadMessageById(_conv, 'same-id'), isNull);
        final held = (await storage.loadMessageById(other, 'same-id'))!;
        expect(held.body, 'retained');
        expect(held.status, MessageStatus.delivered);
        expect(await storage.loadMessageById(other, 'missing'), isNull);
      },
    );
  }

  test('an unreadable target fold cannot create a status write', () async {
    final kv = FakeKvLogStore();
    kv.commit([
      AppendLogOp(Ns.messageLogShardFirst, 1, _bytes('{')),
      PutOp(
        Ns.settings,
        _bytes('msglog_ns:v1:${Ns.messageLogShardFirst}'),
        _bytes('1'),
      ),
      PutOp(Ns.settings, _bytes('msg_next_id'), _bytes('2')),
    ]);
    final storage = await _open(kv);
    addTearDown(storage.close);
    final before = kv.commitSeq();
    expect(
      await storage.markMessageStatus(_conv, 'target', MessageStatus.delivered),
      isFalse,
    );
    expect(kv.commitSeq(), before);
  });

  test(
    'a confirmed delivery rejects later sending, sent and failed writes',
    () async {
      final kv = FakeKvLogStore();
      final storage = await _open(kv);
      addTearDown(storage.close);
      await storage.appendMessage(
        Message(
          id: 'target',
          conversationId: _conv,
          direction: MessageDirection.outgoing,
          body: 'original',
          timestamp: DateTime.utc(2020),
          status: MessageStatus.sent,
        ),
      );
      expect(
        await storage.markMessageStatus(
          _conv,
          'target',
          MessageStatus.delivered,
        ),
        isTrue,
      );
      for (final status in [
        MessageStatus.sending,
        MessageStatus.sent,
        MessageStatus.failed,
      ]) {
        expect(
          await storage.markMessageStatus(_conv, 'target', status),
          isFalse,
        );
        expect(
          (await storage.loadMessageById(_conv, 'target'))!.status,
          MessageStatus.delivered,
        );
      }
    },
  );

  for (final legacy in [false, true]) {
    test(
      'historical out-of-order status rows retain ACK warm and cold legacy=$legacy',
      () async {
        final permutations = [
          [MessageStatus.delivered, MessageStatus.sent, MessageStatus.failed],
          [MessageStatus.delivered, MessageStatus.failed, MessageStatus.sent],
          [MessageStatus.sent, MessageStatus.delivered, MessageStatus.failed],
          [MessageStatus.sent, MessageStatus.failed, MessageStatus.delivered],
          [MessageStatus.failed, MessageStatus.delivered, MessageStatus.sent],
          [MessageStatus.failed, MessageStatus.sent, MessageStatus.delivered],
        ];
        for (final statuses in permutations) {
          final kv = FakeKvLogStore();
          var next = 1;
          void append(Map<String, Object> value) {
            kv.commit([
              AppendLogOp(
                Ns.messageLogShardFirst,
                next,
                _bytes(jsonEncode(value)),
              ),
              PutOp(
                Ns.settings,
                _bytes('msglog_ns:v1:${Ns.messageLogShardFirst}'),
                _bytes('1'),
              ),
              PutOp(Ns.settings, _bytes('msg_next_id'), _bytes('${next + 1}')),
            ]);
            next++;
          }

          append({
            'id': 'target',
            'c': _conv,
            'd': MessageDirection.outgoing.index,
            'b': 'original',
            't': 1,
            's': MessageStatus.sent.index,
          });
          final warm = await _open(kv);
          try {
            var confirmed = false;
            for (final status in statuses) {
              append({
                'op': 'status',
                'id': 'target',
                if (!legacy) 'c': _conv,
                's': status.index,
              });
              confirmed = confirmed || status == MessageStatus.delivered;
              final expected = confirmed ? MessageStatus.delivered : status;
              expect(
                (await warm.loadMessageById(_conv, 'target'))!.status,
                expected,
              );
              expect((await warm.loadMessages(_conv)).single.status, expected);
            }
          } finally {
            await warm.close();
          }
          final cold = await _open(kv);
          try {
            expect(
              (await cold.loadMessageById(_conv, 'target'))!.status,
              MessageStatus.delivered,
            );
            expect(
              (await cold.loadMessages(_conv)).single.status,
              MessageStatus.delivered,
            );
          } finally {
            await cold.close();
          }
        }
      },
    );
  }

  test(
    'a delivered post itself wins over an older retry status overlay',
    () async {
      final kv = FakeKvLogStore();
      kv.commit([
        AppendLogOp(
          Ns.messageLogShardFirst,
          1,
          _bytes(
            jsonEncode({
              'id': 'target',
              'c': _conv,
              'd': MessageDirection.outgoing.index,
              'b': 'original',
              't': 1,
              's': MessageStatus.delivered.index,
            }),
          ),
        ),
        AppendLogOp(
          Ns.messageLogShardFirst,
          2,
          _bytes(
            jsonEncode({
              'op': 'status',
              'id': 'target',
              'c': _conv,
              's': MessageStatus.failed.index,
            }),
          ),
        ),
        PutOp(
          Ns.settings,
          _bytes('msglog_ns:v1:${Ns.messageLogShardFirst}'),
          _bytes('1'),
        ),
        PutOp(Ns.settings, _bytes('msg_next_id'), _bytes('3')),
      ]);
      final storage = await _open(kv);
      addTearDown(storage.close);
      expect(
        (await storage.loadMessageById(_conv, 'target'))!.status,
        MessageStatus.delivered,
      );
      expect(
        (await storage.loadMessages(_conv)).single.status,
        MessageStatus.delivered,
      );
    },
  );
}
