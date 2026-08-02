import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/folder_scan.dart';
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

  group('the scratch file cannot be aimed elsewhere', () {
    test('a remote name carrying the scratch suffix is refused', () {
      // The scanner SKIPS names with this suffix, so a remote file named that
      // way would be written and then be invisible to every later pass:
      // present on disk, absent from the mirror's view of itself, and silently
      // re-downloaded forever (audit XV-13).
      expect(mirrorPathWithin('/root', 'notes$kPartialSuffix'), isNull);
      expect(mirrorPathWithin('/root', 'a/b/x$kPartialSuffix'), isNull);
      // A name that merely CONTAINS it is fine — only the ending is reserved.
      expect(
        mirrorPathWithin('/root', 'x${kPartialSuffix}y.txt'),
        isNotNull,
      );
    });

    test('a symlink pre-created at the predictable name is not followed',
        () async {
      // The old scratch name was `<target>.xveil-part` — fixed, and derivable
      // from the remote listing. Anyone able to write into the sync root could
      // pre-create a SYMLINK there pointing anywhere the user can write, and
      // `File.open` follows it: the next download truncated and overwrote
      // whatever it aimed at, entirely outside the mirrored tree (audit
      // XV-13).
      final root = Directory.systemTemp.createTempSync('xveil_scratch_link');
      addTearDown(() => root.deleteSync(recursive: true));
      final victim = File('${root.parent.path}/xveil-victim-probe.txt')
        ..writeAsStringSync('PRECIOUS');
      addTearDown(() {
        if (victim.existsSync()) victim.deleteSync();
      });

      // Exactly where the old code would have opened.
      Link('${root.path}/report.bin$kPartialSuffix').createSync(victim.path);

      await LocalFolderSyncDisk().writeFrom(
        root.path,
        'report.bin',
        bytesSource(const [9, 9, 9, 9]),
      );

      expect(
        victim.readAsStringSync(),
        'PRECIOUS',
        reason: 'the write must not have followed the planted symlink',
      );
      expect(File('${root.path}/report.bin').existsSync(), isTrue);
    }, skip: Platform.isWindows ? 'POSIX symlink semantics' : null);
  });

  group('stat uses the same resolver as write', () {
    test('an escaping path yields no metadata', () async {
      // This built the path by concatenation, so a name the writer refuses
      // still had its metadata read — `..` segments included (audit XV-12).
      final root = Directory.systemTemp.createTempSync('xveil_stat_esc');
      addTearDown(() => root.deleteSync(recursive: true));
      final outside = File('${root.parent.path}/xveil-outside-probe.txt')
        ..writeAsStringSync('secret');
      addTearDown(() {
        if (outside.existsSync()) outside.deleteSync();
      });

      final disk = LocalFolderSyncDisk();
      expect(
        await disk.stat(root.path, '../xveil-outside-probe.txt'),
        isNull,
        reason: 'metadata outside the root must not be reachable',
      );
      expect(await disk.stat(root.path, '/etc/hosts'), isNull);
    });
  });
}
