import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/domain/folder_sync.dart';
import 'package:xveil/state/folder_sync_controller.dart';
import 'package:xveil/data/storage/folder_sync_store.dart';
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
}
