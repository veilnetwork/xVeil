// A recovery-certificate identity cannot drive the document half of link or
// revoke, and must be told so BEFORE it hands over its secret.
//
// Both paths reach native calls that derive the master key from a PHRASE, and
// a certificate's recovery code is not one — `decode_master_seed_from_phrase`
// refuses it, the call errors, and the operation fails with nothing
// half-applied. Correct, but only after the person has typed the one secret
// that unlocks their identity into a dialog that could never use it.
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/features/settings/devices_screen.dart';

void main() {
  test('a certificate credential does not get the document actions', () {
    expect(documentActionsAvailable('certificate'), isFalse);
  });

  test('a phrase credential does', () {
    expect(
      documentActionsAvailable('phrase'),
      isTrue,
      reason: 'a guard that refuses everything would remove the feature',
    );
  });

  test('an unknown or absent kind is not refused', () {
    // Legacy identities report null, and they are phrase-backed. Refusing
    // them would take link and revoke away from the identities that HAVE
    // always been able to do it.
    expect(documentActionsAvailable(null), isTrue);
    expect(documentActionsAvailable('something-new'), isTrue);
  });
}
