import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/node_lifecycle.dart';

/// Load, somebody else saves, Apply.
///
/// The config editor reads the whole file and writes the whole file back. So a
/// change made by a second administrator — or an automation, or the node's own
/// writer — between those two moments is not merged and not reported: it is
/// rolled back by whoever loaded first, and the only trace is that a revoked
/// allowlist id, a listener or a hardening setting is quietly back.
///
/// Run as shell, because the check has to happen on the far end at the moment
/// of the install, and reading the script cannot tell whether it does.
void main() {
  const digestOfEmpty =
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

  /// Run the guard the write script carries, against a file whose current
  /// contents are [onDisk], claiming it hashed to [expected] when read.
  ///
  /// Everything else the script does — staging, validating, installing,
  /// restarting a unit — needs a server, so only the guard is executed here.
  ProcessResult check({required String onDisk, required String? expected}) {
    final dir = Directory.systemTemp.createTempSync('xveil-cas');
    addTearDown(() => dir.deleteSync(recursive: true));
    final backup = File('${dir.path}/config.backup')
      ..writeAsStringSync(onDisk);

    final script = buildWriteNodeConfigScript(
      NodeConfigTarget.veil,
      'irrelevant = true\n',
      expectedSha256: expected,
    );
    final lines = script.split('\n');
    final from = lines.indexWhere((l) => l.startsWith('if [ "\$had_config" = 1 ]; then'));
    final guard = from < 0
        // No digest was given, so the script carries no guard at all.
        ? '# nothing'
        : lines.sublist(from, lines.indexOf('fi', from) + 1).join('\n');

    return Process.runSync('bash', [
      '-c',
      'set -euo pipefail\n'
          'sudo() { "\$@"; }\n'
          'had_config=1\n'
          'backup="${backup.path}"\n'
          '$guard\n'
          'echo INSTALLED',
    ]);
  }

  test('the file it read is the file it replaces', () {
    final same = check(onDisk: '', expected: digestOfEmpty);

    expect(same.exitCode, 0, reason: '${same.stderr}');
    expect(same.stdout, contains('INSTALLED'));
  });

  test('a file somebody else changed is NOT overwritten', () {
    // The whole scenario: A loads, B saves, A applies. A's copy does not
    // contain B's change, and a full-file write would drop it.
    final changed = check(onDisk: 'b_was_here = true\n', expected: digestOfEmpty);

    expect(changed.exitCode, isNot(0));
    expect(changed.stderr, contains('XVEIL_CONFIG_CHANGED'));
    expect(
      changed.stdout,
      isNot(contains('INSTALLED')),
      reason: 'the install ran anyway, so the check is a report not a guard',
    );
  });

  test('the digest compared is of the bytes about to be replaced', () {
    // Premise: the comparison must be against the file's CURRENT contents, not
    // against what the caller passed in. Staging the new contents and hashing
    // those would pass every time.
    final body = 'listen = "obfs4-tcp://0.0.0.0:5556"\n';
    final actual = sha256.convert(utf8.encode(body)).toString();

    expect(check(onDisk: body, expected: actual).exitCode, 0);
    expect(check(onDisk: body, expected: digestOfEmpty).exitCode, isNot(0));
  });

  group('what the read reports', () {
    const body = 'x = 1\n';
    final encoded = base64Encode(utf8.encode(body));

    test('a digest comes back with the contents', () {
      final read = parseReadNodeConfig(
        'XVEIL_CONFIG_SHA256: $digestOfEmpty\n'
        'XVEIL_CONFIG_BEGIN\n$encoded\n'
        'XVEIL_CONFIG_END\n',
      );

      expect(read!.contents, body);
      expect(read.sha256, digestOfEmpty);
    });

    test('a node whose script is too old reports none, and says so', () {
      // Null rather than a made-up value: it means "this save cannot check",
      // which is a narrower promise and not a different one.
      final read = parseReadNodeConfig(
        'XVEIL_CONFIG_BEGIN\n$encoded\n'
        'XVEIL_CONFIG_END\n',
      );

      expect(read!.contents, body);
      expect(read.sha256, isNull);
      // And the write it produces carries no guard, rather than one that
      // compares against nothing.
      expect(
        buildWriteNodeConfigScript(NodeConfigTarget.veil, 'a = 1\n'),
        isNot(contains('XVEIL_CONFIG_CHANGED')),
      );
    });

    test('the read script asks for the digest at all', () {
      expect(
        buildReadNodeConfigScript(NodeConfigTarget.veil),
        contains('sha256sum'),
      );
    });
  });

  test('a digest that is not one is refused before anything runs', () {
    for (final bad in ['', 'latest', 'g' * 64, '0' * 63]) {
      expect(
        () => buildWriteNodeConfigScript(
          NodeConfigTarget.veil,
          'a = 1\n',
          expectedSha256: bad,
        ),
        throwsArgumentError,
        reason: bad,
      );
    }
  });
}
