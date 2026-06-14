import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/transport/bootstrap_invite.dart';

// Real invites emitted by two live `veil-cli bootstrap invite` runs.
const _inviteA =
    'veil:bootstrap?pk=l/Mxk9sBuZDJh9fAFU/O0a+6vglkoE1bneO0K+OFwgM=&t=tcp://127.0.0.1:9100&a=ed25519&nc=AYX/vg==';
const _nodeIdA =
    'c4934d287519f5d989858a124dd9a79d2b393a2428b4847ab589c910770a9928';

const _inviteB =
    'veil:bootstrap?pk=UmYafaeNyllMnwNeeDbSwuqzZAXlj0YGFwCTiQkCdxo=&t=tcp://127.0.0.1:9101&a=ed25519&nc=AJPSqQ==';
const _nodeIdB =
    '75cb65f33601923fe0ee3b5ec039eec6a1a9b5fd066d5854892d95e0f55eea79';

void main() {
  test('parses a real invite and derives node id = BLAKE3(pubkey)', () {
    final a = BootstrapInvite.parse(_inviteA);
    expect(a.publicKey.length, 32);
    expect(a.transport, 'tcp://127.0.0.1:9100');
    expect(a.algo, 'ed25519');
    expect(a.nodeId.hex, _nodeIdA);

    final b = BootstrapInvite.parse(_inviteB);
    expect(b.nodeId.hex, _nodeIdB);
    expect(b.transport, 'tcp://127.0.0.1:9101');
  });

  test('round-trips parse -> toUri', () {
    expect(BootstrapInvite.parse(_inviteA).toUri(), _inviteA);
    expect(BootstrapInvite.parse(_inviteB).toUri(), _inviteB);
  });

  test('rejects non-invite input', () {
    expect(() => BootstrapInvite.parse('https://example.com'),
        throwsFormatException);
    expect(() => BootstrapInvite.parse('veil:bootstrap?pk=AA=='),
        throwsFormatException);
  });
}
