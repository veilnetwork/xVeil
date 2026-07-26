import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/ids.dart';
import '../data/storage/file_store.dart' show kMaxStoredFileBytes;
import '../data/storage/storage.dart';
import '../domain/chat.dart';
import '../domain/cloud.dart';
import '../domain/cloud_capability.dart';
import '../domain/content_manifest.dart';
import '../domain/device_sync.dart';
import '../domain/group_message.dart';
import 'group_service_providers.dart';
import 'messaging.dart';
import 'providers.dart';

class CloudEditConflict implements Exception {
  const CloudEditConflict(this.current);

  final CloudItem current;
}

/// Transport/persistence edge used by [CloudService]. Keeping it narrow makes
/// the index and integrity logic testable without a Flutter engine or network.
abstract class CloudSyncPort {
  NodeId get selfId;
  Stream<void> get changes;
  Future<List<DeviceSyncRecord>> records();
  Future<bool> postItem(CloudItem item);
  Future<bool> postFolder(CloudFolder folder);
  Future<bool> postClaim(CloudReplicaClaim claim);
  Future<List<NodeId>> members();
  Future<bool> fetch(String contentId, NodeId holder);
  Future<void> close();
}

/// Device-group adapter: signed LWW rows are the replicated index, and a
/// cloud item's attachment ref is what authorizes member-only content pulls.
class GroupCloudSyncPort implements CloudSyncPort {
  GroupCloudSyncPort(this._group) {
    _listener = () {
      if (!_changes.isClosed) _changes.add(null);
    };
    _group.changes.addListener(_listener);
  }

  final GroupService _group;
  final StreamController<void> _changes = StreamController.broadcast();
  late final VoidCallback _listener;

  @override
  NodeId get selfId => _group.selfId;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<List<DeviceSyncRecord>> records() => _group.deviceSyncRecords();

  @override
  Future<bool> postItem(CloudItem item) => _group.postDeviceEvent(
    item.toEvent(),
    attachment: item.deleted || item.contentId == null
        ? null
        : MediaObject(
            kind: 'cloud',
            dataB64: 'AA==',
            w: 1,
            h: 1,
            cid: item.contentId,
          ),
  );

  @override
  Future<bool> postFolder(CloudFolder folder) =>
      _group.postDeviceEvent(folder.toEvent());

  @override
  Future<bool> postClaim(CloudReplicaClaim claim) =>
      _group.postDeviceEvent(claim.toEvent());

  @override
  Future<List<NodeId>> members() => _group.deviceMembers();

  @override
  Future<bool> fetch(String contentId, NodeId holder) async {
    final gid = await _group.deviceGroupIdHex();
    if (gid == null) return false;
    return _group.fetchGroupContent(NodeId.fromHex(gid), contentId, holder);
  }

  @override
  Future<void> close() async {
    _group.changes.removeListener(_listener);
    unawaited(_changes.close());
  }
}

class CloudService {
  CloudService(
    this._storage,
    this._sync, {
    required this.contentReceived,
    DateTime Function()? now,
    String Function()? newId,
    this.integrityChecks = true,
    this.shareStoredContent,
  }) : _now = now ?? DateTime.now,
       _newId = newId ?? const Uuid().v4;

  static const _indexSetting = 'cloud.index.v1';
  static const _claimsSetting = 'cloud.claims.v1';
  static const _profileSetting = 'cloud.profile.v1';
  static const _lastVerifySetting = 'cloud.last_verify.v1';
  static const _seenSetting = 'cloud.seen.v1';
  static const _manifestPrefix = 'mf:';
  static const _wireChunkBytes = 4096;
  static const maxTextNoteBytes = 1024 * 1024;

  /// Ceiling for an import-time preview. Small enough that a row's preview
  /// never competes with the file, generous enough for a legible thumbnail.
  static const maxThumbnailBytes = 32 * 1024;

  final Storage _storage;
  final CloudSyncPort _sync;
  final Stream<String> contentReceived;
  final DateTime Function() _now;
  final String Function() _newId;
  final bool integrityChecks;
  final Future<bool> Function(NodeId peer, String contentId)?
  shareStoredContent;

  final Map<String, CloudItem> _items = {};
  final Map<String, List<CloudItem>> _noteHeads = {};
  final Map<String, CloudFolder> _folders = {};
  final Map<String, CloudReplicaClaim> _claims = {};

  /// Item id -> the revision this device last acknowledged, either by writing
  /// it or by the user opening it. Purely local: what someone has looked at is
  /// their business and nobody else's, so it never leaves this device.
  final Map<String, int> _seen = {};
  final StreamController<void> _changes = StreamController.broadcast();
  final Set<String> _fetching = {};
  CloudReplicationProfile _profile = const CloudReplicationProfile();
  StreamSubscription<void>? _syncSub;
  StreamSubscription<String>? _contentSub;
  Timer? _reconcileTimer;
  Timer? _integrityTimer;
  Future<void>? _started;
  Future<void> _mutationChain = Future.value();
  bool _closed = false;

  CloudReplicationProfile get profile => _profile;

  Future<void> start() => _started ??= _start();

  Future<void> _start() async {
    await _loadLocal();
    await _reconcile();
    _syncSub = _sync.changes.listen((_) => _scheduleReconcile());
    _contentSub = contentReceived.listen((cid) {
      unawaited(_onContentReceived(cid));
    });
    _autoReplicate();
    if (integrityChecks) await _scheduleIntegrityCheck();
  }

  Stream<List<CloudItem>> watchItems() async* {
    await start();
    yield _visibleItems();
    await for (final _ in _changes.stream) {
      yield _visibleItems();
    }
  }

  Future<List<CloudItem>> listItems({bool includeDeleted = false}) async {
    await start();
    final values = includeDeleted ? _items.values.toList() : _visibleItems();
    values.sort((a, b) => b.modifiedAtMs.compareTo(a.modifiedAtMs));
    return values;
  }

  /// What the cloud is using, here and across the identity's devices.
  ///
  /// Folded entirely from state already present: the index gives the logical
  /// size, the replica claims give per-device holdings (a claim carries the
  /// size of what it claims), and the local store answers what is actually on
  /// this disk. No device is asked anything.
  ///
  /// The local total is measured against the STORE rather than trusted from our
  /// own claim — a claim can outlive the bytes it describes, and a number that
  /// tells someone how much disk they are using should come from the disk.
  Future<CloudUsage> usage() async {
    await start();
    final items = _visibleItems();
    var logicalBytes = 0;
    var localItems = 0;
    var localBytes = 0;
    for (final item in items) {
      logicalBytes += item.size;
      if (await isLocal(item)) {
        localItems++;
        localBytes += item.size;
      }
    }
    // One row per device, counting each item once: a device may claim several
    // heads of the same note, and holding two branches is not holding two notes.
    final perDevice = <String, ({NodeId id, Set<String> items, int bytes})>{};
    final counted = <String>{};
    for (final claim in _claims.values) {
      if (!claim.present) continue;
      final row = perDevice.putIfAbsent(
        claim.deviceId.hex,
        () => (id: claim.deviceId, items: <String>{}, bytes: 0),
      );
      final seen = '${claim.deviceId.hex}|${claim.itemId}';
      if (!counted.add(seen)) continue;
      row.items.add(claim.itemId);
      perDevice[claim.deviceId.hex] = (
        id: row.id,
        items: row.items,
        bytes: row.bytes + claim.size,
      );
    }
    final selfHex = _sync.selfId.hex;
    final devices = [
      for (final entry in perDevice.entries)
        CloudDeviceUsage(
          deviceId: entry.value.id,
          isSelf: entry.key == selfHex,
          items: entry.value.items.length,
          bytes: entry.value.bytes,
        ),
    ]..sort((a, b) => b.bytes.compareTo(a.bytes));
    return CloudUsage(
      logicalItems: items.length,
      logicalBytes: logicalBytes,
      localItems: localItems,
      localBytes: localBytes,
      indexOnlyItems: items.length - localItems,
      devices: devices,
    );
  }

