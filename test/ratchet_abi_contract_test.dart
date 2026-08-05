import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/ratchet_ffi.dart';
// ignore: implementation_imports
import 'package:veil_flutter/src/native.dart' show VeilAbiContractMismatch;

/// The ratchet door loads its own library handle and never went through the
/// veil_flutter loader, so the ABI-contract guard that loader performs did not
/// apply to it. That made it the one door in the app reached over an
/// UNVERIFIED ABI — and the door to the only state in veil that cannot be
/// rebuilt from anything public.
///
/// Worse, availability was answered by probing `veil_ratchet_state_version`, a
/// symbol the OUTDATED library exports too. A mismatched native therefore
/// reported the door as available and failed later, somewhere else, on a symbol
/// that had nothing to do with the real problem.
void main() {
  test('a library that does not report the ABI contract is REFUSED, not '
      'probed for the ratchet symbol', () {
    // The test VM has no veil symbols at all, which is the same shape as a
    // pre-contract build: `veil_abi_contract_hash` is absent, so the library
    // cannot say what ABI it speaks. That is not an answer of "no ratchet in
    // this build" — it is a library nothing may be called through.
    expect(
      () => ratchetStateAvailable(lib: DynamicLibrary.process()),
      throwsA(isA<VeilAbiContractMismatch>()),
      reason:
          'availability was answered from a symbol lookup, so an unverified '
          'library got a verdict instead of a refusal',
    );
  });

  test('the refusal names both sides so the mismatch is diagnosable', () {
    try {
      assertRatchetAbiContract(
        DynamicLibrary.process(),
        expectedAbiHash: 'deadbeef',
      );
      fail('a library with no contract hash must not be accepted');
    } on VeilAbiContractMismatch catch (e) {
      expect(e.expected, 'deadbeef');
      expect(e.actual, isNull, reason: 'no veil_abi_contract_hash symbol here');
      expect(e.toString(), contains('deadbeef'));
    }
  });

  group('against a real library', () {
    final dylib = Platform.environment['VEIL_FFI_DYLIB'];
    final skip = (dylib == null || dylib.isEmpty)
        ? 'set VEIL_FFI_DYLIB to a built libveilclient_ffi'
        : false;

    test('the ratchet symbol being present is NOT enough: a library whose '
        'contract hash differs is refused before it is probed', () {
      final lib = DynamicLibrary.open(dylib!);
      // The real thing is accepted...
      expect(() => ratchetStateAvailable(lib: lib), returnsNormally);
      // ...and the SAME library, checked against a different contract, is
      // refused — even though `veil_ratchet_state_version` resolves on it.
      expect(
        () => ratchetStateAvailable(
          lib: lib,
          expectedAbiHash:
              '0000000000000000000000000000000000000000000000000000000000000000',
        ),
        throwsA(isA<VeilAbiContractMismatch>()),
        reason:
            'the outdated library exports this symbol too, which is exactly '
            'why a lookup cannot decide whether the ABI matches',
      );
    }, skip: skip);
  });
}
