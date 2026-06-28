import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Encrypted blob store on the NORMAL filesystem — the LARGE-FILE tier (Phase B).
///
/// A file too big for the hidden-volume index (its per-namespace B+ tree caps at
/// a few thousand small records, so multi-hundred-MB media can't live there) is
/// stored here instead. Each blob is a directory of PER-PIECE sealed files
/// (`<blob>/p<idx>`), one independent ChaCha20-Poly1305 box per piece:
///
///  * pieces arrive in ANY order over the lossy path → each is its own file, so
///    there is no random-offset seeking and a half-written piece (temp+rename) is
///    never seen as complete;
///  * the content layer caps a file at ≤70 pieces, so a blob is ≤70 files;
///  * the nonce is derived from the piece index (unique per piece under the
///    blob's one-time random key → no nonce reuse), so nothing but the ciphertext
///    is stored, and a ranged/streamed read decrypts only the covering pieces —
///    the whole file never sits in RAM.
///
/// The per-blob key + the opaque blob name live in the hidden VOLUME (deniable);
/// only ciphertext is on disk. So an adversary imaging the disk sees encrypted
/// blobs of some size (existence revealable — the §16.5 deniability trade-off)
/// but cannot read them, and a delete that scrubs the key in the volume makes the
/// ciphertext unrecoverable (forward secrecy on delete) even if the file lingers.
class OnDiskBlobStore {
  OnDiskBlobStore(this._root);

  /// Root directory holding every blob's sub-directory (created on first write).
  final Directory _root;

  static final Chacha20 _aead = Chacha20.poly1305Aead();
  static const int _macLen = 16; // Poly1305 tag length

  Directory _blobDir(String name) => Directory('${_root.path}/$name');
  File _pieceFile(String name, int i) => File('${_root.path}/$name/p$i');

  /// 12-byte ChaCha20 nonce derived from the piece index (LE). Unique per piece
  /// under the blob's one-time random key, so there is no nonce reuse.
  List<int> _nonce(int pieceIndex) {
    final n = Uint8List(12);
    var x = pieceIndex;
    for (var i = 0; i < 8 && x != 0; i++) {
      n[i] = x & 0xff;
      x >>= 8;
    }
    return n;
  }

  /// Seal [bytes] (the plaintext of piece [pieceIndex]) under [key] and write it
  /// to its own file (temp + atomic rename, so an interrupted write never looks
  /// complete). Idempotent: re-storing a piece overwrites it with identical
  /// ciphertext (same key + index ⇒ same nonce ⇒ deterministic box).
  Future<void> storePiece(
      String name, Uint8List key, int pieceIndex, Uint8List bytes) async {
    final box = await _aead.encrypt(bytes,
        secretKey: SecretKey(key), nonce: _nonce(pieceIndex));
    final sealed = Uint8List(box.cipherText.length + _macLen)
      ..setRange(0, box.cipherText.length, box.cipherText)
      ..setAll(box.cipherText.length, box.mac.bytes);
    final f = _pieceFile(name, pieceIndex);
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(sealed, flush: true);
    await tmp.rename(f.path);
  }

  /// True if piece [pieceIndex] is durably stored.
  Future<bool> hasPiece(String name, int pieceIndex) =>
      _pieceFile(name, pieceIndex).exists();

  /// Decrypt + return the whole plaintext of piece [pieceIndex], or null if it is
  /// not stored / fails authentication (tampered ciphertext, wrong key).
  Future<Uint8List?> readPiece(
      String name, Uint8List key, int pieceIndex) async {
    final f = _pieceFile(name, pieceIndex);
    if (!await f.exists()) return null;
    final sealed = await f.readAsBytes();
    if (sealed.length < _macLen) return null;
    final cut = sealed.length - _macLen;
    final box = SecretBox(
      Uint8List.sublistView(sealed, 0, cut),
      nonce: _nonce(pieceIndex),
      mac: Mac(Uint8List.sublistView(sealed, cut)),
    );
    try {
      final clear = await _aead.decrypt(box, secretKey: SecretKey(key));
      return Uint8List.fromList(clear);
    } on SecretBoxAuthenticationError {
      return null; // integrity failure → treat as missing (re-request / refuse)
    }
  }

  /// Read [length] plaintext bytes at [offset], decrypting ONLY the pieces the
  /// range covers. [pieceSize]/[totalSize] describe the plaintext layout. Returns
  /// null if a covering piece is missing (the caller re-requests / retries).
  Future<Uint8List?> readRange(String name, Uint8List key, int offset,
      int length, int pieceSize, int totalSize) async {
    if (length <= 0) return Uint8List(0);
    final out = BytesBuilder(copy: false);
    var pos = offset;
    var remaining = length;
    Uint8List? cached; // 1-piece cache: consecutive chunks share a piece
    var cachedIndex = -1;
    while (remaining > 0 && pos < totalSize) {
      final pieceIndex = pos ~/ pieceSize;
      if (pieceIndex != cachedIndex) {
        cached = await readPiece(name, key, pieceIndex);
        if (cached == null) return null;
        cachedIndex = pieceIndex;
      }
      final within = pos - pieceIndex * pieceSize;
      final avail = cached!.length - within;
      final take = avail < remaining ? avail : remaining;
      if (take <= 0) break; // declared range runs past the stored bytes
      out.add(Uint8List.sublistView(cached, within, within + take));
      pos += take;
      remaining -= take;
    }
    return out.toBytes();
  }

  /// True if the blob's directory exists (some pieces stored). Completeness is
  /// tracked by the caller (the volume metadata counts stored pieces).
  Future<bool> exists(String name) => _blobDir(name).exists();

  /// Remove every piece of the blob. Confidentiality rests on the in-volume key
  /// scrub (the ciphertext is useless without it); this reclaims the space.
  Future<void> delete(String name) async {
    final d = _blobDir(name);
    if (await d.exists()) await d.delete(recursive: true);
  }
}