  List<CloudItem> _visibleItems() {
    final values = [
      for (final item in _items.values)
        if (!item.deleted) item,
    ];
    values.sort((a, b) => b.modifiedAtMs.compareTo(a.modifiedAtMs));
    return values;
  }

  Future<void> _loadLocal() async {
    _profile = CloudReplicationProfile.decode(
      await _storage.getSetting(_profileSetting),
    );
    final indexRaw = await _loadMaterialized(_indexSetting);
    if (indexRaw != null) {
      try {
        final rows = jsonDecode(indexRaw);
        if (rows is List) {
          final events = [
            for (final row in rows)
              if (row is String) ?DeviceSyncEvent.fromBody(row),
          ];
          _items.addAll(foldCloudItems(events));
          _noteHeads.addAll(foldCloudNoteHeads(events));
          _folders.addAll(foldCloudFolders(events));
        }
      } catch (_) {}
    }
    final claimsRaw = await _loadMaterialized(_claimsSetting);
    if (claimsRaw != null) {
      try {
        final rows = jsonDecode(claimsRaw);
        if (rows is List) {
          _claims.addAll(
            foldCloudReplicaClaims([
              for (final row in rows)
                if (row is Map &&
                    row['body'] is String &&
                    row['author'] is String)
                  if (DeviceSyncEvent.fromBody(row['body'] as String)
                      case final event?)
                    (
                      event: event,
                      author: NodeId.fromHex(row['author'] as String),
                    ),
            ]),
          );
        }
      } catch (_) {}
    }
    final seenRaw = await _loadMaterialized(_seenSetting);
    if (seenRaw != null) {
      try {
        final rows = jsonDecode(seenRaw);
        if (rows is Map) {
          for (final entry in rows.entries) {
            final revision = entry.value;
            if (entry.key is String && revision is int) {
              _seen[entry.key as String] = revision;
            }
          }
        }
      } catch (_) {}
    }
  }

  Future<void> _saveSeen() =>
      _saveMaterialized(_seenSetting, jsonEncode(_seen));

  /// Record that this device has caught up with [item] as it stands now, so a
  /// later change made somewhere else is what stands out.
  Future<void> markSeen(CloudItem item) async {
    if (_seen[item.id] == item.revision) return;
    _seen[item.id] = item.revision;
    await _saveSeen();
    _emit();
  }

  /// Whether [item] moved on after this device last acknowledged it.
  ///
  /// An item never acknowledged is NOT reported: it is new, not changed, and
  /// flagging everything on first sight would say nothing. Our own writes go
  /// through [_postItemBestEffort], which acknowledges as it posts, so what is
  /// left is exactly the changes that arrived from somewhere else.
  bool changedElsewhere(CloudItem item) {
    final seen = _seen[item.id];
    return seen != null && item.revision > seen;
  }

  Future<String?> _loadMaterialized(String key) async {
    final active = await _storage.getSetting('$key.active');
    final slots = active == 'a' || active == 'b'
        ? [active!, active == 'a' ? 'b' : 'a']
        : const ['a', 'b'];
    for (final slot in slots) {
      final chunked = await _storage.loadFile('$key.$slot');
      if (chunked != null) {
        final decoded = utf8.decode(chunked, allowMalformed: true);
        try {
          if (jsonDecode(decoded) is List) return decoded;
        } catch (_) {}
      }
    }
    // Brief development builds wrote one unslotted chunked copy. Keep this
    // fallback so those stores migrate forward without data loss.
    final legacyChunked = await _storage.loadFile(key);
    if (legacyChunked != null) {
      final decoded = utf8.decode(legacyChunked, allowMalformed: true);
      try {
        if (jsonDecode(decoded) is List) return decoded;
      } catch (_) {}
    }
    final legacy = await _storage.getSetting(key);
    if (legacy != null) {
      try {
        if (jsonDecode(legacy) is List) return legacy;
      } catch (_) {}
    }
    return null;
  }

  /// Cloud indexes are unbounded materialized views, not preferences. A single
  /// hidden-volume setting has a ~4 KiB record cap; once enough historical
  /// items/claims accumulated, every cloud operation failed with
  /// `PayloadTooLarge`. Store the view in the same chunked file-store used by
  /// group bundles. Two alternating slots make replacement crash-safe: fully
  /// publish the inactive blob, then atomically flip a tiny settings pointer.
  /// The previous slot remains a valid fallback if the active blob is missing.
  Future<void> _saveMaterialized(String key, String value) async {
    var active = await _storage.getSetting('$key.active');
    if (active == 'a' || active == 'b') {
      final other = active == 'a' ? 'b' : 'a';
      if (!await _storage.hasFile('$key.$active') &&
          await _storage.hasFile('$key.$other')) {
        // The pointer survived but its slot did not. Treat the readable
        // fallback as active so we never overwrite the only valid copy before
        // publishing a replacement in the missing slot.
        active = other;
      }
    }
    final next = active == 'a' ? 'b' : 'a';
    await _storage.storeFile(
      '$key.$next',
      Uint8List.fromList(utf8.encode(value)),
      name: 'cloud-materialized-index',
    );
    await _storage.putSetting('$key.active', next);
    try {
      await _storage.putSetting(key, '');
    } catch (_) {
      // The chunked copy is already durable. A legacy value may remain as an
      // inert fallback, but future reads always prefer the file-store copy.
    }
  }

  Future<void> _saveIndex() => _saveMaterialized(
    _indexSetting,
    jsonEncode([
      for (final item in _indexRows()) item.toEvent().toBody(),
      for (final folder in _folders.values) folder.toEvent().toBody(),
    ]),
  );

  Iterable<CloudItem> _indexRows() sync* {
    for (final item in _items.values) {
      yield item;
      final currentCid = item.contentId;
      for (final head in _noteHeads[item.id] ?? const <CloudItem>[]) {
        if (head.contentId != currentCid) yield head;
      }
    }
  }

  Future<void> _saveClaims() => _saveMaterialized(
    _claimsSetting,
    jsonEncode([
      for (final claim in _claims.values)
        {'body': claim.toEvent().toBody(), 'author': claim.deviceId.hex},
    ]),
  );

