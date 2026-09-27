import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/sticker_crypto.dart';
import 'package:xveil/state/sticker_message.dart';
import 'package:xveil/state/sticker_store.dart';

import 'support/fake_hv_container.dart';

// A minimal valid 1x1 PNG — small enough to pass normalization untouched.
final _png1x1 = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9'
  'awAAAABJRU5ErkJggg==',
);

/// Deterministic stand-in for the native ed25519 path (the real crypto is
/// covered by group tests over the same FFI): the "signature" is a rolling
/// checksum of the covered bytes, so any byte flip is detectable, and verify
/// recomputes it — mirroring sign/verify semantics without the dylib.
class _FakeCrypto implements StickerPackCrypto {
  _FakeCrypto({this.canSign = true});
  final bool canSign;

  static final author = Uint8List.fromList(List.filled(32, 0xAA));
  static final pub = Uint8List.fromList(List.filled(32, 0xBB));

  static Uint8List checksum(Uint8List m) {
    final out = Uint8List(64);
    var acc = 7;
    for (var i = 0; i < m.length; i++) {
      acc = (acc * 31 + m[i] + 1) & 0xff;
      out[i % 64] = (out[i % 64] + acc) & 0xff;
    }
    return out;
  }

  @override
  Future<Uint8List?> authorId() async => canSign ? author : null;

  @override
  Future<({Uint8List signature, Uint8List publicKey})> sign(
    Uint8List message,
  ) async => (signature: checksum(message), publicKey: pub);

  @override
  Future<bool> verify(StickerPackBundle bundle) async =>
      listEquals(bundle.authorId, author) &&
      listEquals(bundle.authorPubKey, pub) &&
      listEquals(bundle.signature, checksum(bundle.signedBytes!));
}

