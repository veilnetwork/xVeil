import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/node/managed_node.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/state/managed_nodes_controller.dart';
import 'package:xveil/state/providers.dart';

/// A's servers are not something B is meant to know.
///
/// The registry was loaded through `ref.read` and the notifier watched
/// nothing, so after an all-online switch — which `_activateOnline` performs
/// with no teardown — the screen went on showing A's hosts, users and
/// host-key fingerprints, and the next mutation wrote that whole list into B's
/// storage (report17 XV17-H3).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<HiddenVolumeStorage> opened(String password) async {
    final backing = FakeKvLogStore();
    final storage = HiddenVolumeStorage(
      ({required password, required bool create}) => backing,
    );
    await storage.open(password: password, createIfMissing: true);
    return storage;
  }

  ManagedNode node(String id) =>
      ManagedNode(id: id, label: id, sshHost: '$id.example', sshUser: 'root');

  test(
    'a switch shows the new identity\'s registry, not the old one',
    () async {
      final a = await opened('a');
      final b = await opened('b');
      var active = a;

      final container = ProviderContainer(
        overrides: [storageProvider.overrideWith((ref) => active)],
      );
      addTearDown(container.dispose);

      await container.read(managedNodesProvider.future);
      expect(
        await container.read(managedNodesProvider.notifier).upsert(node('a1')),
        isNull,
        reason: 'premise: A has a server',
      );
      expect(container.read(managedNodesProvider).value!.map((n) => n.id), [
        'a1',
      ]);

      active = b;
      container.invalidate(storageProvider);
      final afterSwitch = await container.read(managedNodesProvider.future);

      expect(
        afterSwitch,
        isEmpty,
        reason:
            "A's servers were still on screen under B, and the next mutation "
            "would have written them into B's storage",
      );
    },
  );

  test('and a mutation under B does not carry A\'s list into it', () async {
    final a = await opened('a');
    final b = await opened('b');
    var active = a;

    final container = ProviderContainer(
      overrides: [storageProvider.overrideWith((ref) => active)],
    );
    addTearDown(container.dispose);

    await container.read(managedNodesProvider.future);
    await container.read(managedNodesProvider.notifier).upsert(node('a1'));

    active = b;
    container.invalidate(storageProvider);
    await container.read(managedNodesProvider.future);
    await container.read(managedNodesProvider.notifier).upsert(node('b1'));

    expect(
      container.read(managedNodesProvider).value!.map((n) => n.id),
      ['b1'],
      reason: "B's registry must hold B's server and nothing of A's",
    );
    // And A's own storage still holds A's, untouched by any of it.
    expect(
      ManagedNode.decodeList(
        await a.getSetting('managed_nodes'),
      ).map((n) => n.id),
      ['a1'],
    );
  });

  test('a list that matches what A held is still written to B', () async {
    // The notifier SURVIVES the rebuild, and with it the "already on disk"
    // cache. A's JSON matching B's next write is not a coincidence to wave
    // away: the app writes a registry of two fields a person types, and the
    // suppressed write leaves B's screen showing a server B's disk does not
    // have — gone at the next unlock, host key and all.
    final a = await opened('a');
    final b = await opened('b');
    var active = a;

    final container = ProviderContainer(
      overrides: [storageProvider.overrideWith((ref) => active)],
    );
    addTearDown(container.dispose);

    await container.read(managedNodesProvider.future);
    await container.read(managedNodesProvider.notifier).upsert(node('same'));

    active = b;
    container.invalidate(storageProvider);
    await container.read(managedNodesProvider.future);
    expect(
      await container.read(managedNodesProvider.notifier).upsert(node('same')),
      isNull,
    );

    expect(
      ManagedNode.decodeList(
        await b.getSetting('managed_nodes'),
      ).map((n) => n.id),
      ['same'],
      reason: "the write was skipped as unchanged — against A's disk, not B's",
    );
  });

  test('a mutation asked of A does not land after the switch', () async {
    // Mutations run one at a time through a queue. One asked while A was
    // active can reach the front once B is, and what it writes is the list it
    // read from A.
    final a = await opened('a');
    final b = await opened('b');
    var active = a;

    final container = ProviderContainer(
      overrides: [storageProvider.overrideWith((ref) => active)],
    );
    addTearDown(container.dispose);

    await container.read(managedNodesProvider.future);
    await container.read(managedNodesProvider.notifier).upsert(node('a1'));

    // Asked of A, not awaited...
    final queued = container
        .read(managedNodesProvider.notifier)
        .upsert(node('a2'));
    // ...and the identity moves before it runs.
    active = b;
    container.invalidate(storageProvider);
    await container.read(managedNodesProvider.future);
    await queued;

    expect(
      ManagedNode.decodeList(await b.getSetting('managed_nodes')),
      isEmpty,
      reason: "a list read from A was written into B's storage",
    );
    expect(
      container.read(managedNodesProvider).value,
      isEmpty,
      reason: "and B's screen shows A's servers",
    );
  });

  test('a write already in flight when the identity changes stays in A', () {
    // The queued case above is the easy half. This is the other one: the
    // mutation is not waiting in the queue, it is INSIDE `putSetting` when the
    // switch happens. `_serialized` checks the storage when an operation
    // reaches the front of the queue — one moment too early to see this — and
    // the notifier is reused across builds, so the continuation published A's
    // list into B's `state` and left `_lastPersisted` claiming A's JSON was
    // B's last write (report18 XV18-H4).
    //
    // Deterministic: the write is held open on a gate, not on a timer.
    return () async {
      final aBacking = FakeKvLogStore();
      final a = HiddenVolumeStorage(
        ({required password, required bool create}) => aBacking,
      );
      await a.open(password: 'a', createIfMissing: true);
      final gatedA = _GatedStorage(a);
      final b = await opened('b');

      Storage active = gatedA;
      final container = ProviderContainer(
        overrides: [storageProvider.overrideWith((ref) => active)],
      );
      addTearDown(container.dispose);

      await container.read(managedNodesProvider.future);
      final notifier = container.read(managedNodesProvider.notifier);

      final gate = Completer<void>();
      gatedA.hold = gate;
      final inFlight = notifier.upsert(node('a1'));
      // Let the mutation reach the write and block there.
      await Future<void>.delayed(Duration.zero);

      active = b;
      container.invalidate(storageProvider);
      await container.read(managedNodesProvider.future);

      gate.complete();
      expect(await inFlight, isNull, reason: "A's write itself must succeed");

      expect(
        container.read(managedNodesProvider).value!.map((n) => n.id),
        isEmpty,
        reason: "A's servers appeared in B's live registry",
      );

      // And the cache must not claim A's list was B's last write, or B's next
      // identical write would be skipped as a no-op.
      expect(
        await notifier.upsert(node('b1')),
        isNull,
        reason: "B's own write was refused",
      );
      expect(
        container.read(managedNodesProvider).value!.map((n) => n.id),
        ['b1'],
        reason: "B's container took A's servers with it",
      );

      // A's write is where it belongs, and nowhere else.
      expect(
        ManagedNode.decodeList(
          await a.getSetting('managed_nodes') ?? '[]',
        ).map((n) => n.id),
        ['a1'],
        reason: "A's own write was lost by the guard",
      );
    }();
  });
}

/// A [Storage] whose settings write can be held open.
///
/// Everything else forwards to the real one through noSuchMethod: this exists
/// to open a window inside `putSetting`, not to reimplement storage.
class _GatedStorage implements Storage {
  _GatedStorage(this._inner);

  final Storage _inner;
  Completer<void>? hold;

  @override
  Future<void> putSetting(String key, String value) async {
    final gate = hold;
    if (gate != null) await gate.future;
    return _inner.putSetting(key, value);
  }

  @override
  Future<String?> getSetting(String key) => _inner.getSetting(key);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      _inner.noSuchMethod(invocation);
}