  void _scheduleReconcile() {
    _reconcileTimer?.cancel();
    _reconcileTimer = Timer(const Duration(milliseconds: 250), () {
      unawaited(_serialized(_reconcile));
    });
  }

  Future<void> _reconcile() async {
    if (_closed) return;
    final beforeRows = _indexRows().toList();
    final beforeFolders = _folders.values.toList();
    final remote = await _sync.records();
    final mergedEvents = [
      for (final item in beforeRows) item.toEvent(),
      for (final folder in beforeFolders) folder.toEvent(),
      for (final row in remote) row.event,
    ];
    final mergedItems = foldCloudItems(mergedEvents);
    final mergedHeads = foldCloudNoteHeads(mergedEvents);
    final mergedFolders = foldCloudFolders(mergedEvents);
    final mergedClaims = foldCloudReplicaClaims([
      for (final claim in _claims.values)
        (event: claim.toEvent(), author: claim.deviceId),
      ...remote,
    ]);
    _items
      ..clear()
      ..addAll(mergedItems);
    _noteHeads
      ..clear()
      ..addAll(mergedHeads);
    _folders
      ..clear()
      ..addAll(mergedFolders);
    _claims
      ..clear()
      ..addAll(mergedClaims);
    // A metadata-only rewrite (folder move) can win the LWW row while a
    // concurrent edit advanced the note DAG past the rewritten cid. When no
    // head carries the winner's cid anymore, promote the top head — keeping
    // the winner's folder choice — so displayed content never regresses
    // behind the DAG. One round converges: the promoted row then IS a head.
    for (final entry in _noteHeads.entries) {
      final winner = _items[entry.key];
      final heads = entry.value;
      if (winner == null ||
          winner.deleted ||
          winner.kind != CloudItemKind.note ||
          heads.isEmpty ||
          heads.any((head) => head.contentId == winner.contentId)) {
        continue;
      }
      _items[entry.key] = heads.first.movedToFolder(
        winner.folderId,
        _nextTimestamp(),
      );
    }
    await _saveIndex();
    await _saveClaims();

    // Keep every unresolved note head, but scrub any prior revision that the
    // merged DAG no longer references. This handles remote merge revisions and
    // tombstones without destroying a concurrent offline branch.
    for (final previous in beforeRows) {
      if (!previous.deleted && !_cloudReferencesContent(previous.contentId)) {
        await _dropContentIfUnreferenced(previous);
      }
    }

    // Backfill rows created while this was a solo device. A row already in the
    // signed group log is not posted again, so group change notifications do
    // not create an emit loop.
    final remoteBodies = {for (final row in remote) row.event.toBody()};
    for (final item in _indexRows()) {
      if (!remoteBodies.contains(item.toEvent().toBody())) {
        _postItemBestEffort(item, local: false);
      }
    }
    for (final folder in _folders.values) {
      if (!remoteBodies.contains(folder.toEvent().toBody())) {
        _postFolderBestEffort(folder);
      }
    }
    for (final claim in _claims.values) {
      if (claim.deviceId == _sync.selfId &&
          !remoteBodies.contains(claim.toEvent().toBody())) {
        _postClaimBestEffort(claim);
      }
    }
    _emit();
    _autoReplicate();
  }

  /// A requested target folder, degraded to the root when it is not (or no
  /// longer) alive: a create/import must not fail because another device
  /// deleted the folder a moment ago.
  String? _liveFolderOrNull(String? folderId) {
    if (folderId == null) return null;
    final folder = _folders[folderId];
    return folder != null && !folder.deleted ? folderId : null;
  }

  Future<CloudItem> importContent({
    required String name,
    required int size,
    required Future<Uint8List> Function(int offset, int length) readRange,
    String? mime,
    String? folderId,
    Uint8List? thumbnail,
  }) async {
    await start();
    if (name.isEmpty || name.length > 512 || size < 0 || size > (1 << 50)) {
      throw ArgumentError('invalid cloud object name/size');
    }
    return _serialized(() async {
      final manifest = await ContentManifest.fromReader(
        name: name,
        size: size,
        readRange: readRange,
        pieceSize: ContentManifest.adaptivePieceSize(size),
        chunkBytes: _wireChunkBytes,
      );
      final manifestId = '$_manifestPrefix${manifest.contentId}';
      var createdContent = false;
      var createdManifest = false;
      CloudItem? item;
      try {
        if (!await _storage.hasFile(manifest.contentId)) {
          // The in-volume streamed layout spends one settings-index key per
          // piece. On an aged store even a small file can then hit IndexFull.
          // Below the existing atomically-deletable whole-blob ceiling, one
          // bounded read (<= 3.8 MB) is both cheaper and more index-efficient.
          // Larger objects stay piecewise and route to the encrypted on-disk
          // tier, preserving the TB-scale RAM bound.
          if (size <= kMaxStoredFileBytes) {
            final bytes = await readRange(0, size);
            if (!manifest.verifyWhole(bytes)) {
              throw StateError('source changed while importing');
            }
            await _storage.storeFile(manifest.contentId, bytes, name: name);
          } else {
            for (var piece = 0; piece < manifest.pieceCount; piece++) {
              final offset = piece * manifest.pieceSize;
              final bytes = await readRange(
                offset,
                manifest.pieceLength(piece),
              );
              if (!manifest.verifyPiece(piece, bytes)) {
                throw StateError('source changed while importing piece $piece');
              }
              await _storage.storeFilePiece(
                manifest.contentId,
                piece,
                manifest.pieceCount,
                manifest.pieceSize,
                manifest.size,
                bytes,
                name: name,
              );
            }
          }
          createdContent = true;
        }
        createdManifest = !await _storage.hasFile(manifestId);
        await _storage.storeFile(
          manifestId,
          Uint8List.fromList(utf8.encode(jsonEncode(manifest.toJson()))),
          name: 'cloud-manifest',
        );
        // Stored as its own content object, addressed by its own hash: two
        // imports of the same picture then share one preview, and it travels
        // by the same path as any other content instead of needing one of its
        // own. Oversized input is dropped rather than stored — a "preview"
        // that rivals the file it previews is not one.
        String? thumbId;
        if (thumbnail != null && thumbnail.isNotEmpty) {
          if (thumbnail.length <= maxThumbnailBytes) {
            final thumbManifest = ContentManifest.fromBytes('thumb', thumbnail);
            if (!await _storage.hasFile(thumbManifest.contentId)) {
              await _storage.storeFile(
                thumbManifest.contentId,
                thumbnail,
                name: 'cloud-thumb',
              );
            }
            thumbId = thumbManifest.contentId;
          }
        }
        final now = _nextTimestamp();
        item = CloudItem(
          id: _newId().replaceAll(RegExp('[^A-Za-z0-9_-]'), '_'),
          kind: CloudItemKind.file,
          name: name,
          contentId: manifest.contentId,
          size: size,
          mime: mime,
          createdAtMs: now,
          modifiedAtMs: now,
          revision: 1,
          deleted: false,
          folderId: _liveFolderOrNull(folderId),
          thumbContentId: thumbId,
        );
        _items[item.id] = item;
        await _saveIndex();
      } catch (_) {
        if (item != null) _items.remove(item.id);
        try {
          if (createdContent) {
            await _storage.deleteStoredFile(manifest.contentId);
          }
          if (createdManifest) await _storage.deleteStoredFile(manifestId);
          if (createdContent || createdManifest) await _storage.scrubDeleted();
        } catch (_) {}
        rethrow;
      }
      final imported = item;
      _postItemBestEffort(imported);
      try {
        await _setLocalClaim(imported, present: true);
      } catch (_) {
        // The logical row and bytes are already durable. Keep the in-memory
        // claim; reconciliation/verify retries persistence without turning a
        // successful local import into a false failure.
      }
      _emit();
      return imported;
    });
  }

