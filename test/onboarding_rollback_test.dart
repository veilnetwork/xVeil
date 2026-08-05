import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/providers.dart';

/// Onboarding's rollback covered ONE step — the one that had not opened
/// anything yet. Everything after it (the profile write, the preference writes,
/// the session boot) could fail with the container already OPEN and its
/// exclusive flock held, the screen lock primed with the password, and the
/// phase parked on "setting up": no way forward, no way back, and a container
/// nothing in the process would close again.

/// A container whose space opens fine and then refuses the first write. The
/// shape of a full disk, a faulted FFI, a corrupt log — the failure is not the
/// point, only that it happens after the open.
class _WriteRefusingStore extends FakeKvLogStore {
  var closed = 0;

  @override
  int commit(List<KvLogOp> ops) =>
      throw StateError('the space would not write');

  @override
  void close() {
    closed++;
    super.close();
  }
}

/// A container that takes the profile write and then refuses to be READ — so
/// the failure lands in the session boot, AFTER the preference writes have
/// already marked this install as onboarded.
class _LateFailingStore extends FakeKvLogStore {
  var wrote = false;
  var closed = 0;

  @override
  int commit(List<KvLogOp> ops) {
    wrote = true;
    return super.commit(ops);
  }

  @override
  Uint8List? get(int namespace, Uint8List key) {
    if (wrote) throw StateError('the space would not read');
    return super.get(namespace, key);
  }

  @override
  void close() {
    closed++;
    super.close();
  }
}

/// A preference store that ACCEPTS nothing — main()'s in-memory fallback when
/// the profile store cannot be created is the real instance of this, and a full
/// disk is the other.
class _RefusingPrefsStore extends SharedPreferencesStorePlatform {
  final _values = <String, Object>{};

  @override
  Future<bool> clear() async => true;
  @override
  Future<Map<String, Object>> getAll() async => Map.of(_values);
  @override
  Future<bool> remove(String key) async {
    _values.remove(key);
    return true;
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      false;

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) => clear();
  @override
  Future<Map<String, Object>> getAllWithParameters(
    GetAllParameters parameters,
  ) => getAll();
}

({
  ProviderContainer container,
  AppController controller,
  HiddenVolumeStorage storage,
})
_harness(KvLogStore store) {
  final storage = HiddenVolumeStorage(
    ({required Uint8List password, required bool create}) =>
        password.isEmpty ? null : store,
  );
  final c = ProviderContainer(
    overrides: [singleSpaceStorageProvider.overrideWith((ref) => storage)],
  );
  addTearDown(c.dispose);
  return (
    container: c,
    controller: c.read(appControllerProvider.notifier),
    storage: storage,
  );
}

Future<void> _settle(ProviderContainer c) async {
  for (
    var i = 0;
    i < 30 && c.read(appControllerProvider).phase == AppPhase.bootstrapping;
    i++
  ) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late SharedPreferencesStorePlatform original;

  setUp(() {
    original = SharedPreferencesStorePlatform.instance;
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() => SharedPreferencesStorePlatform.instance = original);

  test('a profile write that fails leaves the container CLOSED and the user '
      'back on onboarding', () async {
    final store = _WriteRefusingStore();
    final h = _harness(store);
    await _settle(h.container);

    await expectLater(
      h.controller.completeOnboarding(
        password: 'pw',
        displayName: 'Me',
        mode: StorageMode.hiddenSpace,
      ),
      throwsA(anything),
    );

    expect(
      h.storage.isOpen,
      isFalse,
      reason:
          'the container stayed open with its exclusive lock held, and nothing '
          'in the process would ever close it again',
    );
    expect(store.closed, greaterThan(0));
    expect(
      h.container.read(appControllerProvider).phase,
      AppPhase.onboarding,
      reason: 'the phase was parked on "setting up" with no way out',
    );
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getBool('onboarded'),
      isNot(isTrue),
      reason:
          'the next launch would go to a lock screen for an identity that was '
          'never finished',
    );
  });

  test('a preference store that refuses the onboarded marker is not treated as '
      'a completed setup', () async {
    // Dropped, both of them: setBool/setString ANSWER whether the write landed.
    SharedPreferencesStorePlatform.instance = _RefusingPrefsStore();
    final h = _harness(FakeKvLogStore());
    await _settle(h.container);

    await expectLater(
      h.controller.completeOnboarding(
        password: 'pw',
        displayName: 'Me',
        mode: StorageMode.hiddenSpace,
      ),
      throwsA(isA<StateError>()),
      reason:
          'onboarding reported success over a marker that only existed in RAM',
    );
    expect(h.storage.isOpen, isFalse);
    expect(h.container.read(appControllerProvider).phase, AppPhase.onboarding);
  });

  test('a failure AFTER the preference writes takes the onboarded marker back '
      'with it', () async {
    // The marker is written before the session boots, so a boot that fails
    // leaves this install claiming to be set up over an identity that was never
    // finished — the next launch offers a lock screen and no way past it.
    final store = _LateFailingStore();
    final h = _harness(store);
    await _settle(h.container);

    await expectLater(
      h.controller.completeOnboarding(
        password: 'pw',
        displayName: 'Me',
        mode: StorageMode.hiddenSpace,
      ),
      throwsA(anything),
    );
    expect(store.wrote, isTrue, reason: 'internal: the write must have landed');

    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getBool('onboarded'),
      isNot(isTrue),
      reason: 'the marker outlived the setup it was marking',
    );
    expect(prefs.getString('storage_mode'), isNull);
    expect(h.storage.isOpen, isFalse);
    expect(h.container.read(appControllerProvider).phase, AppPhase.onboarding);
  });

  test('CONTROL: onboarding that works still opens the session and leaves the '
      'container OPEN', () async {
    final h = _harness(FakeKvLogStore());
    await _settle(h.container);

    await h.controller.completeOnboarding(
      password: 'pw',
      displayName: 'Me',
      mode: StorageMode.hiddenSpace,
    );

    expect(h.container.read(appControllerProvider).phase, AppPhase.ready);
    expect(h.storage.isOpen, isTrue);
    expect((await h.storage.loadProfile())!.displayName, 'Me');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('onboarded'), isTrue);
    expect(prefs.getString('storage_mode'), StorageMode.hiddenSpace.name);
  });
}
