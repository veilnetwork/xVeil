import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Structural, because the choice it guards lives in a method that needs a
/// live node: `_setup` asks the transport which id to hash into the call-media
/// master key, and no unit test can reach it. The derivation itself is
/// symmetric and was green through the whole outage — see
/// `call_media_seal_test.dart`, where every earlier case handed both ends the
/// same pair of ids and therefore could not fail.
///
/// In `test/` on purpose: a source-reading assertion that lives inside the file
/// it guards finds its own needle and passes forever.
void main() {
  test('call media hashes the address the peer has for us, not this device', () {
    final source = File('lib/state/veil_call_media.dart').readAsStringSync();
    // Vacuity guard: an unreadable or renamed file must redden here rather
    // than silently satisfy two `isNot` assertions below.
    expect(source.length, greaterThan(1000));
    expect(
      source.contains('deriveCallMediaKeys'),
      isTrue,
      reason: 'this file no longer derives call-media keys — move the guard',
    );

    final localIdAssignment = RegExp(
      r'final localId = \(await _transport\.([A-Za-z]+)\(\)\)\.bytes;',
    ).firstMatch(source);
    expect(
      localIdAssignment,
      isNotNull,
      reason: 'the local id for call-media key derivation is no longer read '
          'from the transport in one place — re-point this guard',
    );
    expect(
      localIdAssignment!.group(1),
      'peerFacingNodeId',
      reason: 'nodeId() is THIS DEVICE and the peer can only name our '
          'IDENTITY; hashing the device made every sealed cell arrive and '
          'fail to open (stand 2026-09-19)',
    );
  });
}
