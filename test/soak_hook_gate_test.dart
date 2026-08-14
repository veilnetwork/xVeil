import 'dart:io';

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
      final uri = Uri.parse('/unlock?k=deadbeefcafe&limit=5');
      final line = redactSecrets(uri);
      expect(line, isNot(contains('deadbeefcafe')));
      expect(line, contains('REDACTED'));
      // Everything else still readable — a log that hides the request is not a
      // diagnostic.
      expect(line, contains('/unlock'));
      expect(line, contains('limit=5'));
    });

    test('the store password never reaches the log either', () {
      // The half this test used to get WRONG. It asserted the password stayed
      // readable — `expect(line, contains('hunter2'))` — as if only the hook's
      // own key were a secret. `/compact` reads its password through
      // `_mergedParams`, which merges the QUERY STRING, so a `?password=` was a
      // reachable spelling; and this line runs before any handler, so refusing
      // it at the endpoint could not have kept it out of the log.
      for (final name in ['password', 'passphrase', 'phrase', 'pass']) {
        final line = redactSecrets(Uri.parse('/compact?$name=hunter2'));
        expect(
          line,
          isNot(contains('hunter2')),
          reason: '$name= put the store password in the dev-log ring',
        );
        expect(line, contains('REDACTED'));
      }
    });

    test('the name is matched however it is cased', () {
      // A driver that writes `?Password=` is not a different threat.
      expect(redactSecrets(Uri.parse('/compact?Password=hunter2')),
          isNot(contains('hunter2')));
      expect(redactSecrets(Uri.parse('/health?K=deadbeef')),
          isNot(contains('deadbeef')));
    });

    test('a partial key is not good enough', () {
      // Whole-value replacement, not a prefix trim: half a key in a log is
      // still half a key.
      const key = 'a1b2c3d4e5f60718293a4b5c6d7e8f90';
      final line = redactSecrets(Uri.parse('/health?k=$key'));
      for (var i = 8; i <= key.length; i += 8) {
        expect(line, isNot(contains(key.substring(0, i))));
      }
    });

    test('a URI with no secret is passed through untouched', () {
      final uri = Uri.parse('/health?limit=5');
      expect(redactSecrets(uri), uri.toString());
    });
  });

  group('the hook arms whatever boot the app took', () {
    // Structural, for the same reason as the group below: the handler lives in
    // a widget the test build compiles out.
    //
    // The defect: `_publishSoakKey` read `deniableBootProvider?.runtimeDir` and
    // returned false when it was null. Only the DENIABLE boot claims a runtime
    // dir; the config-file boot — `XVEIL_VEIL_CLI` + `XVEIL_VEIL_CONFIG`, which
    // is how a stand points the app at an external node — claims none. So the
    // two env vars a stand always sets were also the ones that turned the hook
    // off, with nothing to see from outside: same build, `XVEIL_DEBUG_HOOK=true`
    // honoured, window up, Dart VM service answering, and the hook port simply
    // never bound.
    final source = File('lib/debug/soak_hook.dart').readAsStringSync();

    test('no runtime dir from the boot is not the end of it', () {
      final publish = source.substring(source.indexOf('Future<bool> _publishSoakKey('));
      final body = publish.substring(0, publish.indexOf('\n  Future<'));
      expect(
        body,
        contains('_claimRuntimeDir()'),
        reason: 'a boot that claims no runtime dir must not decide whether the '
            'explicitly-requested hook arms',
      );
      expect(
        RegExp(r'runtimeDir == null\)\s*return false;').hasMatch(body) &&
            !body.contains('_claimRuntimeDir()'),
        isFalse,
        reason: 'the bare give-up on a null runtime dir must not come back',
      );
    });

    test('the hook claims with the bare pid, so the sweeper can reap it', () {
      // The other half of that fix, and the one with a real cost if it drifts:
      // the per-run key sits in this directory. `test/runtime_dir_sweep_test.dart`
      // pins the claim/sweep coupling behaviourally; this pins the call site so
      // a later edit cannot decorate the name without tripping something.
      final claim = source.substring(source.indexOf('Future<String?> _claimRuntimeDir('));
      final body = claim.substring(0, claim.indexOf('\n  /// Write the per-run key'));
      expect(body, contains(r"uniqueSuffix: '$pid'"));
      expect(
        body,
        isNot(contains(r"uniqueSuffix: '$pid-")),
        reason: 'a decorated name matches nothing in the launch sweeper and '
            'would leave the key on disk through every future launch',
      );
    });
  });

  group('/compact refuses a query-string password', () {
    // The endpoint half. Redaction keeps the value out of the log; this keeps
    // the spelling from being offered at all, so a stand driver does not learn
    // a shape that only works because something downstream cleans up after it.
    // Structural, on the source, because the handler lives inside a widget the
    // test build compiles out — `_debugHookEnabled` is a const `false` there,
    // so no test can drive a request through the real server.
    final source = File('lib/debug/soak_hook.dart').readAsStringSync();

    test('the handler rejects a password on the request line', () {
      final compact = source.substring(source.indexOf('Future<void> _compact('));
      final body = compact.substring(0, compact.indexOf('\n  Future<'));
      expect(
        body,
        contains("req.uri.queryParameters.containsKey('password')"),
        reason: '_mergedParams merges the query string, so without this check '
            'the password is accepted from the request line',
      );
      // Against the CALL, not the word — the comment above the check names
      // `_mergedParams` too, and matching that made this assertion compare the
      // check against its own explanation.
      expect(
        body.indexOf("queryParameters.containsKey('password')"),
        lessThan(body.indexOf('await _mergedParams(req)')),
        reason: 'the refusal must come before the body is read, or a caller '
            'that sends it both ways is served rather than corrected',
      );
    });
  });

  // The stand types into the app's own fields, and the fields it types into are
  // overwhelmingly passwords: a container password at the lock screen, a
  // password twice during onboarding. `/enter_text` answered with the value it
  // had just typed, so the secret came straight back in the response and into
  // whatever captured it — a terminal scrollback, a CI log, a transcript. The
  // query string is already redacted for exactly this reason; answering with
  // the secret undid that one line later.
  //
  // Structural, on the source, for the same reason as the /compact gate above:
  // the handler lives inside a widget this test build compiles out.
  group('/enter_text does not hand the text back', () {
    final source = File('lib/debug/soak_hook.dart').readAsStringSync();

    // Read inside each test, not in the group body: `expect` outside a test is
    // an OutsideTestException, and the guard belongs where it can report.
    String handlerBody() {
      final from = source.indexOf('Future<void> _enterText(');
      expect(from, greaterThan(-1), reason: '_enterText moved or was renamed');
      return source.substring(from, source.indexOf('\n  Future<', from));
    }

    test('the success answer carries a length, not the value', () {
      expect(
        handlerBody(),
        contains("'chars': text.length"),
        reason: 'a length distinguishes typed from typed-nothing and confirms '
            'the field took the whole value, without being the secret',
      );
    });

    test('and never the text itself', () {
      expect(
        handlerBody(),
        isNot(contains("'text': text")),
        reason: 'this is the echo that put a password in the response',
      );
    });
  });

}
