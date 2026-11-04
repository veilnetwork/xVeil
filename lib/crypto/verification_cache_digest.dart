import 'dart:ffi';
import 'dart:typed_data';

import '../data/node/veil_library.dart' show verifiedVeilLibrary;
import 'sha256_backend.dart';

/// Digest for an in-memory signature-verdict cache, never a protocol hash.
///
/// SHA-256 gives the same cache key with either backend. The native primitive
/// already belongs to Veil's ABI; a host without it keeps the Dart digest.
/// Neither backend decides whether a signature or identity document is valid.
class VerificationCacheDigest {
  VerificationCacheDigest._(this._backend);

  /// Pure-Dart backend for hosts which do not load Veil's native library.
  factory VerificationCacheDigest.dart() =>
      VerificationCacheDigest._(Sha256Backend.dart());

  static final _libraries = Expando<VerificationCacheDigest>();
  static final _default = _loadDefault();

  static VerificationCacheDigest _loadDefault() {
    try {
      return forLibrary(verifiedVeilLibrary());
    } catch (_) {
      return VerificationCacheDigest._(Sha256Backend.dart());
    }
  }

  /// Resolve only once per library, including when an older host lacks it.
  static VerificationCacheDigest forLibrary([DynamicLibrary? library]) {
    if (library == null) return _default;
    return _libraries[library] ??= _load(library);
  }

  static VerificationCacheDigest _load(DynamicLibrary library) =>
      VerificationCacheDigest._(Sha256Backend.forLibrary(library));

  final Sha256Backend _backend;
  bool get nativeEnabled => _backend.nativeEnabled;

  Uint8List hash(Uint8List bytes) => _backend.hash(bytes);
  Uint8List hashParts(List<Uint8List> parts) => _backend.hashParts(parts);
}
