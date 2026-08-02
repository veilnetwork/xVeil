import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/folder_sync_adapters.dart';

import 'support/range_source_util.dart';

/// Mirror paths are built from CLOUD ITEM NAMES, and any device linked to the
/// account can create a cloud item — including one that has been compromised.
/// The disk adapter used to concatenate that name straight into
/// `File('$root/$path')`, so a name of `../../.ssh/authorized_keys` wrote
/// outside the folder the user chose, atomically, via temp-then-rename.
void main() {
  group('a mirror path', () {
    const root = '/home/u/sync';

    test('stays inside for an ordinary relative name', () {
      expect(mirrorPathWithin(root, 'a.txt'), '$root/a.txt');
      expect(mirrorPathWithin(root, 'sub/dir/a.txt'), '$root/sub/dir/a.txt');
    });

    test('is refused when it climbs out', () {
      for (final hostile in [
        '../victim',
        '../../victim',
        'sub/../../victim',
        'a/b/../../../victim',
        '..',
      ]) {
        expect(
          mirrorPathWithin(root, hostile),
          isNull,
          reason: '$hostile escapes the sync root',
        );
      }
    });

    test('is refused when it is not relative at all', () {
      expect(mirrorPathWithin(root, '/etc/passwd'), isNull);
      expect(mirrorPathWithin(root, r'C:\Windows\System32\drivers\etc\hosts'),
          isNull);
      expect(mirrorPathWithin(root, r'\\server\share\file'), isNull);
    });

    test('is refused for a separator hidden inside a name', () {
      // A backslash is a separator on Windows, so a name carrying one must not
      // be treated as a single harmless component.
      expect(mirrorPathWithin(root, r'..\..\victim'), isNull);
      expect(mirrorPathWithin(root, 'a//b'), isNull);
      expect(mirrorPathWithin(root, './a'), isNull);
    });

    test('does not mistake a sibling root for a child', () {
      // Prefix comparison without a trailing separator lets `/home/u/syncX`
      // pass as living under `/home/u/sync`.
      expect(mirrorPathWithin('/home/u/sync', '../syncX/file'), isNull);
    });
  });

  test('the disk adapter writes nothing for an escaping name', () async {
    final tmp = Directory.systemTemp.createTempSync('xveil_mirror');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final rootDir = Directory('${tmp.path}/root')..createSync();
    final outside = File('${tmp.path}/victim');
    outside.writeAsStringSync('original');

    await writeBytes(
      const LocalFolderSyncDisk(),
      rootDir.path,
      '../victim',
      <int>[1, 2, 3],
    );

    expect(
      outside.readAsStringSync(),
      'original',
      reason: 'the mirror overwrote a file outside the folder the user chose',
    );
  });

  test('a symlinked directory inside the root is refused', () {
    // Audit X-03. The containment check claimed to catch this and did not:
    // `.absolute` makes a path absolute, it never resolves links, so a
    // directory inside the root pointing outward compared as contained.
    //
    // A remote peer cannot create the link — the scanner skips links — but
    // given one (made locally, or by a local race), it chose where a write
    // from a compromised linked device landed.
    final tmp = Directory.systemTemp.createTempSync('xveil_symlink');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final rootDir = Directory('${tmp.path}/root')..createSync();
    final outsideDir = Directory('${tmp.path}/outside')..createSync();
    Link('${rootDir.path}/escape').createSync(outsideDir.path);

    expect(
      mirrorPathWithin(rootDir.path, 'escape/loot.txt'),
      isNull,
      reason: 'a path through a symlinked component leaves the sync root',
    );
    // The link itself, named directly, is refused too.
    expect(mirrorPathWithin(rootDir.path, 'escape'), isNull);
  });

  test('an ordinary nested path under the root is still allowed', () {
    // The symlink check must reject links, not depth — a mirror that refused
    // subdirectories would be broken rather than safe.
    final tmp = Directory.systemTemp.createTempSync('xveil_nested');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final rootDir = Directory('${tmp.path}/root')..createSync();
    Directory('${rootDir.path}/real').createSync();

    expect(
      mirrorPathWithin(rootDir.path, 'real/file.txt'),
      '${rootDir.path}/real/file.txt',
    );
    // Components that do not exist yet are fine — the writer creates them.
    expect(
      mirrorPathWithin(rootDir.path, 'brand/new/file.txt'),
      '${rootDir.path}/brand/new/file.txt',
    );
  });
}
