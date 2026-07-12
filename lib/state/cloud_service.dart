import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/ids.dart';
import '../data/storage/file_store.dart' show kMaxStoredFileBytes;
import '../data/storage/storage.dart';
import '../domain/cloud.dart';
import '../domain/content_manifest.dart';
import '../domain/device_sync.dart';
import '../domain/group_message.dart';
import 'group_service.dart';
import 'messaging.dart';
import 'providers.dart';

/// Transport/persistence edge used by [CloudService]. Keeping it narrow makes
/// the index and integrity logic testable without a Flutter engine or network.
abstract class CloudSyncPort {
  NodeId get selfId;
  Stream<void> get changes;
  Future<List<DeviceSyncRecord>> records();
  Future<bool> postItem(CloudItem item);
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
        : GroupAttachment(
            kind: 'cloud',
            dataB64: 'AA==',
            w: 1,
            h: 1,
            cid: item.contentId,
          ),
  );

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
  }) : _now = now ?? DateTime.now,
       _newId = newId ?? const Uuid().v4;

  static const _indexSetting = 'cloud.index.v1';
  static const _claimsSetting = 'cloud.claims.v1';
  static const _profileSetting = 'cloud.profile.v1';
  static const _lastVerifySetting = 'cloud.last_verify.v1';
  static const _manifestPrefix = 'mf:';
  static const _wireChunkBytes = 4096;

  final Storage _storage;
  final CloudSyncPort _sync;
  final Stream<String> contentReceived;
  final DateTime Function() _now;
  final String Function() _newId;
  final bool integrityChecks;

  final Map<String, CloudItem> _items = {};
  final Map<String, CloudReplicaClaim> _claims = {};
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
    final indexRaw = await _storage.getSetting(_indexSetting);
    if (indexRaw != null) {
      try {
        final rows = jsonDecode(indexRaw);
        if (rows is List) {
          _items.addAll(
            foldCloudItems([
              for (final row in rows)
                if (row is String) ?DeviceSyncEvent.fromBody(row),
            ]),
          );
        }
      } catch (_) {}
    }
    final claimsRaw = await _storage.getSetting(_claimsSetting);
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
  }

  Future<void> _saveIndex() => _storage.putSetting(
    _indexSetting,
    jsonEncode([for (final item in _items.values) item.toEvent().toBody()]),
  );

  Future<void> _saveClaims() => _storage.putSetting(
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
    final before = Map<String, CloudItem>.from(_items);
    final remote = await _sync.records();
    final mergedItems = foldCloudItems([
      for (final item in _items.values) item.toEvent(),
      for (final row in remote) row.event,
    ]);
    final mergedClaims = foldCloudReplicaClaims([
      for (final claim in _claims.values)
        (event: claim.toEvent(), author: claim.deviceId),
      ...remote,
    ]);
    _items
      ..clear()
      ..addAll(mergedItems);
    _claims
      ..clear()
      ..addAll(mergedClaims);
    await _saveIndex();
    await _saveClaims();

    // A remote tombstone must erase local ciphertext too. Tombstones carry no
    // cid, so use the previously materialized live row; a device that never
    // saw it cannot hold the corresponding bytes.
    for (final item in _items.values) {
      final previous = before[item.id];
      if (item.deleted && previous != null && !previous.deleted) {
        await _dropContentIfUnreferenced(previous);
      }
    }

    // Backfill rows created while this was a solo device. A row already in the
    // signed group log is not posted again, so group change notifications do
    // not create an emit loop.
    final remoteBodies = {for (final row in remote) row.event.toBody()};
    for (final item in _items.values) {
      if (!remoteBodies.contains(item.toEvent().toBody())) {
        await _postItemBestEffort(item);
      }
    }
    for (final claim in _claims.values) {
      if (claim.deviceId == _sync.selfId &&
          !remoteBodies.contains(claim.toEvent().toBody())) {
        await _postClaimBestEffort(claim);
      }
    }
    _emit();
    _autoReplicate();
  }

  Future<CloudItem> importContent({
    required String name,
    required int size,
    required Future<Uint8List> Function(int offset, int length) readRange,
    String? mime,
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
      await _postItemBestEffort(imported);
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
      final tombstone = current.tombstone(_nextTimestamp());
      _items[itemId] = tombstone;
      await _saveIndex();
      await _postItemBestEffort(tombstone);
      await _dropContentIfUnreferenced(current);
      _emit();
    });
  }

  Future<void> _dropContentIfUnreferenced(CloudItem previous) async {
    final cid = previous.contentId;
    if (cid == null) return;
    final shared = _items.values.any(
      (item) => !item.deleted && item.contentId == cid,
    );
    if (shared) {
      await _setLocalClaim(previous, present: false);
      return;
    }
    final manifestId = '$_manifestPrefix$cid';
    final hadContent = await _storage.hasFile(cid);
    final hadManifest = await _storage.hasFile(manifestId);
    if (hadContent || hadManifest) {
      await _storage.deleteStoredFile(cid);
      await _storage.deleteStoredFile(manifestId);
      await _storage.scrubDeleted();
    }
    await _setLocalClaim(previous, present: false);
  }

  Future<void> setProfile(CloudReplicationProfile profile) async {
    await start();
    _profile = profile;
    await _storage.putSetting(_profileSetting, profile.encode());
    _emit();
    _autoReplicate();
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
      if (await _storage.hasFile(item.contentId!)) {
        result[item.id] = await verifyItem(item, repair: repair);
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
      final candidates = <NodeId>[
        ...claimed,
        for (final member in members)
          if (member != _sync.selfId && !claimed.contains(member)) member,
      ];
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

  Future<void> _onContentReceived(String cid) async {
    _fetching.remove(cid);
    for (final item in _items.values) {
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
    await _postClaimBestEffort(claim);
  }

  Future<bool> _postItemBestEffort(CloudItem item) async {
    try {
      return await _sync.postItem(item);
    } catch (_) {
      return false;
    }
  }

  Future<bool> _postClaimBestEffort(CloudReplicaClaim claim) async {
    try {
      return await _sync.postClaim(claim);
    } catch (_) {
      return false;
    }
  }

  void _autoReplicate() {
    for (final item in _items.values) {
      if (_profile.wants(item)) unawaited(ensureLocal(item));
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
  );
  unawaited(service.start());
  ref.onDispose(() => unawaited(service.close()));
  return service;
});

final cloudItemsProvider = StreamProvider<List<CloudItem>>((ref) {
  final service = ref.watch(cloudServiceProvider);
  return service?.watchItems() ?? Stream.value(const []);
});
