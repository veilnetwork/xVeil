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

class _HeldMarkerStore extends TimedNativeStore {
  _HeldMarkerStore(AsyncKvLogStore inner, this.markerKey)
    : super(inner, Stopwatch()..start(), (_) {});
  final String markerKey;
  final entered = Completer<void>(), release = Completer<void>();
  bool hold = false, closeBeforeRelease = false;

  @override
  Future<Uint8List?> get(int namespace, Uint8List key) async {
    final result = await super.get(namespace, key);
    if (hold && namespace == Ns.settings && utf8.decode(key) == markerKey) {
      hold = false;
      entered.complete();
      await release.future;
    }
    return result;
  }

  @override
  Future<void> close() async {
    closeBeforeRelease = entered.isCompleted && !release.isCompleted;
    await super.close();
  }
}

void main() {
  final native = Platform.environment['XVEIL_HV_DYLIB'];
  final rows = int.parse(
    Platform.environment['XVEIL_READ_MARK_ROWS'] ?? '100000',
  );
  if (rows < 1 || rows > 100000) throw ArgumentError('invalid archive rows');
  final peer = NodeId(Uint8List(32)..fillRange(0, 32, 1));
  const initialMarker = 1000, oldIdentityMarker = 2000000;
  Message canary(int i) => Message(
    id: 'canary-${i.toString().padLeft(6, '0')}',
    conversationId: peer.hex,
    direction: MessageDirection.incoming,
    body: 'next-space-body-$i',
    timestamp: DateTime.fromMillisecondsSinceEpoch(initialMarker + i),
    status: MessageStatus.delivered,
    author: peer.hex,
    seq: i + 1,
    positionVerified: true,
  );

  for (final kind in ['markRead', 'setReadMarker']) {
    test(
      'native $kind keeps read position in its own identity with $rows rows',
      () async {
        expect(ensureHiddenVolumeLoaded(dylibPath: native), isTrue);
        final dir = await Directory.systemTemp.createTemp(
          'xveil-native-read-marker-',
        );
        final evidence = Platform.environment['XVEIL_READ_MARK_EVIDENCE_DIR'];
        if (evidence != null) {
          await File('$evidence/runtimes-private.jsonl').writeAsString(
            '${jsonEncode({'root': dir.path, 'pid': pid, 'kind': kind})}\n',
            mode: FileMode.append,
            flush: true,
          );
        }
        final opened = <_HeldMarkerStore>[];
        final storage = HiddenVolumeStorage.async(({
          required password,
          required create,
        }) async {
          final label = utf8.decode(password);
          final store = _HeldMarkerStore(
            (await workerSpaceOpener('${dir.path}/$label.hv')(
              password: password,
              create: false,
            ))!,
            'read:${peer.hex}',
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
        await storage.setReadMarker(peer.hex, initialMarker);
        await storage.close();

        expect(await storage.open(password: 'first'), isTrue);
        await storage.appendMessage(
          Message(
            id: 'old-row',
            conversationId: peer.hex,
            direction: MessageDirection.incoming,
            body: 'first-space-body',
            timestamp: DateTime.fromMillisecondsSinceEpoch(oldIdentityMarker),
            author: peer.hex,
            seq: 1,
          ),
        );
        final old = opened.last..hold = true;
        final work = kind == 'markRead'
            ? storage.markRead(peer.hex)
            : storage.setReadMarker(peer.hex, oldIdentityMarker);
        final outcome = work.then((_) => 'ok', onError: (Object _) => 'error');
        await old.entered.future;
        var reopened = false;
        final opening = storage.open(password: 'next').then((ok) {
          reopened = ok;
          return ok;
        });
        if (Platform.environment['XVEIL_READ_MARK_FORCE_OLD_INTERLEAVING'] ==
            '1') {
          // Negative control only; a fixed implementation must wait at this gate.
          await opening.timeout(const Duration(seconds: 30));
        } else {
          // Opportunity to attempt close, not a timing-based pass criterion.
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        final reopenedBeforeRelease = reopened;
        old.release.complete();
        final result = await outcome;
        expect(await opening, isTrue);
        await storage.close();
        expect(await storage.open(password: 'next'), isTrue);
        final nextMarker = await storage.readMarker(peer.hex);
        final retained = await storage.loadMessageRows(peer.hex);
        final held = {for (final message in retained) message.id: message};
        var exact = 0;
        for (var i = 0; i < rows; i++) {
          final expected = canary(i);
          final actual = held[expected.id];
          if (actual != null &&
              actual.conversationId == expected.conversationId &&
              actual.body == expected.body &&
              actual.status == expected.status &&
              actual.timestamp == expected.timestamp &&
              actual.author == expected.author &&
              actual.seq == expected.seq &&
              actual.orderAuthor == expected.orderAuthor &&
              actual.orderSeq == expected.orderSeq) {
            exact++;
          }
        }
        await storage.close();
        expect(await storage.open(password: 'first'), isTrue);
        final firstMarker = await storage.readMarker(peer.hex);
        final firstRows = await storage.loadMessageRows(peer.hex);
        if (evidence != null) {
          await File('$evidence/$kind-private.json').writeAsString(
            jsonEncode({
              'kind': kind,
              'expectedRows': rows,
              'actualRows': retained.length,
              'uniqueRows': held.length,
              'exactRows': exact,
              'expectedNextMarker': initialMarker,
              'nextMarker': nextMarker,
              'expectedFirstMarker': oldIdentityMarker,
              'firstMarker': firstMarker,
              'firstRows': firstRows.length,
              'coldReopened': true,
              'outcome': result,
              'reopenedBeforeRelease': reopenedBeforeRelease,
              'closedBeforeRelease': old.closeBeforeRelease,
            }),
          );
        }
        expect(retained, hasLength(rows));
        expect(held, hasLength(rows));
        expect(exact, rows);
        expect(nextMarker, initialMarker);
        expect(firstMarker, oldIdentityMarker);
        expect(firstRows.single.body, 'first-space-body');
        expect(result, 'ok');
        expect(reopenedBeforeRelease, isFalse);
        expect(old.closeBeforeRelease, isFalse);
      },
      skip: native == null
          ? 'set XVEIL_HV_DYLIB to a qualified library'
          : false,
    );
  }
}
