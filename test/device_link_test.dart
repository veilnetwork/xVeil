import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/transport/bootstrap_invite.dart';
import 'package:xveil/domain/device_link.dart';

void main() {
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