  /// Create or replace one private text note. The body is an immutable
  /// content-addressed blob; the logical row advances with optimistic
  /// revision checking so an editor cannot silently overwrite a newer device
  /// update. Callers may retry against [CloudEditConflict.current] after an
  /// explicit merge choice.
  Future<CloudItem> saveTextNote({
    String? itemId,
    required String title,
    required String body,
    int? expectedRevision,
    String? expectedContentId,
    Iterable<String>? mergeParentContentIds,
    String? folderId,
  }) async {
    await start();
    final normalizedTitle = title.trim();
    final bytes = Uint8List.fromList(utf8.encode(body));
    if (normalizedTitle.isEmpty || normalizedTitle.length > 512) {
      throw ArgumentError('invalid note title');
    }
    if (bytes.length > maxTextNoteBytes) {
      throw ArgumentError('note body is too large');
    }
    return _serialized(() async {
      CloudItem? previous;
      var previousHeads = const <CloudItem>[];
      if (itemId != null) {
        previous = _items[itemId];
        if (previous == null || previous.deleted) {
          throw StateError('note no longer exists');
        }
        if (previous.kind != CloudItemKind.note) {
          throw StateError('cloud item is not a note');
        }
        if (expectedRevision == null ||
            expectedContentId == null ||
            previous.revision != expectedRevision ||
            previous.contentId != expectedContentId) {
          throw CloudEditConflict(previous);
        }
        previousHeads = noteHeads(previous);
      } else if (expectedRevision != null || expectedContentId != null) {
        throw ArgumentError('new note cannot have an expected version');
      } else if (mergeParentContentIds != null) {
        throw ArgumentError('new note cannot merge existing parents');
      }

      final manifest = ContentManifest.fromBytes(normalizedTitle, bytes);
      final availableParents = {
        for (final head in previousHeads) head.contentId!: head,
      };
      final requestedParents = mergeParentContentIds == null
          ? [if (previous?.contentId != null) previous!.contentId!]
          : mergeParentContentIds.toSet().toList();
      if (requestedParents.length > CloudItem.maxNoteParents ||
          requestedParents.any((cid) => !availableParents.containsKey(cid)) ||
          (previous != null &&
              !requestedParents.contains(previous.contentId))) {
        throw CloudEditConflict(previous!);
      }
      final encodedParents = [
        for (final cid in requestedParents)
          if (cid != manifest.contentId) cid,
      ]..sort();
      final manifestId = '$_manifestPrefix${manifest.contentId}';
      var createdContent = false;
      var createdManifest = false;
      final id = itemId ?? _newId().replaceAll(RegExp('[^A-Za-z0-9_-]'), '_');
      final now = _nextTimestamp();
      final parentRevision = availableParents.values.fold<int>(
        previous?.revision ?? 0,
        (highest, item) => item.revision > highest ? item.revision : highest,
      );
      final note = CloudItem(
        id: id,
        kind: CloudItemKind.note,
        name: normalizedTitle,
        contentId: manifest.contentId,
        size: bytes.length,
        mime: 'text/plain; charset=utf-8',
        createdAtMs: previous?.createdAtMs ?? now,
        modifiedAtMs: now,
        revision: parentRevision + 1,
        deleted: false,
        // An edit must keep the note where it lives; only a brand-new note
        // takes the caller's (still-live) target folder.
        folderId: previous != null
            ? previous.folderId
            : _liveFolderOrNull(folderId),
        parentContentIds: List.unmodifiable(encodedParents),
      );
      final oldHeads = List<CloudItem>.from(previousHeads);
      try {
        if (!await _storage.hasFile(manifest.contentId)) {
          await _storage.storeFile(
            manifest.contentId,
            bytes,
            name: normalizedTitle,
          );
          createdContent = true;
        }
        if (!await _storage.hasFile(manifestId)) {
          await _storage.storeFile(
            manifestId,
            Uint8List.fromList(utf8.encode(jsonEncode(manifest.toJson()))),
            name: 'cloud-manifest',
          );
          createdManifest = true;
        }
        _items[id] = note;
        _noteHeads[id] =
            foldCloudNoteHeads([
              for (final head in oldHeads) head.toEvent(),
              note.toEvent(),
            ])[id] ??
            [note];
        await _saveIndex();
      } catch (_) {
        if (previous == null) {
          _items.remove(id);
          _noteHeads.remove(id);
        } else {
          _items[id] = previous;
          _noteHeads[id] = oldHeads;
        }
        try {
          if (createdContent) {
            await _storage.deleteStoredFile(manifest.contentId);
          }
          if (createdManifest) await _storage.deleteStoredFile(manifestId);
          if (createdContent || createdManifest) await _storage.scrubDeleted();
        } catch (_) {}
        rethrow;
      }

      _postItemBestEffort(note);
      for (final old in oldHeads) {
        if (!_cloudReferencesContent(old.contentId)) {
          await _dropContentIfUnreferenced(old);
        }
      }
      try {
        await _setLocalClaim(note, present: true);
      } catch (_) {
        // The note row and bytes are already durable. Reconcile/verify can
        // repair a claim that could not be persisted under local pressure.
      }
      _emit();
      return note;
    });
  }

  List<CloudItem> noteHeads(CloudItem item) {
    if (item.kind != CloudItemKind.note || item.deleted) return const [];
    final heads = _noteHeads[item.id];
    if (heads == null || heads.isEmpty) return [item];
    return List.unmodifiable(heads);
  }

  Future<CloudItem?> localNoteHead(CloudItem item) async {
    if (item.kind != CloudItemKind.note || item.deleted) return null;
    for (final head in noteHeads(item)) {
      if (head.contentId != null && await _storage.hasFile(head.contentId!)) {
        return head;
      }
    }
    return null;
  }

  Future<String> loadTextNote(CloudItem item) async {
    await start();
    if (item.deleted || item.kind != CloudItemKind.note) {
      throw StateError('cloud item is not a live note');
    }
    if (item.contentId == null || item.size > maxTextNoteBytes) {
      throw StateError('invalid note content');
    }
    if (!await ensureLocal(item)) {
      throw StateError('note content is unavailable');
    }
    final bytes = await _storage.loadFile(item.contentId!);
    if (bytes == null || bytes.length != item.size) {
      throw StateError('note content is unavailable');
    }
    final manifest = ContentManifest.fromBytes(item.name, bytes);
    if (manifest.contentId != item.contentId) {
      await _setLocalClaim(item, present: false);
      throw StateError('note content failed integrity verification');
    }
    return utf8.decode(bytes, allowMalformed: false);
  }

