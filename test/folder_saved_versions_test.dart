import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/document_export.dart';
import 'package:xveil/core/diagnostic_journal.dart';
import 'package:xveil/data/folder_publication.dart';
import 'package:xveil/data/folder_saved_versions.dart';
import 'package:xveil/domain/folder_sync.dart';
import 'package:xveil/domain/range_source.dart';
import 'package:xveil/state/folder_saved_export.dart';

import 'support/folder_fs_fixture.dart';
import 'support/range_source_util.dart';

class _Document implements ExportDocument {
  final bytes = BytesBuilder();
  final sizes = <int>[];
  int finishes = 0, aborts = 0;
  bool failWrite = false, failFinish = false;
  void Function()? onWrite;
  @override
  Future<void> write(List<int> chunk) async {
    if (failWrite) {
      throw const DocumentExportException('write', permissionDenied: true);
    }
    bytes.add(chunk);
    sizes.add(chunk.length);
    onWrite?.call();
  }

  @override
  Future<void> finish() async {
    finishes++;
    if (failFinish) throw const DocumentExportException('finish');
  }

  @override
  Future<void> abort() async {
    aborts++;
  }
}

class _PrivateError {
  @override
  String toString() => throw StateError('must not stringify');
}

class _Access implements FolderSavedVersionAccess {
  _Access(this.inner);
  final FolderSavedVersionAccess inner;
  final opened = <SavedFolderFile>[];
  final readSizes = <int>[];
  @override
  Future<FolderSavedVersionPage> list(
    String root, {
    String? after,
    bool Function()? stillCurrent,
  }) => inner.list(root, after: after, stillCurrent: stillCurrent);
  @override
  Future<SavedFolderFile> open(String root, FolderSavedVersion version) async {
    final file = await inner.open(root, version);
    opened.add(file);
    return _ObservedFile(file, readSizes);
  }
}

class _ObservedFile implements SavedFolderFile {
  _ObservedFile(this.file, List<int> sizes)
    : source = RangeSource(
        size: file.source.size,
        read: (offset, length) {
          sizes.add(length);
          return file.source.read(offset, length);
        },
        close: file.source.dispose,
      );
  final SavedFolderFile file;
  @override
  final RangeSource source;
  @override
  LocalFile get version => file.version;
  @override
  bool Function() get unchanged => file.unchanged;
}

