@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/file_store.dart' show kMaxStoredFileBytes;
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/state/messaging.dart';
import 'support/timed_native_store.dart';

NodeId _id(int n) => NodeId(Uint8List(32)..fillRange(0, 32, n));

class _LostReply extends TimedNativeStore {
  _LostReply(AsyncKvLogStore inner)
    : super(inner, Stopwatch()..start(), (_) {});
  bool lose = false;
  @override
  Future<int> commit(List<KvLogOp> ops) async {
    final loses =
        lose &&
        ops.whereType<PutOp>().any((o) => o.namespace == Ns.outboxIndex);
    if (loses) lose = false;
    final result = await super.commit(ops);
    if (loses) throw StateError('fixture lost durable enqueue reply');
    return result;
  }
}

class _Link extends LoopbackTransport {
  _Link(this.store) : super(localNodeId: _id(1));
  final Storage store;
  List<OutboxFrame>? first;
  Future<void> Function()? afterFirst;
  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    if (first == null) {
      first = await store.pendingOutboxFrames();
      await afterFirst?.call();
    }
  }
}

void _complete(List<OutboxFrame> frames, String original) {
  expect(frames, isNotEmpty);
  final parts = frames
      .map((f) => parseGroupEntryChunk(WireEnvelope.decode(f.wire).body))
      .toList();
  expect(
    parts.length,
    parts.first.count,
    reason: 'every admitted image must contain ALL transfer parts',
  );
  parts.sort((a, b) => a.index.compareTo(b.index));
  expect(parts.map((p) => p.index), List.generate(parts.length, (i) => i));
  expect(utf8.decode([for (final p in parts) ...p.data]), original);
}

void main() {
  for (final native in [false, true]) {
    for (final initial in [false, true]) {
      for (final mode in [
        'first-send',
        'reply-loss',
        if (!initial) 'maximum',
        if (initial) 'ttl-during-send',
      ]) {
        final lost = mode == 'reply-loss';
        test(
          'complete group admission native=$native initial=$initial mode=$mode',
          () async {
            String? path;
            final memory = FakeKvLogStore();
            if (native) {
              expect(
                ensureHiddenVolumeLoaded(
                  dylibPath: Platform.environment['XVEIL_HV_DYLIB'],
                ),
                isTrue,
              );
              final dir = await Directory.systemTemp.createTemp(
                'xveil-admission-',
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
            late _LostReply backing;
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
              return backing = _LostReply(raw);
            });
            expect(await store.open(password: 'fixture'), isTrue);
            final link = _Link(store);
            final service = MessagingService(link, store);
            addTearDown(() async {
              await service.dispose();
              await link.dispose();
              await store.close();
            });
            final empty = jsonEncode({
              'g': [],
              'private': '',
              'keep': 'retained',
            });
            final body = jsonEncode({
              'g': [],
              'private':
                  'x' *
                  (mode == 'maximum'
                      ? kMaxStoredFileBytes - utf8.encode(empty).length
                      : 29000),
              'keep': 'retained',
            });
            if (mode == 'maximum') {
              expect(utf8.encode(body), hasLength(kMaxStoredFileBytes));
              await expectLater(
                service.sendGroupSnapshot(
                  _id(2),
                  'ab' * 32,
                  '$body ',
                  awaitInitialSend: false,
                ),
                throwsArgumentError,
              );
              expect(await store.pendingOutboxFrames(), isEmpty);
            }
            if (mode == 'ttl-during-send') {
              link.afterFirst = () async {
                // Expiry begins AFTER the first live part, not at admission.
                // Keep this separate from the new admission-validation cases.
                service.groupBindingsOwner = Object();
                service.deviceSnapshotExpiryGroup = () async => 'ab' * 32;
                service.onDeviceSnapshotExpiry = (_, input) async {
                  return input == body ? '{"g":[],"keep":"retained"}' : null;
                };
                await service.sweepAllDisappearing();
              };
            }
            backing.lose = lost;
            final send = service.sendGroupSnapshot(
              _id(2),
              'ab' * 32,
              body,
              awaitInitialSend: initial,
            );
            if (lost) {
              await expectLater(send, throwsStateError);
            } else if (mode == 'ttl-during-send') {
              await send;
              final pending = await store.pendingOutboxFrames();
              expect(
                pending,
                hasLength(1),
                reason:
                    'initial sends must not re-enqueue parts retired by expiry',
              );
              expect(
                WireEnvelope.decode(pending.single.wire).body,
                '{"g":[],"keep":"retained"}',
              );
              return;
            } else {
              await send;
              // Queue-only work may start after the sender's durable result.
              await pumpEventQueue();
              expect(link.first, isNotNull);
              _complete(link.first!, body);
            }
            _complete(await store.pendingOutboxFrames(), body);
            await service.dispose();
            await store.close();
            expect(await store.open(password: 'fixture'), isTrue);
            _complete(await store.pendingOutboxFrames(), body);
            // Complete recovery bytes let the existing TTL rewrite preserve
            // unrelated state even after an uncertain admission and cold reopen.
            final next = MessagingService(link, store);
            addTearDown(next.dispose);
            next.groupBindingsOwner = Object();
            next.deviceSnapshotExpiryGroup = () async => 'ab' * 32;
            next.onDeviceSnapshotExpiry = (_, input) async {
              expect(input, body);
              return '{"g":[],"keep":"retained"}';
            };
            await next.sweepAllDisappearing();
            final clean = await store.pendingOutboxFrames();
            expect(clean, hasLength(1));
            expect(
              WireEnvelope.decode(clean.single.wire).body,
              '{"g":[],"keep":"retained"}',
            );
          },
          skip:
              native && (Platform.environment['XVEIL_HV_DYLIB'] ?? '').isEmpty,
        );
      }
    }
  }
}
