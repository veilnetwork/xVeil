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
import 'package:xveil/domain/chat.dart';

class _Store extends HvKvLogStore {
  _Store(super.space);
  bool refuseScrub = false;
  bool refuseTombstone = false;
  int completedScrubs = 0;
  @override
  int commit(List<KvLogOp> ops) {
    if (refuseTombstone &&
        ops.whereType<AppendLogOp>().any((op) {
          final row = jsonDecode(utf8.decode(op.payload)) as Map;
          return row['op'] == 'del';
        })) {
      throw StateError('fixture tombstone refusal');
    }
    return super.commit(ops);
  }

  @override
  void scrub() {
    if (refuseScrub) throw StateError('fixture scrub refusal');
    super.scrub();
    completedScrubs++;
  }
}

void main() {
  final enabled = Platform.environment['XVEIL_HV_DYLIB']?.isNotEmpty ?? false;
  final available = enabled && ensureHiddenVolumeLoaded();
  test(
    'the worker completes a prior interrupted remote clear on open',
    () async {
      final dir = Directory.systemTemp.createTempSync('xveil-peer-clear-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/fixture.hv';
      const password = 'fixture-password';
      final raw = _Store(
        hv.HvSpace.create(
          path: path,
          password: Uint8List.fromList(utf8.encode(password)),
          argon: hv.ArgonPreset.min,
        ),
      );
      final first = HiddenVolumeStorage.fromStore(raw);
      addTearDown(first.close);
      final peer = NodeId.fromHex('39' * 32);
      final self = NodeId.fromHex('63' * 32);
      for (final seq in [1, 2]) {
        await first.appendMessage(
          Message(
            id: 'post-$seq',
            conversationId: peer.hex,
            direction: MessageDirection.incoming,
            body: 'fixture body $seq',
            timestamp: DateTime.fromMillisecondsSinceEpoch(seq * 1000),
            author: peer.hex,
            seq: seq,
          ),
        );
      }
      await first.putSetting('msg.translation.v1:en:post-1', 'fixture removed');
      await first.putSetting('msg.translation.v1:en:post-2', 'fixture kept');
      raw.refuseTombstone = true;
      await expectLater(
        first.applyRemoteClear(peer, peer.hex, 3, {
          peer.hex: 1,
        }, selfHex: self.hex),
        throwsStateError,
      );
      await first.close();

      final storage = HiddenVolumeStorage.async(workerSpaceOpener(path));
      addTearDown(storage.close);
      expect(await storage.open(password: password), isTrue);
      expect(await storage.isMessageDeleted(peer.hex, 'post-1'), isTrue);
      expect((await storage.loadMessages(peer.hex)).single.id, 'post-2');
      expect(await storage.getSetting('msg.translation.v1:en:post-1'), isNull);
      expect(
        await storage.getSetting('msg.translation.v1:en:post-2'),
        'fixture kept',
      );
      await storage.close();
      expect(await storage.open(password: password), isTrue);
      expect((await storage.loadMessages(peer.hex)).single.id, 'post-2');
    },
    skip: available ? null : 'set XVEIL_HV_DYLIB to a verified current library',
  );

  for (final mode in ['password', 'keys', 'async-view']) {
    test(
      'native unfinished delete recovers through $mode without repeated vacuum',
      () async {
        final dir = Directory.systemTemp.createTempSync(
          'xveil-scrub-recovery-',
        );
        addTearDown(() => dir.deleteSync(recursive: true));
        final path = '${dir.path}/fixture.hv';
        final password = Uint8List.fromList(utf8.encode('fixture-password'));
        final firstRaw = _Store(
          hv.HvSpace.create(
            path: path,
            password: password,
            argon: hv.ArgonPreset.min,
          ),
        );
        var first = HiddenVolumeStorage.fromStore(firstRaw);
        addTearDown(() async {
          if (first.isOpen) await first.close();
        });
        const peer = 'fixture-peer';
        for (var i = 0; i < 16; i++) {
          await first.appendMessage(
            Message(
              id: 'm$i',
              conversationId: peer,
              direction: MessageDirection.incoming,
              body: 'fixture body $i',
              timestamp: DateTime.fromMillisecondsSinceEpoch(1000 + i),
            ),
          );
        }
        await first.editMessage(peer, 'm1', 'fixture edited body');
        final keys = firstRaw.exportKeys();
        firstRaw.refuseScrub = true;
        await first.deleteMessage(peer, 'm1');
        await expectLater(first.scrubDeleted(), throwsStateError);
        await first.close();

        final recoveredRaw = _Store(
          mode == 'keys'
              ? hv.HvSpace.openWithKeys(path: path, keys: keys)
              : hv.HvSpace.open(path: path, password: password),
        );
        final recovered = mode == 'async-view'
            ? HiddenVolumeStorage.fromAsyncStore(
                SyncWrappedAsyncKvLogStore(recoveredRaw),
              )
            : HiddenVolumeStorage(
                ({required Uint8List password, required bool create}) =>
                    recoveredRaw,
                keysOpener: (_) => recoveredRaw,
              );
        addTearDown(() async {
          if (recovered.isOpen) await recovered.close();
        });
        if (mode == 'password') {
          await recovered.open(password: 'fixture-password');
        }
        if (mode == 'keys') await recovered.openWithKeys(keys);
        expect(await recovered.isMessageDeleted(peer, 'm1'), isTrue);
        expect(recoveredRaw.completedScrubs, 1);
        expect(await recovered.loadMessageHistory(peer, 'm1'), isEmpty);
        expect(await recovered.loadMessages(peer), hasLength(15));
        // Marker churn must stay within the native transaction/namespace limits.
        for (var i = 2; i < 16; i++) {
          await recovered.deleteMessage(peer, 'm$i');
          await recovered.scrubDeleted();
        }
        await recovered.close();
        final cleanRaw = _Store(
          hv.HvSpace.open(path: path, password: password),
        );
        final clean = HiddenVolumeStorage.fromStore(cleanRaw);
        addTearDown(clean.close);
        expect((await clean.loadMessages(peer)).single.id, 'm0');
        expect(cleanRaw.completedScrubs, 0);
      },
      skip: available
          ? null
          : 'set XVEIL_HV_DYLIB to a verified current library',
    );
  }
}
