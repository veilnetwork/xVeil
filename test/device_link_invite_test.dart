// The invite a device shows to ANOTHER DEVICE of the same identity.
//
// A contact invite names the IDENTITY — every device of one identity hands out
// the same string, deliberately, because that is the address mail goes to. The
// ceremony cannot open on it: it asks "is this me?" and, later, "where do I
// send the snapshot?", and neither has an answer in a string all my devices
// share. So linking gets the device's OWN invite, and these tests pin that
// split down — including keeping it OUT of what contacts receive.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/transport/bootstrap_invite.dart';
import 'package:xveil/data/transport/device_link_invite.dart';

BootstrapInvite _invite(int seed) => BootstrapInvite(
  publicKey: Uint8List.fromList(List.filled(32, seed)),
  nonce: Uint8List.fromList([seed, seed + 1, seed + 2, seed + 3]),
  algo: 'ed25519',
);

void main() {
  test('a device-link invite round-trips its own key', () {
    final src = DeviceLinkInvite(device: _invite(7));
    final back = DeviceLinkInvite.parse(src.toUri());
    expect(back.namesTheDevice, isTrue);
    expect(back.nodeId, _invite(7).nodeId);
    expect(back.device.algo, 'ed25519');
  });

  test('it is a different string from the contact invite', () {
    final d = DeviceLinkInvite(device: _invite(7));
    expect(d.toUri().startsWith(DeviceLinkInvite.scheme), isTrue);
    expect(d.toUri().startsWith(BootstrapInvite.scheme), isFalse);
  });

  // An older device's QR is a plain bootstrap invite naming its identity.
  // Refusing it would break linking to exactly the devices most likely to need
  // it, so it parses — flagged as not naming a device.
  test('a plain bootstrap invite parses as identity-naming', () {
    final back = DeviceLinkInvite.parse(_invite(7).toUri());
    expect(back.namesTheDevice, isFalse);
    expect(back.nodeId, _invite(7).nodeId);
  });

  group('the identity document rides along', () {
    // Without it the two devices deadlock: delivery seals a copy per device
    // and learns which devices exist from the published document, so until
    // the documents merge each side publishes a registry naming only itself
    // and the first message has nowhere to go.
    final doc = Uint8List.fromList(List.generate(300, (i) => (i * 7) % 256));

    test('a document survives the uri', () {
      final src = DeviceLinkInvite(device: _invite(7), document: doc);
      final back = DeviceLinkInvite.parse(src.toUri());
      expect(back.document, doc);
      expect(back.nodeId, _invite(7).nodeId, reason: 'the key still parses');
    });

    test('no document is not an empty one', () {
      final u = DeviceLinkInvite(device: _invite(7)).toUri();
      expect(u.contains('doc='), isFalse);
      expect(DeviceLinkInvite.parse(u).document, isNull);
    });

    // The document is base64url with its padding stripped, because the invite
    // is split on both '&' and '=' — standard base64 would be cut apart by
    // its own padding.
    test('a document carrying + and / and padding survives', () {
      final awkward = Uint8List.fromList([251, 255, 254, 250, 0, 1]);
      final back = DeviceLinkInvite.parse(
        DeviceLinkInvite(device: _invite(7), document: awkward).toUri(),
      );
      expect(back.document, awkward);
    });
  });

  group('is this me', () {
    final identity = _invite(1).nodeId;
    final me = _invite(2).nodeId;

    // THE ONE THE DEFECT WAS ABOUT. Two devices of one identity: the identity
    // ids match and the device ids do not. Comparing identities says "me" and
    // refuses a legitimate link.
    test('a sibling device is not me', () {
      final sibling = DeviceLinkInvite(device: _invite(3));
      expect(
        sibling.isSelf(myDeviceNodeId: me, myIdentityId: identity),
        isFalse,
        reason: 'a second device of my identity must be linkable',
      );
    });

    test('my own device invite is me', () {
      final mine = DeviceLinkInvite(device: _invite(2));
      expect(mine.isSelf(myDeviceNodeId: me, myIdentityId: identity), isTrue);
    });

    // The conservative fallback: nothing here names a device, so the only
    // comparison left is the identity — which for a sibling means "self" and a
    // refusal. Refusing is recoverable; linking on an identifier that cannot
    // tell two devices apart is not.
    test('an identity-naming invite falls back to the identity', () {
      final legacy = DeviceLinkInvite.parse(_invite(1).toUri());
      expect(
        legacy.isSelf(myDeviceNodeId: me, myIdentityId: identity),
        isTrue,
      );
      final other = DeviceLinkInvite.parse(_invite(9).toUri());
      expect(
        other.isSelf(myDeviceNodeId: me, myIdentityId: identity),
        isFalse,
      );
    });
  });
}
