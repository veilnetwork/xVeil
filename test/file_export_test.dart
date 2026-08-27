import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/file_export.dart';
import 'package:xveil/domain/file_names.dart';

/// Copying something out of the encrypted volume and into an ordinary file.
///
/// The file that ends up outside is the whole point and the whole risk. Three
/// paths did this with slightly different endings, and each got one of them
/// wrong: one truncated whatever was already there, one left a half-written
/// document behind when the copy stopped, one deleted the leftovers for a
/// short read but not for an exception.
void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('xveil-export');
    addTearDown(() => dir.deleteSync(recursive: true));
  });

  File target([String name = 'out.bin']) => File('${dir.path}/$name');

  Future<List<int>?> Function(int, int) source(int total, {int? stopAt}) {
    return (offset, want) async {
      if (stopAt != null && offset >= stopAt) return null;
      final end = offset + want > total ? total : offset + want;
      return Uint8List.fromList(List.filled(end - offset, 7));
    };
  }

  test('a complete copy leaves the whole file', () async {
    final file = target();

    final ok = await writeStreamedFile(
      file: file,
      size: 5000,
      read: source(5000),
      chunk: 1024,
    );

    expect(ok, isTrue);
    expect(file.existsSync(), isTrue);
    expect(file.lengthSync(), 5000);
  });

  test('a copy that stops short leaves NO file', () async {
    // A plausible-looking partial is worse than none: somebody opens it, sees
    // the first half of their document, and has no way to know the rest was
    // never written — and it is plaintext, outside the volume.
    final file = target();

    final ok = await writeStreamedFile(
      file: file,
      size: 5000,
      read: source(5000, stopAt: 2048),
      chunk: 1024,
    );

    expect(ok, isFalse);
    expect(
      file.existsSync(),
      isFalse,
      reason: 'a half-written document was left outside the volume',
    );
  });

  test('a read that THROWS leaves no file either', () async {
    // The ending that was missing: the old code deleted only on a short read,
    // so anything thrown mid-copy reached an outer catch with the partial
    // still on disk.
    final file = target();

    await expectLater(
      writeStreamedFile(
        file: file,
        size: 5000,
        read: (offset, want) async {
          if (offset > 0) throw const FileSystemException('storage went away');
          return Uint8List(1024);
        },
        chunk: 1024,
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(file.existsSync(), isFalse);
  });

  test('a close that fails is a failure, and still cleans up', () async {
    // `close` is what flushes, so it is a plausible place for the write to go
    // wrong. Without catching it the exception leaves the `finally` and the
    // cleanup below it never runs.
    //
    // Injected, because it cannot be provoked: on POSIX, taking the file or
    // its directory away underneath an open sink does not disturb the write —
    // tried, and the copy completed into an unlinked file.
    final file = target();

    final ok = await writeStreamedFile(
      file: file,
      size: 2048,
      read: source(2048),
      chunk: 1024,
      openSink: (f) => _FailingCloseSink(f.openWrite()),
    );

    // Reported, not thrown: every caller already handles false, and a copy
    // that flushed into nothing is a copy that did not happen.
    expect(ok, isFalse);
    expect(
      file.existsSync(),
      isFalse,
      reason: 'a failed flush left the partial behind',
    );
  });

  test('an empty item still produces a file', () async {
    // Zero bytes is complete, not a failure. Deleting here would make an empty
    // document impossible to export.
    final file = target();

    expect(
      await writeStreamedFile(file: file, size: 0, read: source(0)),
      isTrue,
    );
    expect(file.existsSync(), isTrue);
    expect(file.lengthSync(), 0);
  });

  test('it leaves the target and nothing beside it', () async {
    // Whichever way it wrote, what remains is the document under its name. A
    // leftover `.xveil-part` is litter the person did not ask for, in a
    // directory they chose.
    final file = target();
    await writeStreamedFile(file: file, size: 64, read: source(64));

    final left = dir.listSync().map((e) => e.path.split('/').last).toList();
    expect(left, ['out.bin']);
  });

  group('an existing document the person chose', () {
    // `openWrite` truncates on open. Writing straight to the chosen path — the
    // sandbox fallback — therefore destroys the document at the moment the
    // copy begins, so a transfer that fails halfway leaves nothing
    // (report16 XV-03). A sibling is written instead wherever one can be
    // opened, and the target is replaced in one step at the end.
    test('survives a copy that fails', () async {
      final file = target('notes.txt')..writeAsStringSync('the original');

      final ok = await writeStreamedFile(
        file: file,
        size: 5000,
        read: source(5000, stopAt: 1024),
        chunk: 1024,
      );

      expect(ok, isFalse);
      expect(
        file.readAsStringSync(),
        'the original',
        reason: 'the document was destroyed by a copy that never finished',
      );
    });

    test('and is replaced whole by one that succeeds', () async {
      final file = target('notes.txt')..writeAsStringSync('the original');

      expect(
        await writeStreamedFile(file: file, size: 4096, read: source(4096)),
        isTrue,
      );
      expect(file.lengthSync(), 4096);
      expect(dir.listSync(), hasLength(1), reason: 'a temp was left behind');
    });

    test('and a sibling refused ASYNCHRONOUSLY still falls back', () async {
      // The one that mattered on the device. `openWrite` opens nothing, so a
      // sandbox's refusal arrives through the sink afterwards — the `try`
      // around the call saw a clean return, the fallback never ran, and every
      // export on that build failed with a partial nobody had asked for
      // (report17 XV17-M1).
      final file = target('notes.txt');
      final opened = <String>[];

      final ok = await writeStreamedFile(
        file: file,
        size: 128,
        read: source(128),
        openSink: (f) {
          opened.add(f.path);
          if (f.path.contains('.xveil-part-')) {
            return _AsyncRefusingSink(f.openWrite());
          }
          return f.openWrite();
        },
      );

      expect(
        opened.any((p) => p.contains('.xveil-part-')),
        isTrue,
        reason: 'no sibling was even tried',
      );
      // THE POINT, and what the first version of this test missed: without the
      // awaited open the refusal never arrives, the sibling is written and
      // renamed, and every assertion about the RESULT still passes. What
      // distinguishes the two is whether the direct path was opened at all.
      expect(
        opened,
        contains(file.path),
        reason:
            'the fallback never ran: the refusal was not seen, so the '
            'export went through a sibling the sandbox had refused',
      );
      expect(ok, isTrue, reason: 'the fallback did not finish the copy');
      expect(file.lengthSync(), 128);
    });

    test('the sibling is not at a name anybody could have guessed', () async {
      // Two things at once. A predictable `<target>.xveil-part` can be a
      // symlink somebody placed in advance — `openWrite` follows it and
      // truncates whatever it points at, before a byte of the export is
      // written. And two exports of one target shared that path, so the first
      // rename moved the file out from under the second.
      final file = target('notes.txt');
      final names = <String>[];

      Future<bool> export() => writeStreamedFile(
        file: file,
        size: 256,
        read: source(256),
        openSink: (f) {
          if (f.path != file.path) names.add(f.path);
          return f.openWrite();
        },
      );

      expect(await export(), isTrue);
      expect(await export(), isTrue);

      expect(names, hasLength(2), reason: 'no sibling was used at all');
      expect(
        names.any((n) => n.endsWith('.xveil-part')),
        isFalse,
        reason: 'the sibling is at the predictable name again',
      );
      expect(
        names[0],
        isNot(names[1]),
        reason:
            'two exports of one target share a temporary path, so the '
            'first rename moves the file out from under the second',
      );
      expect(
        dir.listSync().map((e) => e.path.split('/').last).toList(),
        ['notes.txt'],
        reason: 'a temporary was left behind',
      );
    });

    test(
      'and a filesystem that refuses a sibling still writes direct',
      () async {
        // The sandbox case: the save panel grants the SELECTED path and nothing
        // else, so opening `<name>.part` fails. Falling back is what makes an
        // export possible there at all.
        final file = target('notes.txt');
        var refusedSibling = false;

        final ok = await writeStreamedFile(
          file: file,
          size: 128,
          read: source(128),
          openSink: (f) {
            if (f.path.contains('.xveil-part-')) {
              refusedSibling = true;
              throw const FileSystemException('Operation not permitted');
            }
            return f.openWrite();
          },
        );

        expect(refusedSibling, isTrue, reason: 'no sibling was even tried');
        expect(ok, isTrue);
        expect(file.lengthSync(), 128);
      },
    );
  });

  group('choosing where it goes', () {
    test('a name already taken does not get overwritten', () {
      target('notes.txt').writeAsStringSync('the original');

      final path = uncontestedPath(dir.path, 'notes.txt');

      expect(path, '${dir.path}/notes (1).txt');
      expect(target('notes.txt').readAsStringSync(), 'the original');
    });

    test('a free name is used as it stands', () {
      expect(uncontestedPath(dir.path, 'notes.txt'), '${dir.path}/notes.txt');
    });

    test('the extension stays where a person can read it', () {
      target('a.tar.gz').writeAsStringSync('x');

      expect(uncontestedPath(dir.path, 'a.tar.gz'), '${dir.path}/a.tar (1).gz');
    });
  });
  group('when every reasonable name is taken', () {
    // Returning the plain name after 999 collisions handed the caller a path
    // this had just established is TAKEN — which is the one thing the helper
    // exists to prevent (report16 XV-04).
    test('the answer is never a path known to be somebody else\'s', () {
      var asked = 0;
      final path = uncontestedPath(
        '/d',
        'notes.txt',
        exists: (p) {
          asked++;
          // Everything the numbering can produce is taken.
          return !p.contains(RegExp(r'\([0-9a-f]{8}\)'));
        },
      );
      expect(asked, greaterThan(999), reason: 'it gave up before trying');
      expect(path, isNot('/d/notes.txt'));
      expect(path, matches(RegExp(r'^/d/notes \([0-9a-f]{8}\)\.txt$')));
    });
    test('and two calls do not agree on it', () {
      // A fixed fallback would be the same collision one step along.
      String pick() => uncontestedPath(
        '/d',
        'notes.txt',
        exists: (p) => !p.contains(RegExp(r'\([0-9a-f]{8}\)')),
      );
      expect(pick(), isNot(pick()));
    });
  });
  group('a name that is already at the limit', () {
    // The suffix is the disambiguating part, so it is the last thing to lose.
    // Trimming to the byte bound and THEN adding ` (1)` comes back over it,
    // and a filesystem that truncates turns two different files into one.
    test('keeps its suffix and extension, and still fits', () {
      final long = 'ф' * 200; // 400 bytes in UTF-8.
      final path = uncontestedPath(
        '/d',
        '$long.txt',
        exists: (p) => p == '/d/$long.txt',
      );
      final leaf = path.substring('/d/'.length);
      expect(utf8.encode(leaf).length, lessThanOrEqualTo(maxFileNameBytes));
      expect(leaf, endsWith(' (1).txt'));
    });
    test('and never cuts a character in half', () {
      final long = '🙂' * 100; // 400 bytes, 4 per rune.
      final path = uncontestedPath(
        '/d',
        '$long.bin',
        exists: (p) => p == '/d/$long.bin',
      );
      final leaf = path.substring('/d/'.length);
      expect(utf8.encode(leaf).length, lessThanOrEqualTo(maxFileNameBytes));
      // Decodes cleanly: a half-cut rune would not.
      expect(utf8.decode(utf8.encode(leaf)), leaf);
    });
  });
}

/// An [IOSink] that writes normally and fails to close.
class _AsyncRefusingSink implements IOSink {
  _AsyncRefusingSink(this._inner);

  final IOSink _inner;

  /// The shape a real refusal has. `openWrite` returns a sink without having
  /// opened anything: on a sandboxed macOS build the "Operation not permitted"
  /// arrives LATER, through the sink, which is why the `try` around the call
  /// caught nothing and the fallback never ran.
  @override
  Future<void> flush() async {
    throw const FileSystemException('Operation not permitted');
  }

  @override
  void add(List<int> data) => _inner.add(data);

  @override
  Future<void> close() => _inner.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FailingCloseSink implements IOSink {
  _FailingCloseSink(this._inner);

  final IOSink _inner;

  @override
  void add(List<int> data) => _inner.add(data);

  /// Passes through: the export awaits this to make the OPEN happen where a
  /// refusal can be caught. Failing it here would test the wrong thing.
  @override
  Future<void> flush() => _inner.flush();

  @override
  Future<void> close() async {
    await _inner.close();
    throw const FileSystemException('flush failed');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
