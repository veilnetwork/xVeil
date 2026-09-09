// The direct download route serves attachments, not the store.
//
// report24 A4-1: `GET /v1/files/download` took any `fileId` and read it out of
// the file store — where `groups.index` and `group:<hex>` carry epoch keys in
// `kk`/`ckk`, and `cloud.capabilities.registry.v2` carries provider seeds. A
// read-only token, whose whole purpose is reading messages, could name them.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/api/attachment_downloads.dart';
import 'package:xveil/data/storage/storage.dart';

const _attachment =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _unreferenced =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

class _Store implements Storage {
  _Store(this.referenced);

  Set<String> referenced;
  int snapshots = 0;
  final Map<String, Uint8List> files = {
    _attachment: Uint8List.fromList([1, 2, 3]),
    _unreferenced: Uint8List.fromList([4, 5, 6]),
    'groups.index': Uint8List.fromList([7, 7, 7]),
    'cloud.capabilities.registry.v2': Uint8List.fromList([8, 8, 8]),
  };

  @override
  Future<SharedContentReferenceSnapshot>
  sharedContentReferenceSnapshot() async {
    snapshots++;
    return SharedContentReferenceSnapshot(
      storedContentIds: files.keys.toSet(),
      referencedContentIds: referenced,
      complete: true,
    );
  }

  @override
  Future<int?> fileSize(String fileId) async => files[fileId]?.length;

  @override
  Future<Uint8List?> readFileRange(String id, int offset, int length) async {
    final bytes = files[id];
    if (bytes == null) return null;
    final end = offset + length;
    return Uint8List.sublistView(
      bytes,
      offset,
      end > bytes.length ? bytes.length : end,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('an attachment a message references is served', () async {
    final store = _Store({_attachment});
    final downloads = AttachmentDownloads(store);

    final source = await downloads.open(_attachment);
    expect(source, isNotNull);
    expect(source!.size, 3);
  });

  test('internal key material is not', () async {
    final store = _Store({_attachment});
    final downloads = AttachmentDownloads(store);

    // The exact ids the finding names: group epoch keys and the capability
    // registry with its provider seeds.
    expect(await downloads.open('groups.index'), isNull);
    expect(await downloads.open('cloud.capabilities.registry.v2'), isNull);
  });

  test('a stored blob nothing references is not served either', () async {
    // The point of asking for PROVENANCE rather than filtering names: an id
    // nobody wrote a denylist entry for is still refused.
    final store = _Store({_attachment});
    expect(await AttachmentDownloads(store).open(_unreferenced), isNull);
  });

  test('an attachment that arrives after the walk becomes downloadable',
      () async {
    var clock = 1000;
    final store = _Store({_attachment});
    final downloads = AttachmentDownloads(store, nowMs: () => clock);

    expect(await downloads.open(_unreferenced), isNull);
    store.referenced = {_attachment, _unreferenced};

    // Within the refresh floor the answer is still the cached one…
    clock += 1000;
    expect(await downloads.open(_unreferenced), isNull);

    // …and past it, one walk picks the new attachment up.
    clock += 6000;
    expect(await downloads.open(_unreferenced), isNotNull);
  });

  test('a caller asking for ids that do not exist cannot drive a scan each time',
      () async {
    var clock = 1000;
    final store = _Store({_attachment});
    final downloads = AttachmentDownloads(store, nowMs: () => clock);

    for (var i = 0; i < 20; i++) {
      expect(await downloads.open('c' * 64), isNull);
      clock += 100; // 2 seconds of hammering, under the floor
    }

    expect(
      store.snapshots,
      lessThanOrEqualTo(2),
      reason: 'the message log must not be walked once per request',
    );
  });
}
