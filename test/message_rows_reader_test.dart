import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/message_rows_reader.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/domain/chat.dart';

class _OrdinaryStorage implements Storage {
  int displayReads = 0;
  bool failDisplay = false;
  final rows = <Message>[];

  @override
  Future<List<Message>> loadMessages(
    String conversationId, {
    int? limit,
  }) async {
    displayReads++;
    if (failDisplay) throw StateError('fixture read failed');
    return List.of(rows);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unexpected fixture operation');
}

class _RowsStorage extends _OrdinaryStorage implements MessageRowsReader {
  int rowReads = 0;
  bool failRows = false;

  @override
  Future<List<Message>> loadMessageRows(String conversationId) async {
    rowReads++;
    if (failRows) throw StateError('fixture rows unavailable');
    return List.of(rows);
  }
}

void main() {
  final peer = NodeId(Uint8List(32)..fillRange(0, 32, 1));
  final other = NodeId(Uint8List(32)..fillRange(0, 32, 2));
  Message row(String id, {String? conversation, int seq = 1}) => Message(
    id: id,
    conversationId: conversation ?? peer.hex,
    direction: MessageDirection.outgoing,
    body: 'text $id',
    timestamp: DateTime.utc(2020).add(Duration(seconds: seq)),
    status: MessageStatus.sent,
    author: peer.hex,
    seq: seq,
  );

  test('ordinary storage keeps the fallback read and its errors', () async {
    final store = _OrdinaryStorage()..rows.add(row('ordinary'));
    expect((await readMessageRows(store, peer.hex)).single.id, 'ordinary');
    expect(store.displayReads, 1);
    store.failDisplay = true;
    await expectLater(readMessageRows(store, peer.hex), throwsStateError);
    expect(store.displayReads, 2);
  });

  test('advertised rows are used without building display order', () async {
    final store = _RowsStorage()..rows.add(row('rows'));
    expect((await readMessageRows(store, peer.hex)).single.id, 'rows');
    expect(store.rowReads, 1);
    expect(store.displayReads, 0);
  });

  test(
    'failed row capability does not fall back to a remembered view',
    () async {
      final store = _RowsStorage()..rows.add(row('rows'));
      await readMessageRows(store, peer.hex);
      store.failRows = true;
      await expectLater(readMessageRows(store, peer.hex), throwsStateError);
      expect(store.rowReads, 2);
      expect(store.displayReads, 0);
    },
  );

  group('live hidden-volume rows', () {
    late HiddenVolumeStorage store;
    setUp(() => store = HiddenVolumeStorage.fromStore(FakeKvLogStore()));
    tearDown(() => store.close());

    test(
      'rows are scoped, detached and retain the normal stored values',
      () async {
        await store.appendMessage(row('held'));
        await store.appendMessage(row('foreign', conversation: other.hex));
        await store.markMessageStatus(
          peer.hex,
          'held',
          MessageStatus.delivered,
        );
        await store.markMessageSignature(
          peer.hex,
          'held',
          MessageSignature.verified,
        );
        final display = (await store.loadMessages(peer.hex)).single;
        final snapshot = await readMessageRows(store, peer.hex);
        final held = snapshot.single;
        expect(
          (
            held.id,
            held.body,
            held.timestamp,
            held.status,
            held.signature,
            held.author,
            held.seq,
            held.orderAuthor,
            held.orderSeq,
          ),
          (
            display.id,
            display.body,
            display.timestamp,
            display.status,
            display.signature,
            display.author,
            display.seq,
            display.orderAuthor,
            display.orderSeq,
          ),
        );
        snapshot.clear();
        expect((await readMessageRows(store, peer.hex)).single.id, 'held');
        expect((await store.loadMessages(other.hex)).single.id, 'foreign');
      },
    );

    test('a warm view observes later appends, edits and delivery', () async {
      await store.appendMessage(row('first'));
      final before = await readMessageRows(store, peer.hex);
      await store.appendMessage(row('next', seq: 2));
      await store.editMessage(peer.hex, 'first', 'edited', seq: 3);
      await store.markMessageStatus(peer.hex, 'first', MessageStatus.delivered);
      final current = {
        for (final m in await readMessageRows(store, peer.hex)) m.id: m,
      };
      expect(current.keys, {'first', 'next'});
      expect(current['first']!.body, 'edited');
      expect(current['first']!.edited, isTrue);
      expect(current['first']!.status, MessageStatus.delivered);
      expect((await store.editSeqs(peer.hex))['first'], 3);
      expect(before.single.body, 'text first');
    });

    test('a warm view observes canonical ordering adoption', () async {
      await store.appendMessage(row('position', seq: 10));
      await readMessageRows(store, peer.hex);
      expect(
        await store.adoptMessageOrdering(
          peer.hex,
          'position',
          provisionalAuthor: peer.hex,
          provisionalSeq: 10,
          author: other.hex,
          seq: 42,
        ),
        isTrue,
      );
      final current = (await readMessageRows(store, peer.hex)).single;
      expect((current.author, current.seq), (peer.hex, 10));
      expect((current.orderAuthor, current.orderSeq), (other.hex, 42));
      expect(current.body, 'text position');
    });

    test('deleted and cleared rows cannot survive a prior snapshot', () async {
      await store.appendMessage(row('deleted'));
      await store.appendMessage(row('cleared', seq: 2));
      await store.appendMessage(row('foreign', conversation: other.hex));
      await readMessageRows(store, peer.hex);
      await store.deleteMessage(peer.hex, 'deleted');
      expect((await readMessageRows(store, peer.hex)).single.id, 'cleared');
      await store.clearMessages(peer);
      expect(await readMessageRows(store, peer.hex), isEmpty);
      expect((await readMessageRows(store, other.hex)).single.id, 'foreign');
    });
  });
}
