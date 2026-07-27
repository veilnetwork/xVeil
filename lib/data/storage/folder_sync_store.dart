import 'dart:convert';
import 'dart:typed_data';

import '../../domain/folder_sync.dart';
import 'storage.dart';

/// Everything a folder-sync pair needs to remember between passes.
class FolderSyncState {
  const FolderSyncState({
    required this.base,
    required this.pendingConflicts,
    this.lastPassAtMs,
    this.lastRefusal,
  });

  static const empty = FolderSyncState(base: [], pendingConflicts: {});

  /// What the last successful pass left behind, per path.
  final List<SyncedFile> base;

  /// Paths whose conflict the user has not answered yet.
  final Set<String> pendingConflicts;

  final int? lastPassAtMs;

  /// Why the last pass refused, if it did — kept so the reason can be shown
  /// instead of the folder just appearing to do nothing.
  final String? lastRefusal;
}

/// Persists sync pairs and their state inside the encrypted container.
///
/// The base picture is written to the CHUNKED FILE STORE, not to a setting.
/// A folder with a few thousand files produces a record far past the ~2-3 KiB
/// a single setting record holds, and this project has already been bitten
/// three times by that limit — each time as a deferred PayloadTooLarge that
/// closed-loop tests never saw, because the in-memory fake enforces no cap.
class FolderSyncStore {
  FolderSyncStore(this._storage);

  final Storage _storage;

  static const _pairsKey = 'foldersync.pairs.v1';
  static String _stateKey(String pairId) => 'foldersync.state.v1:$pairId';

  Future<List<FolderSyncPair>> pairs() async {
    final raw = await _read(_pairsKey);
    if (raw == null) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final row in decoded)
          if (row is Map) ?_pairFromJson(row),
      ];
    } catch (_) {
      // A corrupt record must not brick the feature: an empty list means "no
      // folders configured", which syncs nothing and destroys nothing.
      return const [];
    }
  }

  Future<void> savePairs(List<FolderSyncPair> pairs) => _write(
    _pairsKey,
    jsonEncode([
      for (final pair in pairs)
        {
          'id': pair.id,
          'local': pair.localPath,
          if (pair.cloudFolderId != null) 'folder': pair.cloudFolderId,
          'del': pair.deletePropagates,
        },
    ]),
  );

  /// The remembered state of [pairId].
  ///
  /// An unreadable record degrades to [FolderSyncState.empty] rather than
  /// throwing. Losing the base is not dangerous in the safe direction: with no
  /// base every file reads as new, so the next pass uploads and downloads but
  /// can never infer a deletion.
  Future<FolderSyncState> state(String pairId) async {
    final raw = await _read(_stateKey(pairId));
    if (raw == null) return FolderSyncState.empty;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return FolderSyncState.empty;
      final rows = decoded['base'];
      return FolderSyncState(
        base: [
          if (rows is List)
            for (final row in rows)
              if (row is Map) ?_syncedFromJson(row),
        ],
        pendingConflicts: {
          for (final path in (decoded['conflicts'] as List? ?? const []))
            if (path is String) path,
        },
        lastPassAtMs: decoded['at'] is int ? decoded['at'] as int : null,
        lastRefusal: decoded['refused'] is String
            ? decoded['refused'] as String
            : null,
      );
    } catch (_) {
      return FolderSyncState.empty;
    }
  }

  Future<void> saveState(String pairId, FolderSyncState state) => _write(
    _stateKey(pairId),
    jsonEncode({
      'base': [
        for (final file in state.base)
          {
            'p': file.path,
            'c': file.contentId,
            's': file.size,
            'm': file.localModifiedAtMs,
          },
      ],
      'conflicts': state.pendingConflicts.toList()..sort(),
      if (state.lastPassAtMs != null) 'at': state.lastPassAtMs,
      if (state.lastRefusal != null) 'refused': state.lastRefusal,
    }),
  );

  Future<void> forget(String pairId) => _write(_stateKey(pairId), '');

  Future<String?> _read(String key) async {
    final bytes = await _storage.loadFile(key);
    if (bytes == null || bytes.isEmpty) return null;
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(String key, String value) =>
      _storage.storeFile(key, Uint8List.fromList(utf8.encode(value)));

  static FolderSyncPair? _pairFromJson(Map row) {
    final id = row['id'];
    final local = row['local'];
    if (id is! String || id.isEmpty || local is! String || local.isEmpty) {
      return null;
    }
    final folder = row['folder'];
    return FolderSyncPair(
      id: id,
      localPath: local,
      cloudFolderId: folder is String && folder.isNotEmpty ? folder : null,
      deletePropagates: row['del'] != false,
    );
  }

  static SyncedFile? _syncedFromJson(Map row) {
    final path = row['p'];
    final cid = row['c'];
    final size = row['s'];
    final mtime = row['m'];
    if (path is! String || path.isEmpty) return null;
    if (cid is! String || size is! int || mtime is! int) return null;
    return SyncedFile(
      path: path,
      contentId: cid,
      size: size,
      localModifiedAtMs: mtime,
    );
  }
}
