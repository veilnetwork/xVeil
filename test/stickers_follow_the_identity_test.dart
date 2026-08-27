import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/sticker_store.dart';

final _png1x1 = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9'
  'awAAAABJRU5ErkJggg==',
);

/// Stickers are pictures a person chose, and packs travel under a signature.
///
/// Every method read the storage provider at the moment it needed it and the
/// notifier watched nothing, so an all-online switch — which `_activateOnline`
/// performs with no teardown — left A's packs on screen under B, and the next
/// edit wrote A's manifest into B's storage (report17 XV17-H3).
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

  test('a switch shows the new identity\'s packs, not the old ones', () async {
    final a = await opened('a');
    final b = await opened('b');
    var active = a;

    final container = ProviderContainer(
      overrides: [storageProvider.overrideWith((ref) => active)],
    );
    addTearDown(container.dispose);

    await container.read(stickerControllerProvider.future);
    final ctrl = container.read(stickerControllerProvider.notifier);
    expect(
      await ctrl.importImages([Uint8List.fromList(_png1x1)]),
      1,
      reason: 'premise: A has a pack',
    );
    expect(container.read(stickerControllerProvider).value, hasLength(1));

    active = b;
    container.invalidate(storageProvider);
    final afterSwitch = await container.read(stickerControllerProvider.future);

    expect(
      afterSwitch,
      isEmpty,
      reason: "A's stickers were still on screen under B",
    );
  });

  test('and an edit under B does not write A\'s manifest into it', () async {
    final a = await opened('a');
    final b = await opened('b');
    var active = a;

    final container = ProviderContainer(
      overrides: [storageProvider.overrideWith((ref) => active)],
    );
    addTearDown(container.dispose);

    await container.read(stickerControllerProvider.future);
    await container.read(stickerControllerProvider.notifier).importImages([
      Uint8List.fromList(_png1x1),
    ]);

    active = b;
    container.invalidate(storageProvider);
    await container.read(stickerControllerProvider.future);
    await container.read(stickerControllerProvider.notifier).createPack('B');

    final manifest = await b.getSetting('stickers.v1');
    final packs = (jsonDecode(manifest!)['packs'] as List)
        .cast<Map<String, Object?>>();
    expect(
      packs.map((p) => p['name']),
      ['B'],
      reason:
          "A's pack was written into B's manifest, naming blobs B "
          'does not have',
    );
  });

  test(
    'an edit still in flight does not put A\'s packs on B\'s screen',
    () async {
      // A save started under A finishes after the switch. What it wrote belongs
      // in A's storage — that part is right — but handing the same list to the
      // screen puts A's packs in front of B.
      final a = await opened('a');
      final b = await opened('b');
      var active = a;

      final container = ProviderContainer(
        overrides: [storageProvider.overrideWith((ref) => active)],
      );
      addTearDown(container.dispose);

      await container.read(stickerControllerProvider.future);
      final inFlight = container
          .read(stickerControllerProvider.notifier)
          .createPack('A');

      active = b;
      container.invalidate(storageProvider);
      await container.read(stickerControllerProvider.future);
      await inFlight;

      expect(
        container.read(stickerControllerProvider).value,
        isEmpty,
        reason: "a save that belonged to A repainted B's sticker list",
      );
      // And it did land where it was meant to.
      expect(await a.getSetting('stickers.v1'), contains('"name":"A"'));
    },
  );
}