Future<(ProviderContainer, StickerController)> _library({
  bool canSign = true,
}) async {
  final storage = FakeHvContainer().storage();
  await storage.open(password: 'pw', createIfMissing: true);
  final c = ProviderContainer(
    overrides: [
      singleSpaceStorageProvider.overrideWithValue(storage),
      stickerPackCryptoProvider.overrideWithValue(
        _FakeCrypto(canSign: canSign),
      ),
    ],
  );
  final ctrl = c.read(stickerControllerProvider.notifier);
  await c.read(stickerControllerProvider.future); // prime the AsyncNotifier
  return (c, ctrl);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('StickerPack json round-trips; malformed decodes to null', () {
    const p = StickerPack(
      id: 'p',
      name: 'Pack',
      items: ['a', 'b'],
      authorHex: 'aa',
      signed: true,
    );
    final back = StickerPack.fromJson(jsonDecode(jsonEncode(p.toJson())))!;
    expect(back.id, 'p');
    expect(back.name, 'Pack');
    expect(back.items, ['a', 'b']);
    expect(back.authorHex, 'aa');
    expect(back.signed, isTrue);
    // Legacy manifest entries (no provenance fields) still parse.
    final legacy = StickerPack.fromJson({
      'id': 'x',
      'name': 'y',
      'items': <String>[],
    })!;
    expect(legacy.authorHex, isNull);
    expect(legacy.signed, isFalse);
    expect(StickerPack.fromJson('nope'), isNull);
    expect(StickerPack.fromJson({'id': 1}), isNull);
    expect(
      StickerPack.fromJson({'id': 'x', 'name': 'y', 'items': 'z'}),
      isNull,
    );
  });

  test('import stores bytes + persists the manifest across a reload', () async {
    final (c, ctrl) = await _library();
    addTearDown(c.dispose);
    final storage = c.read(storageProvider);

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
      overrides: [singleSpaceStorageProvider.overrideWithValue(storage)],
    );
    addTearDown(c2.dispose);
    final reloaded = await c2.read(stickerControllerProvider.future);
    expect(reloaded.single.items, packs.single.items);
  });

  test('packToBlob signs; installPack verifies + records provenance', () async {
    final (c, ctrl) = await _library();
    addTearDown(c.dispose);
    await ctrl.importImages([_png1x1, _png1x1]);

    final blob = await ctrl.packToBlob(await ctrl.defaultPackId());
    expect(blob, isNotNull);
    final bundle = decodeStickerPack(blob!)!;
    expect(bundle.isSigned, isTrue);
    expect(bundle.authorId, _FakeCrypto.author);

    // A fresh library installs the shared pack — signed + author recorded,
    // and the ORIGINAL blob is kept verbatim for re-export.
    final (c2, ctrl2) = await _library();
    addTearDown(c2.dispose);
    final n = await ctrl2.installPack(blob);
    expect(n, 2);
    final installed = c2.read(stickerControllerProvider).value!.single;
    expect(installed.items.length, 2);
    expect(installed.signed, isTrue);
    expect(installed.authorHex, 'aa' * 32);
    final kept = await c2
        .read(storageProvider)
        .loadFile(stickerPackBlobKey(installed.id));
    expect(kept, blob);

    // Re-export returns the original blob VERBATIM (author's signature and
    // all) — provenance survives the hop.
    expect(await ctrl2.packToBlob(installed.id), blob);

    // Malformed blob installs nothing.
    expect(await ctrl2.installPack(Uint8List.fromList([1, 2, 3])), 0);
  });

  test('a tampered signed blob refuses to install', () async {
    final (c, ctrl) = await _library();
    addTearDown(c.dispose);
    await ctrl.importImages([_png1x1]);
    final blob = (await ctrl.packToBlob(await ctrl.defaultPackId()))!;
    // Flip a byte inside the covered prefix (the name area) — the container
    // still parses, the signature no longer matches.
    final tampered = Uint8List.fromList(blob);
    tampered[7] ^= 0x01;
    expect(decodeStickerPack(tampered), isNotNull);

    final (c2, ctrl2) = await _library();
    addTearDown(c2.dispose);
    await expectLater(
      ctrl2.installPack(tampered),
      throwsA(isA<StickerPackBadSignature>()),
    );
    // Nothing landed.
    expect(c2.read(stickerControllerProvider).value, isEmpty);
  });

  test('legacy unsigned (v1) pack still installs, marked unsigned', () async {
    final blob = encodeStickerPack('Old pack', [_png1x1]);
    final (c, ctrl) = await _library();
    addTearDown(c.dispose);
    expect(await ctrl.installPack(blob), 1);
    final pack = c.read(stickerControllerProvider).value!.single;
    expect(pack.signed, isFalse);
    expect(pack.authorHex, isNull);
    expect(pack.name, 'Old pack');
    // No original blob is kept for unsigned installs.
    expect(
      await c.read(storageProvider).loadFile(stickerPackBlobKey(pack.id)),
      isNull,
    );
  });

  test('no unlocked identity -> shares legacy v1 (unsigned)', () async {
    final (c, ctrl) = await _library(canSign: false);
    addTearDown(c.dispose);
    await ctrl.importImages([_png1x1]);
    final blob = (await ctrl.packToBlob(await ctrl.defaultPackId()))!;
    expect(decodeStickerPack(blob)!.isSigned, isFalse);
  });

  test('editing an installed signed pack forks it from the original', () async {
    final (c, ctrl) = await _library();
    addTearDown(c.dispose);
    await ctrl.importImages([_png1x1, _png1x1]);
    final blob = (await ctrl.packToBlob(await ctrl.defaultPackId()))!;

    final (c2, ctrl2) = await _library();
    addTearDown(c2.dispose);
    await ctrl2.installPack(blob);
    var pack = c2.read(stickerControllerProvider).value!.single;
    await ctrl2.removeSticker(pack.id, pack.items.first);

    pack = c2.read(stickerControllerProvider).value!.single;
    expect(pack.signed, isFalse);
    expect(pack.authorHex, isNull);
    expect(pack.items.length, 1);
    // The kept original is gone; a re-share re-encodes (1 sticker, our sig).
    expect(
      await c2.read(storageProvider).loadFile(stickerPackBlobKey(pack.id)),
      isNull,
    );
    final reshared = decodeStickerPack((await ctrl2.packToBlob(pack.id))!)!;
    expect(reshared.images.length, 1);
    expect(reshared.isSigned, isTrue); // now signed by US, fresh encode
  });

  test('create / rename / import-into / delete a pack', () async {
    final (c, ctrl) = await _library();
    addTearDown(c.dispose);
    final storage = c.read(storageProvider);
    await ctrl.importImages([_png1x1]); // default pack

    final id = await ctrl.createPack('Memes');
    expect(await ctrl.importImages([_png1x1, _png1x1], packId: id), 2);
    // An unknown explicit target imports nothing (no silent fallback).
    expect(await ctrl.importImages([_png1x1], packId: 'gone'), 0);

    await ctrl.renamePack(id, 'Dank memes');
    var packs = c.read(stickerControllerProvider).value!;
    final memes = packs.firstWhere((p) => p.id == id);
    expect(memes.name, 'Dank memes');
    expect(memes.items.length, 2);

    // Delete removes the manifest entry AND the sticker blobs.
    final itemKeys = memes.items.map(stickerFileKey).toList();
    await ctrl.deletePack(id);
    packs = c.read(stickerControllerProvider).value!;
    expect(packs.map((p) => p.id), [await ctrl.defaultPackId()]);
    for (final key in itemKeys) {
      expect(await storage.loadFile(key), isNull);
    }
  });

  test('removeSticker drops the item from its pack', () async {
    final (c, ctrl) = await _library();
    addTearDown(c.dispose);
    await ctrl.importImages([_png1x1]);

    final pack = c.read(stickerControllerProvider).value!.single;
    await ctrl.removeSticker(pack.id, pack.items.first);
    expect(c.read(stickerControllerProvider).value!.single.items, isEmpty);
  });

  test('and takes the bytes with it (report17 XV17-L3)', () async {
    // The bytes used to stay on purpose. Nothing could reach them again — an
    // item id is a pack-private uuid, and the manifest had stopped naming it —
    // so every removal added one more unreferenced blob inside the encrypted
    // container, without limit. In an app whose promise is that a deleted
    // thing is gone, "on disk but unreachable" is the wrong answer twice.
    final (c, ctrl) = await _library();
    addTearDown(c.dispose);
    await ctrl.importImages([_png1x1]);
    final pack = c.read(stickerControllerProvider).value!.single;
    final itemId = pack.items.first;
    expect(
      await c.read(storageProvider).loadFile(stickerFileKey(itemId)),
      isNotNull,
      reason: 'precondition: the bytes were never there',
    );

    await ctrl.removeSticker(pack.id, itemId);

    expect(
      await c.read(storageProvider).loadFile(stickerFileKey(itemId)),
      isNull,
      reason: 'a sticker the person deleted is still in the container',
    );
  });

  test('an installed copy mints its own item ids', () async {
    // The invariant the unconditional delete above rests on. If an install
    // ever carried the sender's item ids instead of minting fresh ones, two
    // packs would name the same bytes and removing a sticker from one would
    // blank it in the other — so this fails here, where the reason is
    // written down, rather than there.
    final (c, ctrl) = await _library();
    addTearDown(c.dispose);
    await ctrl.importImages([_png1x1]);
    final first = c.read(stickerControllerProvider).value!.single;
    final blob = (await ctrl.packToBlob(first.id))!;

    await ctrl.installPack(blob);

    final packs = c.read(stickerControllerProvider).value!;
    expect(packs.length, 2, reason: 'the install did not add a pack');
    final ids = packs.expand((p) => p.items).toList();
    expect(
      ids.toSet().length,
      ids.length,
      reason: 'two packs share an item id — the delete needs a refcount again',
    );
  });

  group('a pack travels to my other devices with its images', () {
    // Owner's decision (2026-09-27): stickers sync between my devices,
    // images included.
    test('what one device has, the other gets, under the same pack id',
        () async {
      final (c1, a) = await _library();
      final (c2, b) = await _library();
      addTearDown(c1.dispose);
      addTearDown(c2.dispose);
      final told = <(String, bool)>[];
      a.onLocalPackChange = (id, {bool deleted = false}) => told.add((id, deleted));

      final packId = await a.createPack('Cats');
      await a.importImages([_png1x1, _png1x1], packId: packId);
      expect(told, hasLength(2),
          reason: 'a local change was not told to my other devices');
      expect(told.map((e) => e.$1), everyElement(packId));

      final form = (await a.syncForm(packId))!;
      await b.applyMirroredPack(packId, name: form.name, blob: form.blob);
      final got = c2.read(stickerControllerProvider).value!
          .singleWhere((p) => p.id == packId);
      expect(got.name, 'Cats');
      expect(got.items, hasLength(2));
      expect(await b.bytesFor(got.items.first), isNotNull,
          reason: 'the pack came without its images');

      // A later change replaces it; a deletion removes it.
      await a.removeSticker(packId, c1.read(stickerControllerProvider).value!
          .singleWhere((p) => p.id == packId).items.first);
      final after = (await a.syncForm(packId))!;
      await b.applyMirroredPack(packId, name: after.name, blob: after.blob);
      expect(c2.read(stickerControllerProvider).value!
          .singleWhere((p) => p.id == packId).items, hasLength(1));
      await b.applyMirroredPack(packId, name: '', deleted: true);
      expect(c2.read(stickerControllerProvider).value!
          .where((p) => p.id == packId), isEmpty);
    });

    test('a sibling-applied pack is not told back', () async {
      final (c1, a) = await _library();
      final (c2, b) = await _library();
      addTearDown(c1.dispose);
      addTearDown(c2.dispose);
      final packId = await a.createPack('Dogs');
      await a.importImages([_png1x1], packId: packId);
      final form = (await a.syncForm(packId))!;
      var echoed = 0;
      b.onLocalPackChange = (id, {bool deleted = false}) => echoed++;
      await b.applyMirroredPack(packId, name: form.name, blob: form.blob);
      expect(echoed, 0);
    });

    test('each device has its own default pack, so two cannot collide',
        () async {
      final (c1, a) = await _library();
      final (c2, b) = await _library();
      addTearDown(c1.dispose);
      addTearDown(c2.dispose);
      await a.importImages([_png1x1]);
      await b.importImages([_png1x1]);
      expect(await a.defaultPackId(), isNot(await b.defaultPackId()),
          reason: 'one id on both devices: the newest replaces the other');
    });

    test('a legacy shared default pack is given an id of its own', () async {
      final (c1, a) = await _library();
      addTearDown(c1.dispose);
      await a.importImages([_png1x1], packId: null);
      // Simulate a pack from before: under the fixed id.
      await a.applyMirroredPack(kDefaultStickerPackId, name: 'Old', blob: null);
      expect(await a.defaultPackId(), kDefaultStickerPackId);
      expect(await a.giveDefaultPackItsOwnId(), isTrue);
      final ids = await a.packIds();
      expect(ids, isNot(contains(kDefaultStickerPackId)));
      expect(ids, contains(await a.defaultPackId()));
    });
  });
}
