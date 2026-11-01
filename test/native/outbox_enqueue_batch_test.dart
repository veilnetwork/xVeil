@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/kv_log_store.dart';

import '../support/timed_native_store.dart';

class _NativeEnqueueStore extends TimedNativeStore {
  _NativeEnqueueStore(AsyncKvLogStore inner)
    : super(inner, Stopwatch()..start(), (_) {});
  final commitFrames = <int>[];
  bool refuse = false, uncertain = false, hold = false;
  final entered = Completer<void>(), release = Completer<void>();

  @override
  Future<int> commit(List<KvLogOp> ops) async {
    final count = ops
        .whereType<PutOp>()
        .where((op) => op.namespace == Ns.outboxIndex)
        .length;
    if (count == 0) return super.commit(ops);
    commitFrames.add(count);
    expect(
      ops.whereType<AppendLogOp>().every((op) => op.payload.length <= 1800),
      isTrue,
    );
    if (hold) {
      hold = false;
      entered.complete();
      await release.future;
    }
    if (refuse) {
      refuse = false;
      throw StateError('native enqueue refusal before commit');
    }
    final sequence = await super.commit(ops);
    if (uncertain) {
      uncertain = false;
      throw StateError('native enqueue lost reply after commit');
    }
    return sequence;
  }
}

void main() {
  final nativePath = Platform.environment['XVEIL_HV_DYLIB'];
  final enabled = nativePath?.isNotEmpty ?? false;
  final skip = enabled ? false : 'set XVEIL_HV_DYLIB to the qualified library';
  late Directory directory;
  late HiddenVolumeStorage storage;
  late _NativeEnqueueStore backing;
  const secret = 'native-enqueue-fixture';
  final password = Uint8List.fromList(utf8.encode(secret));
  final random = Random(1408);
  final wire = Uint8List.fromList(
    List.generate(2048, (_) => random.nextInt(256)),
  );

  setUp(() async {
    if (!enabled) return;
    expect(ensureHiddenVolumeLoaded(dylibPath: nativePath), isTrue);
    directory = await Directory.systemTemp.createTemp('xveil-native-enqueues-');
    final path = '${directory.path}/store.hv';
    HvKvLogStore(
      hv.HvSpace.create(
        path: path,
        password: password,
        argon: hv.ArgonPreset.light,
      ),
    ).close();
    backing = _NativeEnqueueStore(
      (await workerSpaceOpener(path)(password: password, create: false))!,
    );
    storage = HiddenVolumeStorage.async(
      ({required password, required create}) async => backing,
    );
    expect(await storage.open(password: secret), isTrue);
  });
  tearDown(() async {
    if (!enabled) return;
    if (!backing.release.isCompleted) backing.release.complete();
    await storage.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  Future<void> put(String id, {Uint8List? bytes}) =>
      storage.enqueueOutboxFrame(id, 'peer', bytes ?? wire);
  Future<List<String>> ids() async =>
      (await storage.pendingOutboxFrames()).map((f) => f.frameId).toList();
  Future<void> reopen() async {
    await storage.close();
    storage = HiddenVolumeStorage.async(
      workerSpaceOpener('${directory.path}/store.hv'),
    );
    expect(await storage.open(password: secret), isTrue);
  }

  test(
    'native enqueue burst preserves every wire and index across reopen',
    () async {
      final watch = Stopwatch()..start();
      await Future.wait([for (var i = 0; i < 64; i++) put('frame-$i')]);
      watch.stop();
      expect(backing.commitFrames.fold<int>(0, (a, b) => a + b), 64);
      final expected = List.generate(64, (i) => 'frame-$i');
      expect(await ids(), unorderedEquals(expected));
      await reopen();
      expect(await ids(), unorderedEquals(expected));
      for (final frame in await storage.pendingOutboxFrames()) {
        expect(frame.peerHex, 'peer');
        expect(frame.wire, wire);
        expect(frame.enqueuedAtMs, isNotNull);
      }
      final result = {
        'schema': 'xveil-native-outbox-enqueue/1',
        'frames': 64,
        'dataCommits': backing.commitFrames.length,
        'framesPerCommit': backing.commitFrames,
        'enqueueUs': watch.elapsedMicroseconds,
        'reopenedIdsPeersWiresMatchAndTimestampsPresent': true,
      };
      final path = Platform.environment['XVEIL_NATIVE_ENQUEUE_RESULT'];
      if (path != null) await File(path).writeAsString(jsonEncode(result));
    },
    skip: skip,
  );

  for (final batched in [false, true]) {
    for (final uncertain in [false, true]) {
      test(
        'native enqueue reloads all-or-none ($batched/$uncertain)',
        () async {
          await put('keep');
          backing.refuse = !uncertain;
          backing.uncertain = uncertain;
          final first = put('first');
          final second = batched ? put('second') : null;
          await Future.wait([
            expectLater(first, throwsStateError),
            if (second != null) expectLater(second, throwsStateError),
          ]);
          final expected = [
            'keep',
            if (uncertain) 'first',
            if (uncertain && batched) 'second',
          ];
          expect(await ids(), unorderedEquals(expected));
          await reopen();
          expect(await ids(), unorderedEquals(expected));
        },
        skip: skip,
      );
    }
  }

  for (final erase in [false, true]) {
    test(
      'native accepted enqueue batches drain before maintenance ($erase)',
      () async {
        backing.hold = true;
        final first = put('first');
        await backing.entered.future;
        final second = put('second'), third = put('third');
        final maintenance = erase ? storage.eraseSpace() : storage.close();
        final late = expectLater(put('late'), throwsStateError);
        backing.release.complete();
        await Future.wait([first, second, third, maintenance, late]);
        await reopen();
        expect(
          await ids(),
          erase ? isEmpty : unorderedEquals(['first', 'second', 'third']),
        );
      },
      skip: skip,
    );
  }

  test('native encoded byte bound separates large enqueues', () async {
    final bytes = Uint8List.fromList(
      List.generate(20000, (_) => random.nextInt(256)),
    );
    await Future.wait([
      put('first', bytes: bytes),
      put('second', bytes: bytes),
    ]);
    expect(backing.commitFrames, [1, 1]);
    await reopen();
    expect(await ids(), unorderedEquals(['first', 'second']));
    for (final frame in await storage.pendingOutboxFrames()) {
      expect(frame.wire, bytes);
    }
  }, skip: skip);
}
