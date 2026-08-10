// Exercises the FFI layer against the REAL libveil_translate.
//
// Gated on two environment variables because neither the library nor a model
// is in the repository — the library is a prebuilt and the models are hundreds
// of megabytes per language pair:
//
//   VEIL_TRANSLATE_LIB    path to libveil_translate.{dylib,so}
//   VEIL_TRANSLATE_MODEL  a CTranslate2 model directory with source.spm/target.spm
//
//   flutter test test/translate_ffi_test.dart \
//     --dart-define=... is NOT how this reads them; they are process env:
//   VEIL_TRANSLATE_LIB=native/translate/Frameworks/libveil_translate.dylib \
//   VEIL_TRANSLATE_MODEL=$HOME/Projects/veilnetwork/ct2-model \
//     flutter test test/translate_ffi_test.dart
//
// When they are unset the group is SKIPPED, and skipped is not passed — the
// message says exactly what went unchecked. The pure-Dart group below always
// runs.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/translate_ffi.dart';

void main() {
  group('without a native library', () {
    test('a missing library yields no engine, and does not throw', () async {
      final engine = await TranslateEngine.open(
        '/nonexistent/model',
        libraryPath: '/nonexistent/libveil_translate.dylib',
      );
      expect(engine, isNull);
    });

    test('the symbol list is exactly what this layer looks up', () {
      // Set equality, in both directions, and NOT "the source mentions the
      // name": the required list is itself part of the source, so a contains()
      // check is satisfied by the very declaration it is meant to justify. A
      // phantom entry passed that version of this test.
      final source = File('lib/state/translate_ffi.dart').readAsStringSync();
      final lookedUp = RegExp(r"lookupFunction<[^>]+>\(\s*'([a-z_]+)'\s*\)")
          .allMatches(source)
          .map((m) => m.group(1)!)
          .toSet();
      expect(
        lookedUp,
        isNotEmpty,
        reason: 'found no lookupFunction calls — the pattern stopped matching, '
            'so this test was checking nothing',
      );
      expect(
        lookedUp,
        equals(kRequiredSymbols.toSet()),
        reason: 'a name checked for and never called is dead weight; a name '
            'called and never checked for reports "available" and then crashes',
      );
    });

    test('a refusal explains itself', () async {
      TranslateEngine.lastOpenError = '';
      final engine = await TranslateEngine.open(
        '/nonexistent/model',
        libraryPath: '/nonexistent/libveil_translate.dylib',
      );
      expect(engine, isNull);
      // Not merely non-empty: an empty reason is exactly the failure this
      // guards, and it is what the native selftest asserts on its own side.
      expect(TranslateEngine.lastOpenError, isNotEmpty);
    });
  });

  final lib = Platform.environment['VEIL_TRANSLATE_LIB'];
  final model = Platform.environment['VEIL_TRANSLATE_MODEL'];
  final ready = lib != null && model != null &&
      File(lib).existsSync() && Directory(model).existsSync();

  group('against the real engine', () {
    late TranslateEngine engine;

    setUpAll(() async {
      final opened = await TranslateEngine.open(model!, libraryPath: lib, beamSize: 4);
      expect(opened, isNotNull, reason: 'the engine would not open');
      engine = opened!;
    });

    tearDownAll(() async => engine.close());

    test('it reports what it is', () {
      expect(engine.version, contains('veil_translate'));
      expect(engine.version, contains('ctranslate2'));
    });

    test('a message comes back translated, and not rambling', () async {
      final out = await engine.translate(
        'Это сообщение зашифровано и не покидает устройство.',
      );
      expect(out, isNotNull);
      expect(out!.toLowerCase(), contains('device'));
      // The length bound is not decoration. Without Marian's end-of-sequence
      // marker the decoder repeats itself, and every content word still
      // appears — so a contains() check alone passes on text that is plainly
      // broken.
      expect(out.length, lessThan(120), reason: 'degenerate repetition: $out');
    });

    test('blank input is not an error', () async {
      expect(await engine.translate('   '), isEmpty);
    });

    test('the same message twice gives the same answer', () async {
      final first = await engine.translate('Привет!');
      final second = await engine.translate('Привет!');
      expect(first, isNotNull);
      expect(second, equals(first));
    });

    test('a closed engine answers null rather than crashing', () async {
      final second = await TranslateEngine.open(model!, libraryPath: lib);
      expect(second, isNotNull);
      await second!.close();
      expect(await second.translate('Привет!'), isNull);
    });
  },
      skip: ready
          ? null
          : 'NOT CHECKED: set VEIL_TRANSLATE_LIB and VEIL_TRANSLATE_MODEL to '
              'exercise the FFI layer against the real engine. Nothing here '
              'has confirmed that Dart can translate.');
}
