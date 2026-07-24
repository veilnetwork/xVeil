// Sticker library (stickers epic, brick 2 + pack-management polish): the
// user's own stickers organized into packs, held in the deniable store like
// everything else.
//
// Layout: the pack MANIFEST is a settings JSON blob under [_manifestKey]
// (`{"packs":[{"id","name","items":["itemId",...],"author"?,"signed"?}]}`);
// each sticker's bytes live at storeFile('sticker:<itemId>'). A pack
// installed from a SIGNED share also keeps the original blob verbatim at
// storeFile('stickerpack:<packId>') so a re-export preserves the author's
// signature (provenance survives hops). Nothing hits disk in the clear.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:uuid/uuid.dart';

import '../core/ids.dart';
import 'providers.dart';
import 'sticker_crypto.dart';
import 'sticker_message.dart';
import 'sticker_image.dart';

const String _manifestKey = 'stickers.v1';
String stickerFileKey(String itemId) => 'sticker:$itemId';

/// Where an installed SIGNED pack's original blob lives (re-export verbatim).
String stickerPackBlobKey(String packId) => 'stickerpack:$packId';

/// Install refused: the pack claims an author but its ed25519 signature does
/// not verify (tampered blob or forged trailer). Distinct from a malformed
/// container (which installs nothing and returns 0) so the UI can be honest
/// about WHY nothing happened.
class StickerPackBadSignature implements Exception {
  @override
  String toString() => 'sticker pack signature verification failed';
}

class StickerPack {
  const StickerPack({
    required this.id,
    required this.name,
    required this.items,
    this.authorHex,
    this.signed = false,
  });
  final String id;
  final String name;
  final List<String> items; // sticker item ids, newest last

  /// Provenance for a pack installed from a share: the author's node id (hex)
  /// when the blob carried a VERIFIED signature ([signed] true), or null for
  /// local / legacy-unsigned packs. Any local edit forks the pack and clears
  /// both (see [StickerController._forkFromOriginal]).
  final String? authorHex;
  final bool signed;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'items': items,
    if (authorHex != null) 'author': authorHex,
    if (signed) 'signed': true,
  };

  static StickerPack? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'];
    final name = j['name'];
    final items = j['items'];
    if (id is! String || name is! String || items is! List) return null;
    final author = j['author'];
    return StickerPack(
      id: id,
      name: name,
      items: items.whereType<String>().toList(),
      authorHex: author is String ? author : null,
      signed: j['signed'] == true,
    );
  }

  StickerPack copyWith({String? name, List<String>? items}) => StickerPack(
    id: id,
    name: name ?? this.name,
    items: items ?? this.items,
    authorHex: authorHex,
    signed: signed,
  );
}

/// The pack a bare import (no explicit target) lands in.
const String kDefaultStickerPackId = 'my';

class StickerController extends AsyncNotifier<List<StickerPack>> {
  @override
  Future<List<StickerPack>> build() => _load();

