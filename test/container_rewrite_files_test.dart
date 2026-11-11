import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/container_rewrite_files.dart';

void main() {
  test(
    'only exact native temporary names for this container are removed',
    () async {
      final directory = await Directory.systemTemp.createTemp('xveil-rewrite-');
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/fixture.[a]+.hv';
      await File(path).writeAsString('container');
      final matching = [
        '.fixture.[a]+.hv.hv-compact.0123456789abcdef.tmp',
        '.fixture.[a]+.hv.hv-rotate.fedcba9876543210.tmp',
      ];
      final unrelated = [
        '.fixture.a.hv.hv-compact.0123456789abcdef.tmp',
        '.other.hv.hv-compact.0123456789abcdef.tmp',
        '.fixture.[a]+.hv.hv-compact.0123456789abcde.tmp',
        '.fixture.[a]+.hv.hv-compact.0123456789abcdef.tmp.backup',
        '.fixture.[a]+.hv.hv-compact.NOT-A-NATIVE-NONCE.tmp',
      ];
      for (final name in [...matching, ...unrelated]) {
        await File('${directory.path}/$name').writeAsString(name);
      }
      expect((await containerRewriteFiles(path)).length, matching.length);
      await removeContainerRewriteFiles(path);
      expect(await containerRewriteFiles(path), isEmpty);
      expect(await File(path).readAsString(), 'container');
      for (final name in unrelated) {
        expect(await File('${directory.path}/$name').readAsString(), name);
      }
    },
  );

  test('unexpected directories are preserved and remain reportable', () async {
    final directory = await Directory.systemTemp.createTemp('xveil-rewrite-');
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/fixture.hv';
    final unexpected = Directory(
      '${directory.path}/.fixture.hv.hv-compact.0123456789abcdef.tmp',
    );
    await unexpected.create();
    await File('${unexpected.path}/keep').writeAsString('unrecognized content');
    await removeContainerRewriteFiles(path);
    final survivors = await containerRewriteFiles(path);
    expect(survivors.single, isA<Directory>());
    expect(
      await File('${unexpected.path}/keep').readAsString(),
      'unrecognized content',
    );
  });

  test(
    'matching links are unlinked without following their targets',
    () async {
      final directory = await Directory.systemTemp.createTemp('xveil-rewrite-');
      addTearDown(() => directory.delete(recursive: true));
      final target = File('${directory.path}/keep');
      await target.writeAsString('target must survive');
      final link = Link(
        '${directory.path}/.fixture.hv.hv-compact.0123456789abcdef.tmp',
      );
      await link.create(target.path);
      await removeContainerRewriteFiles('${directory.path}/fixture.hv');
      expect(await link.exists(), isFalse);
      expect(await target.readAsString(), 'target must survive');
    },
    skip: Platform.isWindows ? 'requires symlink privilege' : false,
  );

  test('a missing parent is an empty inventory', () async {
    final directory = await Directory.systemTemp.createTemp('xveil-rewrite-');
    addTearDown(() => directory.delete(recursive: true));
    expect(
      await containerRewriteFiles('${directory.path}/absent/fixture.hv'),
      isEmpty,
    );
  });

  test(
    'an invalid inventory is reported instead of treated as empty',
    () async {
      final directory = await Directory.systemTemp.createTemp('xveil-rewrite-');
      addTearDown(() => directory.delete(recursive: true));
      final notDirectory = File('${directory.path}/file');
      await notDirectory.writeAsString('not a directory');
      await expectLater(
        containerRewriteFiles('${notDirectory.path}/fixture.hv'),
        throwsA(isA<FileSystemException>()),
      );
    },
    skip: Platform.isWindows ? 'POSIX ENOTDIR fixture' : false,
  );
}
