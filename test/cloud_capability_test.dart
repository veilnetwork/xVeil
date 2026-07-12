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
}
