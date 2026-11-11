import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../data/folder_scan.dart';
import '../data/folder_file_metadata.dart';
import '../data/folder_publication.dart';
import '../domain/cloud.dart';
import '../domain/folder_sync.dart';
import 'cloud_service.dart';
import '../data/range_sources.dart';
import '../domain/range_source.dart';
import 'folder_sync_engine.dart';
import '../data/fs_beneath.dart';

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
///  * anything that, once joined, does not resolve back inside the root;
///  * any EXISTING component that is a symlink.
///
/// The last one used to be claimed by the containment check and was not
/// delivered by it: `.absolute` makes a path absolute, it does not resolve
/// links, so a directory inside the root pointing outward passed as contained.
/// A compromised linked device cannot create that symlink itself — the scanner
/// skips links — but given one, it chose where a write landed.
///
/// A residual TOCTOU remains: a component checked here can become a symlink
/// before the write. Closing that needs descriptor-relative `openat` with
/// `O_NOFOLLOW`, which `dart:io` does not expose; rejecting known links is the
/// part reachable from here, and it is stated rather than implied.
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
    // The scanner SKIPS names carrying the scratch suffix, so a remote file
    // named that way would be written and then be invisible to every later
    // pass — present on disk, absent from the mirror's view of itself, and
    // silently re-downloaded forever (audit XV-13).
    if (part.endsWith(kPartialSuffix)) return null;
  }
  final joined = '$root/${parts.join('/')}';
  // Containment on the STRING. `..` is already gone, so this mostly guards
  // against a root that is not a prefix of itself after normalisation.
  // Compared with a trailing separator so `/roots` does not pass as a child of
  // `/root`.
  final rootReal = Directory(root).absolute.path;
  final prefix = rootReal.endsWith('/') ? rootReal : '$rootReal/';
  if (!File(joined).absolute.path.startsWith(prefix)) return null;
  // Containment on the FILESYSTEM: no component that already exists may be a
  // symlink. Checked with `followLinks: false` — the point is to see the link
  // itself, not what it points at. Non-existent components are fine: they will
  // be created as real directories by the writer.
  var probe = rootReal.endsWith('/')
      ? rootReal.substring(0, rootReal.length - 1)
      : rootReal;
  for (final part in parts) {
    probe = '$probe/$part';
    if (FileSystemEntity.typeSync(probe, followLinks: false) ==
        FileSystemEntityType.link) {
      return null;
    }
  }
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
      final path = prefix.isEmpty ? item.name : '$prefix/${item.name}';
      // A name the local scanner will never return. Listing it would have the
      // plan download something the next pass cannot see, and a file the scan
      // cannot see reads as one the user deleted (report24 XV24-03).
      if (folderMirrorSkipsPath(path)) continue;
      files.add(
        RemoteFile(
          path: path,
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
      read: (offset, length) => _cloud.readContentRange(target, offset, length),
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
  const LocalFolderSyncDisk({this.library});

  /// Explicit FS-only fixture seam. Production always uses the verified SDK.
  final DynamicLibrary? library;

  @override
  Future<FolderScan> scan(String root) async {
    if (!Directory(root).existsSync()) return scanFolder(Directory(root));
    final scope = NativeFolderSession.open(root, lib: library);
    try {
      await scope.recoverBeforeScan();
      final result = await scanFolder(Directory(root));
      scope.checkRoot();
      return result;
    } finally {
      scope.close();
    }
  }

  @override
  Future<RangeSource?> openRead(String root, String path) async {
    // THROUGH THE ROOT, not through a name checked a moment ago.
    //
    // `mirrorPathWithin` decides by NAME that the path stays inside the
    // mirrored folder, and the open that follows resolves that name again —
    // so a local writer that re-points an intermediate component between the
    // two hands this read a file from outside the root, and the bytes go up
    // to the cloud (report27 X14). The native walk opens each component
    // beneath a held directory handle with no symlink to follow, which is the
    // same guarantee the CREATE side already uses.
    //
    // `supported` is not the same question as "refused": a refusal must not
    // fall back to the weaker open, or the fallback serves exactly the file
    // the walk rejected.
    final beneath = await veilOpenBeneath(root, path, lib: library);
    if (beneath.supported) {
      final source = beneath.source;
      if (source == null) return null;
      return RangeSource(
        size: source.size,
        read: source.read,
        close: source.close,
      );
    }
    final resolved = mirrorPathWithin(root, path);
    if (resolved == null) return null;
    return fileRangeSource(resolved);
  }

  /// Download outside the folder admission. Only a fully prepared local copy
  /// enters the pinned-root publisher, which preserves the displaced version.
  @override
  Future<bool> writeFrom(String root, String path, RangeSource source) async =>
      await writeChecked(
        root,
        path,
        source,
        expected: await stat(root, path),
      ) !=
      null;

  @override
  Future<LocalFile?> writeChecked(
    String root,
    String path,
    RangeSource source, {
    required LocalFile? expected,
  }) async {
    if (mirrorPathWithin(root, path) == null) return null;
    await _requireVersion(root, path, expected);
    // Private staging keeps slow/failed network reads out of the root-wide
    // admission. No user target or parent directory is touched during download.
    final staging = await Directory.systemTemp.createTemp(
      'xveil-folder-stage-',
    );
    try {
      final prepared = File('${staging.path}/payload');
      final output = await prepared.open(mode: FileMode.writeOnly);
      var written = 0;
      try {
        await for (final chunk in rangeChunks(
          source,
          0,
          source.size,
          chunkBytes: kFolderSyncChunkBytes,
        )) {
          await output.writeFrom(chunk);
          written += chunk.length;
        }
        await output.flush();
      } on RangeSourceUnreadable {
        return null;
      } finally {
        await output.close();
      }
      if (written != source.size) return null;
      final scope = NativeFolderSession.open(root, lib: library);
      try {
        await scope.recoverBeforePublish(path);
        await _requireVersion(root, path, expected);
        final random = Random.secure();
        final tag = List.generate(
          16,
          (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join();
        final parts = path.replaceAll(r'\', '/').split('/');
        final incoming = [
          ...parts.take(parts.length - 1),
          '.xveil-$tag.incoming',
        ].join('/');
        final sink = scope.createIncoming(incoming);
        RandomAccessFile? input;
        try {
          input = await prepared.open();
          for (var offset = 0; offset < source.size;) {
            final chunk = await input.read(
              (source.size - offset).clamp(0, kFolderSyncChunkBytes),
            );
            if (chunk.isEmpty) return null;
            await sink.writeFrom(chunk);
            offset += chunk.length;
          }
          await sink.flush();
        } finally {
          try {
            await input?.close();
          } finally {
            await sink.close();
          }
        }
        scope.checkRoot();
        await _requireVersion(root, path, expected);
        // Native compares the actual displaced object and installs with
        // destination exclusion. A last-window writer is never erased by a
        // pathname rename. The returned stamp belongs to the incoming file.
        return scope.publish(path, incoming, expected: expected);
      } finally {
        scope.close();
      }
    } finally {
      await staging.delete(recursive: true);
    }
  }

  Future<void> _requireVersion(
    String root,
    String path,
    LocalFile? expected,
  ) async {
    if (!sameFolderSyncVersion(expected, await stat(root, path))) {
      throw const FolderSyncLocalChanged();
    }
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
    // SAME RESOLVER as write and remove (audit XV-12). This built the path by
    // concatenation, so a name the writer would refuse still had its metadata
    // read — `..` segments and absolute paths included. One resolver for every
    // operation, or the refusal is only as good as the least careful caller.
    final resolved = mirrorPathWithin(root, path);
    if (resolved == null) return null;
    return readFolderFileMetadata(File(resolved), path);
  }
}
