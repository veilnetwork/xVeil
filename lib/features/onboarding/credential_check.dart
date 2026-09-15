// Does this secret open this credential? Asked before anything is committed.
//
// One function for both ways an identity comes back, because the mistake it
// prevents is the same one and it was made once already: a screen that asks for
// a secret and never checks it is not asking for a secret. Any string was
// accepted where a recovery code belongs, the native refusal was swallowed
// deep in the boot, and the install came up at a brand new address without a
// word — reported from the field as "код восстановления могу ввести любой
// (первый раз ввел фразу и получил другую личность)".
//
// WHICH SECRET is decided by the credential's own magic, never by the screen.
// An XVSB was wrapped under the 24 words. An XVRC was re-wrapped under a
// high-entropy code of its own, exactly so the exported file is not openable
// by the words. Asking for the wrong one fails on a perfectly good credential,
// which is how a person concludes their backup is worthless.

import 'dart:typed_data';

import 'package:veil_flutter/veil_ffi.dart' as veil;

import '../../core/log.dart';
import '../../data/node/sovereign_identity_material.dart'
    show isRecoveryCertificate;

/// Whether [secret] opens [credential].
///
/// Injectable at every call site: the real one runs Argon2id over a native
/// handle, which a widget test cannot do — and a widget test that skipped it
/// would be asserting away the thing these screens exist to do.
typedef CredentialSecretCheck =
    Future<bool> Function(Uint8List credential, String secret);

/// The real check: open it, then throw the signer away. Nothing is kept — the
/// question is only whether it opens.
Future<bool> nativeCredentialOpens(Uint8List credential, String secret) async {
  try {
    final signer = isRecoveryCertificate(credential)
        ? veil.VeilSovereignSigner.openRecoveryCertificate(credential, secret)
        : veil.VeilSovereignSigner.openBundle(credential, secret);
    signer.close();
    return true;
  } on Object catch (e) {
    // Every way this fails is the same answer to the person in front of it:
    // this secret does not open this credential. The reason is not theirs to
    // debug, and the message must not vary with it — a wrong secret and a
    // tampered file are indistinguishable by design.
    devLog(() => 'xVeil[restore]: the secret did not open the credential: $e');
    return false;
  }
}
