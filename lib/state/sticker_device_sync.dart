import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../core/log.dart';
import '../data/storage/storage.dart';
import '../domain/content_manifest.dart';
import '../domain/device_sync.dart';
import '../domain/media_object.dart';
import 'sticker_message.dart' show kStickerPackFileExt;
import 'sticker_store.dart';

const stickerPackSyncFileName = 'stickers$kStickerPackFileExt';

typedef StickerContentRegistration = Future<String> Function(Uint8List blob);
typedef StickerEventPost =
    Future<bool> Function(DeviceSyncEvent event, {MediaObject? attachment});

/// Durable announcement state for the packs this device changes locally.
/// A pending marker is written before posting, then replaced only after the
/// device event is stored. A restart can therefore retry an interrupted edit
/// or deletion without announcing every unchanged pack over a sibling's edit.
class StickerDeviceSync {
  StickerDeviceSync({
    required this.storage,
    required this.stickers,
    required this.registerContent,
    required this.postEvent,
    required this.nextTimestamp,
  });

  final Storage storage;
  final StickerController stickers;
  final StickerContentRegistration registerContent;
  final StickerEventPost postEvent;
  final int Function() nextTimestamp;
  final Map<String, Future<void>> _queued = {};

  static const _prefix = 'stickers.announced.v1:';
  static const _deleted = 'v2:deleted';
  static const _pending = 'pending:';

  String _key(String packId) => '$_prefix$packId';

  String _marker(String name, String? cid) =>
      'v2:${crypto.sha256.convert(utf8.encode('$name\u0000${cid ?? ''}'))}';

  String? _contentId(Uint8List? blob) => blob == null
      ? null
      : ContentManifest.fromBytes(stickerPackSyncFileName, blob).contentId;

  /// Serialize edits to one pack. The form is read when its turn starts, so a
  /// slow earlier registration cannot post stale contents after a newer edit.
  Future<void> emit(String packId, {bool deleted = false}) {
    final prior = _queued[packId] ?? Future<void>.value();
    final next = prior.then((_) => _emitNow(packId, deleted: deleted));
    _queued[packId] = next;
    unawaited(
      next.whenComplete(() {
        if (identical(_queued[packId], next)) _queued.remove(packId);
      }),
    );
    return next;
  }

  Future<void> _emitNow(String packId, {required bool deleted}) async {
    try {
      if (deleted) {
        if (await storage.getSetting(_key(packId)) == _deleted) return;
        await storage.putSetting(_key(packId), '$_pending$_deleted');
        final posted = await postEvent(
          DeviceSyncEvent(
            kind: DeviceSyncKind.stickerPack,
            key: packId,
            tsMs: nextTimestamp(),
            payload: const {'del': true},
          ),
        );
        if (posted) await storage.putSetting(_key(packId), _deleted);
        return;
      }

      final form = await stickers.syncForm(packId);
      if (form == null) return;
      final marker = _marker(form.name, _contentId(form.blob));
      if (await storage.getSetting(_key(packId)) == marker) return;
      await storage.putSetting(_key(packId), '$_pending$marker');
      final cid = form.blob == null ? null : await registerContent(form.blob!);
      final posted = await postEvent(
        DeviceSyncEvent(
          kind: DeviceSyncKind.stickerPack,
          key: packId,
          tsMs: nextTimestamp(),
          payload: {'name': form.name, 'cid': ?cid},
        ),
        attachment: cid == null
            ? null
            : MediaObject(kind: 'file', dataB64: 'AA==', w: 1, h: 1, cid: cid),
      );
      if (posted) await storage.putSetting(_key(packId), marker);
    } catch (e) {
      devLog(() => 'xVeil[devices]: sticker pack $packId not sent: $e');
    }
  }

  /// Reconcile local edits interrupted before their event was stored. A
  /// previously announced pack whose local form is unchanged stays silent,
  /// allowing a newer sibling edit to arrive without being overwritten.
  Future<void> reconcile() async {
    await Future.wait(_queued.values.toList());
    final ids = (await stickers.packIds()).toSet();
    for (final id in ids) {
      final form = await stickers.syncForm(id);
      if (form == null) continue;
      final marker = _marker(form.name, _contentId(form.blob));
      final told = await storage.getSetting(_key(id));
      if (told == marker) continue;
      // A previous build stored only the content id. If it still matches,
      // adopt that state as the baseline rather than announcing a stale copy
      // over a change made on the sibling while this device was off.
      if (told != null &&
          !told.startsWith('v2:') &&
          !told.startsWith(_pending) &&
          told == (_contentId(form.blob) ?? '')) {
        await storage.putSetting(_key(id), marker);
        continue;
      }
      await emit(id);
    }

    // Deletion removed the pack from the manifest. The announcement marker
    // survives it, so a crash before posting (or a refused post) is recoverable.
    for (final key in await storage.settingsKeys()) {
      const storedPrefix = 'set:$_prefix';
      if (!key.startsWith(storedPrefix)) continue;
      final id = key.substring(storedPrefix.length);
      if (ids.contains(id)) continue;
      final told = await storage.getSetting(_key(id));
      if (told == _deleted) continue;
      // Legacy deletion markers were the empty string. There is no evidence
      // that a sibling still has that pack, so do not mint a fresh deletion
      // over a pack it may have since changed.
      if (told == '') {
        await storage.putSetting(_key(id), _deleted);
        continue;
      }
      await emit(id, deleted: true);
    }
  }

  /// An own event can return through the device log. Compare both the name
  /// and content: two names for an empty pack have the same null content id.
  Future<bool> isOwnEcho(String packId, String name, String? cid) async {
    final told = await storage.getSetting(_key(packId));
    final marker = _marker(name, cid);
    if (told == marker || told == '$_pending$marker') return true;
    if (told != (cid ?? '')) return false; // not a legacy marker
    final local = await stickers.syncForm(packId);
    return local?.name == name && _contentId(local?.blob) == cid;
  }

  Future<void> noteApplied(
    String packId, {
    required String name,
    required String? cid,
    bool deleted = false,
  }) =>
      storage.putSetting(_key(packId), deleted ? _deleted : _marker(name, cid));
}
