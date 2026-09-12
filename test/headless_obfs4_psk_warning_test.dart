// A daemon with no obfs4 PSK is DEAF, and has to say so.
//
// Both deployment networks separate themselves by an obfs4 pre-shared key, so
// a node without it completes no handshake with any peer it meets. Nothing
// about that looks wrong from the daemon's side: it boots, mines its identity,
// reaches the rendezvous, finds seed addresses, prints `{"ready":true,...}`,
// and then refuses every one of them with `obfs4-tcp transport requires
// obfs4_psk set in TransportContext`. Measured on a daemon that looked healthy
// for an hour (2026-09-12) — the option existed, nothing mentioned it, and the
// documentation did not name it once.
//
// Source-level because the alternative is booting a real node with a real
// container to observe one stderr line. What has to hold is that the branch
// exists, that it triggers on the absent key rather than on something else,
// and that the bundle the operator is pointed at actually carries the file.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the daemon warns when it has no obfs4 PSK', () {
    final source = File('lib/headless/headless_runtime.dart').readAsStringSync();
    final at = source.indexOf('obfs4 PSK');
    expect(at, isNot(-1), reason: 'the PSK is no longer read here');

    // The branch, and what it is keyed on: an absent or empty key, not a
    // missing path. A path that points at an empty file is the same deafness.
    expect(
      source,
      contains("if (psk == null || psk.isEmpty)"),
      reason:
          'without this branch the daemon reports ready:true and refuses '
          'every peer it finds, which is the state this exists to announce',
    );
    final branch = source.substring(source.indexOf("if (psk == null || psk.isEmpty)"));
    expect(
      branch.substring(0, 1200),
      contains('stderr.writeln'),
      reason: 'a branch that decides and says nothing is the old behaviour',
    );
    expect(
      branch.substring(0, 1200).toLowerCase(),
      contains('obfs4_psk_file'),
      reason:
          'the warning must name the option that fixes it — an operator who '
          'cannot act on a warning is no better off than one who never saw it',
    );
  });

  test('the bundle carries the key the warning points at', () {
    final script = File('scripts/build-headless.sh').readAsStringSync();
    expect(
      script,
      contains('obfs4_psk.b64'),
      reason:
          'the doc tells the operator to point obfs4_psk_file at the bundle; '
          'if the build does not put the file there, that is a dead end',
    );
    // From the ONE rule, so the key cannot be the other network's. A bundle
    // with the testnet key beside a production-seeded library fails with the
    // exact log line this whole change is about.
    expect(
      script,
      contains('veil-network.sh'),
      reason:
          'picking the network any other way is the mirrored-constant failure '
          'veil-network.sh exists to prevent',
    );
    expect(
      script.indexOf('veil-network.sh'),
      lessThan(script.indexOf(r'assets/$XVEIL_NETWORK/obfs4_psk.b64')),
      reason: 'the rule has to be sourced before the variable is used',
    );
  });

  test('the documentation names the option', () {
    final doc = File('doc/HEADLESS-DAEMON.md').readAsStringSync();
    expect(
      doc,
      contains('obfs4_psk_file'),
      reason:
          'this was the whole defect: the option existed in headless_config '
          'and the daemon documentation did not mention obfs4 once',
    );
    expect(
      doc,
      contains('XVEIL_OBFS4_PSK_FILE'),
      reason: 'a service manager with no editable config needs the env form',
    );
  });
}
