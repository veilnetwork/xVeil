import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/transport/bootstrap_invite.dart';
import 'package:xveil/data/transport/device_link_invite.dart';
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
    // Sized off the cap rather than off a literal, which is what let this stay
    // green after the cap moved: 9 000 x's stopped exceeding it and went on
    // being refused for the unrelated reason that they carry no `v=1`.
    expect(
      () => DeviceLinkToken.parse(
        'veil:xveil-device?v=1&doc='
        '${'A' * (8 * 1024 + kMaxEncodedDocumentChars)}',
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

  DeviceLinkToken token({NodeId? device, Uint8List? document}) {
    final src = invite(7);
    return DeviceLinkToken(
      groupId: invite(9).nodeId,
      source: src.nodeId,
      manifestHash: Uint8List.fromList(List.generate(32, (i) => i)),
      sourceInvite: src,
      expiresAtMs: 123456789,
      sourceDevice: device,
      document: document,
    );
  }

  // The return leg of the document exchange the invite opens.
  //
  // The invite carries the TARGET's document to the source, so the source can
  // merge before it seals anything. Nothing came back, so the target finished
  // the ceremony holding a document that named only itself — publishing a
  // registry of one, unable to seal to the device it had just been linked to.
  // The link worked in one direction and looked finished.
  group('the source document rides the token back', () {
    final doc = Uint8List.fromList(List.generate(300, (i) => (i * 11) % 256));

    test('a document survives both spellings', () {
      final t = token(document: doc);
      expect(DeviceLinkToken.parse(t.toUri()).document, doc);
      expect(DeviceLinkToken.fromJson(t.toJson())!.document, doc);
    });

    test('no document is not an empty one', () {
      final t = token();
      expect(t.toUri().contains('doc='), isFalse);
      expect(t.toJson().containsKey('doc'), isFalse);
      expect(DeviceLinkToken.parse(t.toUri()).document, isNull);
    });

    // The token is a URI split on '&' and '=', so standard base64 would be cut
    // apart by its own padding — same reason the invite strips it.
    test('a document carrying + and / and padding survives', () {
      final awkward = Uint8List.fromList([251, 255, 254, 250, 0, 1]);
      final back = DeviceLinkToken.parse(token(document: awkward).toUri());
      expect(back.document, awkward);
    });

    // AUDIT X13-M1, the other half. 8 KiB covered the whole token, document
    // included, while the node accepts a 16 KiB document — 21 846 chars of
    // base64url before the ids, the expiry and the percent-encoded source
    // invite are added. Measured, the largest document the old cap could carry
    // was 5 793 bytes, so an identity with enough revocations behind it could no
    // longer ISSUE an adoption token at all and nothing could ever be linked to
    // it again.
    test('a document at the size the node accepts round-trips', () {
      final full = Uint8List.fromList(
        List.generate(kMaxIdentityDocumentBytes, (i) => (i * 13) % 256),
      );
      final t = token(document: full);
      final uri = t.toUri();
      expect(uri.length, greaterThan(8 * 1024), reason: 'past the old cap');
      expect(DeviceLinkToken.parse(uri).document, full);
      expect(DeviceLinkToken.fromJson(t.toJson())!.document, full);
    });

    test('a document past the node ceiling is dropped, not honoured', () {
      final over = Uint8List.fromList(
        List.filled(kMaxIdentityDocumentBytes + 1024, 3),
      );
      final back = DeviceLinkToken.parse(token(document: over).toUri());
      expect(back.document, isNull);
      expect(
        back.source,
        token().source,
        reason: 'the membership half of the token stands on its own',
      );
    });
  });

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
