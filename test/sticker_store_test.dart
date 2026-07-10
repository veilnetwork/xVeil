import 'dart:convert';
import 'dart:typed_data';

// (foundation import removed — Uint8List via typed_data)
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/sticker_store.dart';

import 'support/fake_hv_container.dart';

// A minimal valid 1x1 PNG — small enough to pass normalization untouched.
final _png1x1 = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9'
  'awAAAABJRU5ErkJggg==',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('StickerPack json round-trips; malformed decodes to null', () {
    const p = StickerPack(id: 'p', name: 'Pack', items: ['a', 'b']);
    final back = StickerPack.fromJson(jsonDecode(jsonEncode(p.toJson())))!;
    expect(back.id, 'p');
    expect(back.name, 'Pack');
    expect(back.items, ['a', 'b']);
    expect(StickerPack.fromJson('nope'), isNull);
    expect(StickerPack.fromJson({'id': 1}), isNull);
    expect(StickerPack.fromJson({'id': 'x', 'name': 'y', 'items': 'z'}), isNull);
  });

  test('import stores bytes + persists the manifest across a reload', () async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final c = ProviderContainer(
        overrides: [singleSpaceStorageProvider.overrideWithValue(storage)]);
    addTearDown(c.dispose);

    final ctrl = c.read(stickerControllerProvider.notifier);
    // Prime the AsyncNotifier.
    await c.read(stickerControllerProvider.future);

    final n = await ctrl.importImages([_png1x1, _png1x1]);
    expect(n, 2);

    final packs = c.read(stickerControllerProvider).value!;
    expect(packs.length, 1);
    expect(packs.single.items.length, 2);
    // The bytes are actually in the store.
    for (final id in packs.single.items) {
      expect(await storage.loadFile(stickerFileKey(id)), isNotNull);
    }

    // A fresh controller over the SAME storage reloads the same manifest.
    final c2 = ProviderContainer(
        overrides: [singleSpaceStorageProvider.overrideWithValue(storage)]);
    addTearDown(c2.dispose);
    final reloaded = await c2.read(stickerControllerProvider.future);
    expect(reloaded.single.items, packs.single.items);
  });

  test('packToBlob -> installPack round-trips into a new pack', () async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final c = ProviderContainer(
        overrides: [singleSpaceStorageProvider.overrideWithValue(storage)]);
    addTearDown(c.dispose);
    final ctrl = c.read(stickerControllerProvider.notifier);
    await c.read(stickerControllerProvider.future);
    await ctrl.importImages([_png1x1, _png1x1]);

    final blob = await ctrl.packToBlob('my');
    expect(blob, isNotNull);

    // A fresh library (new storage) installs the shared pack.
    final storage2 = FakeHvContainer().storage();
    await storage2.open(password: 'pw', createIfMissing: true);
    final c2 = ProviderContainer(
        overrides: [singleSpaceStorageProvider.overrideWithValue(storage2)]);
    addTearDown(c2.dispose);
    final ctrl2 = c2.read(stickerControllerProvider.notifier);
    await c2.read(stickerControllerProvider.future);
    final n = await ctrl2.installPack(blob!);
    expect(n, 2);
    final packs = c2.read(stickerControllerProvider).value!;
    expect(packs.single.items.length, 2);
    // Malformed blob installs nothing.
    expect(await ctrl2.installPack(Uint8List.fromList([1, 2, 3])), 0);
  });

  test('removeSticker drops the item from its pack', () async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final c = ProviderContainer(
        overrides: [singleSpaceStorageProvider.overrideWithValue(storage)]);
    addTearDown(c.dispose);
    final ctrl = c.read(stickerControllerProvider.notifier);
    await c.read(stickerControllerProvider.future);
    await ctrl.importImages([_png1x1]);

    final pack = c.read(stickerControllerProvider).value!.single;
    await ctrl.removeSticker(pack.id, pack.items.first);
    expect(c.read(stickerControllerProvider).value!.single.items, isEmpty);
  });
}
