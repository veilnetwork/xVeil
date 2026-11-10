@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/message_batch_store.dart';
import 'package:xveil/domain/chat.dart';

import '../support/timed_native_store.dart';

// Real worker-backed IO. The gate holds a completed preparation read before
// the application continuation may construct or publish a deletion.
class _HeldNativeErasure extends TimedNativeStore {
  _HeldNativeErasure(AsyncKvLogStore inner)
    : super(inner, Stopwatch()..start(), (_) {});
  final entered = Completer<void>(), release = Completer<void>();
  bool holdKeys = false, holdRange = false, closeBeforeRelease = false;

  @override
  Future<List<Uint8List>> kvKeys(int namespace) async {
    final keys = await super.kvKeys(namespace);
    if (holdKeys && namespace == Ns.settings) {
      holdKeys = false;
      entered.complete();
      await release.future;
    }
    return keys;
  }

  @override
  Future<List<KvLogEntry>> iterLogRange({
    required int namespace,
    int? start,
    int? end,
    required int limit,
  }) async {
    final rows = await super.iterLogRange(
      namespace: namespace,
      start: start,
      end: end,
      limit: limit,
    );
    if (holdRange &&
        namespace >= Ns.messageLogShardFirst &&
        namespace <= Ns.messageLogShardLast) {
      holdRange = false;
      entered.complete();
      await release.future;
    }
    return rows;
  }

  @override
  Future<void> close() async {
    closeBeforeRelease = entered.isCompleted && !release.isCompleted;
    await super.close();
  }
}

