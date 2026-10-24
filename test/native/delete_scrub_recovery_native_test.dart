import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/domain/chat.dart';

class _Store extends HvKvLogStore {
  _Store(super.space);
  bool refuseScrub = false;
  int completedScrubs = 0;
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