  int _lastTimestamp = 0;
  int _nextTimestamp() {
    final now = _now().millisecondsSinceEpoch;
    _lastTimestamp = now > _lastTimestamp ? now : _lastTimestamp + 1;
    return _lastTimestamp;
  }

  Future<void> deleteItem(String itemId) async {
    await start();
    await _serialized(() async {
      final current = _items[itemId];
      if (current == null || current.deleted) return;
      final retired = current.kind == CloudItemKind.note
          ? noteHeads(current)
          : [current];
      final tombstone = current.tombstone(_nextTimestamp());
      _items[itemId] = tombstone;
      _noteHeads.remove(itemId);
      await _saveIndex();
      _postItemBestEffort(tombstone);
      for (final item in retired) {
        await _dropContentIfUnreferenced(item);
      }
      _emit();
    });
  }

  static const _maxLiveFolders = 512;

  /// Live folders, name-sorted. Folders are flat in v1 (a deliberate
  /// low-regret scope choice; the event vocabulary can grow a parent later).
  List<CloudFolder> listFolders() {
    final folders = [
      for (final folder in _folders.values)
        if (!folder.deleted) folder,
    ];
    folders.sort((a, b) {
      final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      return byName != 0 ? byName : a.id.compareTo(b.id);
    });
    return folders;
  }

  Stream<List<CloudFolder>> watchFolders() async* {
    await start();
    yield listFolders();
    await for (final _ in _changes.stream) {
      yield listFolders();
    }
  }

  /// Nearest LIVE folder on the parent chain starting at [startId] (which
  /// may itself be live), or null for the root. Dead folders are walked
  /// through, so deleting a folder lifts its contents to the closest living
  /// ancestor; a dangling id, an over-deep chain or a revisit lands at the
  /// root. Pure view-time resolution — no rows are ever rewritten.
  String? _nearestLiveAncestor(String? startId) {
    var current = startId;
    final visited = <String>{};
    while (current != null) {
      if (!visited.add(current) || visited.length > 128) return null;
      final folder = _folders[current];
      if (folder == null) return null;
      if (!folder.deleted) return current;
      current = folder.parentId;
    }
    return null;
  }

  /// Where the item renders: the nearest live ancestor of its folder chain
  /// (the folder itself while alive), otherwise the root. Resolution lives
  /// here instead of rewriting item rows on folder delete, so a delete can
  /// never LWW-clobber a concurrent edit.
  String? effectiveFolderId(CloudItem item) =>
      _nearestLiveAncestor(item.folderId);

  /// The effective display parent of every LIVE folder: its nearest live
  /// ancestor, with one deterministic exception — a cross-device merge can
  /// weave live folders into a parent CYCLE, unreachable from the root.
  /// Each such cycle is broken by promoting its smallest folder id to the
  /// root, so every device renders the same tree and no subtree can vanish.
  Map<String, String?> effectiveFolderParents() {
    final parents = <String, String?>{
      for (final folder in _folders.values)
        if (!folder.deleted) folder.id: _nearestLiveAncestor(folder.parentId),
    };
    Set<String> reachable() {
      final childrenOf = <String?, List<String>>{};
      parents.forEach(
        (id, parent) => childrenOf.putIfAbsent(parent, () => []).add(id),
      );
      final seen = <String>{};
      final queue = <String?>[null];
      while (queue.isNotEmpty) {
        for (final child in childrenOf[queue.removeLast()] ?? const []) {
          if (seen.add(child)) queue.add(child);
        }
      }
      return seen;
    }

    for (var guard = 0; guard <= parents.length; guard++) {
      final unreachable = parents.keys.toSet()..removeAll(reachable());
      if (unreachable.isEmpty) break;
      // An unreachable region contains exactly one cycle: every node in it
      // has a non-null effective parent that is itself unreachable, so a
      // walk from any member must revisit. Promote the cycle's smallest id.
      var cursor = unreachable.first;
      final trail = <String>[];
      final seen = <String>{};
      while (seen.add(cursor)) {
        trail.add(cursor);
        cursor = parents[cursor]!;
      }
      final cycle = trail.sublist(trail.indexOf(cursor));
      final promoted = cycle.reduce((a, b) => a.compareTo(b) < 0 ? a : b);
      parents[promoted] = null;
    }
    return parents;
  }

  /// Live folders rendered directly under [parentId] (null = root),
  /// name-sorted. Uses [effectiveFolderParents], so children of deleted
  /// folders and cycle members surface deterministically.
  List<CloudFolder> childFolders(String? parentId) =>
      folderChildrenIndex()[parentId] ?? const [];

  /// The whole resolved tree in one pass: effective parent → name-sorted
  /// children. Tree walks (pickers, breadcrumb building) should use this
  /// instead of calling [childFolders] per node, which would recompute the
  /// cycle-broken parent map once per visited folder.
  Map<String?, List<CloudFolder>> folderChildrenIndex() {
    final parents = effectiveFolderParents();
    final index = <String?, List<CloudFolder>>{};
    for (final folder in _folders.values) {
      if (folder.deleted) continue;
      index.putIfAbsent(parents[folder.id], () => []).add(folder);
    }
    for (final children in index.values) {
      children.sort((a, b) {
        final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
        return byName != 0 ? byName : a.id.compareTo(b.id);
      });
    }
    return index;
  }

  /// Breadcrumb chain from the root down to [folderId] (inclusive); empty
  /// when the folder is not alive.
  List<CloudFolder> folderPath(String folderId) {
    final folder = _folders[folderId];
    if (folder == null || folder.deleted) return const [];
    final parents = effectiveFolderParents();
    final path = <CloudFolder>[];
    String? current = folderId;
    while (current != null && path.length <= _folders.length) {
      final node = _folders[current];
      if (node == null || node.deleted) break;
      path.add(node);
      current = parents[current];
    }
    return path.reversed.toList();
  }

  Future<CloudFolder> createFolder(String name, {String? parentId}) async {
    await start();
    final normalized = name.trim();
    if (normalized.isEmpty || normalized.length > 512) {
      throw ArgumentError('invalid folder name');
    }
    return _serialized(() async {
      if (listFolders().length >= _maxLiveFolders) {
        throw StateError('too many folders');
      }
      final now = _nextTimestamp();
      final folder = CloudFolder(
        id: _newId().replaceAll(RegExp('[^A-Za-z0-9_-]'), '_'),
        name: normalized,
        createdAtMs: now,
        modifiedAtMs: now,
        revision: 1,
        deleted: false,
        // A parent that died between pick and write degrades to the root:
        // creation must not fail on a remote race.
        parentId: _liveFolderOrNull(parentId),
      );
      _folders[folder.id] = folder;
      await _saveIndex();
      _postFolderBestEffort(folder);
      _emit();
      return folder;
    });
  }

