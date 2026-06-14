/// Minimal, auditable BLAKE3 — enough for veil app-id derivation. Deliberately
/// dependency-free (no third-party crypto in a tool used against state-level
/// adversaries) and verified against the official empty-string vector plus the
/// veil app_id reference vectors (see test/crypto/blake3_test.dart).
///
/// Scope: inputs up to one 1024-byte chunk. veil app_id IKM is capped at 552
/// bytes and the derive-key context is short, so the single-chunk path covers
/// every call site. Longer inputs assert in debug.
library;

import 'dart:convert';
import 'dart:typed_data';

const int _mask = 0xFFFFFFFF;
const List<int> _iv = [
  0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, //
  0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
];
const List<int> _perm = [2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8];

const int _chunkStart = 1 << 0;
const int _chunkEnd = 1 << 1;
const int _root = 1 << 3;
const int _deriveKeyContext = 1 << 5;
const int _deriveKeyMaterial = 1 << 6;

int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & _mask;

void _g(Uint32List s, int a, int b, int c, int d, int mx, int my) {
  s[a] = s[a] + s[b] + mx;
  s[d] = _rotr(s[d] ^ s[a], 16);
  s[c] = s[c] + s[d];
  s[b] = _rotr(s[b] ^ s[c], 12);
  s[a] = s[a] + s[b] + my;
  s[d] = _rotr(s[d] ^ s[a], 8);
  s[c] = s[c] + s[d];
  s[b] = _rotr(s[b] ^ s[c], 7);
}

/// One compression. Returns the 16-word output state (caller takes the first
/// 8 words as the chaining value / 32-byte digest).
Uint32List _compress(
  List<int> cv,
  Uint32List m,
  int counterLow,
  int counterHigh,
  int blockLen,
  int flags,
) {
  final s = Uint32List(16);
  for (var i = 0; i < 8; i++) {
    s[i] = cv[i];
  }
  s[8] = _iv[0];
  s[9] = _iv[1];
  s[10] = _iv[2];
  s[11] = _iv[3];
  s[12] = counterLow;
  s[13] = counterHigh;
  s[14] = blockLen;
  s[15] = flags;

  final w = Uint32List.fromList(m);
  for (var r = 0; r < 7; r++) {
    _g(s, 0, 4, 8, 12, w[0], w[1]);
    _g(s, 1, 5, 9, 13, w[2], w[3]);
    _g(s, 2, 6, 10, 14, w[4], w[5]);
    _g(s, 3, 7, 11, 15, w[6], w[7]);
    _g(s, 0, 5, 10, 15, w[8], w[9]);
    _g(s, 1, 6, 11, 12, w[10], w[11]);
    _g(s, 2, 7, 8, 13, w[12], w[13]);
    _g(s, 3, 4, 9, 14, w[14], w[15]);
    if (r < 6) {
      final p = Uint32List(16);
      for (var i = 0; i < 16; i++) {
        p[i] = w[_perm[i]];
      }
      w.setAll(0, p);
    }
  }
  for (var i = 0; i < 8; i++) {
    s[i] ^= s[i + 8];
  }
  return s;
}

Uint32List _blockWords(Uint8List block64) {
  final m = Uint32List(16);
  final bd = ByteData.sublistView(block64);
  for (var i = 0; i < 16; i++) {
    m[i] = bd.getUint32(i * 4, Endian.little);
  }
  return m;
}

/// Hash [input] (≤ one chunk) under chaining key [key] (8 words) and [baseFlags]
/// (0 = plain, DERIVE_KEY_CONTEXT / DERIVE_KEY_MATERIAL for derive_key).
Uint8List _hashChunk(List<int> key, Uint8List input, int baseFlags) {
  assert(input.length <= 1024, 'single-chunk BLAKE3 only');
  final len = input.length;
  final nBlocks = len == 0 ? 1 : (len + 63) ~/ 64;
  var cv = key;
  for (var b = 0; b < nBlocks; b++) {
    final start = b * 64;
    final end = (start + 64 <= len) ? start + 64 : len;
    final blockLen = end - start;
    final blk = Uint8List(64);
    if (blockLen > 0) {
      blk.setRange(0, blockLen, input, start);
    }
    final last = b == nBlocks - 1;
    var flags = baseFlags;
    if (b == 0) flags |= _chunkStart;
    if (last) flags |= _chunkEnd | _root;
    final out = _compress(cv, _blockWords(blk), 0, 0, blockLen, flags);
    if (last) {
      final res = Uint8List(32);
      final bd = ByteData.sublistView(res);
      for (var i = 0; i < 8; i++) {
        bd.setUint32(i * 4, out[i], Endian.little);
      }
      return res;
    }
    cv = out.sublist(0, 8);
  }
  throw StateError('unreachable');
}

/// Plain BLAKE3 digest (32 bytes).
Uint8List blake3Hash(Uint8List input) => _hashChunk(_iv, input, 0);

/// BLAKE3 `derive_key` mode: a context-separated KDF.
Uint8List blake3DeriveKey(String context, Uint8List keyMaterial) {
  final ctx = Uint8List.fromList(utf8.encode(context));
  final ctxKeyBytes = _hashChunk(_iv, ctx, _deriveKeyContext);
  final bd = ByteData.sublistView(ctxKeyBytes);
  final ctxKey = List<int>.generate(8, (i) => bd.getUint32(i * 4, Endian.little));
  return _hashChunk(ctxKey, keyMaterial, _deriveKeyMaterial);
}
