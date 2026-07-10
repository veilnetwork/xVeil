import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/providers.dart';

import 'support/fake_hv_container.dart';

/// Regression tests for the "container won't unlock with the correct password
/// until an app restart" trap (ROADMAP bug #9): a storage handle leaked past a
/// failed path used to hold the container's exclusive flock forever, so every
/// retry failed Busy. These pin the self-healing behaviour of open()/close().
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('open() closes a stale leaked handle first (retry self-heals)', () async {
    final container = FakeHvContainer();
    final storage = container.storage();

    expect(await storage.open(password: 'pw', createIfMissing: true), isTrue);
    expect(storage.isOpen, isTrue);

    // A second open on the SAME handle models the leak: something failed after
    // open and nobody closed. The fake container throws Busy while its flock is
    // held — before the fix this threw and kept throwing on every retry.
    expect(await storage.open(password: 'pw'), isTrue);
    expect(storage.isOpen, isTrue);

    // And the adopted store is live, not the half-closed stale one.
    await storage.putSetting('k', 'v');
    expect(await storage.getSetting('k'), 'v');
  });

  test('openWithKeys() closes a stale leaked handle first', () async {
    final container = FakeHvContainer();
    final storage = container.storage();
    expect(await storage.open(password: 'pw', createIfMissing: true), isTrue);
    final keys = await storage.exportSpaceKeys();

    // Leak: reopen by keys while the password-opened handle is still held.
    expect(await storage.openWithKeys(keys), isTrue);
    expect(storage.isOpen, isTrue);
  });

  test('close() clears the handle even when the native close throws', () async {
    final throwing = FakeKvLogStore();
    throwing.onClose = () => throw StateError('native close fault');
    final storage = HiddenVolumeStorage(
      ({required Uint8List password, required bool create}) => throwing,
    );
    expect(await storage.open(password: 'pw'), isTrue);

    // Must not throw, and must not leave a stale handle that would wedge the
    // next open behind the flock.
    await storage.close();
    expect(storage.isOpen, isFalse);
  });

  test('concurrent unlock() calls run the container open only once', () async {
    var opens = 0;
    final store = FakeKvLogStore();
    final storage = HiddenVolumeStorage.async((
        {required Uint8List password, required bool create}) async {
      opens++;
      // Model the slow Argon2 KDF so the second unlock arrives mid-open.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return SyncWrappedAsyncKvLogStore(store);
    });
    final c = ProviderContainer(
      overrides: [singleSpaceStorageProvider.overrideWithValue(storage)],
    );
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);

    // Double-submit: UI + debug hook racing. The latecomer must be dropped —
    // two live opens of one container fail Busy and interleave state writes.
    final a = ctrl.unlock('pw');
    final b = ctrl.unlock('pw');
    await Future.wait([a, b]);

    expect(opens, 1);
    expect(c.read(appControllerProvider).phase, AppPhase.ready);
  });
}