  Future<CloudFolder> renameFolder(String folderId, String name) async {
    await start();
    final normalized = name.trim();
    if (normalized.isEmpty || normalized.length > 512) {
      throw ArgumentError('invalid folder name');
    }
    return _serialized(() async {
      final current = _folders[folderId];
      if (current == null || current.deleted) {
        throw StateError('folder no longer exists');
      }
      final renamed = CloudFolder(
        id: current.id,
        name: normalized,
        createdAtMs: current.createdAtMs,
        modifiedAtMs: _nextTimestamp(),
        revision: current.revision + 1,
        deleted: false,
        // A rename must keep the folder where it lives.
        parentId: current.parentId,
      );
      _folders[folderId] = renamed;
      await _saveIndex();
      _postFolderBestEffort(renamed);
      _emit();
      return renamed;
    });
  }

  /// Move a folder under [parentId] (null = root). Refused into itself or
  /// its own subtree — the LOCAL guard; a cycle formed by a concurrent
  /// remote move is broken deterministically by [effectiveFolderParents].
  Future<CloudFolder> moveFolder(String folderId, String? parentId) async {
    await start();
    return _serialized(() async {
      final current = _folders[folderId];
      if (current == null || current.deleted) {
        throw StateError('folder no longer exists');
      }
      if (parentId != null) {
        final target = _folders[parentId];
        if (target == null || target.deleted) {
          throw StateError('target folder no longer exists');
        }
        if (parentId == folderId) {
          throw ArgumentError('cannot move a folder into itself');
        }
        final parents = effectiveFolderParents();
        for (
          String? cursor = parentId;
          cursor != null;
          cursor = parents[cursor]
        ) {
          if (cursor == folderId) {
            throw ArgumentError('cannot move a folder into its own subtree');
          }
        }
      }
      if (current.parentId == parentId) return current;
      final moved = CloudFolder(
        id: current.id,
        name: current.name,
        createdAtMs: current.createdAtMs,
        modifiedAtMs: _nextTimestamp(),
        revision: current.revision + 1,
        deleted: false,
        parentId: parentId,
      );
      _folders[folderId] = moved;
      await _saveIndex();
      _postFolderBestEffort(moved);
      _emit();
      return moved;
    });
  }

  /// Tombstone the folder only. Contained items keep their rows untouched and
  /// surface in the root via [effectiveFolderId] — nothing is deleted or
  /// rewritten, so this cannot race a concurrent edit of any document.
  Future<void> deleteFolder(String folderId) async {
    await start();
    await _serialized(() async {
      final current = _folders[folderId];
      if (current == null || current.deleted) return;
      final tombstone = current.tombstone(_nextTimestamp());
      _folders[folderId] = tombstone;
      await _saveIndex();
      _postFolderBestEffort(tombstone);
      _emit();
    });
  }

  /// Move one document into [folderId] (null = root). Metadata-only LWW
  /// rewrite: revision and content stay untouched.
  Future<CloudItem> moveItemToFolder(String itemId, String? folderId) async {
    await start();
    return _serialized(() async {
      final current = _items[itemId];
      if (current == null || current.deleted) {
        throw StateError('cloud item no longer exists');
      }
      if (folderId != null) {
        final folder = _folders[folderId];
        if (folder == null || folder.deleted) {
          throw StateError('folder no longer exists');
        }
      }
      if (current.folderId == folderId) return current;
      final moved = current.movedToFolder(folderId, _nextTimestamp());
      _items[itemId] = moved;
      if (moved.kind == CloudItemKind.note) {
        final oldHeads = noteHeads(current);
        _noteHeads[itemId] =
            foldCloudNoteHeads([
              for (final head in oldHeads) head.toEvent(),
              moved.toEvent(),
            ])[itemId] ??
            [moved];
      }
      await _saveIndex();
      _postItemBestEffort(moved);
      _emit();
      return moved;
    });
  }

  /// Rename one FILE row. Notes are renamed through the note editor (their
  /// title is part of the content-addressed body), so this refuses every
  /// non-file kind. Like [moveItemToFolder] this is a metadata-only LWW
  /// rewrite: revision and content stay untouched, so an open viewer keeps
  /// its optimistic check and a concurrent edit can never be clobbered.
  Future<CloudItem> renameItem(String itemId, String newName) async {
    await start();
    final normalized = newName.trim();
    if (normalized.isEmpty || normalized.length > 512) {
      throw ArgumentError('invalid cloud item name');
    }
    return _serialized(() async {
      final current = _items[itemId];
      if (current == null || current.deleted) {
        throw StateError('cloud item no longer exists');
      }
      if (current.kind != CloudItemKind.file) {
        throw StateError('only files can be renamed');
      }
      if (current.name == normalized) return current;
      final renamed = CloudItem(
        id: current.id,
        kind: current.kind,
        name: normalized,
        contentId: current.contentId,
        size: current.size,
        mime: current.mime,
        createdAtMs: current.createdAtMs,
        modifiedAtMs: _nextTimestamp(),
        revision: current.revision,
        deleted: false,
        // A rename must keep the file where it lives — and looking the same.
        folderId: current.folderId,
        thumbContentId: current.thumbContentId,
        parentContentIds: current.parentContentIds,
      );
      _items[itemId] = renamed;
      await _saveIndex();
      _postItemBestEffort(renamed);
      _emit();
      return renamed;
    });
  }

  /// Build the current listing tree of a folder for a bearer share: its live
  /// subfolders recurse, and every locally-present file under it (its manifest
  /// read from the content store) becomes a servable entry. Notes and files
  /// whose bytes are not on this device are skipped — a bearer host can only
  /// serve what it physically holds. Returns null if the folder is not alive.
  /// The stored ContentManifest JSON for a locally-present file, validated
  /// against [contentId]. Used to inline piece hashes into shared-folder
  /// metadata rows so members can verify a member-path download.
  Future<String?> manifestJsonFor(String contentId) async {
    await start();
    if (!await _storage.hasFile(contentId)) return null;
    final raw = await _storage.loadFile('$_manifestPrefix$contentId');
    if (raw == null) return null;
    try {
      final text = utf8.decode(raw);
      final json = jsonDecode(text);
      if (json is! Map) return null;
      final manifest = ContentManifest.fromJson(
        Map<String, dynamic>.from(json),
      );
      if (manifest == null || manifest.contentId != contentId) return null;
      return text;
    } catch (_) {
      return null;
    }
  }

  Future<List<CloudFolderListingEntry>?> buildFolderListingEntries(
    String folderId,
  ) async {
    await start();
    final folder = _folders[folderId];
    if (folder == null || folder.deleted) return null;
    return _folderEntries(folderId, 0);
  }

  Future<List<CloudFolderListingEntry>> _folderEntries(
    String? parentId,
    int depth,
  ) async {
    if (depth > CloudFolderListing.maxDepth) return const [];
    final entries = <CloudFolderListingEntry>[];
    for (final child in childFolders(parentId)) {
      entries.add(
        CloudFolderListingEntry.folder(
          name: child.name,
          entries: await _folderEntries(child.id, depth + 1),
        ),
      );
    }
    for (final item in _items.values) {
      if (item.deleted ||
          item.kind == CloudItemKind.note ||
          item.contentId == null ||
          effectiveFolderId(item) != parentId) {
        continue;
      }
      if (!await _storage.hasFile(item.contentId!)) continue;
      final raw = await _storage.loadFile('$_manifestPrefix${item.contentId}');
      if (raw == null) continue;
      ContentManifest? manifest;
      try {
        final json = jsonDecode(utf8.decode(raw));
        if (json is Map) {
          manifest = ContentManifest.fromJson(Map<String, dynamic>.from(json));
        }
      } catch (_) {}
      if (manifest == null || manifest.contentId != item.contentId) continue;
      entries.add(
        CloudFolderListingEntry.file(
          name: item.name,
          manifest: manifest,
          mime: item.mime,
        ),
      );
    }
    return entries;
  }