  Future<List<StickerPack>> _load() async {
    final raw = await ref.read(storageProvider).getSetting(_manifestKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['packs'] is! List) return const [];
      return (decoded['packs'] as List)
          .map(StickerPack.fromJson)
          .whereType<StickerPack>()
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _save(List<StickerPack> packs) async {
    final json = jsonEncode({'packs': packs.map((p) => p.toJson()).toList()});
    await ref.read(storageProvider).putSetting(_manifestKey, json);
    state = AsyncData(packs);
  }

  /// Any local edit forks a pack from its shared original: the verbatim
  /// signed blob no longer matches the contents, so keeping it (or the author
  /// badge) would let a MODIFIED pack travel under someone else's signature.
  /// Drops the stored original and the provenance fields.
  Future<StickerPack> _forkFromOriginal(StickerPack p) async {
    if (!p.signed && p.authorHex == null) return p;
    try {
      await ref
          .read(storageProvider)
          .deleteStoredFile(stickerPackBlobKey(p.id));
    } catch (_) {}
    return StickerPack(id: p.id, name: p.name, items: p.items);
  }

  /// Import already-decoded image [images] as stickers (each normalized to
  /// the sticker budget) into [packId] — the default pack when omitted (it is
  /// created on first use with [packName]); an unknown explicit id imports
  /// nothing. Returns how many landed.
  Future<int> importImages(
    List<Uint8List> images, {
    String? packId,
    String packName = 'My stickers',
  }) async {
    final storage = ref.read(storageProvider);
    final packs = List<StickerPack>.of(state.value ?? await _load());
    final targetId = packId ?? kDefaultStickerPackId;
    var idx = packs.indexWhere((p) => p.id == targetId);
    if (idx < 0) {
      if (packId != null) return 0; // explicit target vanished — don't guess
      packs.add(StickerPack(id: targetId, name: packName, items: const []));
      idx = packs.length - 1;
    }
    final items = List<String>.of(packs[idx].items);
    var added = 0;
    for (final img in images) {
      final norm = await normalizeStickerBytes(img);
      if (norm == null) continue;
      final itemId = const Uuid().v4();
      await storage.storeFile(
        stickerFileKey(itemId),
        norm,
        name: 'sticker$kStickerFileExt',
      );
      items.add(itemId);
      added++;
    }
    if (added == 0) return 0;
    packs[idx] = (await _forkFromOriginal(packs[idx])).copyWith(items: items);
    await _save(packs);
    return added;
  }

  /// Create an empty pack named [name]; returns its id (import target).
  Future<String> createPack(String name) async {
    final packs = List<StickerPack>.of(state.value ?? await _load());
    final id = const Uuid().v4();
    packs.add(StickerPack(id: id, name: name, items: const []));
    await _save(packs);
    return id;
  }

  /// Rename [packId]. The name is part of the signed container, so renaming
  /// an installed signed pack forks it (an honest re-share carries OUR
  /// signature over the new name, not the original author's over the old).
  Future<void> renamePack(String packId, String name) async {
    final packs = List<StickerPack>.of(state.value ?? await _load());
    final idx = packs.indexWhere((p) => p.id == packId);
    if (idx < 0) return;
    packs[idx] = (await _forkFromOriginal(packs[idx])).copyWith(name: name);
    await _save(packs);
  }

  /// Delete [packId] outright: its manifest entry, every sticker blob it
  /// owns, and the kept original share blob (item ids are pack-private
  /// uuids, so the bytes can't be referenced from elsewhere).
  Future<void> deletePack(String packId) async {
    final storage = ref.read(storageProvider);
    final packs = List<StickerPack>.of(state.value ?? await _load());
    final idx = packs.indexWhere((p) => p.id == packId);
    if (idx < 0) return;
    for (final itemId in packs[idx].items) {
      try {
        await storage.deleteStoredFile(stickerFileKey(itemId));
      } catch (_) {}
    }
    try {
      await storage.deleteStoredFile(stickerPackBlobKey(packId));
    } catch (_) {}
    packs.removeAt(idx);
    await _save(packs);
  }

  /// Remove a sticker from its pack (bytes are left in the store — cheap, and a
  /// re-add would want them; a full GC is a later concern).
  Future<void> removeSticker(String packId, String itemId) async {
    final packs = List<StickerPack>.of(state.value ?? await _load());
    final idx = packs.indexWhere((p) => p.id == packId);
    if (idx < 0) return;
    final items = List<String>.of(packs[idx].items)..remove(itemId);
    packs[idx] = (await _forkFromOriginal(packs[idx])).copyWith(items: items);
    await _save(packs);
  }

  /// The bytes for a sticker item, or null if missing.
  Future<Uint8List?> bytesFor(String itemId) =>
      ref.read(storageProvider).loadFile(stickerFileKey(itemId));

  /// Serialize [packId] (its stickers, in order) into a shareable STKP blob,
  /// or null when the pack is unknown / empty / its bytes are gone.
  ///
  /// A pack installed from a signed share re-exports the ORIGINAL blob
  /// verbatim — the author's signature is over exact container bytes, so
  /// re-encoding would orphan it. Everything else is encoded fresh and signed
  /// by our own identity when one is unlocked (legacy v1 otherwise: sharing
  /// never hard-requires crypto).
  Future<Uint8List?> packToBlob(String packId) async {
    final packs = state.value ?? await _load();
    final pack = packs.where((p) => p.id == packId).firstOrNull;
    if (pack == null) return null;
    final storage = ref.read(storageProvider);
    if (pack.signed) {
      final original = await storage.loadFile(stickerPackBlobKey(packId));
      if (original != null && original.isNotEmpty) return original;
      // Original lost (partial wipe?) — fall through to a fresh encode.
    }
    if (pack.items.isEmpty) return null;
    final images = <Uint8List>[];
    for (final id in pack.items) {
      final bytes = await storage.loadFile(stickerFileKey(id));
      if (bytes != null && bytes.isNotEmpty) images.add(bytes);
    }
    if (images.isEmpty) return null;
    final name = pack.name.isEmpty ? 'Stickers' : pack.name;
    final crypto = ref.read(stickerPackCryptoProvider);
    final authorId = await crypto.authorId();
    if (authorId == null) return encodeStickerPack(name, images);
    return encodeSignedStickerPack(
      name,
      images,
      authorId: authorId,
      sign: crypto.sign,
    );
  }

  /// Install a received STKP [blob] as a NEW pack (its own id, so an install
  /// never clobbers a same-named local pack). A signed (v2) blob MUST verify —
  /// a bad signature throws [StickerPackBadSignature] instead of installing a
  /// tampered pack; a legacy v1 blob installs as unsigned. Returns the number
  /// of stickers added, or 0 when the blob is malformed / decodes to nothing
  /// usable.
  Future<int> installPack(Uint8List blob) async {
    final bundle = decodeStickerPack(blob);
    if (bundle == null || bundle.images.isEmpty) return 0;
    if (bundle.isSigned) {
      final ok = await ref.read(stickerPackCryptoProvider).verify(bundle);
      if (!ok) throw StickerPackBadSignature();
    }
    final storage = ref.read(storageProvider);
    final packs = List<StickerPack>.of(state.value ?? await _load());
    final items = <String>[];
    for (final img in bundle.images) {
      final norm = await normalizeStickerBytes(img);
      if (norm == null) continue;
      final itemId = const Uuid().v4();
      await storage.storeFile(
        stickerFileKey(itemId),
        norm,
        name: 'sticker$kStickerFileExt',
      );
      items.add(itemId);
    }
    if (items.isEmpty) return 0;
    final packId = const Uuid().v4();
    if (bundle.isSigned) {
      // Keep the signed original verbatim so a re-share preserves provenance.
      await storage.storeFile(
        stickerPackBlobKey(packId),
        blob,
        name: 'pack$kStickerPackFileExt',
      );
    }
    packs.add(
      StickerPack(
        id: packId,
        name: bundle.name.isEmpty ? 'Shared pack' : bundle.name,
        items: items,
        authorHex: bundle.isSigned
            ? NodeId(Uint8List.fromList(bundle.authorId!)).hex
            : null,
        signed: bundle.isSigned,
      ),
    );
    await _save(packs);
    return items.length;
  }
}

final stickerControllerProvider =
    AsyncNotifierProvider<StickerController, List<StickerPack>>(
      StickerController.new,
    );
