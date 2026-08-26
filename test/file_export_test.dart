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

  test('it writes to the path it was given, not a sibling', () async {
    // A sandboxed macOS save panel grants access to the SELECTED path only, so
    // a `<name>.part` sibling cannot be opened at all and every export failed
    // on a release build.
    final file = target();
    await writeStreamedFile(file: file, size: 64, read: source(64));

    final siblings = dir
        .listSync()
        .map((e) => e.path.split('/').last)
        .toList();
    expect(siblings, ['out.bin']);
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
}

/// An [IOSink] that writes normally and fails to close.
class _FailingCloseSink implements IOSink {
  _FailingCloseSink(this._inner);

  final IOSink _inner;

  @override
  void add(List<int> data) => _inner.add(data);

  @override
  Future<void> close() async {
    await _inner.close();
    throw const FileSystemException('flush failed');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