  void _postFolderBestEffort(CloudFolder folder) {
    try {
      final attempt = _sync.postFolder(folder);
      unawaited(attempt.catchError((_) => false));
    } catch (_) {
      // Folder rows are durable in the materialized index before publish;
      // reconciliation backfills them like item rows.
    }
  }

  Future<void> _dropContentIfUnreferenced(CloudItem previous) async {
    final cid = previous.contentId;
    if (cid == null) return;
    if (_cloudReferencesContent(cid)) {
      await _setLocalClaim(previous, present: false);
      return;
    }
    // A hash-CID may simultaneously belong to a personal chat, Group/Space or
    // another cloud row. No individual domain has enough information to prove
    // global unreachability. Keep payload+manifest until GroupService's single
    // fail-closed mark/sweep has observed every durable root for a full grace
    // period; this also closes the register-then-post race.
    await _setLocalClaim(previous, present: false);
  }

  bool _cloudReferencesContent(String? contentId) {
    if (contentId == null) return false;
    if (_items.values.any(
      (item) => !item.deleted && item.contentId == contentId,
    )) {
      return true;
    }
    return _noteHeads.values
        .expand((heads) => heads)
        .any((head) => !head.deleted && head.contentId == contentId);
  }

  Future<void> setProfile(CloudReplicationProfile profile) async {
    await start();
    _profile = profile;
    await _storage.putSetting(_profileSetting, profile.encode());
    _emit();
    _autoReplicate();
  }

  Future<List<Contact>> acceptedContacts() async {
    await start();
    final byId = <String, Contact>{};
    for (final conversation in await _storage.loadConversations()) {
      final contact = conversation.peer;
      if (contact.canMessage && contact.nodeId != _sync.selfId) {
        byId[contact.nodeId.hex] = contact;
      }
    }
    final contacts = byId.values.toList()
      ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    return contacts;
  }

  /// Share one existing cid as a fresh consent-gated filePost. No blob bytes
  /// cross into this method and no second local copy is created.
  Future<bool> shareWithContact(CloudItem item, NodeId peer) async {
    await start();
    final share = shareStoredContent;
    if (share == null || item.deleted || item.contentId == null) return false;
    if (!await _storage.hasFile(item.contentId!)) return false;
    return share(peer, item.contentId!);
  }

  /// Materialize a successfully downloaded public capability in the cloud
  /// index without copying its already verified content bytes.
  Future<CloudItem> adoptCapability(CloudCapability capability) async {
    await start();
    return _serialized(() async {
      final manifest = capability.manifest;
      if (!manifest.isSelfConsistent ||
          !await _storage.hasFile(manifest.contentId) ||
          !await _storage.hasFile('$_manifestPrefix${manifest.contentId}')) {
        throw StateError('capability content is not verified locally');
      }
      for (final existing in _items.values) {
        if (!existing.deleted && existing.contentId == manifest.contentId) {
          return existing;
        }
      }
      final now = _nextTimestamp();
      final item = CloudItem(
        id: _newId().replaceAll(RegExp('[^A-Za-z0-9_-]'), '_'),
        kind: CloudItemKind.file,
        name: manifest.name,
        contentId: manifest.contentId,
        size: manifest.size,
        mime: capability.mime,
        createdAtMs: now,
        modifiedAtMs: now,
        revision: capability.revision,
        deleted: false,
      );
      _items[item.id] = item;
      await _saveIndex();
      _postItemBestEffort(item);
      await _setLocalClaim(item, present: true);
      _emit();
      return item;
    });
  }

  int replicaCount(CloudItem item) => _claims.values
      .where(
        (claim) =>
            claim.itemId == item.id &&
            claim.contentId == item.contentId &&
            claim.present,
      )
      .map((claim) => claim.deviceId.hex)
      .toSet()
      .length;

  /// The item's preview bytes, if this device holds them.
  ///
  /// Null is the ordinary answer, not a failure: an item may predate previews,
  /// not be an image, or simply not have had its preview pulled here yet.
  Future<Uint8List?> loadThumbnail(CloudItem item) async {
    final id = item.thumbContentId;
    if (id == null) return null;
    return _storage.loadFile(id);
  }

  Future<bool> isLocal(CloudItem item) async =>
      item.contentId != null && await _storage.hasFile(item.contentId!);

  Future<bool> verifyItem(CloudItem item, {bool repair = false}) async {
    if (item.deleted || item.contentId == null) return false;
    final raw = await _storage.loadFile('$_manifestPrefix${item.contentId}');
    ContentManifest? manifest;
    if (raw != null) {
      try {
        final json = jsonDecode(utf8.decode(raw));
        if (json is Map<String, dynamic>) {
          manifest = ContentManifest.fromJson(json);
        } else if (json is Map) {
          manifest = ContentManifest.fromJson(Map<String, dynamic>.from(json));
        }
      } catch (_) {}
    }
    var valid =
        manifest != null &&
        manifest.contentId == item.contentId &&
        manifest.size == item.size;
    if (valid) {
      if (manifest.pieceCount == 0) {
        valid = await _storage.hasFile(item.contentId!);
      } else {
        for (var piece = 0; piece < manifest.pieceCount; piece++) {
          try {
            final bytes = await _storage.readFileRange(
              item.contentId!,
              piece * manifest.pieceSize,
              manifest.pieceLength(piece),
            );
            if (bytes == null || !manifest.verifyPiece(piece, bytes)) {
              valid = false;
              break;
            }
          } catch (_) {
            valid = false;
            break;
          }
        }
      }
    }
    await _setLocalClaim(item, present: valid);
    _emit();
    if (!valid && repair) {
      await _storage.deleteStoredFile(item.contentId!);
      await _storage.deleteStoredFile('$_manifestPrefix${item.contentId}');
      await _storage.scrubDeleted();
      await ensureLocal(item);
    }
    return valid;
  }

  Future<Map<String, bool>> verifyAll({bool repair = false}) async {
    await start();
    final result = <String, bool>{};
    for (final item in _visibleItems()) {
      final candidates = item.kind == CloudItemKind.note
          ? noteHeads(item)
          : [item];
      for (final candidate in candidates) {
        if (await _storage.hasFile(candidate.contentId!)) {
          final key = candidate.contentId == item.contentId
              ? item.id
              : '${item.id}:${candidate.contentId}';
          result[key] = await verifyItem(candidate, repair: repair);
        }
      }
    }
    return result;
  }

