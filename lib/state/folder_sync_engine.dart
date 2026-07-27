import 'dart:typed_data';

import '../data/folder_scan.dart';
import '../data/storage/folder_sync_store.dart';
import '../domain/folder_sync.dart';

/// What one sync pass needs from the cloud, and nothing more.
///
/// A narrow port rather than CloudService itself: the engine's job is the
/// order of operations and what happens when one fails, and both are far
/// easier to pin against five methods than against a service with a hundred.
abstract class FolderSyncCloud {
  /// Every file under the pair's cloud folder, keyed by path RELATIVE to it.
  Future<List<RemoteFile>> list(String? folderId);

  /// Create or replace the cloud copy of [path], returning the row the cloud
  /// now holds.
  ///
  /// It returns the ROW, not just an id, because the engine has to record the
  /// resulting CONTENT id: writing anything else into the base makes every
  /// later pass believe the cloud changed under it, which turns a quiet folder
  /// into an endless argument between the two sides.
  ///
  /// [existingItemId] is the item this path already maps to. Replacing its
  /// content in place matters: minting a fresh item on every edit would break
  /// the replica claims, the version history and any share link pointing at
  /// it.
  Future<RemoteFile> upload({
    required String path,
    required String? folderId,
    required String? existingItemId,
    required Uint8List bytes,
  });

  Future<Uint8List?> download(String itemId);

  Future<void> delete(String itemId);

  /// Move/rename an existing item to [path] within the pair's folder.
  Future<void> rename(String itemId, String path);
}

/// What one sync pass needs from the local folder.
abstract class FolderSyncDisk {
  Future<FolderScan> scan(String root);
  Future<Uint8List?> read(String root, String path);
  Future<void> write(String root, String path, Uint8List bytes);
  Future<void> remove(String root, String path);

  /// Size and mtime AFTER a write, so the base records what is actually on
  /// disk rather than what we intended to put there.
  Future<LocalFile?> stat(String root, String path);
}

/// The outcome of one pass, for the UI and the logs.
class FolderSyncReport {
  const FolderSyncReport({
    required this.applied,
    required this.failed,
    required this.conflicts,
    this.refusedReason,
  });

  final List<SyncAction> applied;

  /// Actions that threw. Their paths are deliberately NOT written into the
  /// base: a failed upload recorded as synced would look, next pass, like the
  /// cloud had deleted it.
  final List<(SyncAction, Object)> failed;

  /// Paths now waiting for the user to choose a side.
  final Set<String> conflicts;

  final String? refusedReason;

  bool get isRefused => refusedReason != null;
}

/// Runs one reconciliation pass for one pair.
class FolderSyncEngine {
  /// Positional because Dart forbids a private NAMED parameter, and these
  /// fields are internal: (cloud, disk, store, clock).
  FolderSyncEngine(this._cloud, this._disk, this._store, this._now);

  final FolderSyncCloud _cloud;
  final FolderSyncDisk _disk;
  final FolderSyncStore _store;
  final int Function() _now;

