@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/storage.dart';
import 'support/timed_native_store.dart';

class _Faults {
  bool hold = false, refuse = false, lost = false;
  bool stageBefore = false, stageAfter = false;
  final entered = Completer<void>(), release = Completer<void>();
  int commits = 0;
}

class _Backing extends TimedNativeStore {
  _Backing(AsyncKvLogStore inner, this.faults)
    : super(inner, Stopwatch()..start(), (_) {});
  final _Faults faults;
  @override
  Future<int> commit(List<KvLogOp> ops) async {
    if (ops.whereType<AppendLogOp>().any((o) => o.namespace == Ns.outbox) &&
        !ops.whereType<PutOp>().any((o) => o.namespace == Ns.outboxIndex)) {
      if (faults.stageBefore) {
        faults.stageBefore = false;
        throw StateError('fixture stage refused');
      }
      final result = await super.commit(ops);
      if (faults.stageAfter) {
        faults.stageAfter = false;
        throw StateError('fixture stage reply lost');
      }
      return result;
    }
    if (!ops.whereType<PutOp>().any((o) => o.namespace == Ns.outboxIndex)) {
      return super.commit(ops);
    }
    faults.commits++;
    if (faults.hold) {
      faults.hold = false;
      faults.entered.complete();
      await faults.release.future;
    }
    if (faults.refuse) {
      faults.refuse = false;
      throw StateError('fixture refused transfer commit');
    }
    final result = await super.commit(ops);
    if (faults.lost) {
      faults.lost = false;
      throw StateError('fixture lost transfer commit reply');
    }
    return result;
  }
}

void main() {
  for (final native in [false, true]) {
    for (final mode in [
      'refuse',
      'lost',
      'conflict',
      'ownership-close',
      'stage-before',
      'stage-after',
      'publish-lost',
    ]) {
      test(
        'outbox transfer $mode native=$native',
        () async {
          final faults = _Faults();
          final memory = FakeKvLogStore();
          String? path;
          if (native) {
            expect(
              ensureHiddenVolumeLoaded(
                dylibPath: Platform.environment['XVEIL_HV_DYLIB'],
              ),
              isTrue,
            );
            final dir = await Directory.systemTemp.createTemp(
              'xveil-transfer-port-',
            );
            addTearDown(() => dir.delete(recursive: true));
            path = '${dir.path}/store.hv';
            HvKvLogStore(
              hv.HvSpace.create(
                path: path,
                password: Uint8List.fromList(utf8.encode('fixture')),
                argon: hv.ArgonPreset.light,
              ),
            ).close();
          }
          late AsyncKvLogStore rawStore;
          final store = HiddenVolumeStorage.async(({
            required password,
            required create,
          }) async {
            final raw = native
                ? (await workerSpaceOpener(path!)(
                    password: password,
                    create: false,
                  ))!
                : SyncWrappedAsyncKvLogStore(memory);
            rawStore = raw;
            return _Backing(raw, faults);
          });
          addTearDown(() async {
            if (!faults.release.isCompleted) faults.release.complete();
            await store.close();
          });
          expect(await store.open(password: 'fixture'), isTrue);
          await store.enqueueOutboxFrame(
            'unrelated',
            'other',
            Uint8List.fromList([33]),
          );
          final staged = mode.startsWith('stage-') || mode == 'publish-lost';
          final count = staged ? 250 : 17;
          Uint8List wire(int i) => staged
              ? (Uint8List(5000)
                  ..fillRange(0, 5000, 22)
                  ..[1] = i)
              : Uint8List.fromList([22, i]);
          final frames = [
            for (var i = 0; i < count; i++)
              OutboxFrame(
                frameId: 'part-$i',
                peerHex: 'peer',
                wire: wire(i),
                enqueuedAtMs: 123456,
              ),
          ];
          faults.commits = 0;
          if (mode == 'conflict') {
            await store.enqueueOutboxFrame(
              'part-0',
              'peer',
              Uint8List.fromList([99]),
            );
            faults.commits = 0;
            await expectLater(
              store.enqueueOutboxTransfer(frames),
              throwsStateError,
            );
            expect(faults.commits, 0);
            expect(
              (await store.pendingOutboxFrames()).map((f) => f.frameId),
              unorderedEquals(['part-0', 'unrelated']),
            );
            return;
          }
          if (mode == 'ownership-close') {
            faults.hold = true;
            final admitted = store.enqueueOutboxTransfer(frames);
            await faults.entered.future;
            frames.first.wire[0] = 99;
            frames.clear();
            var closed = false;
            final closing = store.close().then((_) => closed = true);
            await Future<void>(() {});
            expect(closed, isFalse);
            expect(
              () => store.enqueueOutboxTransfer([
                OutboxFrame(
                  frameId: 'late',
                  peerHex: 'peer',
                  wire: Uint8List(1),
                ),
              ]),
              throwsStateError,
            );
            faults.release.complete();
            await admitted;
            await closing;
          } else {
            faults.refuse = mode == 'refuse';
            faults.lost = mode == 'lost' || mode == 'publish-lost';
            faults.stageBefore = mode == 'stage-before';
            faults.stageAfter = mode == 'stage-after';
            await expectLater(
              store.enqueueOutboxTransfer(frames),
              throwsStateError,
            );
            expect(faults.commits, mode.startsWith('stage-') ? 0 : 1);
            if (mode.startsWith('stage-')) {
              expect(await rawStore.count(Ns.outboxIndex), 1);
              expect(
                await rawStore.count(Ns.outbox),
                mode == 'stage-after' ? greaterThan(1) : 1,
              );
            }
            expect(
              (await store.pendingOutboxFrames()).length,
              (mode == 'lost' || mode == 'publish-lost') ? count + 1 : 1,
            );
            if (staged) {
              await store.finishOutboxCleanup();
              expect(
                await rawStore.count(Ns.outbox),
                mode == 'publish-lost' ? greaterThan(count) : 1,
              );
              expect(
                await store.settingsKeys(),
                isNot(contains('outbox.replacement_scrub_pending')),
              );
            }
            await store.enqueueOutboxTransfer(frames);
          }
          await store.close();
          expect(await store.open(password: 'fixture'), isTrue);
          final pending = await store.pendingOutboxFrames();
          expect(pending, hasLength(count + 1));
          for (var i = 0; i < count; i++) {
            final f = pending.singleWhere((f) => f.frameId == 'part-$i');
            expect(f.wire, wire(i));
            expect(f.enqueuedAtMs, 123456);
            expect(await store.containsOutboxFrame(f), isTrue);
            expect(
              await store.containsOutboxFrame(
                OutboxFrame(frameId: f.frameId, peerHex: 'other', wire: f.wire),
              ),
              isFalse,
            );
            expect(
              await store.containsOutboxFrame(
                OutboxFrame(
                  frameId: f.frameId,
                  peerHex: f.peerHex,
                  wire: Uint8List.fromList([99]),
                ),
              ),
              isFalse,
            );
          }
          expect(
            (await store.pendingOutboxFrames())
                .singleWhere((f) => f.frameId == 'unrelated')
                .wire,
            [33],
          );
        },
        skip: native && (Platform.environment['XVEIL_HV_DYLIB'] ?? '').isEmpty,
      );
    }
  }
}
