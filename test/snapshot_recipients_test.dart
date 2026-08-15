// Who a device-group snapshot goes to — the one decision this area kept
// getting wrong, in three different ways.
//
// A device group's members are DEVICES. Every device of an identity shares the
// identity, so the identity cannot answer "which member is me": on the device
// restored into an existing identity, filtering by it removes the SIBLING and
// keeps this device, and the result is a send to nobody with the shape of a
// send to somebody.
//
// The version before this addressed the identity ONCE instead of the members,
// on the belief that a device is not addressable. Rendezvous resolves an
// identity to one device, and for a sender that device is itself — measured on
// a two-device stand as seven inbound frames arriving back at the source and
// nothing at the sibling.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/state/group_service.dart';

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

void main() {
  // A two-device identity as the stand actually holds it. The device that
  // booted on the master key has the identity AS its transport id; the restored
  // one has a key of its own.
  final identity = _id(0xB1);
  final restored = _id(0xCD);

  group('a device group addresses its members', () {
    // The device group's OWNER is the identity's MASTER key — a separate value
    // from either device's transport id, and not a device at all.
    final master = _id(0xD3);

    List<NodeId> from(NodeId? myDevice) => snapshotRecipients(
      isDeviceGroup: true,
      members: [identity, restored],
      identity: identity,
      myDevice: myDevice,
      owner: master,
    );

    test('the master-key device sends to the restored one', () {
      expect(from(identity), [restored]);
    });

    // THE ONE. Asking the identity here answers "I am the member whose id is
    // the identity", which on this device is the SIBLING.
    test('the restored device sends to the sibling, not to itself', () {
      expect(
        from(restored),
        [identity],
        reason: 'filtering by the identity would drop the sibling and keep us',
      );
    });

    test('a lone device has nobody to send to', () {
      expect(
        snapshotRecipients(
          isDeviceGroup: true,
          members: [identity],
          identity: identity,
          myDevice: identity,
          owner: master,
        ),
        isEmpty,
      );
    });

    // The master key owns the group and runs nothing. Seeding it produced a
    // deposit against an id no node answers to, which then failed on retry
    // forever.
    test('the master key is not a device and gets nothing', () {
      expect(
        snapshotRecipients(
          isDeviceGroup: true,
          members: [master, identity, restored],
          identity: identity,
          myDevice: identity,
          owner: master,
        ),
        [restored],
      );
    });

    // THE ONE THE LOOP CAME FROM. Falling back to the identity looks
    // conservative and is not: on the restored device the identity names the
    // SIBLING, so the fallback drops the sibling, keeps this device, and the
    // snapshot goes to ourselves — is ingested, and provokes the next one.
    // Measured on the stand as 286 entries in one device group against 34 in
    // the other. Sending nowhere is recoverable; a loop is not.
    test('an unknown device id sends nowhere rather than guessing', () {
      expect(from(null), isEmpty);
    });
  });

  // Unchanged, and the reason the two branches stay separate: an ordinary
  // group's members are separate identities, this device is one of them, and
  // the owner is not a delivery target.
  test('an ordinary group drops us and the owner', () {
    final owner = _id(2);
    final me = _id(3);
    final other = _id(4);
    expect(
      snapshotRecipients(
        isDeviceGroup: false,
        members: [owner, me, other],
        identity: me,
        myDevice: me,
        owner: owner,
      ),
      [other],
    );
  });
}
