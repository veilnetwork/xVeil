import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/identity/veil_identity.dart';

/// Verifies the production phrase validator [veilPhraseValid] against the real
/// veil_flutter FFI: veil's validateBip39Phrase THROWS on invalid input (and
/// uses veil's own master-phrase checksum), and the wrapper must turn that into
/// a clean `false` so the UI never crashes. Env-gated on VEIL_FFI_DYLIB.
///
/// (A valid-phrase assertion needs a phrase from veil's `identity create`
/// ceremony — out of scope for a smoke test; the wrapper's no-throw contract is
/// the production-critical behaviour.)
void main() {
  final hasDylib = Platform.environment['VEIL_FFI_DYLIB']?.isNotEmpty ?? false;

  test('rejects invalid phrases without throwing', () {
    expect(veilPhraseValid(List.filled(24, 'abandon').join(' ')), isFalse);
    expect(veilPhraseValid('not a phrase'), isFalse);
    expect(veilPhraseValid(''), isFalse);
  }, skip: hasDylib ? false : 'set VEIL_FFI_DYLIB to libveilclient_ffi');
}
