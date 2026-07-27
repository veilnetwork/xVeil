/// Three-way reconciliation for mirroring a local folder against the cloud.
///
/// Pure decision logic: it takes three pictures of the world and returns what
/// should happen. No file system, no network, no clock — so every case below,
/// including the ones that are hard to stage live (a folder that went offline,
/// two devices editing the same file), is an ordinary unit test.
///
/// The three pictures are what makes this a MERGE rather than a copy:
///   * [base]   — what the last successful sync left behind,
///   * [local]  — the folder as it is now,
///   * [remote] — the cloud index as it is now.
/// Without [base] you cannot tell "the other side added it" from "this side
/// deleted it", and a two-way comparison has to guess. Guessing is how sync
/// tools delete people's files.
///
/// Behaviour settled by the product owner:
///   * a local delete DOES remove the cloud copy, guarded by the mass-deletion
///     brake below;
///   * a genuine conflict is ASKED, never resolved automatically — so an
///     unanswered one has to survive between passes without blocking the rest
///     of the folder, which is what [pendingConflicts] is for;
///   * the unit of configuration is a PAIR: one local folder mapped to one
///     folder in the cloud, and a device may have several.
library;

/// One configured mapping: a local folder mirrored to a cloud folder.
class FolderSyncPair {
  const FolderSyncPair({
    required this.id,
    required this.localPath,
    this.cloudFolderId,
    this.deletePropagates = true,
  });

  final String id;
  final String localPath;

  /// Null means the root of the cloud storage.
  final String? cloudFolderId;

  final bool deletePropagates;
}

/// One file as the local folder currently presents it.
class LocalFile {
  const LocalFile({
    required this.path,
    required this.size,
    required this.modifiedAtMs,
    this.contentId,
  });

  final String path;
  final int size;
  final int modifiedAtMs;

  /// Filled in only when the caller has already hashed the bytes. Cheap
  /// scans leave it null and fall back to size+mtime, which is what every
  /// mainstream sync tool does; the hash is what makes a rename recognisable
  /// rather than a delete followed by an upload.
  final String? contentId;
}

/// One file as the cloud index currently presents it.
class RemoteFile {
  const RemoteFile({
    required this.path,
    required this.itemId,
    required this.contentId,
    required this.size,
    required this.modifiedAtMs,
  });

  final String path;
  final String itemId;
  final String contentId;
  final int size;
  final int modifiedAtMs;
}

/// What the previous successful sync recorded for a path. A path present here
/// and absent from a side means that side deleted it.
class SyncedFile {
  const SyncedFile({
    required this.path,
    required this.contentId,
    required this.size,
    required this.localModifiedAtMs,
  });

  final String path;
  final String contentId;
  final int size;

  /// The local mtime AS OF the last sync. Comparing against it is what makes
  /// "the user touched this file" detectable without re-hashing every file on
  /// every pass.
  final int localModifiedAtMs;
}

enum SyncActionKind {
  upload,
  download,
  deleteLocal,
  deleteRemote,
  /// Both sides changed. Never resolved silently here — see [FolderSyncPlan].
  conflict,
  /// Same content, new path: a move, not a re-upload.
  renameRemote,
}

class SyncAction {
  const SyncAction(this.kind, this.path, {this.fromPath, this.itemId});

  final SyncActionKind kind;
  final String path;

  /// Set on [SyncActionKind.renameRemote]: where the content used to live.
  final String? fromPath;

  /// Set whenever the action addresses an existing cloud item.
  final String? itemId;

  @override
  String toString() =>
      '${kind.name}($path${fromPath == null ? '' : ' <- $fromPath'})';

  @override
  bool operator ==(Object other) =>
      other is SyncAction &&
      other.kind == kind &&
      other.path == path &&
      other.fromPath == fromPath;

  @override
  int get hashCode => Object.hash(kind, path, fromPath);
}

/// The outcome of one reconciliation.
class FolderSyncPlan {
  const FolderSyncPlan({required this.actions, required this.refusedReason});

  final List<SyncAction> actions;

  /// Non-null when the plan was REFUSED wholesale. The actions list is empty
  /// in that case: a refusal is not a partial apply.
  final String? refusedReason;

  bool get isRefused => refusedReason != null;
}

/// How much of the tracked set may disappear locally in one pass before the
/// plan is refused instead of applied.
///
/// The failure this exists for is not hypothetical and not rare: an unmounted
/// drive, a permission change, a sync folder pointed at the wrong path, or a
/// half-finished restore all present as "every file is gone". A two-way
/// mirror that trusts that observation deletes the user's cloud copy too,
/// which is precisely when they need it. So a mass disappearance is treated as
/// evidence the SCAN is wrong, not the folder — the pass stops and says so.
const double kMassDeletionBrake = 0.5;

/// Below this many tracked files the brake is not applied.
///
/// A proportion computed over one or two files is noise, not evidence: renaming
/// the only file in a folder is "100% vanished" and emptying a two-file folder
/// is an ordinary thing to do on purpose. The brake exists for the case where
/// the SIZE of the loss is itself the signal.
const int kMassDeletionFloor = 4;

