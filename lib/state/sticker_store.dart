// Sticker library (stickers epic, brick 2): the user's own stickers organized
// into packs, held in the deniable store like everything else.
//
// Layout: the pack MANIFEST is a settings JSON blob under [_manifestKey]
// (`{"packs":[{"id","name","items":["itemId",...]}]}`); each sticker's bytes
// live at storeFile('sticker:<itemId>'). Nothing hits disk in the clear.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:uuid/uuid.dart';

import 'providers.dart';
import 'sticker_message.dart';

const String _manifestKey = 'stickers.v1';
String stickerFileKey(String itemId) => 'sticker:$itemId';

class StickerPack {
  const StickerPack({required this.id, required this.name, required this.items});
  final String id;
  final String name;
  final List<String> items; // sticker item ids, newest last

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'items': items};

  static StickerPack? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'];
    final name = j['name'];
    final items = j['items'];
    if (id is! String || name is! String || items is! List) return null;
    return StickerPack(
      id: id,
      name: name,
      items: items.whereType<String>().toList(),
    );
  }

  StickerPack copyWith({String? name, List<String>? items}) =>
      StickerPack(id: id, name: name ?? this.name, items: items ?? this.items);
}

/// The default pack every import lands in until pack management ships.
const String _defaultPackId = 'my';

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

  /// Import already-decoded image [images] as stickers into the default pack
  /// (each normalized to the sticker budget). Returns how many landed.
  Future<int> importImages(
    List<Uint8List> images, {
    String packName = 'My stickers',
  }) async {
    final storage = ref.read(storageProvider);
    final packs = List<StickerPack>.of(state.valueOrNull ?? await _load());
    var pack = packs.firstWhere(
      (p) => p.id == _defaultPackId,
      orElse: () => const StickerPack(id: _defaultPackId, name: '', items: []),
    );
    if (!packs.contains(pack)) {
      pack = StickerPack(id: _defaultPackId, name: packName, items: const []);
      packs.add(pack);
    }
    final items = List<String>.of(pack.items);
    var added = 0;
    for (final img in images) {
      final norm = await normalizeStickerBytes(img);
      if (norm == null) continue;
      final itemId = const Uuid().v4();
      await storage.storeFile(stickerFileKey(itemId), norm,
          name: 'sticker$kStickerFileExt');
      items.add(itemId);
      added++;
    }
    if (added == 0) return 0;
    final idx = packs.indexWhere((p) => p.id == pack.id);
    packs[idx] = pack.copyWith(items: items);
    await _save(packs);
    return added;
  }

  /// Remove a sticker from its pack (bytes are left in the store — cheap, and a
  /// re-add would want them; a full GC is a later concern).
  Future<void> removeSticker(String packId, String itemId) async {
    final packs = List<StickerPack>.of(state.valueOrNull ?? await _load());
    final idx = packs.indexWhere((p) => p.id == packId);
    if (idx < 0) return;
    final items = List<String>.of(packs[idx].items)..remove(itemId);
    packs[idx] = packs[idx].copyWith(items: items);
    await _save(packs);
  }

  /// The bytes for a sticker item, or null if missing.
  Future<Uint8List?> bytesFor(String itemId) =>
      ref.read(storageProvider).loadFile(stickerFileKey(itemId));
}

final stickerControllerProvider =
    AsyncNotifierProvider<StickerController, List<StickerPack>>(
  StickerController.new,
);