  Future<FolderSyncReport> runOnce(FolderSyncPair pair) async {
    final state = await _store.state(pair.id);
    final scan = await _disk.scan(pair.localPath);

    // A scan that could not see everything must never let the differ conclude
    // that the unseen files were deleted. Both of these look identical to a
    // real deletion from the differ's side, so the decision is taken here,
    // where the difference is still known.
    final trustworthy = !scan.truncated && scan.unreadable.isEmpty;
    final remote = await _cloud.list(pair.cloudFolderId);

    final plan = planFolderSync(
      base: state.base,
      local: scan.files,
      remote: remote,
      deletePropagates: pair.deletePropagates && trustworthy,
      pendingConflicts: state.pendingConflicts,
    );

    if (plan.isRefused) {
      await _store.saveState(
        pair.id,
        FolderSyncState(
          base: state.base,
          pendingConflicts: state.pendingConflicts,
          lastPassAtMs: _now(),
          lastRefusal: plan.refusedReason,
        ),
      );
      return FolderSyncReport(
        applied: const [],
        failed: const [],
        conflicts: state.pendingConflicts,
        refusedReason: plan.refusedReason,
      );
    }

    final base = {for (final file in state.base) file.path: file};
    final localByPath = {for (final file in scan.files) file.path: file};
    final remoteByPath = {for (final file in remote) file.path: file};
    final applied = <SyncAction>[];
    final failed = <(SyncAction, Object)>[];
    final conflicts = {...state.pendingConflicts};

    for (final action in plan.actions) {
      try {
        switch (action.kind) {
          case SyncActionKind.conflict:
            // Recorded, never resolved here. The user picks a side; until then
            // the differ leaves this path alone.
            conflicts.add(action.path);
          case SyncActionKind.upload:
            final bytes = await _disk.read(pair.localPath, action.path);
            if (bytes == null) continue; // vanished mid-pass: next pass sees it
            final stored = await _cloud.upload(
              path: action.path,
              folderId: pair.cloudFolderId,
              existingItemId:
                  action.itemId ?? remoteByPath[action.path]?.itemId,
              bytes: bytes,
            );
            final stat = await _disk.stat(pair.localPath, action.path);
            base[action.path] = SyncedFile(
              path: action.path,
              contentId: stored.contentId,
              size: stat?.size ?? bytes.length,
              localModifiedAtMs: stat?.modifiedAtMs ?? _now(),
            );
            applied.add(action);
          case SyncActionKind.download:
            final id = action.itemId;
            if (id == null) continue;
            final bytes = await _cloud.download(id);
            if (bytes == null) continue; // content not here yet; try next pass
            await _disk.write(pair.localPath, action.path, bytes);
            final stat = await _disk.stat(pair.localPath, action.path);
            base[action.path] = SyncedFile(
              path: action.path,
              contentId: remoteByPath[action.path]?.contentId ?? '',
              size: stat?.size ?? bytes.length,
              localModifiedAtMs: stat?.modifiedAtMs ?? _now(),
            );
            applied.add(action);
          case SyncActionKind.deleteLocal:
            await _disk.remove(pair.localPath, action.path);
            base.remove(action.path);
            applied.add(action);
          case SyncActionKind.deleteRemote:
            final id = action.itemId ?? remoteByPath[action.path]?.itemId;
            if (id != null) await _cloud.delete(id);
            base.remove(action.path);
            applied.add(action);
          case SyncActionKind.renameRemote:
            final id = action.itemId;
            if (id == null) continue;
            await _cloud.rename(id, action.path);
            final from = action.fromPath;
            final was = from == null ? null : base.remove(from);
            final stat = await _disk.stat(pair.localPath, action.path);
            base[action.path] = SyncedFile(
              path: action.path,
              contentId: was?.contentId ?? '',
              size: stat?.size ?? was?.size ?? 0,
              localModifiedAtMs:
                  stat?.modifiedAtMs ?? localByPath[action.path]?.modifiedAtMs ?? _now(),
            );
            applied.add(action);
        }
      } catch (error) {
        // One file's failure is not the pass's failure. Its base row is left
        // exactly as it was, so nothing later reads the failure as a deletion.
        failed.add((action, error));
      }
    }

    await _store.saveState(
      pair.id,
      FolderSyncState(
        base: base.values.toList(),
        pendingConflicts: conflicts,
        lastPassAtMs: _now(),
      ),
    );
    return FolderSyncReport(
      applied: applied,
      failed: failed,
      conflicts: conflicts,
    );
  }

  /// The user picked a side. Clearing the path lets the next pass plan it
  /// again, from whatever the two sides look like by then.
  Future<void> resolveConflict(String pairId, String path) async {
    final state = await _store.state(pairId);
    if (!state.pendingConflicts.contains(path)) return;
    await _store.saveState(
      pairId,
      FolderSyncState(
        base: state.base,
        pendingConflicts: {...state.pendingConflicts}..remove(path),
        lastPassAtMs: state.lastPassAtMs,
        lastRefusal: state.lastRefusal,
      ),
    );
  }
}
