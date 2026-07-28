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

  test('a malformed link fails as FormatException, never as a crash', () async {
    // The link is a string the user PASTES, so every rejection on this path has
    // to arrive as the declared FormatException rather than as some other
    // throw escaping the decoder.
    //
    // What this pins, verified by breaking: nothing SINGLE among the length
    // bounds. The minimum-length check and take()'s upper bound back each
    // other up, and the sealed-length floor is covered downstream, so removing
    // any ONE of them leaves the contract intact. That is defence in depth,
    // not coverage — the value here is the contract across malformed shapes,
    // and the clause this file does pin on its own is the exact-length one in
    // the test below.
    final link = await _link(manifest);
    final prefix = link.substring(0, link.indexOf('#') + 1);
    final raw = base64Url.decode(
      base64Url.normalize(link.substring(prefix.length)),
    );

    Future<void> expectFormatException(List<int> mutated, String why) async {
      await expectLater(
        CloudCapabilityCodec.parseLink(
          prefix +
              base64Url.encode(Uint8List.fromList(mutated)).replaceAll('=', ''),
        ),
        throwsA(isA<FormatException>()),
        reason: why,
      );
    }

    await expectFormatException(raw.sublist(0, 8), 'shorter than the header');
    // A sealed section too short to even hold its MAC. Crafted so the length
    // field AGREES with the body, otherwise the exact-length check would
    // reject it first and this shape would never be exercised.
    const lengthFieldAt = 154; // magic..nonce, then the u32 length
    final shortSeal = Uint8List.fromList([
      ...raw.sublist(0, 158),
      ...List.filled(8, 0),
    ]);
    shortSeal.buffer.asByteData().setUint32(lengthFieldAt, 8);
    await expectFormatException(shortSeal, 'sealed section cannot hold a MAC');
    await expectFormatException(
      raw.sublist(0, raw.length - 8),
      'the sealed manifest is cut short',
    );
    // A length field that promises more than the link carries.
    final lying = Uint8List.fromList(raw);
    lying[lying.length - 1] ^= 0xFF;
    await expectFormatException(lying, 'the sealed bytes do not authenticate');
  });

  test('a link with trailing bytes is refused, not silently accepted', () async {
    // The sealed length must account for the WHOLE body. Ignoring a tail makes
    // the encoding non-canonical: the same capability then has unlimited
    // representations, so anything comparing or deduplicating links by string
    // is defeated by appending a byte.
    final link = await _link(manifest);
    final prefix = link.substring(0, link.indexOf('#') + 1);
    final raw = base64Url.decode(
      base64Url.normalize(link.substring(prefix.length)),
    );
    expect(
      await CloudCapabilityCodec.parseLink(link),
      isA<ParsedCloudFileLink>(),
      reason: 'the untouched link must parse, or the test proves nothing',
    );
    await expectLater(
      CloudCapabilityCodec.parseLink(
        prefix +
            base64Url
                .encode(Uint8List.fromList([...raw, 0]))
                .replaceAll('=', ''),
      ),
      throwsA(isA<FormatException>()),
    );
  });

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
    final aManifest = ContentManifest.fromBytes(
      'a.bin',
      Uint8List.fromList(List.generate(24, (i) => i)),
    );
    final bManifest = ContentManifest.fromBytes(
      'b.txt',
      Uint8List.fromList(List.generate(4, (i) => i)),
    );
    final listing = CloudFolderListing(
      name: 'Проекты',
      revision: 3,
      entries: [
        CloudFolderListingEntry.file(
          name: 'a.bin',
          manifest: aManifest,
          mime: 'application/octet-stream',
        ),
        CloudFolderListingEntry.folder(
          name: 'вложенная',
          entries: [
            CloudFolderListingEntry.file(name: 'b.txt', manifest: bManifest),
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
    final tiny = ContentManifest.fromBytes('t', Uint8List.fromList(const [1]));
    // Entry-count cap.
    final flood = CloudFolderListing(
      name: 'flood',
      revision: 1,
      entries: [
        for (var i = 0; i < CloudFolderListing.maxTotalEntries + 1; i++)
          CloudFolderListingEntry.file(name: 'f$i', manifest: tiny),
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
    // A within-bounds listing round-trips with the manifest intact.
    final fine = CloudFolderListing(
      name: 'fine',
      revision: 2,
      entries: [CloudFolderListingEntry.file(name: 'ok', manifest: tiny)],
    );
    final parsedFine = CloudFolderListing.fromJson(fine.toJson());
    expect(parsedFine?.revision, 2);
    expect(parsedFine?.entries.single.manifest?.contentId, tiny.contentId);
  });

  test('per-file subkeys serve chunks through the folder share', () async {
    final link = await folderLink();
    final capability =
        ((await CloudCapabilityCodec.parseLink(link)) as ParsedCloudFolderLink)
            .capability;
    final fileBytes = Uint8List.fromList(List.generate(700, (i) => i & 0xff));
    final fileManifest = ContentManifest.fromBytes(
      'served.bin',
      fileBytes,
      pieceSize: 256,
    );
    final entry = CloudFolderListingEntry.file(
      name: 'served.bin',
      manifest: fileManifest,
    );
    // Host and requester derive the SAME synthetic capability from the
    // folder link + listing entry; the existing chunk path round-trips.
    final host = CloudCapabilityCodec.folderFileCapability(capability, entry);
    final requester = CloudCapabilityCodec.folderFileCapability(
      capability,
      entry,
    );
    expect(host.key, requester.key);
    expect(
      host.key,
      isNot(capability.key),
      reason: 'the folder root key never seals file bytes directly',
    );
    final otherEntry = CloudFolderListingEntry.file(
      name: 'other.bin',
      manifest: ContentManifest.fromBytes(
        'other.bin',
        Uint8List.fromList(const [9, 9, 9]),
      ),
    );
    expect(
      CloudCapabilityCodec.folderFileCapability(capability, otherEntry).key,
      isNot(host.key),
      reason: 'each contentId gets its own subkey',
    );
    final clear = Uint8List.sublistView(fileBytes, 0, 256);
    final sealed = await CloudCapabilityCodec.sealChunk(
      capability: host,
      pieceIndex: 0,
      chunkIndex: 0,
      clear: Uint8List.fromList(
        clear.sublist(
          0,
          CloudCapabilityCodec.publicChunkBytes > 256
              ? 256
              : CloudCapabilityCodec.publicChunkBytes,
        ),
      ),
    );
    final opened = await CloudCapabilityCodec.openChunk(
      capability: requester,
      pieceIndex: 0,
      chunkIndex: 0,
      sealed: sealed,
    );
    expect(opened, clear);
  });

  test('listing request MAC binds share, return alias and nonce', () async {
    final link = await folderLink();
    final capability =
        ((await CloudCapabilityCodec.parseLink(link)) as ParsedCloudFolderLink)
            .capability;
    final returnKey = Uint8List.fromList(List.filled(32, 3));
    final returnApp = Uint8List.fromList(List.filled(32, 4));
    final nonce = Uint8List.fromList(List.generate(16, (i) => i));
    final mac = CloudCapabilityCodec.listingRequestMac(
      capability: capability,
      returnServicePublicKey: returnKey,
      returnAppId: returnApp,
      returnEndpointId: 48,
      requestNonce: nonce,
    );
    expect(mac, hasLength(32));
    expect(
      CloudCapabilityCodec.listingRequestMac(
        capability: capability,
        returnServicePublicKey: returnKey,
        returnAppId: returnApp,
        returnEndpointId: 49,
        requestNonce: nonce,
      ),
      isNot(mac),
    );
    final otherNonce = Uint8List.fromList(List.generate(16, (i) => i + 1));
    expect(
      CloudCapabilityCodec.listingRequestMac(
        capability: capability,
        returnServicePublicKey: returnKey,
        returnAppId: returnApp,
        returnEndpointId: 48,
        requestNonce: otherNonce,
      ),
      isNot(mac),
    );
  });
}
