import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';

void main() {
  const fs = ManagedFsPlatform();
  late Directory fixture;
  File source() {
    final f = File('${fixture.path}/source')..createSync(exclusive: true);
    fs.restrictNewFile(f.path);
    f.writeAsBytesSync([1, 2, 3], flush: true);
    return f;
  }

  setUp(
    () => fixture = Directory.systemTemp.createTempSync(
      'xveil-file-publication-',
    ),
  );
  tearDown(() => fixture.deleteSync(recursive: true));

  test(
    'atomic regular-file publication preserves bytes and object witness',
    () {
      final f = source();
      final witness = fs.inspect(f.path);
      final to = '${fixture.path}/destination';
      expect(fs.publishFileNoReplace(f.path, to), isTrue);
      fs.syncDirectory(fixture.path);
      expect(f.existsSync(), isFalse);
      expect(fs.requirePrivateFile(to).sameObject(witness), isTrue);
      expect(File(to).readAsBytesSync(), [1, 2, 3]);
    },
  );

  for (final kind in ['file', 'directory', 'link']) {
    test(
      'existing $kind is never overwritten',
      () {
        final f = source();
        final to = '${fixture.path}/destination';
        final outside = File('${fixture.path}/outside')
          ..writeAsBytesSync([9, 8, 7]);
        if (kind == 'file') File(to).writeAsBytesSync([9, 8, 7]);
        if (kind == 'directory') Directory(to).createSync();
        if (kind == 'link') Link(to).createSync(outside.path);
        final type = FileSystemEntity.typeSync(to, followLinks: false);
        expect(fs.publishFileNoReplace(f.path, to), isFalse);
        expect(FileSystemEntity.typeSync(to, followLinks: false), type);
        if (kind != 'directory') expect(File(to).readAsBytesSync(), [9, 8, 7]);
        expect(outside.readAsBytesSync(), [9, 8, 7]);
        expect(f.readAsBytesSync(), [1, 2, 3]);
      },
      skip: kind == 'link' && Platform.isWindows,
    );
  }

  test(
    'source link, source directory and different parent refuse publication',
    () {
      final f = source();
      final to = '${fixture.path}/destination';
      final d = Directory('${fixture.path}/other')..createSync();
      expect(
        () => fs.publishFileNoReplace(f.path, '${d.path}/destination'),
        throwsA(isA<ManagedFsFailure>()),
      );
      expect(
        () => fs.publishFileNoReplace(d.path, to),
        throwsA(isA<ManagedFsFailure>()),
      );
      if (!Platform.isWindows) {
        final link = Link('${fixture.path}/link')..createSync(f.path);
        expect(
          () => fs.publishFileNoReplace(link.path, to),
          throwsA(isA<ManagedFsFailure>()),
        );
      }
      expect(f.readAsBytesSync(), [1, 2, 3]);
      expect(
        FileSystemEntity.typeSync(to, followLinks: false),
        FileSystemEntityType.notFound,
      );
    },
  );
}
