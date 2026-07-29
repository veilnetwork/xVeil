import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/folder_sync_adapters.dart';

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

    await const LocalFolderSyncDisk().write(
      rootDir.path,
      '../victim',
      Uint8List.fromList(<int>[1, 2, 3]),
    );

    expect(
      outside.readAsStringSync(),
      'original',
      reason: 'the mirror overwrote a file outside the folder the user chose',
    );
  });
}
