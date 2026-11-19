@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/kv_log_store.dart';

import '../support/timed_native_store.dart';

class _NativeAckStore extends TimedNativeStore {
  _NativeAckStore(AsyncKvLogStore inner)
    : super(inner, Stopwatch()..start(), (_) {});
  int commits = 0, indexDeletes = 0;
  bool refuse = false, uncertain = false, hold = false;
  final entered = Completer<void>(), release = Completer<void>();

  @override
  Future<int> commit(List<KvLogOp> ops) async {
    final deletes = ops
        .whereType<DeleteOp>()
        .where((op) => op.namespace == Ns.outboxIndex)
        .length;
    if (deletes == 0) return super.commit(ops);
    commits++;
    indexDeletes += deletes;
    if (hold) {
      hold = false;
      entered.complete();
      await release.future;
    }
    if (refuse) {
      refuse = false;
      throw StateError('injected native pre-commit refusal');
    }
    final sequence = await super.commit(ops);
    if (uncertain) {
      uncertain = false;
      throw StateError('injected lost native reply');
    }
    return sequence;
  }
}

void main() {
  final nativePath = Platform.environment['XVEIL_HV_DYLIB'];
  final enabled = nativePath?.isNotEmpty ?? false;
  late Directory directory;
  late HiddenVolumeStorage storage;
  late _NativeAckStore backing;
  final password = Uint8List.fromList(utf8.encode('native-ack-fixture'));

  setUp(() async {
    if (!enabled) return;
    expect(ensureHiddenVolumeLoaded(dylibPath: nativePath), isTrue);
    directory = await Directory.systemTemp.createTemp('xveil-native-ack-');
    final path = '${directory.path}/store.hv';
    HvKvLogStore(
      hv.HvSpace.create(
        path: path,
        password: password,
        argon: hv.ArgonPreset.light,
      ),
    ).close();
    backing = _NativeAckStore(
      (await workerSpaceOpener(path)(password: password, create: false))!,
    );
    storage = HiddenVolumeStorage.async(
      ({required password, required create}) async => backing,
    );
    expect(await storage.open(password: 'fixture'), isTrue);
  });
  tearDown(() async {
    if (!enabled) return;
    if (!backing.release.isCompleted) backing.release.complete();
    await storage.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  Future<void> put(String id, {String peer = 'peer'}) =>
      storage.enqueueOutboxFrame(id, peer, Uint8List.fromList(utf8.encode(id)));
  Future<List<String>> pending(HiddenVolumeStorage target) async =>
      (await target.pendingOutboxFrames()).map((row) => row.frameId).toList();

  Future<HiddenVolumeStorage> reopen() async {
    await storage.close();
    final next = HiddenVolumeStorage.async(
      workerSpaceOpener('${directory.path}/store.hv'),
    );
    expect(await next.open(password: 'native-ack-fixture'), isTrue);
    storage = next;
    return next;
  }

  test(
    'native close drains admitted outbox ACKs before releasing the worker',
    () async {
      await put('first');
      await put('queued');
      await put('keep', peer: 'other');

      backing.hold = true;
      final first = storage.ackOutboxFrame('first', fromPeerHex: 'peer');
      await backing.entered.future;
      final next = storage.ackOutboxFrames([
        'queued',
        'keep',
      ], fromPeerHex: 'peer');
      final closing = storage.close();
      final accepted = Future.wait([
        first,
        next.then((retired) => expect(retired, ['queued'])),
      ]);
      await pumpEventQueue();
      final openBeforeCommit = storage.isOpen;
      backing.release.complete();
      await accepted;
      await closing;

      expect(openBeforeCommit, isTrue);
      expect(backing.commits, 2);
      expect(await pending(await reopen()), ['keep']);
    },
    skip: enabled ? false : 'set XVEIL_HV_DYLIB to the qualified library',
  );

  test(
    'native concurrent ACK burst retains only unrelated rows across reopen',
    () async {
      for (var i = 0; i < 64; i++) {
        await put('frame-$i');
      }
      await put('keep', peer: 'other');
      final clock = Stopwatch()..start();
      await Future.wait([
        for (var i = 0; i < 64; i++)
          storage.ackOutboxFrame('frame-$i', fromPeerHex: 'peer'),
      ]);
      clock.stop();
      expect(backing.indexDeletes, 64);
      // Both baseline and candidate execute this benchmark unchanged. The
      // outer A/B/A driver verifies exact commit counts against source hashes.
      expect(backing.commits, inInclusiveRange(1, 64));
      expect(await pending(storage), ['keep']);
      expect(await pending(await reopen()), ['keep']);
      final result = {
        'schema': 'xveil-native-ack-burst/1',
        'frames': 64,
        'retirementCommits': backing.commits,
        'indexDeletes': backing.indexDeletes,
        'retirementUs': clock.elapsedMicroseconds,
        'unrelatedSurvivedReopen': true,
      };
      final resultPath = Platform.environment['XVEIL_NATIVE_ACK_RESULT'];
      if (resultPath != null) {
        await File(resultPath).writeAsString(jsonEncode(result));
      }
    },
    skip: enabled ? false : 'set XVEIL_HV_DYLIB to the qualified library',
  );

  for (final uncertain in [false, true]) {
    test(
      'native coalesced ACK recovers after failure ($uncertain)',
      () async {
        await put('first');
        await put('second');
        await put('keep', peer: 'other');
        backing.uncertain = uncertain;
        backing.refuse = !uncertain;
        final first = storage.ackOutboxFrame('first', fromPeerHex: 'peer');
        final second = storage.ackOutboxFrame('second', fromPeerHex: 'peer');
        await Future.wait([
          expectLater(first, throwsStateError),
          expectLater(second, throwsStateError),
        ]);
        expect(backing.commits, 1);
        final expected = uncertain ? ['keep'] : ['first', 'second', 'keep'];
        expect(await pending(storage), unorderedEquals(expected));
        expect(await pending(await reopen()), unorderedEquals(expected));
      },
      skip: enabled ? false : 'set XVEIL_HV_DYLIB to the qualified library',
    );
  }
}
