import 'dart:io';
import 'dart:typed_data';

import '../data/folder_scan.dart';
import '../domain/cloud.dart';
import '../domain/folder_sync.dart';
import 'cloud_service.dart';
import 'folder_sync_engine.dart';

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
    required Uint8List bytes,
  }) async {
    final segments = path.split('/');
    final name = segments.removeLast();
    final parent = await _ensureFolderChain(folderId, segments);
    Future<Uint8List> read(int offset, int length) async =>
        Uint8List.sublistView(bytes, offset, offset + length);

    final item = existingItemId == null
        ? await _cloud.importContent(
            name: name,
            size: bytes.length,
            readRange: read,
            folderId: parent,
          )
        : await _cloud.replaceContent(
            itemId: existingItemId,
            size: bytes.length,
            readRange: read,
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
  Future<Uint8List?> download(String itemId) async {
    final item = (await _cloud.listItems()).where((i) => i.id == itemId);
    if (item.isEmpty) return null;
    final target = item.first;
    // The bytes may live on another device: ask for them before reading, and
    // let a miss be a miss — the engine simply tries again next pass rather
    // than writing a truncated file.
    if (!await _cloud.ensureLocal(target)) return null;
    return _cloud.readContentRange(target, 0, target.size);
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
class LocalFolderSyncDisk implements FolderSyncDisk {
  const LocalFolderSyncDisk();

  @override
  Future<FolderScan> scan(String root) => scanFolder(Directory(root));

  @override
  Future<Uint8List?> read(String root, String path) async {
    final file = File('$root/$path');
    if (!file.existsSync()) return null;
    try {
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  /// Written to a sibling and then renamed.
  ///
  /// A crash halfway through a direct write leaves a truncated file, and the
  /// next scan reads that as the user having edited it — the mirror would then
  /// faithfully upload the damage over the good copy in the cloud. The rename
  /// is atomic on every platform this runs on.
  @override
  Future<void> write(String root, String path, Uint8List bytes) async {
    final file = File('$root/$path');
    await file.parent.create(recursive: true);
    final temp = File('${file.path}$kPartialSuffix');
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(file.path);
  }

  @override
  Future<void> remove(String root, String path) async {
    final file = File('$root/$path');
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
