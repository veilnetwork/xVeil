import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/p2p_policy_controller.dart';

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

/// A P2P question about a contact's DEVICE is a question about the contact.
void main() {
  final identity = _id(0x11);
  final device = _id(0x12);
  final stranger = _id(0x13);
  final contact = Contact(nodeId: identity, status: ContactStatus.accepted);
  Future<Contact?> getContact(NodeId peer) async =>
      peer == identity ? contact : null;

  test('a contact is found by its own id', () async {
    expect(
      await policyContactFor(
        identity,
        getContact: getContact,
        identityOfDevice: (_) => null,
      ),
      contact,
    );
  });

  test('a device proven to speak for a contact finds that contact', () async {
    expect(
      await policyContactFor(
        device,
        getContact: getContact,
        identityOfDevice: (d) => d == device ? identity : null,
      ),
      contact,
      reason: 'acks and device-scoped sends name the device; refusing it '
          'kept that device of the contact on the relay for good',
    );
  });

  test('a device nobody proved stays unknown', () async {
    expect(
      await policyContactFor(
        stranger,
        getContact: getContact,
        identityOfDevice: (_) => null,
      ),
      isNull,
    );
  });
}
