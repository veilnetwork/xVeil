import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  /// Hosting registers the service ONCE.
  ///
  /// It used to loop for `extraProviderSlots` more, and the loop could not
  /// work in two independent ways. `registerEphemeralOnionService` ZEROES the
  /// seed it is handed — that is its contract — so every call after the first
  /// passed thirty-two zero bytes, which is not this service's identity but a
  /// well-known one anybody can derive. And the native side refuses the same
  /// identity in a second slot anyway (report27 X37).
  ///
  /// Checked at the source: the register call goes into a live daemon, so what
  /// is verifiable here is that the caller asks for one slot and no loop asks
  /// again with a buffer the first call emptied.
  test('a hosted capability registers its service exactly once', () {
    final src = File(
      'lib/data/transport/veil_flutter_transport.dart',
    ).readAsStringSync();
    final at = src.indexOf('Future<VeilCapabilityEndpoint> hostTransientCapabilityEndpoint(');
    expect(at, greaterThan(0), reason: 'the hosting call moved');
    final body = src.substring(at, src.indexOf('\n  Future<', at + 10));

    expect(
      'registerEphemeralOnionService('.allMatches(body).length,
      1,
      reason:
          'the hosting call registers more than once, and every call after '
          'the first is handed a seed the previous one zeroed',
    );
    expect(
      body,
      isNot(contains('extraProviderSlots')),
      reason: 'the option the layer below cannot honour is back',
    );
  });

  test('nothing asks for extra provider slots any more', () {
    for (final path in [
      'lib/state/cloud_capability_service.dart',
      'lib/state/cloud_document_replication_service.dart',
    ]) {
      final src = File(path).readAsStringSync();
      final mentions = 'extraProviderSlots:'.allMatches(src).length;
      expect(
        mentions,
        0,
        reason: '$path still passes extraProviderSlots',
      );
    }
  });
}
