import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/crypto/blake3.dart';

/// Cross-language vectors for the multi-chunk path.
///
/// The Dart port was single-chunk (≤1024 bytes) behind a debug `assert`, so a
/// release build returned a WRONG digest for anything longer instead of
/// failing. That was reachable in production: [blake3Hash] derives a peer's
/// node id from their public key, and veil's hybrid `ed25519+falcon1024` key
/// is 1825 bytes — a scanned invite from a post-quantum peer produced an id
/// that matched nothing, silently.
///
/// Every expectation below was PRODUCED by the reference Rust `blake3` crate
/// over the official test input (`input[i] = i % 251`), not recalled. Lengths
/// 3072 and 5000 are deliberate: their chunk counts are not powers of two, and
/// BLAKE3's tree gives the left subtree the largest power of two BELOW the
/// total rather than splitting evenly — a balanced split passes 1024/2048/4096
/// and fails exactly here.
Uint8List _input(int n) =>
    Uint8List.fromList(List<int>.generate(n, (i) => i % 251));

String _hex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  const vectors = <int, String>{
    0: 'af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262',
    1: '2d3adedff11b61f14c886e35afa036736dcd87a74d27b5c1510225d0f592e213',
    63: 'e9bc37a594daad83be9470df7f7b3798297c3d834ce80ba85d6e207627b7db7b',
    64: '4eed7141ea4a5cd4b788606bd23f46e212af9cacebacdc7d1f4c6dc7f2511b98',
    1023: '10108970eeda3eb932baac1428c7a2163b0e924c9a9e25b35bba72b28f70bd11',
    1024: '42214739f095a406f3fc83deb889744ac00df831c10daa55189b5d121c855af7',
    1025: 'd00278ae47eb27b34faecf67b4fe263f82d5412916c1ffd97c8cb7fb814b8444',
    // The length that made this a bug and not a limitation.
    1825: 'c6360554f45cc1a08cbafc5667efd3e10a7edcd4146fc59752ebc788dbc883fe',
    2048: 'e776b6028c7cd22a4d0ba182a8bf62205d2ef576467e838ed6f2529b85fba24a',
    3072: 'b98cb0ff3623be03326b373de6b9095218513e64f1ee2edd2525c7ad1e5cffd2',
    4096: '015094013f57a5277b59d8475c0501042c0b642e531b0a1c8f58d2163229e969',
    5000: 'ee78d92070de3df1c57c37002abf0a6b1a6589acdeef4d8ffac7cf3d9e8f2836',
  };

  vectors.forEach((len, want) {
    test('blake3 of $len bytes matches the reference implementation', () {
      expect(_hex(blake3Hash(_input(len))), want);
    });
  });

  test('derive_key also spans chunks', () {
    // The other entry point takes the same tree path, and its context key is
    // itself a BLAKE3 output — a mistake here would be invisible in the plain
    // hash vectors above.
    expect(
      _hex(blake3DeriveKey('veil.test.ctx', _input(2000))),
      '6505ec703720979a2864e3ef4ee8c696e80cedcc7e2b05622e067c53c071623e',
    );
  });

  test('a 1825-byte key hashes to a stable id, not a truncated one', () {
    // Guards the specific production path: a hybrid public key arriving in a
    // scanned invite. Two keys differing only past byte 1024 must not collide.
    final a = _input(1825);
    final b = Uint8List.fromList(a)..[1500] ^= 0xff;
    expect(_hex(blake3Hash(a)), isNot(_hex(blake3Hash(b))));
    expect(utf8.encode(''), isEmpty); // keeps the import honest
  });
}
