import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/folder_scan.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('xveil-scan');
  });
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  File write(String relative, String body) {
    final file = File('${root.path}/$relative');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(body);
    return file;
  }

  test('returns paths relative to the root, with forward slashes', () async {
    write('a.txt', 'a');
    write('nested/deep/b.txt', 'bb');

    final scan = await scanFolder(root);

    expect(scan.files.map((f) => f.path), ['a.txt', 'nested/deep/b.txt']);
    expect(
      scan.files.every((f) => !f.path.startsWith('/')),
      isTrue,
      reason: 'a leading separator would make the key machine-specific',
    );
    expect(scan.files.firstWhere((f) => f.path == 'a.txt').size, 1);
    expect(scan.files.firstWhere((f) => f.path == 'nested/deep/b.txt').size, 2);
  });

  test('skips hidden entries and operating-system junk', () async {
    write('keep.txt', 'k');
    write('.hidden', 'h');
    write('.git/config', 'c');
    write('.DS_Store', 'd');
    write('Thumbs.db', 't');

    final scan = await scanFolder(root);

    // A mirror that carries .git across devices corrupts it, and .DS_Store
    // changes whenever a Finder window is resized.
    expect(scan.files.map((f) => f.path), ['keep.txt']);
  });

  test('does not follow symlinks', () async {
    write('real.txt', 'r');
    final outside = Directory.systemTemp.createTempSync('xveil-outside');
    addTearDown(() => outside.deleteSync(recursive: true));
    File('${outside.path}/secret.txt').writeAsStringSync('s');
    try {
      Link('${root.path}/link').createSync(outside.path);
    } on FileSystemException {
      return; // a platform without symlink permission: nothing to assert
    }

    final scan = await scanFolder(root);

    expect(
      scan.files.map((f) => f.path),
      ['real.txt'],
      reason: 'a link can point outside the folder, or into it forever',
    );
  });

  test('an excluded path is left out', () async {
    write('a.txt', 'a');
    write('build/out.bin', 'b');

    final scan = await scanFolder(
      root,
      exclude: (path) => path.startsWith('build/'),
    );

    expect(scan.files.map((f) => f.path), ['a.txt']);
  });

  test('truncation is REPORTED, never silent', () async {
    // A truncated scan looks exactly like mass deletion to the differ, so the
    // caller has to be able to tell the difference.
    for (var i = 0; i < 5; i++) {
      write('f$i.txt', '$i');
    }

    final scan = await scanFolder(root, maxFiles: 3);

    expect(scan.truncated, isTrue);
    expect(scan.files, hasLength(3));
  });

  test('a missing root is empty rather than an exception', () async {
    final gone = Directory('${root.path}/nope');
    final scan = await scanFolder(gone);
    expect(scan.files, isEmpty);
    expect(scan.truncated, isFalse);
  });

  test('an unreadable directory is reported, and the walk continues',
      () async {
    write('readable.txt', 'r');
    final locked = Directory('${root.path}/locked')..createSync();
    File('${locked.path}/inside.txt').writeAsStringSync('i');
    try {
      Process.runSync('chmod', ['000', locked.path]);
    } catch (_) {
      return;
    }
    addTearDown(() => Process.runSync('chmod', ['755', locked.path]));

    final scan = await scanFolder(root);

    if (scan.unreadable.isEmpty) return; // running as root: nothing is denied
    expect(
      scan.files.map((f) => f.path),
      contains('readable.txt'),
      reason: 'one denied directory must not abort the whole scan',
    );
    expect(scan.unreadable, contains('locked'));
  });
}
