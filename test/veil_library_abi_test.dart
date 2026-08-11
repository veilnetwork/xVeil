@TestOn('mac-os || linux')
library;

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/veil_library.dart';
import 'package:veil_flutter/src/native.dart' show VeilAbiContractMismatch;

/// The embedded node and the packet tunnel both took the process image
/// straight from `processLibFor` and started calling into it. The only ABI
/// check in the app ran later, on the ratchet path — so by the time anything
/// verified the contract, the node had already been started through a library
/// nobody had identified.
///
/// `lookupFunction` matches a NAME, so a library of another revision that kept
/// a symbol and moved its arguments resolves cleanly and corrupts memory on
/// the first call. A stale prebuilt has shipped in this tree before; that one
/// was caught by a MISSING symbol, which a changed one would not be.
void main() {
  final lib = _loadOrNull();

  test('a library whose contract does not match is refused', () {
    if (lib == null) {
      // Not silently skipped: an absent library must read as "unverified", not
      // as "passed" — see the positive control below.
      markTestSkipped('veilclient_ffi not built for this host');
      return;
    }
    expect(
      () => verifiedVeilLibrary(lib: lib, expectedAbiHash: 'not-the-hash'),
      throwsA(isA<VeilAbiContractMismatch>()),
      reason: 'no handle may escape a contract mismatch',
    );
  });

  test('the real library satisfies its own contract', () {
    if (lib == null) {
      markTestSkipped('veilclient_ffi not built for this host');
      return;
    }
    // The positive control. Without it the refusal above would also pass
    // against a library that exports no hash at all, or against a handle the
    // gate rejects for an unrelated reason — and the check would be measuring
    // nothing.
    expect(verifiedVeilLibrary(lib: lib), isNotNull);
  });

  test('the node and the tunnel go through the gate, not around it', () {
    // Structural, because the defect was an absence: both call sites resolved
    // the library themselves. A future edit that reintroduces `processLibFor`
    // at either entry point turns this red.
    for (final path in const [
      'lib/data/node/embedded_node.dart',
      'lib/data/vpn/packet_tunnel_ffi.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(
        source,
        contains('verifiedVeilLibrary()'),
        reason: '$path must resolve the library through the contract gate',
      );
      expect(
        source.contains("processLibFor('veilclient_ffi')"),
        isFalse,
        reason: '$path must not take the process image unverified',
      );
    }
  });
}

DynamicLibrary? _loadOrNull() {
  for (final name in const [
    'libveilclient_ffi.dylib',
    'libveilclient_ffi.so',
  ]) {
    for (final dir in const [
      'third_party/veil/target/debug/',
      'third_party/veil/target/release/',
      'macos/Frameworks/',
    ]) {
      final path = '$dir$name';
      if (File(path).existsSync()) {
        try {
          return DynamicLibrary.open(path);
        } on ArgumentError {
          continue;
        }
      }
    }
  }
  return null;
}
