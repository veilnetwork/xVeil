import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/domain/screen_lock.dart';
import 'package:xveil/state/screen_lock_controller.dart';
import 'package:xveil/state/providers.dart';

/// The screen-lock timeout decides whether the app covers itself in the
/// switcher and how soon it asks for a password again.
///
/// Several loads of it run at once by design: `build` starts one while the
/// container is still shut, `reloadTimeout` starts another the moment it
/// opens, and an all-online switch starts a third. Nothing ordered them, so
/// the one that finished LAST won — and a late `off` read out of A's storage
/// could replace B's `immediately`, leaving B's screen uncovered (report17
/// XV17-M4).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<HiddenVolumeStorage> opened(String password) async {
    final backing = FakeKvLogStore();
    final storage = HiddenVolumeStorage(
      ({required Uint8List password, required bool create}) => backing,
    );
    await storage.open(password: password, createIfMissing: true);
    return storage;
  }

  test('a load asked of A does not weaken B', () async {
    final a = _GatedStorage(await opened('a'));
    final b = await opened('b');
    await a.inner.putSetting(
      kScreenLockTimeoutSettingKey,
      ScreenLockTimeout.off.name,
    );
    await b.putSetting(
      kScreenLockTimeoutSettingKey,
      ScreenLockTimeout.immediately.name,
    );
    Storage active = a;

    final container = ProviderContainer(
      overrides: [storageProvider.overrideWith((ref) => active)],
    );
    addTearDown(container.dispose);

    container.read(screenLockProvider);
    await Future<void>.delayed(Duration.zero);

    // The identity moves while A's read is still parked.
    active = b;
    container.invalidate(storageProvider);
    container.read(screenLockProvider);
    await Future<void>.delayed(Duration.zero);

    // A's read comes back now, after the switch, with A's answer.
    a.release(0);
    await Future<void>.delayed(Duration.zero);

    expect(
      container.read(screenLockProvider).timeout,
      ScreenLockTimeout.immediately,
      reason:
          "A's 'off' landed after the switch and replaced B's "
          "'immediately' — B's screen is no longer covered in the switcher",
    );
  });

  test('and the later of two loads of ONE identity wins', () async {
    // `build` reads a shut container and `reloadTimeout` reads it once it
    // opens. The second is the one that can answer, so it must not be
    // overwritten by the first arriving late — and "late" is the ordinary
    // case here, because the first read is the one that had to wait.
    final storage = _GatedStorage(await opened('a'));
    await storage.inner.putSetting(
      kScreenLockTimeoutSettingKey,
      ScreenLockTimeout.off.name,
    );

    final container = ProviderContainer(
      overrides: [storageProvider.overrideWith((ref) => storage)],
    );
    addTearDown(container.dispose);

    container.read(screenLockProvider);
    await Future<void>.delayed(Duration.zero);
    expect(storage.parked, 1, reason: 'the first read did not park');

    // What the container answers once it is open.
    await storage.inner.putSetting(
      kScreenLockTimeoutSettingKey,
      ScreenLockTimeout.immediately.name,
    );
    final reload = container.read(screenLockProvider.notifier).reloadTimeout();
    await Future<void>.delayed(Duration.zero);
    expect(storage.parked, 2, reason: 'the second read did not park');

    // The second lands first, then the first arrives with its stale answer.
    storage.release(1);
    await reload;
    storage.release(0);
    await Future<void>.delayed(Duration.zero);

    expect(
      container.read(screenLockProvider).timeout,
      ScreenLockTimeout.immediately,
      reason:
          'the first, stale read landed on top of the second, so the '
          'screen lock is off when the person set it to immediately',
    );
  });
}

/// A storage whose reads take their answer NOW and hand it back later.
///
/// Both halves matter. Parking the read models the race; capturing the value
/// at call time is what makes two parked reads able to disagree — without it
/// they both come back with whatever the store holds at release, and a test
/// that cannot tell them apart proves nothing about which one won.
class _GatedStorage implements Storage {
  _GatedStorage(this.inner);

  final HiddenVolumeStorage inner;
  final List<Completer<void>> _gates = [];

  /// Let the `n`-th parked read finish.
  void release(int n) {
    if (n < _gates.length && !_gates[n].isCompleted) _gates[n].complete();
  }

  int get parked => _gates.length;

  @override
  Future<String?> getSetting(String key) async {
    final answer = await inner.getSetting(key);
    final gate = Completer<void>();
    _gates.add(gate);
    await gate.future;
    return answer;
  }

  @override
  Future<void> putSetting(String key, String value) =>
      inner.putSetting(key, value);

  /// Touched by the controller's dispose hook, which is what makes the
  /// provider rebuild on a switch.
  @override
  bool get isOpen => inner.isOpen;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      Function.apply((inner as dynamic).noSuchMethod, [invocation]);
}
