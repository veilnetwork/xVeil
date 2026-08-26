import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/content_manifest.dart';
import 'package:xveil/domain/file_names.dart';
import 'package:xveil/state/model_import.dart';

/// A received filename is a LABEL. One place read it as a path: the model
/// bundle was staged at `File('${tempDir.path}/$name')` and the cleanup then
/// removed that file's PARENT recursively — so `../elsewhere/x.veiltranslate`
/// wrote outside the stage and deleted an unrelated directory (report14
/// X14-H1).
///
/// Three seams, because the fix has three parts and each can regress alone.
Map<String, dynamic> _manifestJson(String name) {
  final bytes = Uint8List.fromList(List<int>.generate(64, (i) => i));
  // Default geometry: a hand-picked pieceSize below the default chunk size
  // is refused by the geometry check, which would make every case here pass
  // for the wrong reason.
  final m = ContentManifest.fromBytes(name, bytes);
  return jsonDecode(jsonEncode(m.toJson())) as Map<String, dynamic>;
}

void main() {
  group('the manifest boundary refuses a name that is a path', () {
    test('a plain name is accepted — or the refusals below prove nothing', () {
      final json = _manifestJson('ru-en.veiltranslate');
      final parsed = ContentManifest.fromJson(json);
      expect(parsed, isNotNull);
      expect(parsed!.name, 'ru-en.veiltranslate');
    });

    for (final hostile in <String>[
      '../escape.veiltranslate',
      'sub/dir.veiltranslate',
      r'sub\dir.veiltranslate',
      '..',
      '.',
      'nul\x00byte.veiltranslate',
      'bell\x07.veiltranslate',
      '',
    ]) {
      test('refused: ${jsonEncode(hostile)}', () {
        // Built by our own encoder, so the manifest is SELF-CONSISTENT: it is
        // refused for the name and not because its hashes disagree.
        final json = _manifestJson(hostile);
        expect(
          ContentManifest.fromJson(json),
          isNull,
          reason:
              'a name carrying path structure reaches Message.fileName and '
              'from there every place that offers to save the file',
        );
      });
    }

    test('an unreasonably long name is refused', () {
      expect(ContentManifest.fromJson(_manifestJson('a' * 300)), isNull);
    });
  });

  group('safeFileLeaf never leaves the directory', () {
    test('traversal collapses to one leaf', () {
      expect(safeFileLeaf('../../etc/passwd'), '.._.._etc_passwd');
      expect(safeFileLeaf(r'..\..\windows'), '.._.._windows');
    });

    test('the directory aliases have nothing to preserve', () {
      expect(safeFileLeaf('..'), 'file');
      expect(safeFileLeaf('.'), 'file');
    });

    test('controls and NUL become visible, not silent', () {
      expect(safeFileLeaf('a\x00b'), 'a_b');
      expect(safeFileLeaf('a\nb'), 'a_b');
    });

    test('a trailing dot cannot smuggle a second name for one file', () {
      // Windows strips these on create: `evil. ` and `evil` are one file.
      expect(safeFileLeaf('evil. '), 'evil');
    });

    test('the leaf fits a filesystem component, whole characters only', () {
      final long = safeFileLeaf('я' * 400);
      expect(utf8.encode(long).length, lessThanOrEqualTo(maxFileNameBytes));
      expect(long.runes.every((r) => r == 'я'.runes.first), isTrue);
      expect(long, isNotEmpty);
    });

    test('nothing left means the fallback, never an empty path', () {
      expect(safeFileLeaf(null), 'file');
      expect(safeFileLeaf('///'), '___');
      expect(safeFileLeaf('   '), 'file');
    });
  });

  group('staging keeps to the directory it created', () {
    test(
      'the bundle lands in a fresh directory under a name we chose',
      () async {
        final staged = await materialiseBundle(Uint8List.fromList([1, 2, 3]));
        addTearDown(staged.dispose);
        expect(staged.file.existsSync(), isTrue);
        expect(
          staged.file.parent.path,
          staged.directory.path,
          reason: 'cleanup deletes the directory, so the file must be in it',
        );
        final leaf = staged.file.path.split(Platform.pathSeparator).last;
        expect(leaf, isNot(contains('/')));
        expect(leaf, isNot(contains(r'\')));
      },
    );

    test('cleanup removes the stage and nothing beside it', () async {
      final staged = await materialiseBundle(Uint8List.fromList([1, 2, 3]));
      // A directory a person would notice losing, sitting where a traversal
      // out of the stage would land.
      final sentinel = Directory(
        '${staged.directory.parent.path}/xveil-sentinel',
      )..createSync(recursive: true);
      final keepsake = File('${sentinel.path}/do-not-delete')
        ..writeAsStringSync('still here');
      addTearDown(() => sentinel.deleteSync(recursive: true));

      await staged.dispose();

      expect(staged.directory.existsSync(), isFalse);
      expect(
        keepsake.existsSync(),
        isTrue,
        reason: 'cleanup may only delete what this install created',
      );
    });

    test('disposing twice is not an error', () async {
      final staged = await materialiseBundle(Uint8List.fromList([1]));
      await staged.dispose();
      await staged.dispose();
    });
  });

  test('the install card never hands a received name to the filesystem', () {
    // A STRUCTURAL guard. The path from `Message.fileName` to `File(...)` runs
    // through a widget, and a widget test of the install would need the whole
    // storage/provider stack — so what is asserted is the shape that made the
    // defect possible, which is exactly what a well-meaning refactor would
    // reintroduce.
    final source = File(
      'lib/features/chat/model_bundle_card.dart',
    ).readAsStringSync();
    expect(
      source.contains('staged.parent'),
      isFalse,
      reason:
          "the staged file's parent is only the stage while the leaf name "
          'is one this side chose; delete the directory the staging returned',
    );
    expect(
      RegExp(r'materialiseBundle\([^)]*fileName').hasMatch(source),
      isFalse,
      reason: 'a name from the wire must not decide where bytes land',
    );
  });

  group('a name is read by a person before they open it', () {
    // U+202E RIGHT-TO-LEFT OVERRIDE reverses what follows it, so
    // `photo<RLO>gnp.exe` is displayed as `photoexe.png`. The extension the
    // person reads is not the one the system uses, and the name arrives from
    // whoever sent the file.
    // Escaped, not literal: a raw bidi character in source reorders the
    // source too, and the analyzer says so. The same reason a raw NUL made a
    // test file undiffable.
    const rlo = '\u202E';
    const lri = '\u2066';
    const zwsp = '\u200B';

    test('a bidi override is not a safe label', () {
      expect(isSafeFileLabel('photo${rlo}gnp.exe'), isFalse);
      expect(isSafeFileLabel('a${lri}b.png'), isFalse);
      expect(isSafeFileLabel('a${zwsp}b.png'), isFalse);
      // Vacuity guard: ordinary names, including non-Latin ones, still pass.
      expect(isSafeFileLabel('фото.png'), isTrue);
      expect(isSafeFileLabel('photo.png'), isTrue);
    });

    test('and it does not survive the sanitiser', () {
      final leaf = safeFileLeaf('photo${rlo}gnp.exe');

      expect(leaf.contains(rlo), isFalse);
      // Replaced, not removed: two names differing only by something
      // invisible must not collapse into one file.
      expect(leaf, 'photo_gnp.exe');
    });

    test('joiners that real scripts need are left alone', () {
      // U+200C and U+200D separate and join letters in Persian, Hindi and
      // emoji sequences. They reorder nothing, and stripping them breaks
      // names that are simply written in another script.
      const zwnj = '\u200C';
      const zwj = '\u200D';

      expect(safeFileLeaf('nam${zwnj}ha.png'), 'nam${zwnj}ha.png');
      expect(safeFileLeaf('a${zwj}b.png'), 'a${zwj}b.png');
    });

    test('the result still fits a filesystem leaf', () {
      // Premise, because the replacement above adds characters: whatever the
      // input, what comes out is one component and within the byte bound.
      for (final name in [
        'a' * 300,
        rlo * 100 + 'b' * 200,
        'фото${'ю' * 200}.png',
      ]) {
        final leaf = safeFileLeaf(name);
        expect(utf8.encode(leaf).length, lessThanOrEqualTo(maxFileNameBytes));
        expect(leaf, isNot(contains('/')));
      }
    });
  });
}
