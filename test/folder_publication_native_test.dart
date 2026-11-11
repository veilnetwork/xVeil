// FS-only ABI qualification. The fixture compiles the exact production FS
// modules, exports their real error destructor and deliberately has NO SDK ABI
// marker. It is passed explicitly; it is never registered as veilclient-ffi.
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:veil_flutter/src/native.dart' show VeilAbiContractMismatch;
import 'package:xveil/data/folder_publication.dart';
import 'package:xveil/data/node/veil_library.dart';
import 'package:xveil/domain/folder_sync.dart';

const _stem = '.xveil-0123456789abcdef0123456789abcdef';
const _second = '.xveil-1123456789abcdef0123456789abcdef';

void main() {
  final path = Platform.environment['XVEIL_FS_TEST_DYLIB'];
  final missing =
      path == null ||
      path.isEmpty ||
      !File(path).isAbsolute ||
      !File(path).existsSync();
  final required = Platform.environment['XVEIL_REQUIRE_FOLDER_FS'] == '1';
  final Object skip = missing && !required
      ? 'Build tests/fs_fixture; set XVEIL_FS_TEST_DYLIB (FS-only fixture)'
      : false;
  late DynamicLibrary library;
  late Directory root;
  final sessions = <NativeFolderSession>[];

  setUpAll(() {
    if (missing) {
      if (required) fail('Required FS-only test fixture is unavailable');
      return;
    }
    library = DynamicLibrary.open(path);
  });
  setUp(() {
    if (missing) return;
    root = Directory.systemTemp.createTempSync('xveil-folder-abi-');
  });
  tearDown(() {
    for (final session in sessions.reversed) {
      session.close();
    }
    sessions.clear();
    if (!missing && root.existsSync()) root.deleteSync(recursive: true);
  });

  NativeFolderSession open() {
    final session = NativeFolderSession.open(root.path, lib: library);
    sessions.add(session);
    return session;
  }

  Matcher failure(FolderFsFailureKind kind) =>
      isA<FolderFsFailure>().having((error) => error.kind, 'category', kind);

  test(
    'fixture cannot be mistaken for a complete SDK at the production gate',
    () {
      expect(
        () => verifiedVeilLibrary(lib: library),
        throwsA(isA<VeilAbiContractMismatch>()),
      );
      open().checkRoot();
    },
    skip: skip,
  );

  test('the admission is exclusive and release is idempotent', () {
    final first = open();
    expect(
      () => NativeFolderSession.open(root.path, lib: library),
      throwsA(failure(FolderFsFailureKind.busy)),
    );
    first.close();
    first.close();
    expect(first.checkRoot, throwsStateError);
    open().checkRoot();
  }, skip: skip);

  test(
    'saved descriptor survives root admission release and a replaced filename',
    () async {
      final scope = open();
      final path = '${root.path}/$_stem.previous';
      File(path).writeAsStringSync('saved bytes');
      final source = scope.openSaved('$_stem.previous')!;
      scope.close();
      open().close(); // A user chooser must not retain the folder admission.
      File(path).renameSync('${root.path}/moved');
      File(path).writeAsStringSync('substituted bytes');
      try {
        expect(source.unchanged(), isTrue);
        expect(
          String.fromCharCodes((await source.source.read(0, 20))!),
          'saved bytes',
        );
      } finally {
        await source.source.dispose();
      }
      await source.source.dispose();
      expect(source.unchanged, throwsStateError);
    },
    skip: skip,
  );

  test(
    'saved change witness notices in-place edits and refuses nonprotocol names',
    () async {
      final scope = open();
      final path = '${root.path}/$_stem.previous';
      final file = File(path)..writeAsStringSync('before');
      final stamp = DateTime.utc(
        2026,
        1,
        1,
      ).add(const Duration(microseconds: 100));
      file.setLastModifiedSync(stamp);
      final source = scope.openSaved('$_stem.previous')!;
      try {
        file.writeAsStringSync('after!');
        file.setLastModifiedSync(stamp.add(const Duration(seconds: 1)));
        expect(
          file.statSync().modified.millisecondsSinceEpoch,
          source.version.modifiedAtMs + 1000,
        );
        expect(file.lengthSync(), source.version.size);
        expect(source.unchanged(), isFalse);
        // This fixture has no journal: orphan previous copies are deliberately
        // refused before deletion, even when the held file also changed.
        expect(
          () => source.discard(scope, '$_stem.previous', '$_second.incoming'),
          throwsA(failure(FolderFsFailureKind.cleanup)),
        );
        expect(scope.openSaved('$_second.incoming'), isNull);
        expect(
          () => scope.openSaved('user-file.txt'),
          throwsA(failure(FolderFsFailureKind.reading)),
        );
      } finally {
        await source.source.dispose();
      }
      expect(
        () => source.discard(scope, '$_stem.previous', '$_second.incoming'),
        throwsStateError,
      );
    },
    skip: skip,
  );

  test(
    'incoming preparation makes parents under the admission and keeps exclusions',
    () async {
      final scope = open();
      final sink = scope.createIncoming('one/two/$_stem.incoming');
      await sink.writeFrom([1, 2, 3]);
      await sink.flush();
      await sink.close();
      await sink.close();
      expect(
        () => scope.createIncoming('one/two/$_stem.incoming'),
        throwsA(failure(FolderFsFailureKind.preparation)),
      );
      expect(
        () => scope.createIncoming('forbidden/user.txt'),
        throwsA(failure(FolderFsFailureKind.preparation)),
      );
      expect(Directory('${root.path}/forbidden').existsSync(), isFalse);
      final receipt = scope.publish(
        'one/two/note.txt',
        'one/two/$_stem.incoming',
        expected: null,
      );
      expect(receipt.size, 3);
      expect(File('${root.path}/one/two/note.txt').readAsBytesSync(), [
        1,
        2,
        3,
      ]);
    },
    skip: skip,
  );

  test(
    'publication recovery is parent-scoped while a full scan refuses unrelated damage',
    () async {
      final scope = open();
      Directory('${root.path}/unrelated').createSync();
      File('${root.path}/unrelated/$_stem.intent').writeAsStringSync('invalid');
      await scope.recoverBeforePublish('new/note.txt');
      final sink = scope.createIncoming('new/$_second.incoming');
      await sink.writeFrom([7]);
      await sink.close();
      await scope.recoverBeforePublish('new/note.txt');
      expect(
        scope
            .publish('new/note.txt', 'new/$_second.incoming', expected: null)
            .size,
        1,
      );
      await expectLater(
        scope.recoverBeforeScan(),
        throwsA(failure(FolderFsFailureKind.recovery)),
      );
      expect(
        () => scope.recoverBeforePublish('../note.txt'),
        throwsFormatException,
      );
      expect(File('${root.path}/new/note.txt').readAsBytesSync(), [7]);
    },
    skip: skip,
  );

  test(
    'real publication returns the incoming stamp and keeps the previous bytes',
    () {
      final scope = open();
      final incoming = File('${root.path}/$_stem.incoming')
        ..writeAsStringSync('first');
      final stat = incoming.statSync();
      final first = scope.publish(
        'note.txt',
        '$_stem.incoming',
        expected: null,
      );
      expect(first.path, 'note.txt');
      expect(first.size, stat.size);
      expect(first.modifiedAtMs, stat.modified.millisecondsSinceEpoch);
      File('${root.path}/$_second.incoming').writeAsStringSync('second');
      final second = scope.publish(
        'note.txt',
        '$_second.incoming',
        expected: first,
      );
      expect(second.size, 6);
      expect(File('${root.path}/note.txt').readAsStringSync(), 'second');
      expect(
        File('${root.path}/$_second.previous').readAsStringSync(),
        'first',
      );
    },
    skip: skip,
  );

  test(
    'a local edit becomes a conflict and is neither erased nor certified',
    () {
      final scope = open();
      File('${root.path}/$_stem.incoming').writeAsStringSync('original');
      final first = scope.publish(
        'note.txt',
        '$_stem.incoming',
        expected: null,
      );
      File(
        '${root.path}/note.txt',
      ).writeAsStringSync('local edit after the scan');
      File(
        '${root.path}/$_second.incoming',
      ).writeAsStringSync('remote replacement');
      expect(
        () => scope.publish('note.txt', '$_second.incoming', expected: first),
        throwsA(isA<FolderSyncLocalChanged>()),
      );
      expect(
        File('${root.path}/note.txt').readAsStringSync(),
        'local edit after the scan',
      );
      expect(
        File('${root.path}/$_second.incoming').readAsStringSync(),
        'remote replacement',
      );
      expect(File('${root.path}/$_second.intent').existsSync(), isFalse);
    },
    skip: skip,
  );

  test(
    'recovery discovery reaches nested intents and restores before a scan',
    () async {
      Directory('${root.path}/nested').createSync();
      final scope = open();
      File('${root.path}/nested/$_stem.incoming').writeAsStringSync('old');
      final old = scope.publish(
        'nested/заметка.txt',
        'nested/$_stem.incoming',
        expected: null,
      );
      File('${root.path}/nested/$_second.incoming').writeAsStringSync('new');
      scope.publish(
        'nested/заметка.txt',
        'nested/$_second.incoming',
        expected: old,
      );
      scope.close();
      // Recreate a pre-install interruption from a real native-generated intent:
      // previous and incoming exist, the primary is temporarily absent. Actual
      // abrupt process exits at every boundary are qualified by the Rust tests.
      File(
        '${root.path}/nested/заметка.txt',
      ).renameSync('${root.path}/nested/$_second.incoming');
      final intent = File('${root.path}/nested/$_second.intent');
      final bytes = intent.readAsBytesSync();
      expect(bytes.take(8), [88, 86, 80, 85, 66, 48, 49, 0]);
      bytes[8] = 0;
      intent.writeAsBytesSync(bytes, flush: true);
      expect(File('${root.path}/nested/заметка.txt').existsSync(), isFalse);
      final recovered = open();
      await recovered.recoverBeforeScan();
      expect(File('${root.path}/nested/заметка.txt').readAsStringSync(), 'old');
      expect(
        File('${root.path}/nested/$_second.incoming').readAsStringSync(),
        'new',
      );
      expect(recovered.recover('nested/$_second.intent'), isFalse);
    },
    skip: skip,
  );

  test(
    'an unreadable intent refuses recovery without exposing its path',
    () async {
      File(
        '${root.path}/$_stem.intent',
      ).writeAsStringSync('not a valid record');
      File('${root.path}/note.txt').writeAsStringSync('keep');
      final scope = open();
      Object? failure;
      try {
        await scope.recoverBeforeScan();
      } catch (error) {
        failure = error;
      }
      expect(
        failure,
        isA<FolderFsFailure>().having(
          (e) => e.kind,
          'category',
          FolderFsFailureKind.recovery,
        ),
      );
      expect(failure.toString(), isNot(contains(root.path)));
      expect(failure.toString(), isNot(contains(_stem)));
      expect(File('${root.path}/note.txt').readAsStringSync(), 'keep');
    },
    skip: skip,
  );

  test(
    'NUL input is refused before C-string truncation can select a prefix',
    () {
      final scope = open();
      expect(
        () => scope.recover('$_stem.intent\u0000ignored'),
        throwsFormatException,
      );
      expect(
        () => scope.publish(
          'prefix\u0000suffix',
          '$_stem.incoming',
          expected: null,
        ),
        throwsFormatException,
      );
      expect(File('${root.path}/prefix').existsSync(), isFalse);
    },
    skip: skip,
  );

  if (!Platform.isWindows) {
    test(
      'a symlink intent cannot change a valid record outside the root',
      () async {
        final outside = Directory.systemTemp.createTempSync(
          'xveil-folder-outside-',
        );
        addTearDown(() => outside.deleteSync(recursive: true));
        final scope = open();
        File('${root.path}/$_stem.incoming').writeAsStringSync('data');
        scope.publish('note.txt', '$_stem.incoming', expected: null);
        final original = File('${root.path}/$_stem.intent');
        final bytes = original.readAsBytesSync();
        bytes[8] = 0;
        final victim = File('${outside.path}/intent')
          ..writeAsBytesSync(bytes, flush: true);
        original.deleteSync();
        Link(original.path).createSync(victim.path);
        await expectLater(
          scope.recoverBeforeScan(),
          throwsA(failure(FolderFsFailureKind.recovery)),
        );
        expect(victim.readAsBytesSync(), bytes);
      },
      skip: skip,
    );

    test(
      'root substitution refuses the scan rather than treating it as empty',
      () {
        final scope = open();
        final moved = root.renameSync('${root.path}-parked');
        addTearDown(() => moved.deleteSync(recursive: true));
        root.createSync();
        expect(
          scope.checkRoot,
          throwsA(failure(FolderFsFailureKind.rootChanged)),
        );
      },
      skip: skip,
    );
  }

  test(
    'lossy UTF-16 input cannot select the replacement-character filename',
    () {
      final scope = open();
      final innocent = File('${root.path}/note-\ufffd.txt')
        ..writeAsStringSync('keep');
      for (final path in ['note-\ud800.txt', 'note-\udc00.txt']) {
        expect(
          () => scope.publish(path, '$_stem.incoming', expected: null),
          throwsFormatException,
        );
      }
      expect(innocent.readAsStringSync(), 'keep');
      File('${root.path}/$_stem.incoming').writeAsStringSync('valid');
      scope.publish('note-\ud83d\ude00.txt', '$_stem.incoming', expected: null);
      expect(File('${root.path}/note-😀.txt').readAsStringSync(), 'valid');
    },
    skip: skip,
  );
}
