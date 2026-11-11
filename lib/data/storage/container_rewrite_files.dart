import 'dart:io';

/// Only native rewrite temporaries belonging to this exact container name.
/// Do not walk directories or follow links: an interrupted rewrite leaves a
/// sibling file, never a directory tree or a file for another container.
Future<List<FileSystemEntity>> containerRewriteFiles(String path) async {
  final container = File(path).absolute;
  final stem = RegExp.escape(container.uri.pathSegments.last);
  final name = RegExp(
    '^\\.$stem\\.hv-(?:compact|rotate)\\.[0-9a-f]{16}\\.tmp\$',
  );
  final found = <FileSystemEntity>[];
  try {
    await for (final entry in container.parent.list(followLinks: false)) {
      if (name.hasMatch(
        entry.uri.pathSegments.where((s) => s.isNotEmpty).last,
      )) {
        found.add(entry);
      }
    }
  } on FileSystemException catch (error) {
    // A missing parent contains no survivors. Permission and other I/O errors
    // mean unknown, and must reach the wipe's verification/reporting path.
    final code = error.osError?.errorCode;
    if (code == 2 || (Platform.isWindows && code == 3)) return const [];
    rethrow;
  }
  return found;
}

/// Call only after this application's accepted rewrites have settled.
Future<void> removeContainerRewriteFiles(String path) async {
  for (final entry in await containerRewriteFiles(path)) {
    // A native temporary cannot be a directory. Preserve unexpected contents
    // and let the later inventory report that deletion is incomplete.
    if (entry is Directory) continue;
    try {
      await entry.delete();
    } on FileSystemException {
      // Best effort here, verified by a fresh inventory at the end of wipe.
    }
  }
}
