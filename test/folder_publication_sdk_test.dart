// Opt-in qualification against a complete SDK. FS-only fixtures deliberately
// fail its ordinary ABI gate; they must never be accepted by this mode.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:veil_flutter/src/native.dart' show VeilAbiContractMismatch;
import 'package:xveil/core/document_export.dart';
import 'package:xveil/data/folder_saved_versions.dart';
import 'package:xveil/data/folder_publication.dart';
import 'package:xveil/data/node/veil_library.dart';
import 'package:xveil/state/folder_saved_export.dart';
import 'package:xveil/state/folder_sync_adapters.dart';

import 'support/folder_fs_fixture.dart';
import 'support/range_source_util.dart';
import 'support/precise_file_time.dart';

class _Destination implements ExportDocument {
  final bytes = BytesBuilder();
  int finishes = 0;
  @override
  Future<void> write(List<int> chunk) async {
    expect(chunk.length, lessThanOrEqualTo(256 * 1024));
    bytes.add(chunk);
  }

  @override
  Future<void> finish() async => finishes++;
  @override
  Future<void> abort() async => fail('Unexpected export failure');
}

void main() {
  final requested = Platform.environment['XVEIL_FULL_FOLDER_SDK'] == '1';
  final Object skip = requested
      ? false
      : 'Set XVEIL_FULL_FOLDER_SDK=1 and VEIL_FFI_DYLIB to a complete SDK';
  late LocalFolderSyncDisk disk;
  late Directory root;
  setUpAll(() {
    if (requested) disk = folderDiskFixture();
  });
  setUp(() {
    if (requested) {
      root = Directory.systemTemp.createTempSync('xveil-folder-sdk-');
    }
  });
  tearDown(() {
    if (requested) root.deleteSync(recursive: true);
  });

  test('complete SDK passes the default gate without a library injection', () {
    expect(disk.library, isNull);
    final library = verifiedVeilLibrary();
    expect(library.providesSymbol('veil_config_init'), isTrue);
    expect(library.providesSymbol('veil_node_start_deferred'), isTrue);
    expect(library.providesSymbol('veil_fs_folder_discard_saved'), isTrue);
    expect(
      () => verifiedVeilLibrary(expectedAbiHash: 'wrong-contract'),
      throwsA(isA<VeilAbiContractMismatch>()),
    );
    // A refused explicit check cannot poison the process default.
    expect(verifiedVeilLibrary().handle, library.handle);
  }, skip: skip);

  test(
    'scan and stat preserve the native publisher millisecond stamp',
    () async {
      const modifiedMs = 1700000000123;
      final file = File('${root.path}/note.bin');
      await file.writeAsBytes([1, 2, 3]);
      await setPreciseFileTime(file, modifiedMs);
      final stat = await disk.stat(root.path, 'note.bin');
      final scan = await disk.scan(root.path);
      // Read the same object through the native descriptor metadata API.
      const saved = '.xveil-00000000000000000000000000000000.incoming';
      await file.rename('${root.path}/$saved');
      final scope = NativeFolderSession.open(root.path);
      try {
        final native = scope.openSaved(saved)!;
        try {
          expect(native.version.modifiedAtMs, modifiedMs);
          expect(stat!.modifiedAtMs, native.version.modifiedAtMs);
          expect(stat.size, native.version.size);
          expect(scan.unreadable, isEmpty);
          expect(scan.files.single.modifiedAtMs, native.version.modifiedAtMs);
        } finally {
          await native.source.dispose();
        }
      } finally {
        scope.close();
      }
    },
    skip: skip,
  );

  test(
    'default SDK publishes, lists, exports and explicitly removes a copy',
    () async {
      final previous = Uint8List.fromList(
        List.generate(600017, (i) => i % 251),
      );
      final current = Uint8List.fromList([9, 8, 7]);
      await writeBytes(disk, root.path, 'nested/note.bin', previous);
      await writeBytes(disk, root.path, 'nested/note.bin', current);
      const access = NativeFolderSavedVersions(); // Default verified SDK.
      final versions = await access.list(root.path);
      expect(versions.entries, hasLength(1));
      final copy = versions.entries.single;
      expect(copy.previous, isTrue);
      expect(copy.originalPath, 'nested/note.bin');
      final destination = _Destination();
      expect(
        await exportFolderSavedVersion(
          access: access,
          root: root.path,
          version: copy,
          stillCurrent: () => true,
          pick: (_) async => destination,
        ),
        isTrue,
      );
      expect(destination.finishes, 1);
      expect(destination.bytes.toBytes(), previous);
      expect(
        await access.discard(
          root.path,
          copy,
          confirm: () async => true,
          stillCurrent: () => true,
        ),
        isTrue,
      );
      expect((await access.list(root.path)).entries, isEmpty);
      expect(await readAllFrom(disk, root.path, 'nested/note.bin'), current);
      final scan = await disk.scan(root.path);
      expect(scan.files.map((file) => file.path), ['nested/note.bin']);
    },
    skip: skip,
  );
}
