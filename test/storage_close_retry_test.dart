import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';

class _HeldCloseStore extends SyncWrappedAsyncKvLogStore {
  _HeldCloseStore() : super(FakeKvLogStore());
  final entered = Completer<void>();
  final release = Completer<void>();
  int closes = 0;
  @override
  Future<void> close() async {
    if (++closes == 1) {
      entered.complete();
      await release.future;
      throw StateError('synthetic close refusal');
    }
    await super.close();
  }
}

void main() {
  test(
    'failed close blocks I/O and retains the exact owner for retry',
    () async {
      final raw = FakeKvLogStore();
      var closes = 0;
      var refuse = true;
      raw.onClose = () {
        closes++;
        if (refuse) throw StateError('synthetic close refusal');
      };
      final storage = HiddenVolumeStorage(
        ({required password, required create}) => raw,
      );
      expect(await storage.open(password: 'fixture'), isTrue);
      await storage.putSetting('scope', 'old');
      await expectLater(storage.close(), throwsA(isA<StateError>()));
      expect(storage.isOpen, isFalse);
      await expectLater(
        storage.getSetting('scope'),
        throwsA(isA<StateError>()),
      );
      await expectLater(storage.close(), throwsA(isA<StateError>()));
      expect(closes, 2);
      refuse = false;
      await storage.close();
      expect(closes, 3);
      await storage.close();
      expect(closes, 3);
    },
  );

  for (final byKeys in [false, true]) {
    test(
      'reopen ${byKeys ? 'by keys' : 'by password'} waits for retired ownership',
      () async {
        final old = FakeKvLogStore();
        final next = FakeKvLogStore();
        var refuses = 2;
        var closes = 0;
        var opens = 0;
        old.onClose = () {
          closes++;
          if (refuses-- > 0) throw StateError('synthetic close refusal');
        };
        final storage = HiddenVolumeStorage(
          ({required password, required create}) => ++opens == 1 ? old : next,
          keysOpener: (keys) {
            opens++;
            return next;
          },
        );
        expect(await storage.open(password: 'fixture'), isTrue);
        await storage.putSetting('scope', 'old');
        await expectLater(storage.close(), throwsA(isA<StateError>()));
        Future<bool> reopen() => byKeys
            ? storage.openWithKeys(Uint8List(64))
            : storage.open(password: 'other-fixture');
        await expectLater(reopen(), throwsA(isA<StateError>()));
        expect(opens, 1, reason: 'a replacement opened before release');
        expect(closes, 2);
        expect(await reopen(), isTrue);
        expect(closes, 3);
        expect(opens, 2);
        expect(await storage.getSetting('scope'), isNull);
        await storage.putSetting('scope', 'new');
        expect(await storage.getSetting('scope'), 'new');
        await storage.close();
      },
    );
  }

  test(
    'concurrent callers observe one failed close and can retry it',
    () async {
      final raw = _HeldCloseStore();
      final storage = HiddenVolumeStorage.fromAsyncStore(raw);
      final first = expectLater(storage.close(), throwsA(isA<StateError>()));
      await raw.entered.future;
      final second = expectLater(storage.close(), throwsA(isA<StateError>()));
      raw.release.complete();
      await Future.wait([first, second]);
      expect(raw.closes, 1);
      expect(storage.isOpen, isFalse);
      await storage.close();
      expect(raw.closes, 2);
    },
  );
}
