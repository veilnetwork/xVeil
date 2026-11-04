import 'dart:ffi';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:ffi/ffi.dart';

import '../data/node/veil_library.dart' show verifiedVeilLibrary;

typedef _HashNative = Int32 Function(Pointer<Uint8>, IntPtr, Pointer<Uint8>);
typedef _HashDart = int Function(Pointer<Uint8>, int, Pointer<Uint8>);

/// Exact SHA-256 over fresh bytes, using Veil's existing primitive when loaded.
///
/// Both backends produce the standard SHA-256 digest. The native primitive
/// already belongs to Veil's ABI; a host without it keeps the Dart digest.
/// Neither backend decides whether a signature or identity document is valid.
class Sha256Backend {
  Sha256Backend._(this._native);

  /// Pure-Dart backend for hosts which do not load Veil's native library.
  factory Sha256Backend.dart() => Sha256Backend._(null);

  static final _libraries = Expando<Sha256Backend>();
  static final _default = _loadDefault();

  static Sha256Backend _loadDefault() {
    try {
      return forLibrary(verifiedVeilLibrary());
    } catch (_) {
      return Sha256Backend._(null);
    }
  }

  /// Resolve only once per library, including when an older host lacks it.
  static Sha256Backend forLibrary([DynamicLibrary? library]) {
    if (library == null) return _default;
    return _libraries[library] ??= _load(library);
  }

  static Sha256Backend _load(DynamicLibrary library) {
    try {
      return Sha256Backend._(
        library.lookupFunction<_HashNative, _HashDart>('veil_sha256'),
      );
    } catch (_) {
      return Sha256Backend._(null);
    }
  }

  final _HashDart? _native;
  bool get nativeEnabled => _native != null;

  Uint8List hash(Uint8List bytes) => hashParts([bytes]);

  /// Hash separate fields without first concatenating plaintext in Dart.
  Uint8List hashParts(List<Uint8List> parts) {
    final native = _native;
    if (native == null) {
      final result = _DigestResult();
      final sink = crypto.sha256.startChunkedConversion(result);
      for (final part in parts) {
        sink.add(part);
      }
      sink.close();
      return Uint8List.fromList(result.digest!.bytes);
    }
    final length = parts.fold<int>(0, (total, part) => total + part.length);
    final out = calloc<Uint8>(32);
    Pointer<Uint8> input = nullptr;
    try {
      if (length != 0) {
        input = calloc<Uint8>(length);
        final buffer = input.asTypedList(length);
        var offset = 0;
        for (final part in parts) {
          buffer.setRange(offset, offset + part.length, part);
          offset += part.length;
        }
      }
      final result = native(input, length, out);
      if (result != 0) throw StateError('Native SHA-256 rejected input');
      return Uint8List.fromList(out.asTypedList(32));
    } finally {
      // Canonical rows may contain plaintext. Do not leave the extra FFI
      // copies in freed native memory, on success or failure.
      if (input != nullptr) {
        input.asTypedList(length).fillRange(0, length, 0);
        calloc.free(input);
      }
      out.asTypedList(32).fillRange(0, 32, 0);
      calloc.free(out);
    }
  }
}

class _DigestResult implements Sink<crypto.Digest> {
  crypto.Digest? digest;

  @override
  void add(crypto.Digest data) => digest = data;

  @override
  void close() {}
}
