// The daemon says which id is an address, because two of them are not.
//
// `node` is this daemon's transport id; `identity` is what contacts address.
// They are the same value for a classic identity — there the master IS the
// node's Ed25519 key — and that is why one field looked like enough for so
// long. For a hybrid identity they differ. Measured on a running daemon:
//
//     ready  node=7950d395…6153e
//     log    node.sovereign_identity.loaded node_id=2d3d8572…6da2
//
// An operator answering "who is it?" with the first hands out the DEVICE, and
// mail sent to a device id never arrives. The same confusion the invite had,
// in a different place.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final cli = File('bin/xveil.dart').readAsStringSync();
  final runtime = File('lib/headless/headless_runtime.dart').readAsStringSync();
  final doc = File('doc/HEADLESS-DAEMON.md').readAsStringSync();

  test('the startup line carries the identity, not only the node', () {
    final at = cli.indexOf("'ready': true");
    expect(at, isNot(-1), reason: 'the startup line was renamed or removed');
    // Both sides of it: the value is resolved just ABOVE the line it goes
    // into, and a window that only looked forward missed it — the test's
    // fault, not the code's, caught on its first run.
    final line = cli.substring(at - 700 < 0 ? 0 : at - 700, at + 400);
    expect(
      line,
      contains("'identity'"),
      reason:
          'a startup line that offers only `node` is one an operator will '
          'copy and hand out — it is the first thing the daemon prints',
    );
    expect(
      line,
      contains('sovereignReceiveAddress'),
      reason:
          'the identity has to come from where the mailbox is registered, or '
          'it is a second answer to the same question',
    );
  });

  test('GET /v1/account answers "who is it" with both', () {
    final at = runtime.indexOf("'reachableOffline'");
    expect(at, isNot(-1), reason: 'the account answer was restructured');
    final body = runtime.substring(at, at + 1400);
    expect(body, contains("'nodeId'"), reason: 'existing clients read this');
    expect(
      body,
      contains("'identity'"),
      reason:
          'the documentation calls this endpoint "who is it?" — answering only '
          'with the device id is the defect this exists to prevent',
    );
  });

  test('the documentation says which one to hand out', () {
    expect(doc, contains('identity'));
    expect(
      doc.contains('hand out `identity`, never `nodeId`') ||
          doc.contains('This is the one to hand out'),
      isTrue,
      reason:
          'two ids in one answer need the doc to say which is which, or the '
          'reader picks the one that is named more like an address',
    );
  });
}
