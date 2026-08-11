import 'dart:ffi';

// Reached into `src/` deliberately, as `ratchet_ffi.dart` does: the hash is
// generated beside the header it describes, and re-declaring it here would
// drift from that header the moment it changed — the exact divergence this
// check exists to catch.
// ignore: implementation_imports
import 'package:veil_flutter/src/abi_contract.dart' show veilAbiContractHash;
// ignore: implementation_imports
import 'package:veil_flutter/src/native.dart'
    show VeilAbiContractMismatch, readAbiContractHash;

import '../native_libs.dart' show processLibFor;

/// The veilclient library, refused unless it is the one these bindings
/// describe.
///
/// ## Why a gate rather than a plain handle
///
/// `lookupFunction` matches a NAME. It says nothing about the signature behind
/// it, so a library of a different revision that kept a symbol and changed its
/// arguments — or the layout of a struct crossing the boundary — resolves
/// cleanly and corrupts memory on the first call. The symbol table cannot tell
/// these apart; the contract hash can.
///
/// veil already ships that hash and `veil_flutter` already refuses a mismatched
/// library in `openVeilLibrary`. Two call sites went around it: the embedded
/// node and the packet tunnel both took `processLibFor` directly, and the only
/// contract check in the app runs later, on the ratchet path — after the node
/// has been started and talked to.
///
/// This is not a hypothetical mismatch in this repository. A prebuilt native
/// library twelve commits behind its callers shipped in this tree, and the
/// media engine's symbol gate exists because of it. That one was caught by a
/// missing symbol; a CHANGED one would not have been.
///
/// Fail-closed on purpose: a mismatch throws and no handle escapes, so no
/// entry point can be reached through it. A pre-contract library (no
/// `veil_abi_contract_hash` at all) reads as null and is refused for the same
/// reason — "I cannot tell what this is" is not permission to call into it.
///
/// Verified once per process: the answer cannot change under a running
/// program, and re-reading it per call would put a lookup in front of every
/// FFI entry point for nothing.
DynamicLibrary? _verified;

DynamicLibrary verifiedVeilLibrary({
  DynamicLibrary? lib,
  String expectedAbiHash = veilAbiContractHash,
}) {
  // The cache is bypassed whenever a caller supplies either seam, so a test
  // can exercise the refusal without poisoning the process-wide answer.
  final explicit = lib != null || expectedAbiHash != veilAbiContractHash;
  if (!explicit) {
    final cached = _verified;
    if (cached != null) return cached;
  }

  final handle = lib ?? processLibFor('veilclient_ffi');
  final actual = readAbiContractHash(handle);
  if (actual != expectedAbiHash) {
    throw VeilAbiContractMismatch(expected: expectedAbiHash, actual: actual);
  }
  if (!explicit) _verified = handle;
  return handle;
}
