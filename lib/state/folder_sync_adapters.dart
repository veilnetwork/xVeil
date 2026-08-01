import 'dart:io';
import 'dart:typed_data';

import '../data/folder_scan.dart';
import '../domain/cloud.dart';
import '../domain/folder_sync.dart';
import 'cloud_service.dart';
import '../data/range_sources.dart';
import '../domain/range_source.dart';
import 'folder_sync_engine.dart';

/// The path a mirrored file may occupy under a sync root, or null if it may
/// not occupy one at all.
///
/// Mirror paths are built from CLOUD ITEM NAMES, and a cloud item can be
/// created by any device linked to the account — including one that has been
/// compromised. Nothing upstream constrains a name to a single path component,
/// so `../../.ssh/authorized_keys` arrives here as an ordinary string and used
/// to be concatenated straight into `File('$root/$path')`. The write is
/// temp-then-rename, so it would have landed atomically on whatever it hit.
///
/// Rejected, component by component, rather than sanitised: silently rewriting
/// a hostile name into a nearby legal one still creates a file the user never
/// asked for, and leaves the mirror disagreeing with the cloud about where
/// that item lives.
///
///  * an absolute path, a Windows drive (`C:`) or a UNC prefix — it is not
///    relative to anything, let alone to this root;
///  * `.` and `..` in any position, and an empty component (`a//b`);
///  * a separator INSIDE a component, which is how a name smuggles depth;
///  * anything that, once joined, does not resolve back inside the root —
///    the belt to the component check's braces, and the only part that also
///    catches a symlinked directory pointing outward.
String? mirrorPathWithin(String root, String path) {
  if (path.isEmpty) return null;
  // Windows accepts both separators; normalise before splitting so a
  // backslash cannot hide a component boundary from the checks below.
  final normalised = path.replaceAll('\\', '/');
  if (normalised.startsWith('/')) return null; // absolute
  if (normalised.length >= 2 && normalised[1] == ':') return null; // drive
  final parts = normalised.split('/');
  for (final part in parts) {
    if (part.isEmpty || part == '.' || part == '..') return null;
  }
  final joined = '$root/${parts.join('/')}';
  // Canonical containment. `..` is already gone, so this exists to catch what
  // the string check cannot see: a component that is a symlink out of the
  // tree. Compared with a trailing separator so `/roots` does not pass as a
  // child of `/root`.
  final rootReal = Directory(root).absolute.path;
  final prefix = rootReal.endsWith('/') ? rootReal : '$rootReal/';
  if (!File(joined).absolute.path.startsWith(prefix)) return null;
  return joined;
}

/// [FolderSyncCloud] over the real [CloudService].
///
/// Only FILES are mirrored. A note carries a revision DAG that a folder cannot
/// represent — writing one out as a text file and reading it back would
/// collapse its branches into whatever the disk happened to hold, which is the
/// silent conflict resolution the whole design refuses.
class CloudServiceFolderSync implements FolderSyncCloud {
  CloudServiceFolderSync(this._cloud);

  final CloudService _cloud;

  @override
  Future<List<RemoteFile>> list(String? folderId) async {
    final paths = _folderPaths(folderId);
    final files = <RemoteFile>[];
    for (final item in await _cloud.listItems()) {
      if (item.deleted || item.kind != CloudItemKind.file) continue;
      final cid = item.contentId;
      if (cid == null) continue;
      final prefix = paths[item.folderId];
      if (prefix == null) continue; // outside this pair's subtree
      files.add(
        RemoteFile(
          path: prefix.isEmpty ? item.name : '$prefix/${item.name}',
          itemId: item.id,
          contentId: cid,
          size: item.size,
          modifiedAtMs: item.modifiedAtMs,
        ),
      );
    }
    return files;
  }

  @override
  Future<RemoteFile> upload({
    required String path,
    required String? folderId,
    required String? existingItemId,
    required int size,
    required Future<Uint8List> Function(int offset, int length) readRange,
  }) async {
    final segments = path.split('/');
    final name = segments.removeLast();
    final parent = await _ensureFolderChain(folderId, segments);

    // The reader is passed straight through: the cloud has always chunked its
    // own writes, and the adapter used to defeat that by materialising the
    // file just to hand back slices of the copy.
    final item = existingItemId == null
        ? await _cloud.importContent(
            name: name,
            size: size,
            readRange: readRange,
            folderId: parent,
          )
        : await _cloud.replaceContent(
            itemId: existingItemId,
            size: size,
            readRange: readRange,
          );
    return RemoteFile(
      path: path,
      itemId: item.id,
      contentId: item.contentId!,
      size: item.size,
      modifiedAtMs: item.modifiedAtMs,
    );
  }

  @override
  Future<RangeSource?> openDownload(String itemId) async {
    final item = (await _cloud.listItems()).where((i) => i.id == itemId);
    if (item.isEmpty) return null;
    final target = item.first;
    // The bytes may live on another device: ask for them before reading, and
    // let a miss be a miss — the engine simply tries again next pass rather
    // than writing a truncated file.
    if (!await _cloud.ensureLocal(target)) return null;
    return RangeSource(
      size: target.size,
      read: (offset, length) =>
          _cloud.readContentRange(target, offset, length),
    );
  }

  @override
  Future<void> delete(String itemId) => _cloud.deleteItem(itemId);