/// Reconcile the three pictures into a plan.
///
/// [deletePropagates] is the user's call: with it off, a file removed on one
/// side is simply re-fetched from the other on the next pass, which is the
/// conservative reading of "sync" and the safe default for a first release.
FolderSyncPlan planFolderSync({
  required Iterable<SyncedFile> base,
  required Iterable<LocalFile> local,
  required Iterable<RemoteFile> remote,
  bool deletePropagates = true,
  double massDeletionBrake = kMassDeletionBrake,
  Set<String> pendingConflicts = const {},
}) {
  final baseByPath = {for (final f in base) f.path: f};
  final localByPath = {for (final f in local) f.path: f};
  final remoteByPath = {for (final f in remote) f.path: f};

  final actions = <SyncAction>[];
  final paths = <String>{
    ...baseByPath.keys,
    ...localByPath.keys,
    ...remoteByPath.keys,
  }..removeWhere((p) => p.isEmpty);

  // A rename shows up as one path losing content another path gained. Match
  // them by content id so the cloud is told to MOVE rather than to re-upload
  // bytes it already holds. Done BEFORE the brake below: a renamed file has
  // not disappeared, and counting it as a loss would refuse to sync a folder
  // someone simply reorganised.
  final movedInto = <String, String>{}; // new path -> old path
  for (final path in paths) {
    final localFile = localByPath[path];
    if (localFile == null ||
        remoteByPath.containsKey(path) ||
        baseByPath.containsKey(path)) {
      continue; // only a genuinely NEW local path can be a rename target
    }
    final cid = localFile.contentId;
    if (cid == null) continue;
    for (final entry in baseByPath.entries) {
      if (entry.value.contentId == cid &&
          !localByPath.containsKey(entry.key) &&
          remoteByPath.containsKey(entry.key)) {
        movedInto[path] = entry.key;
        break;
      }
    }
  }
  final movedFrom = movedInto.values.toSet();

  // The brake looks only at paths we were tracking: files the user never
  // synced cannot vanish, and a first-ever pass (empty base) can never trip it.
  if (deletePropagates && baseByPath.length >= kMassDeletionFloor) {
    final vanished = baseByPath.keys
        .where(
          (path) => !localByPath.containsKey(path) && !movedFrom.contains(path),
        )
        .length;
    if (vanished / baseByPath.length > massDeletionBrake) {
      return FolderSyncPlan(
        actions: const [],
        refusedReason:
            'refusing to mirror the disappearance of $vanished of '
            '${baseByPath.length} tracked files — the folder looks '
            'unavailable rather than emptied',
      );
    }
  }

  for (final path in paths.toList()..sort()) {
    if (movedFrom.contains(path)) continue; // handled at the destination
    // A conflict the user has not answered yet. Left strictly alone: asking
    // again every pass is nagging, and picking a side while they think is the
    // silent overwrite that asking was meant to avoid. Its neighbours keep
    // syncing — one undecided file must not freeze the folder.
    if (pendingConflicts.contains(path)) continue;
    final was = baseByPath[path];
    final here = localByPath[path];
    final there = remoteByPath[path];

    if (movedInto.containsKey(path)) {
      actions.add(
        SyncAction(
          SyncActionKind.renameRemote,
          path,
          fromPath: movedInto[path],
          itemId: remoteByPath[movedInto[path]]?.itemId,
        ),
      );
      continue;
    }

    final localChanged = was == null
        ? here != null
        : here != null &&
              (here.size != was.size ||
                  here.modifiedAtMs != was.localModifiedAtMs);
    final remoteChanged = was == null
        ? there != null
        : there != null && there.contentId != was.contentId;
    final localGone = was != null && here == null;
    final remoteGone = was != null && there == null;

    if (here == null && there == null) continue; // gone from both: forget it

    if (localGone && !remoteChanged) {
      if (deletePropagates) {
        actions.add(
          SyncAction(SyncActionKind.deleteRemote, path, itemId: there?.itemId),
        );
      } else {
        actions.add(
          SyncAction(SyncActionKind.download, path, itemId: there?.itemId),
        );
      }
      continue;
    }
    if (remoteGone && !localChanged) {
      actions.add(
        deletePropagates
            ? SyncAction(SyncActionKind.deleteLocal, path)
            : SyncAction(SyncActionKind.upload, path),
      );
      continue;
    }
    // One side deleted while the other edited. The edit is the intentional,
    // information-bearing act; deletion of a file someone else was working on
    // is the accident. Resurrect.
    if (localGone && remoteChanged) {
      actions.add(
        SyncAction(SyncActionKind.download, path, itemId: there.itemId),
      );
      continue;
    }
    if (remoteGone && localChanged) {
      actions.add(SyncAction(SyncActionKind.upload, path));
      continue;
    }

    if (localChanged && remoteChanged) {
      // Identical edits on both sides are not a conflict, just a coincidence
      // (or the same file arriving by two routes).
      if (here.contentId != null && here.contentId == there.contentId) {
        continue;
      }
      actions.add(
        SyncAction(SyncActionKind.conflict, path, itemId: there.itemId),
      );
      continue;
    }
    if (localChanged) {
      actions.add(
        SyncAction(SyncActionKind.upload, path, itemId: there?.itemId),
      );
      continue;
    }
    if (remoteChanged) {
      actions.add(
        SyncAction(SyncActionKind.download, path, itemId: there.itemId),
      );
    }
  }
  return FolderSyncPlan(actions: actions, refusedReason: null);
}
