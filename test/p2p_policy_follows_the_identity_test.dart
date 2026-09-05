import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/domain/p2p_policy.dart';
import 'package:xveil/state/p2p_policy_controller.dart';
import 'package:xveil/state/providers.dart';

/// Whether a conversation may take the direct ladder is a decision about
/// whether a peer learns this identity's real address.
///
/// The controller survives an all-online switch — `_activateOnline` re-points
/// the storage and nothing else — and it carried two things across: the loaded
/// policy, and the flag saying a person had chosen one. So A's "allow" became
/// B's policy even though B's owner had said "never", and B's next
/// conversation offered its peer a direct connection (report17 XV17-M3).
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

  test("B's own policy is what B runs under", () async {
    final a = await opened('a');
    final b = await opened('b');
    // A allows; B has said never.
    await a.putSetting(
      kP2PGlobalPolicySettingKey,
      P2PGlobalPolicy.allowAll.name,
    );
    await b.putSetting(kP2PGlobalPolicySettingKey, P2PGlobalPolicy.denied.name);
    var active = a;

    final container = ProviderContainer(
      overrides: [storageProvider.overrideWith((ref) => active)],
    );
    addTearDown(container.dispose);

    container.read(p2pPolicyProvider);
    await Future<void>.delayed(Duration.zero);
    expect(
      container.read(p2pPolicyProvider),
      P2PGlobalPolicy.allowAll,
      reason: "premise: A's policy is loaded",
    );

    active = b;
    container.invalidate(storageProvider);
    container.read(p2pPolicyProvider);
    await Future<void>.delayed(Duration.zero);

    expect(
      container.read(p2pPolicyProvider),
      P2PGlobalPolicy.denied,
      reason: "A's policy was carried into B, whose owner said never",
    );
  });

  test("and a choice made under A does not silence B's own load", () async {
    final a = await opened('a');
    final b = await opened('b');
    await b.putSetting(kP2PGlobalPolicySettingKey, P2PGlobalPolicy.denied.name);
    var active = a;

    final container = ProviderContainer(
      overrides: [storageProvider.overrideWith((ref) => active)],
    );
    addTearDown(container.dispose);

    // The person picks a policy under A. That sets the "a person has chosen"
    // flag, which lives on the notifier — and the notifier survives a switch.
    await container
        .read(p2pPolicyProvider.notifier)
        .set(P2PGlobalPolicy.allowAll);
    expect(container.read(p2pPolicyProvider), P2PGlobalPolicy.allowAll);
    expect(
      await a.getSetting(kP2PGlobalPolicySettingKey),
      P2PGlobalPolicy.allowAll.name,
      reason: "the choice was written somewhere other than A's storage",
    );

    active = b;
    container.invalidate(storageProvider);
    container.read(p2pPolicyProvider);
    await Future<void>.delayed(Duration.zero);

    expect(
      container.read(p2pPolicyProvider),
      P2PGlobalPolicy.denied,
      reason:
          "A's choice made B's load return early, so B ran under A's "
          'permissive policy',
    );
    expect(
      await b.getSetting(kP2PGlobalPolicySettingKey),
      P2PGlobalPolicy.denied.name,
      reason: "A's choice was written into B's storage",
    );
  });

  test('a load asked of A does not land on B', () async {
    // The read is fire-and-forget: nothing waits for it, so it can come back
    // after the identity has moved. What it returns is A's policy.
    final a = _GatedStorage(await opened('a'));
    final b = await opened('b');
    await a.inner.putSetting(
      kP2PGlobalPolicySettingKey,
      P2PGlobalPolicy.allowAll.name,
    );
    await b.putSetting(kP2PGlobalPolicySettingKey, P2PGlobalPolicy.denied.name);
    Storage active = a;

    final container = ProviderContainer(
      overrides: [storageProvider.overrideWith((ref) => active)],
    );
    addTearDown(container.dispose);

    container.read(p2pPolicyProvider);
    await Future<void>.delayed(Duration.zero);

    // The identity moves while A's read is still parked.
    active = b;
    container.invalidate(storageProvider);
    container.read(p2pPolicyProvider);
    await Future<void>.delayed(Duration.zero);

    a.release();
    await Future<void>.delayed(Duration.zero);

    expect(
      container.read(p2pPolicyProvider),
      P2PGlobalPolicy.denied,
      reason:
          "a read of A's storage landed after the switch and became B's "
          'policy — the permissive direction, on an identity whose owner '
          'said never',
    );
  });

  test('a choice made under A is written to A, and leaves B alone', () async {
    final a = _GatedStorage(await opened('a'));
    final b = await opened('b');
    await b.putSetting(kP2PGlobalPolicySettingKey, P2PGlobalPolicy.denied.name);
    Storage active = a;

    final container = ProviderContainer(
      overrides: [storageProvider.overrideWith((ref) => active)],
    );
    addTearDown(container.dispose);

    container.read(p2pPolicyProvider);
    await Future<void>.delayed(Duration.zero);
    a.release(); // let the initial load finish
    await Future<void>.delayed(Duration.zero);

    // The person picks a policy under A; the write parks.
    a.reblock();
    final writing = container
        .read(p2pPolicyProvider.notifier)
        .set(P2PGlobalPolicy.allowAll);

    active = b;
    container.invalidate(storageProvider);
    container.read(p2pPolicyProvider);
    await Future<void>.delayed(Duration.zero);

    a.release();
    await writing;

    expect(
      await a.inner.getSetting(kP2PGlobalPolicySettingKey),
      P2PGlobalPolicy.allowAll.name,
      reason: "the choice made under A did not reach A's storage",
    );
    expect(
      await b.getSetting(kP2PGlobalPolicySettingKey),
      P2PGlobalPolicy.denied.name,
      reason: "a choice made under A was written into B's storage",
    );
  });

  group('a write that fails is not a choice that stood (report20 XV20-M2)', () {
    test('the setter says so, and the live state keeps the answer', () async {
      final storage = _RefusingWrites(await opened('a'));
      final container = ProviderContainer(
        overrides: [storageProvider.overrideWith((ref) => storage)],
      );
      addTearDown(container.dispose);

      container.read(p2pPolicyProvider);
      await Future<void>.delayed(Duration.zero);

      final saved = await container
          .read(p2pPolicyProvider.notifier)
          .set(P2PGlobalPolicy.denied);

      expect(
        saved,
        isFalse,
        reason:
            'the write failed and the setter reported success, so the screen '
            'shows a posture the store does not hold',
      );
      // The answer still applies NOW — that is what the person asked for. What
      // must not happen is their believing it survived a restart.
      expect(container.read(p2pPolicyProvider), P2PGlobalPolicy.denied);
      expect(
        await storage.inner.getSetting(kP2PGlobalPolicySettingKey),
        isNull,
        reason: 'retarget this: the write was supposed to have failed',
      );
    });

    test('a write that lands still reports success', () async {
      final storage = await opened('a');
      final container = ProviderContainer(
        overrides: [storageProvider.overrideWith((ref) => storage)],
      );
      addTearDown(container.dispose);
      container.read(p2pPolicyProvider);
      await Future<void>.delayed(Duration.zero);

      expect(
        await container
            .read(p2pPolicyProvider.notifier)
            .set(P2PGlobalPolicy.denied),
        isTrue,
      );
      expect(
        await storage.getSetting(kP2PGlobalPolicySettingKey),
        P2PGlobalPolicy.denied.name,
      );
    });
  });
}

/// A storage that reads but will not write — a full or damaged container.
class _RefusingWrites implements Storage {
  _RefusingWrites(this.inner);

  final HiddenVolumeStorage inner;

  @override
  bool get isOpen => inner.isOpen;

  @override
  Future<String?> getSetting(String key) => inner.getSetting(key);

  @override
  Future<void> putSetting(String key, String value) async =>
      throw StateError('no space left in the container');

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      Function.apply((inner as dynamic).noSuchMethod, [invocation]);
}

/// A storage whose settings calls finish when the test says so.
class _GatedStorage implements Storage {
  _GatedStorage(this.inner);

  final HiddenVolumeStorage inner;
  Completer<void>? _gate = Completer<void>();

  void release() {
    final gate = _gate;
    _gate = null;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  void reblock() => _gate = Completer<void>();

  Future<void> _wait() async {
    final gate = _gate;
    if (gate != null) await gate.future;
  }

  @override
  Future<String?> getSetting(String key) async {
    await _wait();
    return inner.getSetting(key);
  }

  @override
  Future<void> putSetting(String key, String value) async {
    await _wait();
    return inner.putSetting(key, value);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      Function.apply((inner as dynamic).noSuchMethod, [invocation]);
}
