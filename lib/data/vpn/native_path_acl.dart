// Owner and permissions read from the OBJECT a path resolved to.
//
// The native side (`veil_path_security_facts`) opens the path once and answers
// everything from that one handle: the attributes, the final path, the owner
// and the DACL. Getting the same answers from a NAME is what this replaces,
// and it was wrong two ways — the name is resolved once to read permissions
// and again to use the file, and a name can cross a junction whose target's
// permissions say nothing about who can repoint it.
//
// This file is only the wire. Every judgement stays in
// `privileged_launch_guard.dart`, where the whole matrix is exercised without
// a filesystem.

import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../node/veil_library.dart';

typedef _FactsNative =
    Int32 Function(
      Pointer<Uint8> path,
      Size pathLen,
      Pointer<Pointer<Utf8>> outJson,
      Pointer<Pointer<Utf8>> errOut,
    );
typedef _FactsDart =
    int Function(
      Pointer<Uint8> path,
      int pathLen,
      Pointer<Pointer<Utf8>> outJson,
      Pointer<Pointer<Utf8>> errOut,
    );

typedef _FreeStrNative = Void Function(Pointer<Utf8>);
typedef _FreeStrDart = void Function(Pointer<Utf8>);

/// The decoded answer for one path, or null when this build cannot ask.
///
/// Null is NOT "nothing is wrong with the path" — the caller must read it as
/// undetermined and refuse. A library without the symbol is a build that
/// cannot make the handle-bound read, and falling back to reading permissions
/// by name would restore exactly the hole this closes.
Map<String, Object?>? veilPathSecurityFacts(String path, {DynamicLibrary? lib}) {
  final DynamicLibrary dl;
  try {
    dl = lib ?? verifiedVeilLibrary();
  } catch (_) {
    return null;
  }
  final _FactsDart facts;
  final _FreeStrDart freeStr;
  try {
    facts = dl.lookupFunction<_FactsNative, _FactsDart>(
      'veil_path_security_facts',
    );
    freeStr = dl.lookupFunction<_FreeStrNative, _FreeStrDart>(
      'veil_free_string',
    );
  } catch (_) {
    return null;
  }

  final bytes = utf8.encode(path);
  final buffer = calloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
  final outJson = calloc<Pointer<Utf8>>();
  final errOut = calloc<Pointer<Utf8>>();
  try {
    buffer.asTypedList(bytes.isEmpty ? 1 : bytes.length).setAll(0, bytes);
    final rc = facts(buffer, bytes.length, outJson, errOut);
    if (errOut.value != nullptr) freeStr(errOut.value);
    if (rc != 0 || outJson.value == nullptr) return null;
    final text = outJson.value.toDartString();
    freeStr(outJson.value);
    final decoded = jsonDecode(text);
    return decoded is Map<String, Object?> ? decoded : null;
  } on FormatException {
    return null;
  } finally {
    calloc.free(buffer);
    calloc.free(outJson);
    calloc.free(errOut);
  }
}

/// Whether this build can make the handle-bound read at all.
///
/// Asked by looking the symbol up rather than by guessing from the platform,
/// for the same reason `veilOpenBeneathAvailable` does: a build shipping an
/// older library has the same problem as a platform that cannot do it.
bool veilPathSecurityFactsAvailable({DynamicLibrary? lib}) {
  try {
    final dl = lib ?? verifiedVeilLibrary();
    dl.lookup<NativeFunction<_FactsNative>>('veil_path_security_facts');
    return true;
  } catch (_) {
    return false;
  }
}

/// `\\?\C:\x` → `C:\x`.
///
/// `GetFinalPathNameByHandleW` answers in the extended-length form. The chain
/// this is compared against is written the ordinary way, and comparing the two
/// spellings would report every path as having moved.
String stripExtendedLengthPrefix(String path) {
  const unc = r'\\?\UNC\';
  const plain = r'\\?\';
  if (path.startsWith(unc)) return '\\\\${path.substring(unc.length)}';
  if (path.startsWith(plain)) return path.substring(plain.length);
  return path;
}
