import 'dart:io';

import '../domain/folder_sync.dart';

/// The result of walking one local folder.
class FolderScan {
  const FolderScan({
    required this.files,
    required this.unreadable,
    required this.truncated,
  });

  final List<LocalFile> files;

  /// Paths the walk could not read (permissions, a file deleted mid-walk, a
  /// broken link). Reported rather than swallowed: a file that silently fails
  /// to appear looks exactly like a file the user deleted, and the sync would
  /// mirror that "deletion" to the cloud.
  final List<String> unreadable;

  /// True when [maxFiles] stopped the walk. The caller must surface this —
  /// a truncated scan also looks like deletions.
  final bool truncated;
}

/// Names that belong to the operating system rather than to the user. Syncing
/// them is noise at best: .DS_Store in particular changes whenever a Finder
/// window is resized, which would produce a stream of uploads describing
/// nothing.
const _junk = {'.DS_Store', 'Thumbs.db', 'desktop.ini', '.localized'};

/// The suffix a half-finished download carries. It is OURS, never the user's,
/// and a write that died before its rename leaves one behind: without this the
/// next scan reads the debris as a new file and uploads it.
const kPartialSuffix = '.xveil-part';

/// Walk [root] and describe every file it contains, relative to [root].
///
/// Paths are returned with forward slashes and no leading separator, so the
/// same folder scanned on Windows and on macOS produces the same keys and a
/// pair keeps working when its owner switches machines.
///
/// Symlinks are NOT followed. A link can point outside the folder (uploading
/// data the user never put there) or into it (an infinite walk), and neither
/// belongs in a mirror.
Future<FolderScan> scanFolder(
  Directory root, {
  int maxFiles = 100000,
  bool Function(String relativePath)? exclude,
}) async {
  final files = <LocalFile>[];
  final unreadable = <String>[];
  var truncated = false;
  if (!root.existsSync()) {
    return FolderScan(files: files, unreadable: unreadable, truncated: false);
  }
  final rootPath = root.absolute.path;

  Future<void> walk(Directory dir) async {
    if (truncated) return;
    final List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } catch (_) {
      unreadable.add(_relative(rootPath, dir.path));
      return;
    }
    entries.sort((a, b) => a.path.compareTo(b.path));
    for (final entry in entries) {
      if (truncated) return;
      final name = entry.uri.pathSegments
          .where((segment) => segment.isNotEmpty)
          .last;
      // Hidden entries are configuration, caches and version-control
      // internals. A mirror that carries .git across devices corrupts it.
      if (name.startsWith('.') ||
          _junk.contains(name) ||
          name.endsWith(kPartialSuffix)) {
        continue;
      }
      final relative = _relative(rootPath, entry.path);
      if (exclude?.call(relative) ?? false) continue;
      if (entry is Link) continue;
      if (entry is Directory) {
        await walk(entry);
        continue;
      }
      if (entry is! File) continue;
      try {
        final stat = entry.statSync();
        if (files.length >= maxFiles) {
          truncated = true;
          return;
        }
        files.add(
          LocalFile(
            path: relative,
            size: stat.size,
            modifiedAtMs: stat.modified.millisecondsSinceEpoch,
          ),
        );
      } catch (_) {
        unreadable.add(relative);
      }
    }
  }

  await walk(root);
  return FolderScan(
    files: files,
    unreadable: unreadable,
    truncated: truncated,
  );
}

String _relative(String rootPath, String path) {
  var relative = path.startsWith(rootPath)
      ? path.substring(rootPath.length)
      : path;
  relative = relative.replaceAll(r'\', '/');
  while (relative.startsWith('/')) {
    relative = relative.substring(1);
  }
  return relative;
}
