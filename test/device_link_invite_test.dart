// The invite a device shows to ANOTHER DEVICE of the same identity.
//
// The ceremony opens by asking "is this me?". Once an invite began naming the
// IDENTITY instead of the device, every device of one identity handed out a
// byte-identical string and that question stopped having an answer — linking a
// genuine second device was refused as "self device". These tests pin the
// answer down, and pin the contact invite OUT of it.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/bootstrap_invite.dart';
import 'package:xveil/data/transport/device_link_invite.dart';

BootstrapInvite _invite({int keyByte = 7}) => BootstrapInvite(
  publicKey: Uint8List.fromList(List.filled(32, keyByte)),
  nonce: Uint8List.fromList([0, 11, 22, 33]),
  algo: 'ed25519',
);

Uint8List _inst(int b) => Uint8List.fromList(List.filled(16, b));

void main() {
  test('a device-link invite round-trips through its uri', () {
    final src = DeviceLinkInvite(invite: _invite(), instance: _inst(0xA1));
    final back = DeviceLinkInvite.parse(src.toUri());
    expect(back.instance, _inst(0xA1));
    expect(base64.encode(back.invite.publicKey), base64.encode(_invite().publicKey));
    expect(base64.encode(back.invite.nonce), base64.encode(_invite().nonce));
    expect(back.invite.algo, 'ed25519');
  });

  test('it is a different string from the contact invite', () {
    final d = DeviceLinkInvite(invite: _invite(), instance: _inst(1));
    expect(d.toUri().startsWith(DeviceLinkInvite.scheme), isTrue);
    expect(d.toUri().startsWith(BootstrapInvite.scheme), isFalse);
    // THE PRIVACY POINT: what a contact receives carries no device value.
    expect(_invite().toUri().contains('inst='), isFalse);
  });

  // An older device's QR is a plain bootstrap invite. Refusing it would break
  // linking to exactly the devices most likely to need it.
  test('a plain bootstrap invite is still accepted, with no instance', () {
    final back = DeviceLinkInvite.parse(_invite().toUri());
    expect(back.instance, isNull);
    expect(back.invite.nodeId, _invite().nodeId);
  });

  group('is this me', () {
    final mine = _inst(0x11);

    test('same instance is this device', () {
      final d = DeviceLinkInvite(invite: _invite(), instance: mine);
      expect(
        d.isSelf(myInstance: mine, myNodeId: _invite().nodeId),
        isTrue,
      );
    });

    // THE ONE THE DEFECT WAS ABOUT. Same identity — so the node ids match —
    // and a different device. Comparing node ids says "me"; comparing
    // instances says what is true.
    test('same identity, different instance is NOT this device', () {
      final d = DeviceLinkInvite(invite: _invite(), instance: _inst(0x22));
      expect(
        d.isSelf(myInstance: mine, myNodeId: _invite().nodeId),
        isFalse,
        reason: 'a second device of my identity must be linkable',
      );
    });

    test('no instance on either side falls back to the node id', () {
      final same = DeviceLinkInvite(invite: _invite());
      expect(same.isSelf(myInstance: null, myNodeId: _invite().nodeId), isTrue);
      final other = DeviceLinkInvite(invite: _invite(keyByte: 9));
      expect(
        other.isSelf(myInstance: null, myNodeId: _invite().nodeId),
        isFalse,
      );
    });

    test('an instance of a different length is not a match', () {
      final d = DeviceLinkInvite(
        invite: _invite(),
        instance: Uint8List.fromList([0x11, 0x11]),
      );
      expect(d.isSelf(myInstance: mine, myNodeId: _invite().nodeId), isFalse);
    });
  });

  test('a malformed instance does not take the invite down with it', () {
    final uri = '${DeviceLinkInvite.scheme}'
        'pk=${base64.encode(_invite().publicKey)}'
        '&a=ed25519&nc=${base64.encode(_invite().nonce)}&inst=zznothex';
    final back = DeviceLinkInvite.parse(uri);
    expect(back.instance, isNull);
    expect(back.invite.nodeId, _invite().nodeId);
  });
}
