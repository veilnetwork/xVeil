import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/main.dart';

/// The audit's highest finding: a shipped build whose hidden-volume library
/// failed to load kept running on the in-memory fake store. Every non-empty
/// password opened the SAME space, nothing was encrypted, nothing survived the
/// process — and the FATAL banner announcing it goes through `devLog`, which is
/// compiled out under `dart.vm.product`. The degradation was therefore silent
/// in precisely the build where it mattered.
///
/// The gate is a pure function so this can be asserted without a bootstrap; the
/// screen it selects is a separate widget for the same reason.
void main() {
  group('a build that cannot open secure storage', () {
    test('refuses to start when it is a shipped one', () {
      expect(
        mustRefuseInsecureStorage(shipped: true, secureStorageReady: false),
        isTrue,
        reason:
            'the alternative is a password prompt that accepts anything and a '
            'recovery phrase written down for a container that does not exist',
      );
    });

    test('still runs in debug, where the fake store IS the wiring', () {
      // Not an oversight to be tightened later: the entire suite and every
      // `flutter run` without native libraries depend on this path. Refusing
      // here would trade a real shipped-build hazard for a broken workflow.
      expect(
        mustRefuseInsecureStorage(shipped: false, secureStorageReady: false),
        isFalse,
      );
    });

    test('does not refuse a shipped build that DID open the container', () {
      // The gate has to be a gate, not a wall: a check that refuses every
      // shipped build would pass the first test above while shipping nothing.
      expect(
        mustRefuseInsecureStorage(shipped: true, secureStorageReady: true),
        isFalse,
      );
      expect(
        mustRefuseInsecureStorage(shipped: false, secureStorageReady: true),
        isFalse,
      );
    });
  });
}
