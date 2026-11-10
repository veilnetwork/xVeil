import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/message_batch_store.dart';
import 'package:xveil/domain/chat.dart';

class _CountingStore extends FakeKvLogStore {
  int readRows = 0, scrubs = 0;
  final starts = <int?>[];
  bool loseTombstoneReply = false;
  @override
  List<KvLogEntry> iterLogRange({
    required int namespace,
    int? start,
    int? end,
    required int limit,
  }) {
    final rows = super.iterLogRange(
      namespace: namespace,
      start: start,
      end: end,
      limit: limit,
    );
    if (namespace >= Ns.messageLogShardFirst &&
        namespace <= Ns.messageLogShardRetiredLast) {
      starts.add(start);
      readRows += rows.length;
    }
    return rows;
  }

  @override
  void scrub() {
    scrubs++;
    super.scrub();
  }

  @override
  int commit(List<KvLogOp> ops) {
    final result = super.commit(ops);
    if (loseTombstoneReply &&
        ops.whereType<AppendLogOp>().any(
          (op) => (jsonDecode(utf8.decode(op.payload)) as Map)['op'] == 'del',
        )) {
      loseTombstoneReply = false;
      throw StateError('fixture committed without a reply');
    }
    return result;
  }
}

void main() {
  final peer = NodeId(Uint8List(32)..fillRange(0, 32, 1));
  final other = NodeId(Uint8List(32)..fillRange(0, 32, 2));
  final base = DateTime.utc(2020);
  Message row(int i, {NodeId? node}) => Message(
    id: 'm$i',
    conversationId: (node ?? peer).hex,
    direction: MessageDirection.incoming,
    body: 'body-$i',
    timestamp: base.add(Duration(seconds: i)),
    status: MessageStatus.delivered,
    author: (node ?? peer).hex,
    seq: i + 1,
    positionVerified: true,
  );

  test(
    'point scrub retains the 100000-row warm fold and forward watermark',
    () async {
      final raw = _CountingStore();
      final storage = HiddenVolumeStorage.fromStore(raw);
      addTearDown(storage.close);
      for (
        var start = 0;
        start < 100000;
        start += preparedMessageBatchMaxRows
      ) {
        final end = (start + preparedMessageBatchMaxRows).clamp(0, 100000);
        expect(
          await storage.appendMissingMessageBatch([
            for (var i = start; i < end; i++) row(i),
          ], beforeCommit: () async {}),
          List.filled(end - start, PreparedMessageWrite.appended),
        );
      }
      expect(await storage.loadMessageRows(peer.hex), hasLength(100000));
      raw.readRows = 0;
      raw.starts.clear();
      raw.scrubs = 0;
      await storage.deleteMessage(peer.hex, 'm50000');
      await storage.scrubDeleted();
      final remaining = await storage.loadMessageRows(peer.hex);
      expect(remaining, hasLength(99999));
      expect(remaining.map((m) => m.id).toSet(), hasLength(99999));
      expect(remaining.where((m) => m.id == 'm50000'), isEmpty);
      expect(
        remaining.every(
          (m) =>
              m.body == 'body-${m.seq! - 1}' &&
              m.author == peer.hex &&
              m.status == MessageStatus.delivered,
        ),
        isTrue,
      );
      expect(await storage.isMessageDeleted(peer.hex, 'm50000'), isTrue);
      expect(raw.scrubs, 1, reason: 'forensic reclamation is still required');
      expect(
        raw.readRows,
        0,
        reason:
            'a stable-ID physical vacuum must not re-read every live message',
      );
      await storage.appendMessage(row(100000));
      expect(await storage.loadMessageRows(peer.hex), hasLength(100000));
      expect(raw.starts, isNotEmpty);
      expect(raw.starts.every((start) => start != null && start > 0), isTrue);
      expect(
        (await storage.loadMessageById(peer.hex, 'm100000'))!.body,
        'body-100000',
      );
    },
  );

  for (final kind in [
    'clear',
    'remove',
    'prune',
    'remote-clear',
    'emit-clear',
  ]) {
    test(
      'bulk $kind still drops stale folded rows and survives a cold view',
      () async {
        final raw = _CountingStore();
        var storage = HiddenVolumeStorage.fromStore(raw);
        addTearDown(() => storage.close());
        for (var i = 0; i < 6; i++) {
          await storage.appendMessage(row(i));
        }
        await storage.appendMessage(row(9, node: other));
        expect(await storage.loadMessageRows(peer.hex), hasLength(6));
        switch (kind) {
          case 'clear':
            await storage.clearMessages(peer);
          case 'remove':
            await storage.removeConversation(peer);
          case 'prune':
            await storage.pruneConversationBefore(
              peer,
              base.add(const Duration(seconds: 3)),
            );
          case 'remote-clear':
            await storage.applyRemoteClear(peer, peer.hex, 100, {
              peer.hex: 3,
            }, selfHex: other.hex);
          default:
            await storage.emitClearConversation(peer, other.hex);
        }
        final expected = kind == 'prune' || kind == 'remote-clear'
            ? {'m3', 'm4', 'm5'}
            : <String>{};
        expect(
          (await storage.loadMessageRows(peer.hex)).map((m) => m.id).toSet(),
          expected,
        );
        expect(
          (await storage.loadMessageRows(other.hex)).single.body,
          'body-9',
        );
        await storage.close();
        storage = HiddenVolumeStorage.fromStore(raw);
        expect(
          (await storage.loadMessageRows(peer.hex)).map((m) => m.id).toSet(),
          expected,
        );
        expect(
          (await storage.loadMessageRows(other.hex)).single.body,
          'body-9',
        );
      },
    );
  }

  test(
    'uncertain bulk publication cannot preserve stale rows after explicit scrub',
    () async {
      final raw = _CountingStore();
      final storage = HiddenVolumeStorage.fromStore(raw);
      addTearDown(storage.close);
      await storage.appendMessage(row(0));
      await storage.appendMessage(row(1));
      expect(await storage.loadMessageRows(peer.hex), hasLength(2));
      raw.loseTombstoneReply = true;
      await expectLater(storage.clearMessages(peer), throwsStateError);
      // Scrub itself is the next operation: no read/recovery has refreshed the cache.
      await storage.scrubDeleted();
      expect(await storage.loadMessageRows(peer.hex), isEmpty);
      expect(await storage.isMessageDeleted(peer.hex, 'm0'), isTrue);
      expect(await storage.isMessageDeleted(peer.hex, 'm1'), isTrue);
    },
  );
}
