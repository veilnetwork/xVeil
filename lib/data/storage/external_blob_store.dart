import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:veil_flutter/veil_flutter.dart' show veilSealBytes, veilUnsealBytes;

import '../../crypto/blake3.dart';

/// Encrypted, at-rest storage for LARGE file blobs kept OUTSIDE the deniable
/// hidden-volume container — so the container isn't bloated past its
/// atomic-delete ceiling. The blob on disk is opaque XChaCha20-Poly1305
/// ciphertext: its per-blob key is derived from a master key that lives ONLY in
/// the unlocked container, so a seized device sees indistinguishable-from-random
/// files with no name, peer, or timestamp in the path. (The EXISTENCE/size of a
/// large transfer does leak — an accepted tradeoff for files > the small-file
/// in-container threshold.)
///
/// On-disk layout per blob: `[1 version][16 nonce-prefix]` then a sequence of
/// `[u32-LE ciphertext-len][ciphertext]` segments. Each segment encrypts up to
/// [_segment] plaintext bytes under nonce = `prefix || u64-LE(segment index)`,
/// so streaming read/write never holds the whole (multi-GB) blob in memory.
class ExternalBlobStore {
  ExternalBlobStore(this._dir, this._masterKey)
      : assert(_masterKey.length == 32);

  /// Root dir for blobs (app-private). Files are sharded by the first 2 hex of
  /// their opaque name to keep directories small.
  final Directory _dir;

  /// 32-byte master key held in the container; per-blob keys derive from it.
  final Uint8List _masterKey;

  static const int _segment = 64 * 1024; // plaintext bytes per AEAD segment
  static const int _version = 1;
  static const String _keyContext = 'xveil/large-file-key/v1';
  static const String _nameContext = 'xveil/large-file-name/v1';

  Uint8List _blobKey(String blobId) =>
      blake3DeriveKey(_keyContext, _concat(_masterKey, _utf8(blobId)));

  /// Opaque, deterministic on-disk name — keyed so it reveals nothing about the
  /// blobId/transferId. (Distinct context from the key so the two never collide.)
  String _name(String blobId) {
    final h = blake3Hash(
        _concat(blake3DeriveKey(_nameContext, _masterKey), _utf8(blobId)));
    final hex = _hex(h);
    return hex.substring(0, 32); // 16 bytes of name is plenty
  }

  File _file(String blobId) {
    final n = _name(blobId);
    return File('${_dir.path}/${n.substring(0, 2)}/$n.bin');
  }

  Future<bool> exists(String blobId) => _file(blobId).exists();

  /// Plaintext size of a stored blob (sum of segment plaintext), or null if
  /// absent. Reads only the segment-length headers, not the data.
  Future<int?> size(String blobId) async {
    final f = _file(blobId);
    if (!await f.exists()) return null;
    final raf = await f.open();
    try {
      final header = await raf.read(1 + 16);
      if (header.length < 17 || header[0] != _version) return null;
      var total = 0;
      while (true) {
        final lenBuf = await raf.read(4);
        if (lenBuf.isEmpty) break;
        if (lenBuf.length < 4) return null;
        final ctLen = _u32(lenBuf, 0);
        total += ctLen - 16; // minus the AEAD tag
        await raf.setPosition(await raf.position() + ctLen);
      }
      return total;
    } finally {
      await raf.close();
    }
  }

  /// Encrypt [source] into the blob keyed by [blobId], streaming in segments.
  /// Overwrites any existing blob of the same id atomically (write to a temp
  /// file, then rename). Returns the plaintext byte count written.
  Future<int> writeBlob(String blobId, Stream<List<int>> source) async {
    final key = _blobKey(blobId);
    final prefix = _randomBytes(16);
    final dst = _file(blobId);
    await dst.parent.create(recursive: true);
    final tmp = File('${dst.path}.tmp');
    final sink = tmp.openWrite();
    var segIdx = 0;
    var plaintextTotal = 0;
    final buf = BytesBuilder(copy: false);
    try {
      sink.add(<int>[_version, ...prefix]);
      Future<void> flushSegment() async {
        final pt = buf.takeBytes();
        if (pt.isEmpty) return;
        final ct = veilSealBytes(key, _nonce(prefix, segIdx), pt);
        sink.add(_u32le(ct.length));
        sink.add(ct);
        plaintextTotal += pt.length;
        segIdx++;
      }

      await for (final chunk in source) {
        buf.add(chunk);
        while (buf.length >= _segment) {
          // Split off exactly one segment without copying the remainder twice.
          final all = buf.takeBytes();
          final pt = Uint8List.sublistView(all, 0, _segment);
          final ct = veilSealBytes(key, _nonce(prefix, segIdx), pt);
          sink.add(_u32le(ct.length));
          sink.add(ct);
          plaintextTotal += pt.length;
          segIdx++;
          if (all.length > _segment) {
            buf.add(Uint8List.sublistView(all, _segment));
          }
        }
      }
      await flushSegment(); // trailing partial segment
      await sink.flush();
      await sink.close();
      await tmp.rename(dst.path);
      return plaintextTotal;
    } catch (e) {
      await sink.close().catchError((_) {});
      if (await tmp.exists()) await tmp.delete().catchError((_) => tmp);
      rethrow;
    }
  }

