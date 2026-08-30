import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/domain/folder_sync.dart';
import 'package:xveil/state/folder_sync_controller.dart';
import 'package:xveil/data/storage/folder_sync_store.dart';
import 'package:xveil/state/folder_sync_engine.dart';
import 'package:xveil/state/providers.dart';

/// The folder sync belongs to ONE identity, and to no other.
///
/// `_store` and `_engine` were read at the moment they were used, so after an
/// all-online switch the pairs in `state` still belonged to A while those
/// answered with B's store and B's cloud. A watcher event or the five-minute
/// sweep then uploaded A's local files into B's cloud, where they are new —
/// a confidentiality and deniability break with nobody attacking anything
/// (report17 XV17-H2).
///
/// The switch itself is real: `AppController._activateOnline` says "no
/// teardown" and only points the providers at another identity, so anything
/// that captured by `read` keeps A's.
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

  test('a switch rebuilds the controller against the new identity', () async {
    final a = await opened('a');
    final b = await opened('b');
    var active = a;

    final container = ProviderContainer(
      overrides: [storageProvider.overrideWith((ref) => active)],
    );
    addTearDown(container.dispose);

    // A pair that belongs to A and to nobody else.
    await FolderSyncStore(
      a,
    ).savePairs(const [FolderSyncPair(id: 'p1', localPath: '/tmp/a-only')]);

    final controller = container.read(folderSyncControllerProvider.notifier);
    await controller.reload();
    expect(
      container.read(folderSyncControllerProvider).map((v) => v.pair.id),
      ['p1'],
      reason: 'premise: the controller holds A\'s pair',
    );

    // The switch: same container, another storage. No teardown, exactly as
    // `_activateOnline` does it.
    active = b;
    container.invalidate(storageProvider);
    await container.read(folderSyncControllerProvider.notifier).reload();

    expect(
      container.read(folderSyncControllerProvider),
      isEmpty,
      reason:
          "A's pair survived into B: the next sweep would upload A's folder "
          "into B's cloud",
    );
  });

  test('and B\'s own pairs are what it then holds', () async {
    // Vacuity guard: an empty list is also what a controller that stopped
    // working returns.
    final a = await opened('a');
    final b = await opened('b');
    var active = a;

    final container = ProviderContainer(
      overrides: [storageProvider.overrideWith((ref) => active)],
    );
    addTearDown(container.dispose);

    await FolderSyncStore(
      a,
    ).savePairs(const [FolderSyncPair(id: 'p1', localPath: '/tmp/a')]);
    await FolderSyncStore(
      b,
    ).savePairs(const [FolderSyncPair(id: 'p2', localPath: '/tmp/b')]);

    await container.read(folderSyncControllerProvider.notifier).reload();
    expect(container.read(folderSyncControllerProvider).map((v) => v.pair.id), [
      'p1',
    ]);

    active = b;
    container.invalidate(storageProvider);
    await container.read(folderSyncControllerProvider.notifier).reload();

    expect(
      container.read(folderSyncControllerProvider).map((v) => v.pair.id),
      ['p2'],
      reason: 'the controller must hold the pairs of the identity now shown',
    );
  });

  test(
    'a pass already running does not finish against the new identity',
    () async {
      // The rebuild stops NEW passes. This is the one already inside `runOnce`
      // when the switch lands: its engine is A's cloud, its folder is A's, and
      // finishing it after the switch is the upload this whole file is about.
      final a = await opened('a');
      final b = await opened('b');
      var active = a;
      final engine = _CountingEngine();
      final gate = Completer<void>();

      final container = ProviderContainer(
        overrides: [
          storageProvider.overrideWith((ref) => active),
          folderSyncEngineProvider.overrideWith((ref) => engine),
          // Holds the pass open exactly where `runOnce` awaits its reload.
          folderSyncStoreProvider.overrideWith(
            (ref) => _GatedStore(ref.watch(storageProvider), gate.future),
          ),
        ],
      );
      addTearDown(container.dispose);

      final dir = Directory.systemTemp.createTempSync('xveil-sync-identity');
      addTearDown(() => dir.deleteSync(recursive: true));
      Process.runSync('chmod', ['0700', dir.path]);
      final pair = FolderSyncPair(id: 'p1', localPath: dir.path);
      await FolderSyncStore(a).savePairs([pair]);

      final controller = container.read(folderSyncControllerProvider.notifier);
      final pass = controller.runOnce(pair);

      // The identity moves while the pass is held at its reload.
      active = b;
      container.invalidate(storageProvider);
      container.read(folderSyncControllerProvider);
      gate.complete();
      await pass;

      expect(
        engine.runs,
        0,
        reason: "a pass that started under A ran against B's cloud",
      );
    },
  );
  test('a reload already in flight does not publish A\'s pairs into B', () {
    // `runOnce` has captured its store since report17. `reload` had not, and
    // read `_store` on both sides of its awaits — so a reload started under A
    // and finishing after the switch published A's pairs into B's state and
    // handed the same list to `_rewatch`, pointing B's scheduler at A's
    // folders (report18 XV18-H6). From there a watcher event or the sweep
    // uploads A's local files into B's cloud.
    return () async {
      final a = await opened('a');
      final b = await opened('b');
      var active = a;
      final gate = Completer<void>();

      final container = ProviderContainer(
        overrides: [
          storageProvider.overrideWith((ref) => active),
          folderSyncStoreProvider.overrideWith(
            (ref) => _GatedStore(ref.watch(storageProvider), gate.future),
          ),
        ],
      );
      addTearDown(container.dispose);

      await FolderSyncStore(
        a,
      ).savePairs(const [FolderSyncPair(id: 'p1', localPath: '/tmp/a-only')]);

      final controller = container.read(folderSyncControllerProvider.notifier);
      final reloading = controller.reload();

      // The identity moves while the reload is held at its first read.
      active = b;
      container.invalidate(storageProvider);
      container.read(folderSyncControllerProvider);
      gate.complete();
      await reloading;

      expect(
        container.read(folderSyncControllerProvider).map((v) => v.pair.id),
        isEmpty,
        reason:
            "A's folder pair reached B's live state, and with it the "
            "scheduler that watches B's cloud",
      );
    }();
  });
}

/// Counts passes and does nothing else.
class _CountingEngine implements FolderSyncEngine {
  int runs = 0;

  @override
  Future<FolderSyncReport> runOnce(FolderSyncPair pair) async {
    runs++;
    return const FolderSyncReport(
      applied: [],
      failed: [],
      conflicts: <String>{},
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// A store whose first `pairs()` finishes when the test says so — the await
/// inside `runOnce` that the switch has to land in. Everything else is the
/// real store over the real container.
class _GatedStore extends FolderSyncStore {
  _GatedStore(super.storage, this._gate);
  final Future<void> _gate;
  var _gated = false;

  @override
  Future<List<FolderSyncPair>> pairs() async {
    if (!_gated) {
      _gated = true;
      await _gate;
    }
    return super.pairs();
  }
}
