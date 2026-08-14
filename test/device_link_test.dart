import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/transport/bootstrap_invite.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/device_link.dart';

void main() {
  _instanceTests();
  BootstrapInvite invite(int seed) => BootstrapInvite(
    publicKey: Uint8List.fromList(List.filled(32, seed)),
    nonce: Uint8List.fromList([seed, seed + 1, seed + 2, seed + 3]),
  );

  test(
    'device-link token URI and persisted JSON round-trip exact bindings',
    () {
      final sourceInvite = invite(7);
      final token = DeviceLinkToken(
        groupId: invite(9).nodeId,
        source: sourceInvite.nodeId,
        manifestHash: Uint8List.fromList(List.generate(32, (i) => i)),
        sourceInvite: sourceInvite,
        expiresAtMs: 123456789,
      );
      final uri = DeviceLinkToken.parse(token.toUri());
      expect(uri.groupId, token.groupId);
      expect(uri.source, token.source);
      expect(uri.manifestHash, token.manifestHash);
      expect(uri.sourceInvite.toUri(), sourceInvite.toUri());
      expect(uri.expiresAtMs, token.expiresAtMs);

      final json = DeviceLinkToken.fromJson(
        jsonDecode(jsonEncode(token.toJson())),
      );
      expect(json, isNotNull);
      expect(json!.toUri(), token.toUri());
    },
  );

  test('token rejects source id not bound to embedded invite', () {
    final sourceInvite = invite(1);
    final uri = Uri(
      scheme: 'veil',
      path: 'xveil-device',
      queryParameters: {
        'v': '1',
        'gid': invite(2).nodeId.hex,
        'src': invite(3).nodeId.hex,
        'mh': base64Url.encode(List.filled(32, 4)),
        'exp': '9999999999999',
        'invite': sourceInvite.toUri(),
      },
    ).toString();
    expect(() => DeviceLinkToken.parse(uri), throwsFormatException);
  });

  test('token caps hostile input and validates hash length', () {
    expect(
      () => DeviceLinkToken.parse(
        'veil:xveil-device?${List.filled(9000, 'x').join()}',
      ),
      throwsFormatException,
    );
    final sourceInvite = invite(1);
    final bad = DeviceLinkToken.fromJson({
      'v': 1,
      'gid': invite(2).nodeId.hex,
      'src': sourceInvite.nodeId.hex,
      'mh': base64.encode([1, 2]),
      'exp': 9999999999999,
      'invite': sourceInvite.toUri(),
    });
    expect(bad, isNull);
  });

  test('expiry is explicit and boundary-inclusive', () {
    final sourceInvite = invite(5);
    final token = DeviceLinkToken(
      groupId: invite(6).nodeId,
      source: sourceInvite.nodeId,
      manifestHash: Uint8List(32),
      sourceInvite: sourceInvite,
      expiresAtMs: 1000,
    );
    expect(token.isExpired(999), isFalse);
    expect(token.isExpired(1000), isTrue);
  });
}

// Which DEVICE issued the token, and the decision that reads it.
//
// `source` names the IDENTITY, and every device of an identity shares it. The
// target's adoption guard compared that with its own id to mean "a token I
// issued myself" — so a token from a genuine sibling was refused and linking
// died at "admission rejected". The device node id is what carries the
// difference.
void _instanceTests() {
  BootstrapInvite invite(int seed) => BootstrapInvite(
    publicKey: Uint8List.fromList(List.filled(32, seed)),
    nonce: Uint8List.fromList([seed, seed + 1, seed + 2, seed + 3]),
  );

  DeviceLinkToken token({NodeId? device}) {
    final src = invite(7);
    return DeviceLinkToken(
      groupId: invite(9).nodeId,
      source: src.nodeId,
      manifestHash: Uint8List.fromList(List.generate(32, (i) => i)),
      sourceInvite: src,
      expiresAtMs: 123456789,
      sourceDevice: device,
    );
  }

  test('the issuing device survives both spellings', () {
    final d = invite(3).nodeId;
    final t = token(device: d);
    expect(DeviceLinkToken.parse(t.toUri()).sourceDevice, d);
    expect(DeviceLinkToken.fromJson(t.toJson())!.sourceDevice, d);
  });

  // A token from a build without the field must still parse, and still adopt
  // by the old rule — that is the whole point of the fallback.
  test('a token without it round-trips as null and adds no field', () {
    final t = token();
    expect(t.toUri().contains('sd='), isFalse);
    expect(t.toJson().containsKey('sd'), isFalse);
    expect(DeviceLinkToken.parse(t.toUri()).sourceDevice, isNull);
  });

  group('is this token from me', () {
    final me = invite(2).nodeId;
    final t = token(device: invite(3).nodeId);

    // THE ONE THE DEFECT WAS ABOUT: same identity, different device.
    test('a sibling device is NOT me', () {
      expect(
        isSameDevice(
          theirDevice: t.sourceDevice,
          myDevice: me,
          theirIdentity: t.source,
          myIdentity: t.source,
        ),
        isFalse,
        reason: 'a token issued by my other device must be adoptable',
      );
    });

    test('my own token is me', () {
      final mine = token(device: me);
      expect(
        isSameDevice(
          theirDevice: mine.sourceDevice,
          myDevice: me,
          theirIdentity: mine.source,
          myIdentity: mine.source,
        ),
        isTrue,
      );
    });

    test('with no device ids it falls back to identities', () {
      expect(
        isSameDevice(
          theirDevice: null,
          myDevice: null,
          theirIdentity: t.source,
          myIdentity: t.source,
        ),
        isTrue,
      );
      expect(
        isSameDevice(
          theirDevice: null,
          myDevice: me,
          theirIdentity: t.source,
          myIdentity: invite(4).nodeId,
        ),
        isFalse,
      );
    });
  });
}
