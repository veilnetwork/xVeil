import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/expect_before.dart';

/// Where a merged identity document is allowed to land.
///
/// A sibling device sends its copy of the identity document; the native merge
/// takes it in and the running node re-reads it. The re-read takes a Storage
/// and writes into a runtime DIRECTORY, and the two arguments come from
/// different places: the storage from the group service of the identity that
/// received the document, the directory from a provider an all-online switch
/// re-points. The apply sits behind a native await, which is exactly where a
/// switch lands — so one identity's document, secret device key included,
/// could be written into another identity's private runtime directory
/// (report17 XV17-M13).
///
/// The native reload compares node ids and refuses, which is what keeps the
/// running identity from BECOMING the other one. It does not stop the key from
/// being written there first.
///
/// Structural, and this is why: the behaviour needs a running embedded node
/// with a materialised runtime directory and a live group service, and the
/// decision under test is which arguments are allowed to meet. The decision
/// itself — whether material belongs in a directory — is a pure function,
/// tested against a real directory in `sovereign_identity_material_test.dart`.
void main() {
  final stack = File('lib/data/veil_stack.dart').readAsStringSync();
  final bridge = File('lib/state/device_sync_bridge.dart').readAsStringSync();

  test('the re-read checks the directory before it writes into it', () {
    expectBefore(
      stack,
      'sovereignMaterialBelongsHere(dir, files)',
      'materialiseSovereignIdentity(dir, files)',
      reason:
          'the material is written first and questioned afterwards, which is '
          'the secret device key already on disk in the wrong directory',
    );
  });

  test('and the apply asks whether it is still the running identity', () {
    // Before the stack is read, not after: reading it first is what hands a
    // switched-to identity's node to a callback that belongs to the one
    // being left behind.
    expectBefore(
      bridge,
      'identical(ref.read(groupServiceProvider), svc)',
      'ref.read(realStackProvider)',
    );
  });

  test('and a re-read that was refused is not announced', () {
    // The announcement says "I hold this merge". A node that did not take the
    // document does not hold it, and the other devices then stop sending —
    // the divergence this whole exchange exists to end becomes permanent.
    final adopted = bridge.indexOf(
      'if (changed == SovereignDocumentAdoption.adopted) {',
    );
    expect(adopted, isNot(-1), reason: 'the apply moved; re-anchor this test');
    final block = bridge.substring(adopted, adopted + 2000);

    expectBefore(
      block,
      'refreshSovereignIdentity(svc.storage)',
      'announceIdentityDocument()',
    );
    expect(
      block,
      contains('!await stack.refreshSovereignIdentity(svc.storage)'),
      reason: 'the answer is thrown away, so a refusal is announced anyway',
    );
  });
}
