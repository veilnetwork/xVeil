import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/bootstrap_invite.dart';
import 'package:xveil/domain/device_link.dart';

NodeId _id(int b) => NodeId(Uint8List.fromList(List.filled(32, b)));

DeviceLinkToken _token(NodeId source) => DeviceLinkToken(
  groupId: _id(1),
  source: source,
  manifestHash: Uint8List(32),
  sourceInvite: BootstrapInvite(
    publicKey: Uint8List.fromList(List.filled(32, 2)),
    nonce: Uint8List.fromList([1, 2, 3, 4]),
  ),
  expiresAtMs: DateTime.now().millisecondsSinceEpoch + 60000,
);

void main() {
  // A joining device boots under a throwaway identity, and a running node
  // cannot become another identity in place: the source sealed for the
  // identity it had admitted and the joiner dropped every frame (111 on the
  // stand) until the app was restarted by hand.
  test('a device running as another identity restarts into the joined one', () {
    expect(
      adoptionNeedsNodeRestart(runningIdentity: _id(9), token: _token(_id(5))),
      isTrue,
    );
  });

  test('a device already running as the joined identity does not restart', () {
    expect(
      adoptionNeedsNodeRestart(runningIdentity: _id(5), token: _token(_id(5))),
      isFalse,
    );
  });
}
