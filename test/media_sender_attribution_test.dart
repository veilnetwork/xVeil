import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/veil_addressing.dart';
import 'package:xveil/data/transport/veil_flutter_transport.dart';

void main() {
  final identity = NodeId(Uint8List.fromList(List.filled(32, 0xA1)));
  final device = NodeId(Uint8List.fromList(List.filled(32, 0xD1)));

  test('relay source app matches the physical envelope before and after P2P', () {
    for (final admitted in [false, true]) {
      final source =
          mediaSenderUsesIdentity(relay: true, sessionAdmitted: admitted)
          ? identity
          : device;
      // Native startDirectMediaReceiver computes this from envelope.src_node_id.
      expect(mediaAppIdFor(source), orderedEquals(mediaAppIdFor(device)));
      expect(
        mediaAppIdFor(source),
        isNot(orderedEquals(mediaAppIdFor(identity))),
      );
    }
  });

  test('direct source still follows authenticated session attribution', () {
    expect(
      mediaSenderUsesIdentity(relay: false, sessionAdmitted: true),
      isTrue,
    );
    expect(
      mediaSenderUsesIdentity(relay: false, sessionAdmitted: false),
      isFalse,
    );
  });
}
