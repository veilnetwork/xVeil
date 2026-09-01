import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/data/veil_bundle.dart';
import 'package:xveil/state/model_import.dart';

/// Installing a received model used to pull the WHOLE blob into one Uint8List
/// and then write a second full copy to the stage. Two complete copies of a
/// model at the peak, against a ceiling of 2 GiB — which is what the format
/// arithmetic can be trusted with, not what a phone can hold. A bundle
/// anywhere near it did not get refused; it took the app down (report14
/// X14-M2).
///
/// What is pinned: the largest single read, the ceiling being a RECEIVING
/// policy checked before any read, and the whole-blob read not happening at
/// all.
class _RecordingStore implements Storage {
  _RecordingStore(this.bytes);

  final Uint8List bytes;

  /// Every range asked for, so the largest one can be checked.
  final ranges = <({int offset, int length})>[];

  /// Reads of the whole blob. The defect was one of these per install.
  int wholeReads = 0;

  /// Make the blob look absent from the size call on.
  bool vanish = false;

  @override
  Future<int?> fileSize(String fileId) async => vanish ? null : bytes.length;

  @override
  Future<Uint8List?> readFileRange(
    String fileId,
    int offset,
    int length,
  ) async {
    ranges.add((offset: offset, length: length));
    if (vanish) return null;
    final end = offset + length > bytes.length ? bytes.length : offset + length;
    if (offset >= bytes.length) return Uint8List(0);
    return Uint8List.sublistView(bytes, offset, end);
  }

  @override
  Future<Uint8List?> loadFile(String fileId, {int? maxBytes}) async {
    wholeReads++;
    return bytes;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Uint8List payload(int size) =>
      Uint8List.fromList([for (var i = 0; i < size; i++) i & 0xff]);

  test('a bundle is copied out in bounded chunks, never read whole', () async {
    // Several chunks' worth, so "one read" and "one chunk" cannot be confused.
    final bytes = payload(5 * 1024 * 1024 + 12345);
    final store = _RecordingStore(bytes);

    final result = await stageReceivedBundle(store, 'blob');
    final staged = result.bundle;
    expect(staged, isNotNull, reason: 'this one is well under the ceiling');
    addTearDown(staged!.dispose);

    expect(
      staged.file.readAsBytesSync(),
      equals(bytes),
      reason:
          'streaming that loses or reorders bytes is worse than not '
          'streaming',
    );
    expect(
      store.wholeReads,
      0,
      reason: 'reading the blob whole is the allocation this exists to avoid',
    );
    expect(store.ranges, isNotEmpty);
    final largest = store.ranges
        .map((r) => r.length)
        .reduce((a, b) => a > b ? a : b);
    expect(
      largest,
      lessThanOrEqualTo(1024 * 1024),
      reason: 'the peak must not scale with the bundle',
    );
    expect(
      store.ranges.length,
      greaterThan(1),
      reason:
          'a single range for the whole file is the old behaviour wearing '
          'a new name',
    );
  });

  test(
    'a bundle past what this device accepts is refused before any read',
    () async {
      final store = _RecordingStore(payload(1024));

      final result = await stageReceivedBundle(store, 'blob', maxBytes: 512);

      expect(result.bundle, isNull);
      expect(result.refusal, BundleStageRefusal.tooLarge);
      expect(
        store.ranges,
        isEmpty,
        reason:
            'the size comes from the store record, so nothing needs reading '
            'to decide this',
      );
      expect(store.wholeReads, 0);
    },
  );

  test('the receiving cap is far below what the format allows', () {
    expect(
      kMaxReceivedBundleBytes,
      lessThan(kMaxBundleBytes),
      reason:
          'the format bound describes the arithmetic; a phone asked to '
          'install 2 GiB dies rather than refusing',
    );
    // Room for the real bundles several times over: the speech model is one
    // ~57 MB file and a translation pair is a few hundred MB at the outside.
    expect(kMaxReceivedBundleBytes, greaterThanOrEqualTo(256 * 1024 * 1024));
  });

  test('a blob that is not there is named, not silently empty', () async {
    final store = _RecordingStore(payload(16))..vanish = true;
    final result = await stageReceivedBundle(store, 'blob');
    expect(result.bundle, isNull);
    expect(result.refusal, BundleStageRefusal.missing);
  });

  test('a record that disappears mid-copy leaves nothing behind', () async {
    // Its OWN temp root, not the machine's. `Directory.systemTemp` is shared
    // by every test file the runner has in flight, so counting `xveil-bundle*`
    // there charges this test for stages other tests are legitimately holding
    // open -- which it did, failing in full runs and passing alone. The
    // overridden root is visible to the code under test, so what it creates
    // lands where only this test looks.
    final root = await Directory.systemTemp.createTemp('xveil-stage-scope');
    addTearDown(() async {
      if (root.existsSync()) await root.delete(recursive: true);
    });

    Set<String> stages() => root
        .listSync()
        .whereType<Directory>()
        .map((d) => d.path)
        .where(
          (p) =>
              p.split(Platform.pathSeparator).last.startsWith('xveil-bundle'),
        )
        .toSet();

    final store = _VanishAfterFirstChunk(payload(3 * 1024 * 1024));
    final partial = await IOOverrides.runZoned(
      () => stageReceivedBundle(store, 'blob'),
      getSystemTempDirectory: () => root,
    );

    expect(partial.bundle, isNull);
    expect(partial.refusal, BundleStageRefusal.missing);
    expect(
      stages(),
      isEmpty,
      reason:
          'half a model left in the temp directory is a half-installed '
          'pair for the next reader to trip over',
    );
  });
}

/// Answers the first range and then reports the record gone, the way a store
/// that lost a piece under a running copy would.
class _VanishAfterFirstChunk extends _RecordingStore {
  _VanishAfterFirstChunk(super.bytes);

  int served = 0;

  @override
  Future<Uint8List?> readFileRange(
    String fileId,
    int offset,
    int length,
  ) async {
    if (served++ >= 1) return null;
    return super.readFileRange(fileId, offset, length);
  }
}
