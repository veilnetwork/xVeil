// Which identity a phrase names, and how the boot decides.
//
// One phrase names TWO identities. The Ed25519 half of a hybrid master comes
// from the same words, so `BLAKE3(ed)` and `BLAKE3(ed ‖ falcon)` are both
// derivable from them — different addresses, both valid, only one yours.
//
// The rule, chosen deliberately: a stored credential means the hybrid
// identity; none means the classic one. Its cost is named in the code and
// here, because it is the kind of cost that should not be discovered by
// accident — restoring a hybrid identity WITHOUT its certificate does not
// fail. It succeeds into the other identity, with a different address, and
// everything works except that nobody can reach you where your contacts look.
// That is why the restore path says so out loud rather than only deciding.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File('lib/data/veil_stack.dart').readAsStringSync();

  /// The body of `ensureSovereignIdentity`, by brace matching — cutting at
  /// "the next member" once swept a whole file into a guard that then failed
  /// on code it never meant to read.
  String provisioningBody() {
    final start = source.indexOf('ensureSovereignIdentity(\n    Storage storage');
    expect(start, isNot(-1), reason: 'the provisioning entry point was renamed');
    // The BODY's brace, not the named-parameter block's: `Storage storage, {`
    // opens one too, and counting from there closes at the end of the
    // signature and hands back a body of nothing. The first version of this
    // guard did exactly that and passed on an empty span.
    final open = source.indexOf('}) async {', start) + '}) async '.length;
    expect(open, greaterThan(start), reason: 'signature shape changed');
    var depth = 0;
    for (var i = open; i < source.length; i++) {
      if (source[i] == '{') depth++;
      if (source[i] == '}') {
        depth--;
        if (depth == 0) return source.substring(start, i + 1);
      }
    }
    fail('unbalanced braces after ensureSovereignIdentity');
  }

  test('the credential decides which identity the phrase names', () {
    final body = provisioningBody();
    // Both paths must be reachable from here: one identity per phrase would
    // mean the decision is not being made at all.
    expect(
      body.contains('provisionHybridSovereignIdentity'),
      isTrue,
      reason: 'a stored credential must provision the HYBRID identity',
    );
    expect(
      body.contains('provisionSovereignIdentity'),
      isTrue,
      reason: 'without one it must provision the classic identity',
    );
    // And the decision must be the credential, not something else that
    // happens to be around — a phrase length, a flag, a platform.
    expect(
      body.contains('_sovereignCredential(storage)'),
      isTrue,
      reason: 'the decision must read the credential',
    );
  });

  test('restoring without a certificate is said out loud, not only decided', () {
    final body = provisioningBody();
    final restoringIdx = body.indexOf('restoringIdentity');
    expect(
      restoringIdx,
      isNot(-1),
      reason:
          'the restore case must be distinguished — creating has nothing to '
          'be compatible with and is always hybrid',
    );
    // The warning has to live in the branch that takes the classic path while
    // restoring. Checking only that the word appears somewhere would pass on
    // a file that merely mentions it.
    final elseBranch = body.substring(body.indexOf('} else {'));
    expect(
      elseBranch.contains('restoringIdentity') &&
          elseBranch.contains('devLog'),
      isTrue,
      reason:
          'a restore that falls back to the classic identity must say so: it '
          'succeeds into a DIFFERENT identity, and silence is how that is '
          'discovered far too late',
    );
  });

  test('creating mints the credential BEFORE the identity is provisioned', () {
    final body = provisioningBody();
    final mint = body.indexOf('_mintSovereignCredential');
    expect(
      mint,
      isNot(-1),
      reason:
          'creating must mint the credential here: lazily is too late once '
          'the credential decides the identity — the node would already have '
          'published the classic address',
    );
    final provisionHybrid = body.indexOf('provisionHybridSovereignIdentity');
    expect(
      mint,
      lessThan(provisionHybrid),
      reason:
          'the credential IS the master: an identity provisioned before it '
          'exists is named by a key the credential does not hold',
    );
    // And only when creating. Minting on a restore would manufacture a NEW
    // master and a new address for someone who came to recover an old one.
    final beforeMint = body.substring(0, mint);
    expect(
      beforeMint.contains('!restoringIdentity'),
      isTrue,
      reason: 'minting must be gated on creating, not reached on a restore',
    );
  });

  test('an unreadable credential is not treated as an absent one', () {
    // Absent means "classic identity". Damaged must not mean that too, or a
    // corrupted file silently moves the address.
    final reader = source.substring(
      source.indexOf('static Future<Uint8List?> _sovereignCredential('),
    );
    final body = reader.substring(0, reader.indexOf('\n  static '));
    expect(
      body.contains('rethrow'),
      isTrue,
      reason:
          'swallowing a read error would provision the OTHER identity and '
          'change the address without a word',
    );
    expect(
      body.contains('return null;'),
      isFalse,
      reason: 'a null on error is exactly the silent fallback under test',
    );
  });
}
