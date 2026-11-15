import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/legacy_compaction_source.dart';

void main() {
  for (final name in [
    'xveil.store',
    'данные #100%?.hv',
    'space name.hv',
    '..%2foutside.hv',
    '.private-volume',
  ]) {
    test('profile binding preserves a literal leaf: $name', () {
      final base = Directory.systemTemp.createTempSync('xveil-source-binding-');
      addTearDown(() => base.deleteSync(recursive: true));
      final profile = '${base.path}/visible-storage';
      final expected = File('${base.path}/$name');
      expect(LegacyCompactionSource.path(profile, name), expected.path);
      expect(LegacyCompactionSource.nameForPath(profile, expected.path), name);
      expect(
        expected.existsSync(),
        isFalse,
        reason: 'lexical admission must not create or probe a source',
      );
      expect(
        File(LegacyCompactionSource.path(profile, name)).parent.path,
        base.path,
      );
    });
  }
  for (final name in [
    '',
    '.',
    '..',
    '../outside.hv',
    r'..\outside.hv',
    'https:evil',
    'file.hv:stream',
    'trailing.',
    'trailing ',
    'bad\x00name',
    'bad\nname',
    'x' * 1025,
    String.fromCharCode(0xd800),
  ]) {
    test('unsafe source leaf is rejected (${name.length} code units)', () {
      expect(
        () => LegacyCompactionSource.validateName(name),
        throwsFormatException,
      );
    });
  }
  test('another directory and relative paths grant no source binding', () {
    final base = Directory.systemTemp.createTempSync('xveil-source-binding-');
    addTearDown(() => base.deleteSync(recursive: true));
    final profile = '${base.path}/visible-storage';
    expect(
      () => LegacyCompactionSource.nameForPath(
        profile,
        '${base.path}/other/xveil.store',
      ),
      throwsFormatException,
    );
    expect(
      () => LegacyCompactionSource.nameForPath(profile, 'xveil.store'),
      throwsFormatException,
    );
  });
}
