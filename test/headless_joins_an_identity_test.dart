// A daemon given a phrase CREATES an identity; it takes a certificate to JOIN
// one.
//
// Measured on two daemons from one phrase, before this existed:
//
//   daemon A   node_id 97acf899…   instance_id 36244f90…
//   daemon B   node_id 236e2085…   instance_id 36244f90…
//
// Both halves backwards. The ADDRESSES differ because a daemon with no
// certificate mints a fresh credential, and a hybrid identity's address is
// hashed over the Falcon half that credential carries. The INSTANCE IDS match
// because a created identity derives its device key from the phrase, and the
// same phrase gives the same key — so the two are one device to everything
// that counts devices. Two different identities that believe they are the same
// machine.
//
// Both are fixed by the same argument, and that is why it sets BOTH: the
// credential decides the address, `restoringIdentity` makes this device mine a
// key of its own. Half of it would be worse than neither.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final runtime = File('lib/headless/headless_runtime.dart').readAsStringSync();
  final cli = File('bin/xveil.dart').readAsStringSync();

  test('the daemon accepts a credential and stores it before provisioning', () {
    expect(
      runtime,
      contains('String? identityCredential'),
      reason: 'without this parameter a daemon can only ever create',
    );
    final storeAt = runtime.indexOf('kSovereignBundleSetting');
    final bootAt = runtime.indexOf('RealVeilStack.startDeniable');
    expect(storeAt, isNot(-1), reason: 'the credential is never stored');
    expect(bootAt, isNot(-1));
    expect(
      storeAt,
      lessThan(bootAt),
      reason:
          'the boot reads the credential to decide which identity the phrase '
          'names, so storing it afterwards decides nothing — the daemon would '
          'still create, and the certificate would name an identity nobody '
          'uses',
    );
  });

  test('a credential also makes this device mine a key of its own', () {
    expect(
      runtime,
      contains('restoringIdentity: joining'),
      reason:
          'the credential alone fixes the ADDRESS and leaves both daemons '
          'deriving one device key from one phrase — same instance_id, so one '
          'device wearing two hats. Both halves or neither.',
    );
  });

  test('the flag is reachable, documented, and read like the phrase', () {
    expect(cli, contains('--identity-credential-file'));
    expect(
      cli,
      contains('XVEIL_IDENTITY_CREDENTIAL_FILE'),
      reason: 'a service manager with no editable command line needs the env',
    );
    // The same checks as the phrase: together they ARE the identity, so a
    // world-readable certificate beside a 0600 phrase protects nothing.
    final at = cli.indexOf("readSecret(credentialFile");
    expect(
      at,
      isNot(-1),
      reason:
          'the certificate carries the master Falcon half that exists nowhere '
          'else; it gets the strict reader, not the relaxed one the PSK uses',
    );

    final help = cli.substring(cli.indexOf('xveil run --config'));
    expect(
      help.substring(0, 400),
      contains('--identity-credential-file'),
      reason: 'an option absent from --help is an option nobody finds',
    );

    final doc = File('doc/HEADLESS-DAEMON.md').readAsStringSync();
    expect(doc, contains('--identity-credential-file'));
    expect(
      doc,
      contains('instance_id'),
      reason:
          'the doc has to show the measured failure, or the next person '
          'reading it cannot tell this option from a nicety',
    );
  });
}
