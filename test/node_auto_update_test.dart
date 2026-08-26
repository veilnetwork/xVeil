import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/node_auto_update.dart';

/// A node that updates itself fetches a binary over the network and installs it
/// as root, unattended. What keeps that honest is a short list of refusals, and
/// the one that decides everything -- "is this tag actually newer" -- is a
/// shell function. So it is exercised by a real shell rather than read.
void main() {
  /// The `newer_than` helper exactly as the generated script carries it.
  String comparator() {
    final script = buildNodeAutoUpdateScript(enabled: true);
    final line = script
        .split('\n')
        .firstWhere((l) => l.startsWith('newer_than()'));
    return line;
  }

  /// True when the script would treat [candidate] as newer than [have].
  bool newerThan(String candidate, String have) {
    final result = Process.runSync('bash', [
      '-c',
      '${comparator()}\nnewer_than "$candidate" "$have" && echo yes || echo no',
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    return (result.stdout as String).trim() == 'yes';
  }

  group('deciding whether to move', () {
    test('a newer tag is newer', () {
      expect(newerThan('v0.8.1', 'v0.8.0'), isTrue);
      expect(newerThan('v0.9.0', 'v0.8.9'), isTrue);
      expect(newerThan('v1.0.0', 'v0.99.99'), isTrue);
    });

    test('the same tag is NOT newer, so a re-run installs nothing', () {
      expect(newerThan('v0.8.1', 'v0.8.1'), isFalse);
    });

    test('an older tag is refused — no walking a node backwards', () {
      // The whole reason the floor and this check exist: "latest" is whatever
      // the API says it is.
      expect(newerThan('v0.7.0', 'v0.8.1'), isFalse);
      expect(newerThan('v0.8.0', 'v0.8.1'), isFalse);
    });

    test('two-digit parts order as numbers, not as text', () {
      // The classic: `v0.10.0` sorts BELOW `v0.9.0` under a plain string
      // compare, which would hold a fleet a release behind forever.
      expect(newerThan('v0.10.0', 'v0.9.0'), isTrue);
      expect(newerThan('v0.9.0', 'v0.10.0'), isFalse);
    });

    test('an unknown running version does not block an update', () {
      // `veil-cli --version` on a broken install yields an empty string; the
      // node should still be able to repair itself.
      expect(newerThan('v0.8.1', 'v'), isTrue);
    });
  });

  group('what the installed updater refuses', () {
    final script = buildNodeAutoUpdateScript(enabled: true);

    test('it verifies the digest before installing', () {
      expect(script, contains('sha256sum'));
      expect(script, contains('digest mismatch'));
      // The comparison must guard the install, not merely be computed.
      expect(script.indexOf('digest mismatch'), lessThan(script.indexOf('install -o root')));
    });

    test('it will not go below the floor', () {
      expect(script, contains("FLOOR='v0.4.2'"));
      expect(script, contains('below the floor'));
    });

    test('it keeps the previous binary and restores it', () {
      expect(script, contains(r'cp -a "$BIN" "$BIN.previous"'));
      expect(script, contains('did not come back'));
      expect(script, contains(r'install -o root -g root -m 0755 "$BIN.previous" "$BIN"'));
    });

    test('it only restarts a service that was running', () {
      expect(script, contains('was_active=1'));
      expect(script, contains(r'if [ "$was_active" = 1 ]'));
    });

    test('an unreachable API is a quiet no-op, not a failed unit', () {
      // A timer that reports failure every time the network is down trains
      // whoever runs the box to ignore it.
      expect(script, contains('release API unreachable'));
    });

    test('the fleet does not ask all at once', () {
      expect(script, contains('RandomizedDelaySec'));
    });
  });

  group('turning it off', () {
    test('removes the timer, the unit and the script', () {
      final off = buildNodeAutoUpdateScript(enabled: false);

      expect(off, contains('disable --now'));
      expect(off, contains(kAutoUpdateScriptPath));
      expect(off, contains('rm -f'));
      // Removing rather than masking: a disabled timer left on disk is a thing
      // somebody re-enables by accident, and this one installs as root.
      expect(off, isNot(contains('systemctl mask')));
    });

    test('off and on are not the same script', () {
      // Vacuity guard for the assertions above.
      expect(
        buildNodeAutoUpdateScript(enabled: false),
        isNot(buildNodeAutoUpdateScript(enabled: true)),
      );
    });
  });

  group('refusing bad arguments', () {
    test('a floor that is not a version', () {
      for (final bad in ['latest', 'v1.2', '0.4.2; rm -rf /', '']) {
        expect(
          () => buildNodeAutoUpdateScript(enabled: true, minimumTag: bad),
          throwsArgumentError,
          reason: bad,
        );
      }
    });

    test('a schedule that is not a calendar word', () {
      // It lands in a unit file unquoted; anything but a word has no business
      // there.
      for (final bad in ['daily; rm -rf /', '*-*-* 00:00:00', '']) {
        expect(
          () => buildNodeAutoUpdateScript(enabled: true, schedule: bad),
          throwsArgumentError,
          reason: bad,
        );
      }
    });
  });

  test('the generated script is valid bash', () {
    // Structure only — it is never run here, and `bash -n` is what says the
    // quoting and the heredocs actually close.
    for (final enabled in [true, false]) {
      final file = File(
        '${Directory.systemTemp.createTempSync('xveil-au').path}/s.sh',
      )..writeAsStringSync(buildNodeAutoUpdateScript(enabled: enabled));
      final check = Process.runSync('bash', ['-n', file.path]);
      expect(check.exitCode, 0, reason: '${check.stderr}');
      file.parent.deleteSync(recursive: true);
    }
  });
}
