import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';

class _Store extends FakeKvLogStore {
  int closes = 0;
  @override
  void close() {
    closes++;
    super.close();
  }
}

void main() {
  test(
    'normal close remains reopenable but retired facades reject both openers',
    () async {
      var opens = 0, keyOpens = 0;
      final storage = HiddenVolumeStorage(
        ({required password, required create}) {
          opens++;
          return _Store();
        },
        keysOpener: (_) {
          keyOpens++;
          return _Store();
        },
      );
      addTearDown(storage.close);
      expect(await storage.open(password: 'synthetic'), isTrue);
      await storage.close();
      expect(await storage.open(password: 'synthetic'), isTrue);
      await storage.close();
      storage.retireOpening();
      await expectLater(
        storage.open(password: 'stale', createIfMissing: true),
        throwsStateError,
      );
      await expectLater(storage.openWithKeys(Uint8List(64)), throwsStateError);
      expect(opens, 2);
      expect(keyOpens, 0);
    },
  );

  for (final keys in [false, true]) {
    test(
      'retirement owns a late ${keys ? 'keys' : 'password'} opener and closes its actual result',
      () async {
        final entered = Completer<void>(), release = Completer<void>();
        final raw = _Store();
        Future<AsyncKvLogStore?> opening() async {
          entered.complete();
          await release.future;
          return SyncWrappedAsyncKvLogStore(raw);
        }

        final storage = HiddenVolumeStorage.async(
          ({required password, required create}) => opening(),
          keysOpener: (_) => opening(),
        );
        addTearDown(storage.close);
        final result = keys
            ? storage.openWithKeys(Uint8List(64))
            : storage.open(password: 'synthetic');
        final failed = expectLater(result, throwsStateError);
        await entered.future;
        storage.retireOpening();
        var settled = false;
        final closing = storage.settleOpening().then((_) => settled = true);
        await Future<void>(() {});
        expect(settled, isFalse);
        release.complete();
        await failed;
        await closing;
        expect(raw.closes, 1);
        expect(storage.isOpen, isFalse);
      },
    );
  }
}
