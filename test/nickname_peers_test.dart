import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/nickname_peers.dart';

void main() {
  test('PeerNickname json round-trip', () {
    const binding = PeerNickname(
      name: 'alicename',
      checkedAtUnix: 1783659000,
      ownerChanged: false,
    );
    final back = PeerNickname.fromJson(
      jsonDecode(jsonEncode(binding)) as Object,
    );
    expect(back, isNotNull);
    expect(back!.name, 'alicename');
    expect(back.checkedAtUnix, 1783659000);
    expect(back.ownerChanged, false);
  });

  test('PeerNickname ownerChanged flag survives round-trip', () {
    const binding = PeerNickname(
      name: 'takenname',
      checkedAtUnix: 1,
      ownerChanged: true,
    );
    final back = PeerNickname.fromJson(
      jsonDecode(jsonEncode(binding)) as Object,
    );
    expect(back!.ownerChanged, true);
  });

  test('PeerNickname.fromJson rejects junk', () {
    expect(PeerNickname.fromJson('nope'), isNull);
    expect(PeerNickname.fromJson(<String, dynamic>{}), isNull);
    expect(PeerNickname.fromJson(<String, dynamic>{'name': 7}), isNull);
    expect(PeerNickname.fromJson(null), isNull);
  });
}