  @override
  Future<void> rename(String itemId, String path) async {
    final segments = path.split('/');
    final name = segments.removeLast();
    final items = (await _cloud.listItems()).where((i) => i.id == itemId);
    if (items.isEmpty) return;
    final current = items.first;
    final parent = await _ensureFolderChain(_rootOf(current), segments);
    if (current.folderId != parent) {
      await _cloud.moveItemToFolder(itemId, parent);
    }
    if (current.name != name) await _cloud.renameItem(itemId, name);
  }

  /// The pair's root as seen from an item already inside it: walking up from
  /// the item is what keeps a rename inside the pair rather than relocating
  /// the file to the cloud root.
  String? _rootOf(CloudItem item) {
    final folderId = item.folderId;
    if (folderId == null) return null;
    final chain = _cloud.folderPath(folderId);
    return chain.isEmpty ? null : chain.first.id;
  }

  /// folderId -> path relative to [root], for [root] and everything under it.
  Map<String?, String> _folderPaths(String? root) {
    final folders = _cloud.listFolders();
    final byId = {for (final folder in folders) folder.id: folder};
    final paths = <String?, String>{root: ''};
    for (final folder in folders) {
      final segments = <String>[];
      String? cursor = folder.id;
      var reachedRoot = false;
      // Bounded by the folder count: a cycle in the parent chain would
      // otherwise hang the scan, and a cycle is cheap for a remote peer to
      // create.
      for (var hops = 0; hops <= folders.length && cursor != null; hops++) {
        if (cursor == root) {
          reachedRoot = true;
          break;
        }
        final node = byId[cursor];
        if (node == null || node.deleted) break;
        segments.insert(0, node.name);
        cursor = node.parentId;
      }
      if (cursor == null && root == null) reachedRoot = true;
      if (reachedRoot) paths[folder.id] = segments.join('/');
    }
    return paths;
  }

  Future<String?> _ensureFolderChain(
    String? root,
    List<String> segments,
  ) async {
    var parent = root;
    for (final segment in segments) {
      if (segment.isEmpty) continue;
      final existing = _cloud
          .childFolders(parent)
          .where((f) => !f.deleted && f.name == segment);
      parent = existing.isNotEmpty
          ? existing.first.id
          : (await _cloud.createFolder(segment, parentId: parent)).id;
    }
    return parent;
  }
}

/// [FolderSyncDisk] over the real file system.
/// Bytes moved per hop when mirroring a file to or from disk. Bounds the peak
/// at one chunk rather than one file.
const int kFolderSyncChunkBytes = 256 * 1024;

class LocalFolderSyncDisk implements FolderSyncDisk {
  const LocalFolderSyncDisk();

  @override
  Future<FolderScan> scan(String root) => scanFolder(Directory(root));

  @override
  Future<RangeSource?> openRead(String root, String path) async {
    final resolved = mirrorPathWithin(root, path);
    if (resolved == null) return null;
    return fileRangeSource(resolved);
  }

  /// Written to a sibling and then renamed.
  ///
  /// A crash halfway through a direct write leaves a truncated file, and the
  /// next scan reads that as the user having edited it — the mirror would then
  /// faithfully upload the damage over the good copy in the cloud. The rename
  /// is atomic on every platform this runs on.
  @override
  Future<void> writeFrom(String root, String path, RangeSource source) async {
    final resolved = mirrorPathWithin(root, path);
    if (resolved == null) {
      // Refuse rather than throw: one hostile name must not stop the pass from
      // mirroring every other file, and a throw here would be reported to the
      // user as "sync failed" with nothing they can act on.
      return;
    }
    final file = File(resolved);
    await file.parent.create(recursive: true);
    final temp = File('${file.path}$kPartialSuffix');
    final sink = await temp.open(mode: FileMode.writeOnly);
    var written = 0;
    try {
      await for (final chunk in rangeChunks(
        source,
        0,
        source.size,
        chunkBytes: kFolderSyncChunkBytes,
      )) {
        await sink.writeFrom(chunk);
        written += chunk.length;
      }
      await sink.flush();
    } on RangeSourceUnreadable {
      // The remote copy stopped being readable. Leave the `.part` behind
      // unrenamed and bail: the real path keeps whatever it had, and the next
      // pass retries. Renaming a short file would publish a truncated one that
      // the following scan reads as a deliberate user edit and faithfully
      // uploads over the good copy.
      return;
    } finally {
      await sink.close();
    }
    // Deliberately a second gate: the loop already returns without renaming on
    // a dead source, but that makes publishing depend on a `return` staying a
    // `return`. Turn it into a `break` — a plausible refactor — and this is the
    // only thing left standing between a truncated download and the mirrored
    // path. Verified by weakening: dropping either alone keeps the tests green,
    // dropping both turns them red.
    if (written == source.size) await temp.rename(file.path);
  }

  @override
  Future<void> remove(String root, String path) async {
    final resolved = mirrorPathWithin(root, path);
    if (resolved == null) return;
    final file = File(resolved);
    if (file.existsSync()) await file.delete();
    // Prune the directories the file left behind, but never the pair's root:
    // a mirror that removes the folder the user pointed at looks like the
    // feature uninstalled itself.
    var dir = file.parent;
    while (dir.path.length > root.length && dir.existsSync()) {
      if (dir.listSync().isNotEmpty) break;
      await dir.delete();
      dir = dir.parent;
    }
  }

  @override
  Future<LocalFile?> stat(String root, String path) async {
    final file = File('$root/$path');
    if (!file.existsSync()) return null;
    final stat = file.statSync();
    return LocalFile(
      path: path,
      size: stat.size,
      modifiedAtMs: stat.modified.millisecondsSinceEpoch,
    );
  }
}