  /// Decrypt the blob as a byte stream (segment by segment). Throws if a segment
  /// fails to open (wrong key / corruption). Empty stream if the blob is absent.
  Stream<List<int>> readBlob(String blobId) async* {
    final f = _file(blobId);
    if (!await f.exists()) return;
    final key = _blobKey(blobId);
    final raf = await f.open();
    try {
      final header = await raf.read(1 + 16);
      if (header.length < 17 || header[0] != _version) {
        throw StateError('blob $blobId: bad header');
      }
      final prefix = Uint8List.sublistView(header, 1, 17);
      var segIdx = 0;
      while (true) {
        final lenBuf = await raf.read(4);
        if (lenBuf.isEmpty) break;
        if (lenBuf.length < 4) throw StateError('blob $blobId: truncated');
        final ctLen = _u32(lenBuf, 0);
        final ct = await raf.read(ctLen);
        if (ct.length < ctLen) throw StateError('blob $blobId: truncated');
        yield veilUnsealBytes(key, _nonce(prefix, segIdx), ct);
        segIdx++;
      }
    } finally {
      await raf.close();
    }
  }

  /// Convenience: whole blob in memory (only for sizes known to fit RAM).
  Future<Uint8List?> readBlobBytes(String blobId) async {
    if (!await exists(blobId)) return null;
    final out = BytesBuilder(copy: false);
    await for (final seg in readBlob(blobId)) {
      out.add(seg);
    }
    return out.toBytes();
  }

  /// Forensically remove a blob: overwrite with random bytes, then unlink. The
  /// blob is opaque without the container key anyway; the overwrite is
  /// belt-and-suspenders against undelete.
  Future<void> scrub(String blobId) async {
    final f = _file(blobId);
    if (!await f.exists()) return;
    try {
      final len = await f.length();
      final raf = await f.open(mode: FileMode.write);
      try {
        var written = 0;
        while (written < len) {
          final n = (len - written) < _segment ? (len - written) : _segment;
          raf.writeFromSync(_randomBytes(n));
          written += n;
        }
        await raf.flush();
      } finally {
        await raf.close();
      }
    } catch (_) {
      // best-effort overwrite; proceed to unlink regardless
    }
    await f.delete().catchError((_) => f);
  }

  /// Garbage-collect orphans: delete every on-disk blob whose id is NOT in
  /// [referencedBlobIds]. Runs only when the container is unlocked (the master
  /// key is required to map ids → opaque filenames). Returns how many removed.
  Future<int> gcOrphans(Set<String> referencedBlobIds) async {
    if (!await _dir.exists()) return 0;
    final keep = {for (final id in referencedBlobIds) '${_name(id)}.bin'};
    var removed = 0;
    await for (final entity in _dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final base = entity.uri.pathSegments.last;
      if (keep.contains(base)) continue;
      // Orphan .bin (no message references it) or a leftover .bin.tmp — both
      // get scrub-deleted; only referenced blobs survive.
      try {
        final len = await entity.length();
        final raf = await entity.open(mode: FileMode.write);
        await raf.writeFrom(_randomBytes(len < _segment ? len : _segment));
        await raf.close();
      } catch (_) {}
      await entity.delete().catchError((_) => entity);
      removed++;
    }
    return removed;
  }

  // ── helpers ────────────────────────────────────────────────────────────────

  static Uint8List _nonce(Uint8List prefix16, int segIdx) {
    final n = Uint8List(24);
    n.setRange(0, 16, prefix16);
    var v = segIdx;
    for (var i = 0; i < 8; i++) {
      n[16 + i] = v & 0xff;
      v >>= 8;
    }
    return n;
  }

  static Uint8List _randomBytes(int n) {
    final r = Random.secure();
    final b = Uint8List(n);
    for (var i = 0; i < n; i++) {
      b[i] = r.nextInt(256);
    }
    return b;
  }

  static Uint8List _u32le(int v) =>
      Uint8List.fromList([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);

  static int _u32(List<int> b, int o) =>
      b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

  static Uint8List _concat(Uint8List a, Uint8List b) {
    final out = Uint8List(a.length + b.length);
    out.setRange(0, a.length, a);
    out.setRange(a.length, out.length, b);
    return out;
  }

  static Uint8List _utf8(String s) => Uint8List.fromList(utf8.encode(s));

  static String _hex(Uint8List b) {
    const d = '0123456789abcdef';
    final sb = StringBuffer();
    for (final x in b) {
      sb.write(d[(x >> 4) & 0xf]);
      sb.write(d[x & 0xf]);
    }
    return sb.toString();
  }
}
