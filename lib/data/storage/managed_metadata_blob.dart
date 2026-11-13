import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'kv_log_store.dart';

/// A bounded, atomically published metadata blob for the dedicated managed
/// maintenance space. Not an application backend and never a hidden-space
/// discovery or cleanup API. The caller owns and serializes the backing store.
///
/// All records use a LOG namespace: native storage forbids mixing KV and log
/// addressing in a namespace. Two fixed banks bound abandoned preparations.
/// A new head is committed only after every chunk in its inactive bank.
final class ManagedMetadataBlob {
  ManagedMetadataBlob(this._store);

  final KvLogStore _store;
  static const namespace = 255;
  static const maxBytes = 64 * 1024;
  static const _chunkBytes = 1024;
  static const _chunksPerBank = maxBytes ~/ _chunkBytes;
  static const _headId = 1;
  static const _headBytes = 38; // version, bank, u32 length, SHA-256

  static int _chunkId(int bank, int index) => 2 + bank * _chunksPerBank + index;

  ({int bank, int length, Uint8List digest})? _head() {
    final bytes = _store.readLog(namespace, _headId);
    if (bytes == null) return null;
    if (bytes.length != _headBytes || bytes[0] != 1 || bytes[1] > 1) {
      throw const FormatException('Invalid managed metadata head');
    }
    final length = ByteData.sublistView(bytes).getUint32(2, Endian.big);
    if (length > maxBytes) {
      throw const FormatException('Managed metadata exceeds its limit');
    }
    return (bank: bytes[1], length: length, digest: bytes.sublist(6));
  }

  Uint8List _read(({int bank, int length, Uint8List digest}) head) {
    final result = Uint8List(head.length);
    for (
      var offset = 0, index = 0;
      offset < head.length;
      offset += _chunkBytes, index++
    ) {
      final chunk = _store.readLog(namespace, _chunkId(head.bank, index));
      final remaining = head.length - offset;
      final expected = remaining < _chunkBytes ? remaining : _chunkBytes;
      if (chunk == null || chunk.length != expected) {
        throw const FormatException('Incomplete managed metadata');
      }
      result.setRange(offset, offset + expected, chunk);
    }
    final actual = sha256.convert(result).bytes;
    var difference = 0;
    for (var i = 0; i < actual.length; i++) {
      difference |= actual[i] ^ head.digest[i];
    }
    if (difference != 0) {
      throw const FormatException('Invalid managed metadata digest');
    }
    return result;
  }

  /// Missing published metadata is an error for an existing identity, never an
  /// invitation to silently reset its authorization/rollback state.
  Uint8List read() {
    final head = _head();
    if (head == null) throw StateError('Managed metadata is not initialized');
    return _read(head);
  }

  /// [initialize] is exclusively for an unpublished new managed space. It
  /// cannot reset an existing head. A failed first preparation may be retried.
  ///
  /// On an error after a native commit, read/reopen is authoritative: a lost
  /// response can mean the new complete head was already published. No cleanup
  /// or rollback is attempted in that ambiguous case.
  int write(Uint8List value, {bool initialize = false}) {
    if (value.length > maxBytes) {
      throw ArgumentError('Managed metadata exceeds its limit');
    }
    final previous = _head();
    if (initialize && previous != null) {
      throw StateError('Managed metadata is already initialized');
    }
    if (!initialize && previous == null) {
      throw StateError('Managed metadata is not initialized');
    }
    if (previous != null) _read(previous); // Do not overwrite corrupt state.
    final bytes = Uint8List.fromList(value);
    final bank = previous == null ? 0 : 1 - previous.bank;
    // One 1-KiB record per commit also respects native DataBatch limits.
    // Publication is rare maintenance work, not the message-write hot path.
    for (
      var offset = 0, index = 0;
      offset < bytes.length;
      offset += _chunkBytes, index++
    ) {
      final end = offset + _chunkBytes < bytes.length
          ? offset + _chunkBytes
          : bytes.length;
      _store.commit([
        AppendLogOp(
          namespace,
          _chunkId(bank, index),
          bytes.sublist(offset, end),
        ),
      ]);
    }
    final head = Uint8List(_headBytes)
      ..[0] = 1
      ..[1] = bank;
    ByteData.sublistView(head).setUint32(2, bytes.length, Endian.big);
    head.setRange(6, _headBytes, sha256.convert(bytes).bytes);
    return _store.commit([AppendLogOp(namespace, _headId, head)]);
  }
}
