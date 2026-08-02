import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/debug/soak_hook.dart';

/// The soak hook answers commands that drive the whole app — unlock, send, and
/// handing out the automation API token — over loopback HTTP, and it used to be
/// default-ON in every debug build with no authentication at all. Release
/// builds never contain it, so this is not a release-surface question; it is a
/// STAND question. Those debug builds run against real containers and real
/// identities, on machines where any other local process can reach the port.
void main() {
  test('the hook is off unless the build asked for it', () {
    // The suite runs under a debug VM, so `_hookBuildAllowed` is true here and
    // the explanation is exactly what a stand operator needs to see. A build
    // WITH `--dart-define=XVEIL_DEBUG_HOOK=true` returns null instead.
    final note = debugHookDisabledExplanation();
    expect(
      note,
      isNotNull,
      reason: 'without the define the hook must not be listening',
    );
    expect(
      note,
      contains('XVEIL_DEBUG_HOOK=true'),
      reason: 'the diagnosis has to name the flag that turns it back on — the '
          'silent-compile-out trap is what default-ON was protecting against',
    );
  });

  test('the key file sits beside the runtime dir', () {
    expect(soakKeyPath('/run/xveil'), '/run/xveil/soak.key');
  });

  group('the per-run key comparison', () {
    const key = 'a1b2c3d4';

    test('accepts only the exact key', () {
      expect(soakKeyMatches(key, key), isTrue);
      expect(soakKeyMatches(key, 'a1b2c3d5'), isFalse);
      expect(soakKeyMatches(key, 'a1b2c3d'), isFalse);
      expect(soakKeyMatches(key, 'a1b2c3d4x'), isFalse);
    });

    test('a missing key on either side never matches', () {
      // Before the server has minted one, "no key" must not mean "no check".
      expect(soakKeyMatches(null, key), isFalse);
      expect(soakKeyMatches(key, null), isFalse);
      expect(soakKeyMatches(null, null), isFalse);
      expect(soakKeyMatches('', ''), isFalse);
    });

    test('a prefix is not enough', () {
      // A length-and-prefix compare turns into an oracle the moment somebody
      // adds a retry path.
      expect(soakKeyMatches(key, 'a1b2c3d0'), isFalse);
      expect(soakKeyMatches(key, '01b2c3d4'), isFalse);
    });
  });

  group('the request log line', () {
    test('the soak key never reaches the log', () {
      // Audit XV-15. This line ran BEFORE the gate and printed the whole URI —
      // including the `?k=` the gate accepts — so the per-run key landed in the
      // dev-log ring, which the hook itself serves over `/dev_log`. The secret
      // leaked through the diagnostic channel it was meant to protect.
      final uri = Uri.parse('/unlock?k=deadbeefcafe&password=hunter2');
      final line = redactSoakKey(uri);
      expect(line, isNot(contains('deadbeefcafe')));
      expect(line, contains('REDACTED'));
      // Everything else still readable — a log that hides the request is not a
      // diagnostic.
      expect(line, contains('/unlock'));
      expect(line, contains('hunter2'));
    });

    test('a partial key is not good enough', () {
      // Whole-value replacement, not a prefix trim: half a key in a log is
      // still half a key.
      const key = 'a1b2c3d4e5f60718293a4b5c6d7e8f90';
      final line = redactSoakKey(Uri.parse('/health?k=$key'));
      for (var i = 8; i <= key.length; i += 8) {
        expect(line, isNot(contains(key.substring(0, i))));
      }
    });

    test('a URI with no key is passed through untouched', () {
      final uri = Uri.parse('/health?limit=5');
      expect(redactSoakKey(uri), uri.toString());
    });
  });
}