void main() {
  final disk = folderDiskFixture();
  late Directory root;
  late _Access access;
  setUp(() {
    root = Directory.systemTemp.createTempSync('xveil-saved-');
    access = _Access(
      NativeFolderSavedVersions(library: disk.library, pageSize: 2),
    );
  });
  tearDown(() async {
    for (final file in access.opened) {
      await file.source.dispose();
    }
    root.deleteSync(recursive: true);
  });
  Future<FolderSavedVersion> saved() async {
    await writeBytes(
      disk,
      root.path,
      'nested/note.txt',
      Uint8List.fromList(utf8.encode('previous')),
    );
    await writeBytes(
      disk,
      root.path,
      'nested/note.txt',
      Uint8List.fromList(utf8.encode('current')),
    );
    return (await access.list(root.path)).entries.single;
  }

  test(
    'failure evidence uses only source categories and never exception data',
    () {
      final errors = <(Object, FolderSavedDiagnosticFailure)>[
        (
          const FolderFsFailure(FolderFsFailureKind.busy),
          FolderSavedDiagnosticFailure.busy,
        ),
        (
          const FolderFsFailure(FolderFsFailureKind.unavailable),
          FolderSavedDiagnosticFailure.unavailable,
        ),
        (
          const FolderSavedVersionChanged(),
          FolderSavedDiagnosticFailure.changed,
        ),
        (
          const DocumentExportException('write', permissionDenied: true),
          FolderSavedDiagnosticFailure.destinationPermission,
        ),
        (
          const DocumentExportException('finish'),
          FolderSavedDiagnosticFailure.destinationFinish,
        ),
        (
          const DocumentExportException('PRIVATE_CANARY'),
          FolderSavedDiagnosticFailure.other,
        ),
        (
          const FileSystemException('PRIVATE_CANARY', '/private-canary/file'),
          FolderSavedDiagnosticFailure.reading,
        ),
        (_PrivateError(), FolderSavedDiagnosticFailure.other),
      ];
      for (final (error, code) in errors) {
        expect(folderSavedFailureCode(error), code);
        final journal = DiagnosticJournal(enabled: true, capacity: 1);
        journal.recordFolderSavedFailure(
          action: FolderSavedDiagnosticAction.exporting,
          failure: folderSavedFailureCode(error),
        );
        journal.record(DiagnosticEvent.transportSent);
        final retained =
            (journal.toJson()['last_evidence'] as Map)['folderSavedFailure']
                as Map;
        expect(retained['values'], {
          'origin': 1,
          'code': code.index,
          'success': 0,
        });
        expect(jsonEncode(journal.toJson()), isNot(contains('CANARY')));
        expect(jsonEncode(journal.toJson()), isNot(contains('private-canary')));
      }
      final disabled = DiagnosticJournal(enabled: false);
      disabled.recordFolderSavedFailure(
        action: FolderSavedDiagnosticAction.listing,
        failure: FolderSavedDiagnosticFailure.reading,
      );
      expect(disabled.toJson()['counts'], isEmpty);
      expect(disabled.toJson()['last_evidence'], isEmpty);
    },
  );

  test(
    'a large native saved file reaches export through bounded source reads',
    () async {
      final bytes = Uint8List(2 * kDocumentExportChunkBytes + 17);
      for (var i = 0; i < bytes.length; i++) {
        bytes[i] = i % 251;
      }
      File(
        '${root.path}/.xveil-0123456789abcdef0123456789abcdef.incoming',
      ).writeAsBytesSync(bytes);
      final version = (await access.list(root.path)).entries.single;
      final document = _Document();
      expect(
        await exportFolderSavedVersion(
          access: access,
          root: root.path,
          version: version,
          stillCurrent: () => true,
          pick: (_) async => document,
        ),
        isTrue,
      );
      expect(access.readSizes, [
        kDocumentExportChunkBytes,
        kDocumentExportChunkBytes,
        17,
      ]);
      expect(document.sizes, access.readSizes);
      expect(document.bytes.toBytes(), bytes);
    },
  );

  test(
    'real saved version exports its bytes without rewriting the mirror',
    () async {
      final version = await saved();
      expect(version.originalPath, 'nested/note.txt');
      expect(version.previous, isTrue);
      final document = _Document();
      String? chosenName;
      expect(
        await exportFolderSavedVersion(
          access: access,
          root: root.path,
          version: version,
          stillCurrent: () => true,
          pick: (name) async {
            chosenName = name;
            final admission = NativeFolderSession.open(
              root.path,
              lib: disk.library,
            );
            admission.close();
            return document;
          },
        ),
        isTrue,
      );
      expect(chosenName, 'copy-note.txt');
      expect(utf8.decode(document.bytes.toBytes()), 'previous');
      expect(document.finishes, 1);
      expect(document.aborts, 0);
      expect(
        File('${root.path}/nested/note.txt').readAsStringSync(),
        'current',
      );
      expect(
        File('${root.path}/${version.relativePath}').readAsStringSync(),
        'previous',
      );
      expect(access.opened.single.unchanged, throwsStateError);
    },
  );

  test(
    'bounded pages include orphan incoming copies and never traverse hidden user directories',
    () async {
      final paths = <String>[];
      for (var i = 0; i < 7; i++) {
        final stem = '.xveil-${i.toRadixString(16).padLeft(32, '0')}';
        final path =
            '${i.isEven ? 'nested/' : ''}$stem.${i.isEven ? 'incoming' : 'previous'}';
        final file = File('${root.path}/$path');
        file.parent.createSync(recursive: true);
        file.writeAsStringSync('copy $i');
        paths.add(path);
      }
      Directory('${root.path}/.private').createSync();
      File(
        '${root.path}/.private/.xveil-ffffffffffffffffffffffffffffffff.previous',
      ).writeAsStringSync('excluded');
      File('${root.path}/ordinary.txt').writeAsStringSync('not a backup');
      final found = <String>[];
      String? cursor;
      do {
        final page = await access.list(root.path, after: cursor);
        expect(page.entries.length, lessThanOrEqualTo(2));
        expect(
          page.entries.every((v) => v.originalPath == null && v.readable),
          isTrue,
        );
        found.addAll(page.entries.map((v) => v.relativePath));
        if (page.nextAfter != null && cursor != null) {
          expect(page.nextAfter!.compareTo(cursor), greaterThan(0));
        }
        cursor = page.nextAfter;
      } while (cursor != null);
      expect(found, paths..sort());
      expect(found.toSet(), hasLength(7));
    },
  );

  test(
    'damaged intent cannot turn its display name into an open path',
    () async {
      const stem = '.xveil-0123456789abcdef0123456789abcdef';
      File('${root.path}/$stem.previous').writeAsStringSync('recoverable');
      // Valid-looking header but a forbidden target outside this folder.
      final target = utf8.encode('../private');
      File('${root.path}/$stem.intent').writeAsBytesSync([
        88,
        86,
        80,
        85,
        66,
        48,
        49,
        0,
        1,
        1,
        target.length,
        0,
        ...target,
      ]);
      final entry = (await access.list(root.path)).entries.single;
      expect(entry.originalPath, isNull);
      final source = await access.open(root.path, entry);
      expect(utf8.decode((await source.source.read(0, 100))!), 'recoverable');
    },
  );

  test(
    'copy symlinks are shown unreadable and never exported',
    () async {
      final outside = Directory.systemTemp.createTempSync(
        'xveil-saved-outside-',
      );
      addTearDown(() => outside.deleteSync(recursive: true));
      final private = File('${outside.path}/private')
        ..writeAsStringSync('outside bytes');
      Link(
        '${root.path}/.xveil-0123456789abcdef0123456789abcdef.previous',
      ).createSync(private.path);
      final entry = (await access.list(root.path)).entries.single;
      expect(entry.readable, isFalse);
      var picked = false;
      await expectLater(
        exportFolderSavedVersion(
          access: access,
          root: root.path,
          version: entry,
          stillCurrent: () => true,
          pick: (_) async {
            picked = true;
            return _Document();
          },
        ),
        throwsA(isA<FolderSavedVersionChanged>()),
      );
      expect(picked, isFalse);
      expect(private.readAsStringSync(), 'outside bytes');
    },
    skip: Platform.isWindows ? 'Unix leaf symlink fixture' : false,
  );

  test('cancelled enumeration releases the native admission', () async {
    File('${root.path}/ordinary').writeAsStringSync('x');
    var checks = 0;
    await expectLater(
      access.list(root.path, stillCurrent: () => ++checks < 2),
      throwsA(isA<FolderSavedOperationCancelled>()),
    );
    final admission = NativeFolderSession.open(root.path, lib: disk.library);
    admission.close();
  });

  for (final failure in [
    'picker-cancel',
    'owner-changed',
    'write',
    'finish',
    'copy-changed',
  ]) {
    test(
      'export $failure never reports a completed save and releases its descriptor',
      () async {
        final version = await saved();
        final document = _Document()
          ..failWrite = failure == 'write'
          ..failFinish = failure == 'finish';
        if (failure == 'copy-changed') {
          document.onWrite = () =>
              File('${root.path}/${version.relativePath}').setLastModifiedSync(
                DateTime.fromMillisecondsSinceEpoch(
                  version.version!.modifiedAtMs + 1000,
                ),
              );
        }
        var current = true;
        final result = exportFolderSavedVersion(
          access: access,
          root: root.path,
          version: version,
          stillCurrent: () => current,
          pick: (_) async {
            if (failure == 'picker-cancel') return null;
            if (failure == 'owner-changed') current = false;
            return document;
          },
        );
        if (failure == 'picker-cancel') {
          expect(await result, isFalse);
          expect(document.aborts, 0);
        } else {
          final expected = failure == 'owner-changed'
              ? isA<FolderSavedOperationCancelled>()
              : failure == 'copy-changed'
              ? isA<FolderSavedVersionChanged>()
              : isA<DocumentExportException>();
          await expectLater(result, throwsA(expected));
          expect(document.aborts, 1);
        }
        expect(document.finishes, failure == 'finish' ? 1 : 0);
        expect(access.opened.single.unchanged, throwsStateError);
        expect(
          File('${root.path}/nested/note.txt').readAsStringSync(),
          'current',
        );
      },
    );
  }
}