  /// A low-frequency scrub while the app is alive. It is deliberately kept
  /// off the unlock path: overdue/new stores wait one minute, then persist the
  /// completion timestamp and schedule the next daily pass.
  Future<void> _scheduleIntegrityCheck() async {
    _integrityTimer?.cancel();
    final raw = await _storage.getSetting(_lastVerifySetting);
    final last = int.tryParse(raw ?? '') ?? 0;
    const interval = Duration(hours: 24);
    final now = _now().millisecondsSinceEpoch;
    final dueAt = last + interval.inMilliseconds;
    final delay = last == 0 || dueAt <= now
        ? const Duration(minutes: 1)
        : Duration(milliseconds: dueAt - now);
    _integrityTimer = Timer(delay, () => unawaited(_runIntegrityCheck()));
  }

  Future<void> _runIntegrityCheck() async {
    if (_closed) return;
    try {
      await verifyAll(repair: true);
      await _storage.putSetting(
        _lastVerifySetting,
        _now().millisecondsSinceEpoch.toString(),
      );
    } finally {
      if (!_closed) await _scheduleIntegrityCheck();
    }
  }

  Future<bool> ensureLocal(CloudItem item) async {
    await start();
    if (item.deleted || item.contentId == null) return false;
    if (await _storage.hasFile(item.contentId!)) {
      final local = _claims['${item.id}|${_sync.selfId.hex}'];
      if (local != null &&
          local.present &&
          local.contentId == item.contentId &&
          local.size == item.size) {
        return true;
      }
      return verifyItem(item);
    }
    if (!_fetching.add(item.contentId!)) return true;
    try {
      final candidates = await _holdersFor(item);
      for (final holder in candidates) {
        if (await _sync.fetch(item.contentId!, holder)) return true;
      }
      return false;
    } finally {
      // The transfer continues asynchronously; completion clears this sooner.
      Timer(
        const Duration(seconds: 30),
        () => _fetching.remove(item.contentId),
      );
    }
  }

  /// Devices worth asking for [item]'s bytes: the ones that claim to hold them
  /// first, then the rest of the group. A claim is a hint, not a guarantee, so
  /// the others stay in the list behind it.
  Future<List<NodeId>> _holdersFor(CloudItem item) async {
    final members = await _sync.members();
    final claimed = _claims.values
        .where(
          (claim) =>
              claim.itemId == item.id &&
              claim.contentId == item.contentId &&
              claim.present &&
              claim.deviceId != _sync.selfId,
        )
        .map((claim) => claim.deviceId)
        .toList();
    return <NodeId>[
      ...claimed,
      for (final member in members)
        if (member != _sync.selfId && !claimed.contains(member)) member,
    ];
  }

  /// Pull an item's preview if this device does not have it.
  ///
  /// Deliberately ignores the replication profile. A device on "index only"
  /// asked to be spared the CONTENT; a preview is a few kilobytes and exists
  /// precisely so that such a device can show what it is not storing. Refusing
  /// to fetch it there would leave previews visible only where they were made,
  /// which is the one place they are least needed.
  Future<bool> ensureThumbnail(CloudItem item) async {
    await start();
    final thumbId = item.thumbContentId;
    if (item.deleted || thumbId == null) return false;
    if (await _storage.hasFile(thumbId)) return true;
    if (!_fetching.add(thumbId)) return true;
    try {
      for (final holder in await _holdersFor(item)) {
        if (await _sync.fetch(thumbId, holder)) return true;
      }
      return false;
    } finally {
      Timer(const Duration(seconds: 30), () => _fetching.remove(thumbId));
    }
  }

  Future<void> _onContentReceived(String cid) async {
    _fetching.remove(cid);
    for (final item in _indexRows()) {
      if (!item.deleted && item.contentId == cid) {
        await verifyItem(item);
      }
    }
    _emit();
  }

  Future<void> _setLocalClaim(CloudItem item, {required bool present}) async {
    final claim = CloudReplicaClaim(
      itemId: item.id,
      deviceId: _sync.selfId,
      contentId: item.contentId!,
      present: present,
      verifiedAtMs: _nextTimestamp(),
      size: item.size,
    );
    _claims[claim.key] = claim;
    await _saveClaims();
    _postClaimBestEffort(claim);
  }

  /// [local] marks a post this device initiated. The reconcile backfill also
  /// posts, but it re-publishes rows of the MERGED index — which includes what
  /// other devices wrote — so acknowledging there would quietly mark their
  /// changes as ours and the whole distinction would collapse.
  void _postItemBestEffort(CloudItem item, {bool local = true}) {
    if (local && _seen[item.id] != item.revision) {
      _seen[item.id] = item.revision;
      // Best-effort like the post itself: a shutdown between the write and this
      // flush costs at most one item's acknowledgement, and the store may
      // already be locked by then.
      unawaited(_saveSeen().catchError((_) {}));
    }
    try {
      final attempt = _sync.postItem(item);
      unawaited(attempt.catchError((_) => false));
    } catch (_) {
      // A synchronous adapter failure is handled like an async transport
      // failure. The encrypted materialized index remains the retry source.
    }
  }

  void _postClaimBestEffort(CloudReplicaClaim claim) {
    try {
      final attempt = _sync.postClaim(claim);
      unawaited(attempt.catchError((_) => false));
    } catch (_) {
      // Claims are durable locally before publish and reconcile backfills them.
    }
  }

  void _autoReplicate() {
    for (final item in _items.values) {
      if (!_profile.wants(item)) continue;
      final candidates = item.kind == CloudItemKind.note
          ? noteHeads(item)
          : [item];
      for (final candidate in candidates) {
        unawaited(ensureLocal(candidate));
      }
    }
  }

  void _emit() {
    if (!_closed) _changes.add(null);
  }

  Future<T> _serialized<T>(Future<T> Function() body) {
    final result = _mutationChain.then((_) => body());
    _mutationChain = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _reconcileTimer?.cancel();
    _integrityTimer?.cancel();
    await _syncSub?.cancel();
    await _contentSub?.cancel();
    await _sync.close();
    // A Riverpod StreamProvider may briefly keep its broadcast subscription
    // paused while its own container is being disposed. Awaiting close here
    // would deadlock provider teardown; no further events can be emitted once
    // [_closed] is set, so initiate completion without waiting on consumers.
    unawaited(_changes.close());
  }
}

final cloudServiceProvider = Provider<CloudService?>((ref) {
  final group = ref.watch(groupServiceProvider);
  if (group == null) return null;
  final messaging = ref.read(messagingServiceProvider);
  final service = CloudService(
    ref.read(storageProvider),
    GroupCloudSyncPort(group),
    contentReceived: messaging.contentReceived.map((event) => event.contentId),
    shareStoredContent: messaging.shareStoredContent,
  );
  unawaited(service.start());
  ref.onDispose(() => unawaited(service.close()));
  return service;
});

final cloudItemsProvider = StreamProvider<List<CloudItem>>((ref) {
  final service = ref.watch(cloudServiceProvider);
  return service?.watchItems() ?? Stream.value(const []);
});

final cloudFoldersProvider = StreamProvider<List<CloudFolder>>((ref) {
  final service = ref.watch(cloudServiceProvider);
  return service?.watchFolders() ?? Stream.value(const []);
});
