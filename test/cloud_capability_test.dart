import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/cloud_capability.dart';
import 'package:xveil/domain/content_manifest.dart';

class _SequenceRandom implements Random {
  _SequenceRandom(this._seed);
  int _seed;

  @override
  bool nextBool() => nextInt(2) == 1;

  @override
  double nextDouble() => nextInt(1 << 24) / (1 << 24);

  @override
  int nextInt(int max) {
    _seed = (_seed * 1103515245 + 12345) & 0x7fffffff;
    return _seed % max;
  }
}

Future<String> _link(ContentManifest manifest) => CloudCapabilityCodec.create(
  manifest: manifest,
  revision: 3,
  expiresAtMs: DateTime(2035).millisecondsSinceEpoch,
  servicePublicKey: Uint8List.fromList(List.filled(32, 0x51)),
  appId: Uint8List.fromList(List.filled(32, 0xA7)),
  endpointId: 37,
  mime: 'application/octet-stream',
  random: _SequenceRandom(7),
);

void main() {
  final bytes = Uint8List.fromList(List.generate(700, (i) => i & 0xff));
  final manifest = ContentManifest.fromBytes(
    'public.bin',
    bytes,
    pieceSize: 256,
  );

  test('strict link roundtrip contains no sovereign node id field', () async {
    final link = await _link(manifest);
    expect(link, startsWith('xveil://cloud/v1#'));
    expect(link, isNot(contains('node_id')));
    expect(link, isNot(contains('nodeId')));

    final decoded = await CloudCapabilityCodec.parse(link);
    expect(decoded.manifest.contentId, manifest.contentId);
    expect(decoded.manifest.name, 'public.bin');
    expect(decoded.manifest.size, 700);
    expect(decoded.revision, 3);
    expect(decoded.endpointId, 37);
    expect(decoded.mime, 'application/octet-stream');
    expect(decoded.servicePublicKey, everyElement(0x51));
    expect(decoded.appId, everyElement(0xA7));
  });

  test(
    'rejects malformed base64, version, truncation and hostile length',
    () async {
      for (final bad in <String>[
        'xveil://cloud/v1#***',
        'xveil://cloud/v2#AAAA',
        'xveil://cloud/v1#AAAA',
        'https://cloud/v1#AAAA',
      ]) {
        await expectLater(
          CloudCapabilityCodec.parse(bad),
          throwsFormatException,
        );
      }

      final link = await _link(manifest);
      final uri = Uri.parse(link);
      final raw = Uint8List.fromList(
        base64Url.decode(base64Url.normalize(uri.fragment)),
      );
      // Sealed-length field starts after magic, four 32-byte values, u16, u64,
      // and nonce. Claim 1 MiB while supplying the original short payload.
      ByteData.sublistView(raw).setUint32(154, 1024 * 1024, Endian.big);
      final hostile =
          'xveil://cloud/v1#${base64Url.encode(raw).replaceAll('=', '')}';
      await expectLater(
        CloudCapabilityCodec.parse(hostile),
        throwsFormatException,
      );
    },
  );

  test(
    'wrong key or authenticated metadata tamper releases no manifest',
    () async {
      final link = await _link(manifest);
      final uri = Uri.parse(link);
      final raw = Uint8List.fromList(
        base64Url.decode(base64Url.normalize(uri.fragment)),
      );
      raw[40] ^= 0x80; // capability key byte
      final wrongKey =
          'xveil://cloud/v1#${base64Url.encode(raw).replaceAll('=', '')}';
      await expectLater(
        CloudCapabilityCodec.parse(wrongKey),
        throwsFormatException,
      );

      final raw2 = Uint8List.fromList(
        base64Url.decode(base64Url.normalize(uri.fragment)),
      );
      raw2[100] ^= 1; // service/app AAD
      final tampered =
          'xveil://cloud/v1#${base64Url.encode(raw2).replaceAll('=', '')}';
      await expectLater(
        CloudCapabilityCodec.parse(tampered),
        throwsFormatException,
      );
    },
  );

  test('piece AEAD binds share, revision and piece index', () async {
    final capability = await CloudCapabilityCodec.parse(await _link(manifest));
    final piece = Uint8List.sublistView(bytes, 0, 256);
    final sealed = await CloudCapabilityCodec.sealPiece(
      capability: capability,
      pieceIndex: 0,
      clear: piece,
    );
    expect(
      await CloudCapabilityCodec.openPiece(
        capability: capability,
        pieceIndex: 0,
        sealed: sealed,
      ),
      piece,
    );
    final tampered = Uint8List.fromList(sealed)..[0] ^= 1;
    await expectLater(
      CloudCapabilityCodec.openPiece(
        capability: capability,
        pieceIndex: 0,
        sealed: tampered,
      ),
      throwsFormatException,
    );
    await expectLater(
      CloudCapabilityCodec.openPiece(
        capability: capability,
        pieceIndex: 1,
        sealed: sealed,
      ),
      throwsFormatException,
    );
  });

  test('request proof binds return alias, endpoint, piece and nonce', () async {
    final capability = await CloudCapabilityCodec.parse(await _link(manifest));
    final returnKey = Uint8List.fromList(List.filled(32, 3));
    final returnApp = Uint8List.fromList(List.filled(32, 4));
    final nonce = Uint8List.fromList(List.generate(16, (i) => i));
    Uint8List mac(int piece) => CloudCapabilityCodec.requestMac(
      capability: capability,
      returnServicePublicKey: returnKey,
      returnAppId: returnApp,
      returnEndpointId: 41,
      pieceIndex: piece,
      chunkIndex: 0,
      requestNonce: nonce,
    );
    expect(mac(0), hasLength(32));
    expect(mac(0), mac(0));
    expect(mac(1), isNot(mac(0)));
  });

  Future<String> folderLink({int listingRevision = 1}) =>
      CloudCapabilityCodec.createFolder(
        folderName: 'Проекты',
        listingRevision: listingRevision,
        expiresAtMs: DateTime(2035).millisecondsSinceEpoch,
        servicePublicKey: Uint8List.fromList(List.filled(32, 0x51)),
        appId: Uint8List.fromList(List.filled(32, 0xA7)),
        endpointId: 41,
        random: _SequenceRandom(11),
      );

  test('folder link round-trips and legacy file parse fails closed', () async {
    final link = await folderLink(listingRevision: 4);
    final parsed = await CloudCapabilityCodec.parseLink(link);
    expect(parsed, isA<ParsedCloudFolderLink>());
    final capability = (parsed as ParsedCloudFolderLink).capability;
    expect(capability.folderName, 'Проекты');
    expect(capability.listingRevision, 4);
    expect(capability.endpointId, 41);
    await expectLater(
      CloudCapabilityCodec.parse(link),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('folder link'),
        ),
      ),
      reason: 'pre-folder callers must never mistake a listing for content',
    );
    // A file link keeps parsing through BOTH entry points.
    final fileBytes = Uint8List.fromList(List.generate(64, (i) => i));
    final fileLink = await _link(ContentManifest.fromBytes('f.bin', fileBytes));
    expect(
      await CloudCapabilityCodec.parseLink(fileLink),
      isA<ParsedCloudFileLink>(),
    );
    expect((await CloudCapabilityCodec.parse(fileLink)).revision, 3);
  });

  test('listing seals per revision and rejects rollback and tamper', () async {
    final link = await folderLink(listingRevision: 2);
    final capability =
        ((await CloudCapabilityCodec.parseLink(link)) as ParsedCloudFolderLink)
            .capability;
    final listing = CloudFolderListing(
      name: 'Проекты',
      revision: 3,
      entries: [
        const CloudFolderListingEntry.file(
          name: 'a.bin',
          size: 10,
          link: 'xveil://cloud/v1#AAAA',
          mime: 'application/octet-stream',
        ),
        const CloudFolderListingEntry.folder(
          name: 'вложенная',
          entries: [
            CloudFolderListingEntry.file(
              name: 'b.txt',
              size: 4,
              link: 'xveil://cloud/v1#BBBB',
            ),
          ],
        ),
      ],
    );
    final sealed = await CloudCapabilityCodec.sealListing(
      capability: capability,
      listing: listing,
    );
    final opened = await CloudCapabilityCodec.openListing(
      capability: capability,
      revision: 3,
      sealed: sealed,
    );
    expect(opened.revision, 3);
    expect(opened.entries, hasLength(2));
    expect(opened.entries[1].isFolder, isTrue);
    expect(opened.entries[1].entries!.single.name, 'b.txt');
    expect(opened.totalEntries, 3);

    // Rollback below the link's floor fails before any crypto.
    await expectLater(
      CloudCapabilityCodec.openListing(
        capability: capability,
        revision: 1,
        sealed: sealed,
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('rollback'),
        ),
      ),
    );
    // A revision mismatch (server lying about the AAD-bound revision) fails
    // authentication.
    await expectLater(
      CloudCapabilityCodec.openListing(
        capability: capability,
        revision: 4,
        sealed: sealed,
      ),
      throwsA(isA<FormatException>()),
    );
    // Bit-flip fails authentication.
    final tampered = Uint8List.fromList(sealed)..[8] ^= 1;
    await expectLater(
      CloudCapabilityCodec.openListing(
        capability: capability,
        revision: 3,
        sealed: tampered,
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('authentication'),
        ),
      ),
    );
  });

  test('listing bounds fail closed', () async {
    // Entry-count cap.
    final flood = CloudFolderListing(
      name: 'flood',
      revision: 1,
      entries: [
        for (var i = 0; i < CloudFolderListing.maxTotalEntries + 1; i++)
          CloudFolderListingEntry.file(
            name: 'f$i',
            size: 1,
            link: 'xveil://cloud/v1#X',
          ),
      ],
    );
    expect(CloudFolderListing.fromJson(flood.toJson()), isNull);
    // Depth cap.
    var nested = const CloudFolderListingEntry.folder(
      name: 'leaf',
      entries: [],
    );
    for (var i = 0; i < CloudFolderListing.maxDepth + 1; i++) {
      nested = CloudFolderListingEntry.folder(name: 'd$i', entries: [nested]);
    }
    final deep = CloudFolderListing(
      name: 'deep',
      revision: 1,
      entries: [nested],
    );
    expect(CloudFolderListing.fromJson(deep.toJson()), isNull);
    // A within-bounds listing round-trips.
    final fine = CloudFolderListing(
      name: 'fine',
      revision: 2,
      entries: const [
        CloudFolderListingEntry.file(
          name: 'ok',
          size: 1,
          link: 'xveil://cloud/v1#OK',
        ),
      ],
    );
    expect(CloudFolderListing.fromJson(fine.toJson())?.revision, 2);
  });
}