void main() {
  final native = Platform.environment['XVEIL_HV_DYLIB'];
  final skip = native == null
      ? 'set XVEIL_HV_DYLIB to a qualified library'
      : false;
  final firstPeer = NodeId(Uint8List(32)..fillRange(0, 32, 1));
  final nextPeer = NodeId(Uint8List(32)..fillRange(0, 32, 2));
  final rows = int.parse(
    Platform.environment['XVEIL_ERASURE_ROWS'] ?? '100000',
  );
  if (rows < 1 || rows > 100000) throw ArgumentError('invalid archive rows');
  Message canary(int i) => Message(
    id: 'canary-${i.toString().padLeft(6, '0')}',
    conversationId: nextPeer.hex,
    direction: MessageDirection.incoming,
    body: 'next-space-body-$i',
    timestamp: DateTime.utc(2020).add(Duration(milliseconds: i)),
    status: MessageStatus.delivered,
    author: nextPeer.hex,
    seq: i + 1,
    positionVerified: true,
  );

  for (final kind in ['delete', 'clear', 'prune']) {
    test(
      'native $kind cannot overwrite another identity with $rows rows',
      () async {
        expect(ensureHiddenVolumeLoaded(dylibPath: native), isTrue);
        final dir = await Directory.systemTemp.createTemp(
          'xveil-native-erasure-',
        );
        final evidence = Platform.environment['XVEIL_ERASURE_EVIDENCE_DIR'];
        if (evidence != null) {
          await File('$evidence/runtimes-private.jsonl').writeAsString(
            '${jsonEncode({'root': dir.path, 'pid': pid, 'kind': kind})}\n',
            mode: FileMode.append,
            flush: true,
          );
        }
        final opened = <_HeldNativeErasure>[];
        final storage = HiddenVolumeStorage.async(({
          required password,
          required create,
        }) async {
          final label = utf8.decode(password);
          final store = _HeldNativeErasure(
            (await workerSpaceOpener('${dir.path}/$label.hv')(
              password: password,
              create: false,
            ))!,
          );
          opened.add(store);
          return store;
        });
        addTearDown(() async {
          for (final store in opened) {
            if (!store.release.isCompleted) store.release.complete();
          }
          await storage.close();
          await dir.delete(recursive: true);
        });
        for (final label in ['first', 'next']) {
          HvKvLogStore(
            hv.HvSpace.create(
              path: '${dir.path}/$label.hv',
              password: Uint8List.fromList(utf8.encode(label)),
              argon: hv.ArgonPreset.light,
            ),
          ).close();
        }
        expect(await storage.open(password: 'next'), isTrue);
        for (
          var start = 0;
          start < rows;
          start += preparedMessageBatchMaxRows
        ) {
          final end = (start + preparedMessageBatchMaxRows).clamp(0, rows);
          expect(
            await storage.appendMissingMessageBatch([
              for (var i = start; i < end; i++) canary(i),
            ], beforeCommit: () async {}),
            List.filled(end - start, PreparedMessageWrite.appended),
          );
        }
        await storage.close();

        expect(await storage.open(password: 'first'), isTrue);
        await storage.appendMessage(
          Message(
            id: 'old-row',
            conversationId: firstPeer.hex,
            direction: MessageDirection.incoming,
            body: 'first-space-body',
            timestamp: DateTime.utc(2020),
            author: firstPeer.hex,
            seq: 1,
          ),
        );
        await storage.loadMessages(firstPeer.hex);
        final old = opened.last;
        old.holdKeys = kind != 'prune';
        old.holdRange = kind == 'prune';
        final work = switch (kind) {
          'delete' => storage.deleteMessage(firstPeer.hex, 'old-row'),
          'clear' => storage.clearMessages(firstPeer),
          _ => storage.pruneConversationBefore(firstPeer, DateTime.utc(2021)),
        };
        final outcome = work.then((_) => 'ok', onError: (Object _) => 'error');
        await old.entered.future;
        var reopened = false;
        final opening = storage.open(password: 'next').then((ok) {
          reopened = ok;
          return ok;
        });
        if (Platform.environment['XVEIL_ERASURE_FORCE_OLD_INTERLEAVING'] ==
            '1') {
          // Negative-control probe only: drive the vulnerable parent into the
          // demonstrated bad ordering. A fixed implementation cannot get here
          // before release. This is not a performance A/B fixture.
          await opening.timeout(const Duration(seconds: 30));
        } else {
          // Opportunity to attempt close while the gate is held. Correctness
          // is recorded operation order and exact data, not this duration.
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        final reopenedBeforeRelease = reopened;
        old.release.complete();
        final result = await outcome;
        expect(await opening, isTrue);
        final closeBeforeRelease = old.closeBeforeRelease;
        final retained = await storage.loadMessageRows(nextPeer.hex);
        await storage.close();
        final held = {for (final m in retained) m.id: m};
        final exact = [for (var i = 0; i < rows; i++) canary(i)].where((
          expected,
        ) {
          final actual = held[expected.id];
          return actual != null &&
              actual.body == expected.body &&
              actual.status == expected.status &&
              actual.author == expected.author &&
              actual.seq == expected.seq &&
              actual.orderAuthor == expected.orderAuthor &&
              actual.orderSeq == expected.orderSeq &&
              actual.timestamp.millisecondsSinceEpoch ==
                  expected.timestamp.millisecondsSinceEpoch;
        }).length;
        if (evidence != null) {
          await File('$evidence/$kind-private.json').writeAsString(
            jsonEncode({
              'kind': kind,
              'expectedRows': rows,
              'actualRows': retained.length,
              'uniqueRows': held.length,
              'exactRows': exact,
              'outcome': result,
              'reopenedBeforeRelease': reopenedBeforeRelease,
              'closedBeforeRelease': closeBeforeRelease,
            }),
          );
        }
        expect(retained, hasLength(rows));
        expect(held, hasLength(rows));
        expect(exact, rows);
        expect(result, 'ok');
        expect(reopenedBeforeRelease, isFalse);
        expect(closeBeforeRelease, isFalse);
        expect(await storage.open(password: 'first'), isTrue);
        expect(
          await storage.isMessageDeleted(firstPeer.hex, 'old-row'),
          isTrue,
        );
        expect(await storage.loadMessages(firstPeer.hex), isEmpty);
      },
      skip: skip,
    );
  }
}
