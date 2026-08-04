@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/posix_file_facts.dart';

/// The reproduction from audit C-01, run for real.
///
/// The guard used to read owner and mode by running `stat` — a BARE command
/// name. Anything the user can drop into a PATH component answered it, and the
/// answer decided whether xVeil would hand itself to `pkexec`. A wrapper that
/// claimed "root-owned, 0755" for a directory the user can rewrite turned
/// same-user code execution into root; one that claimed the opposite could
/// silently disable the VPN.
///
/// Both directions are checked, deliberately. A "fix" that refuses everything
/// would pass a one-sided test and ship a feature that never works.
///
/// It runs in a CHILD process because Dart snapshots the environment at
/// startup: `setenv` from FFI does change this process's `environ`, but
/// children still get the snapshot, so an in-process hijack would be a test
/// that proves nothing. The child prints what the hijacked PATH answers as a
/// CONTROL — if that sentinel does not come back, the hijack was not live and
/// the rest of the assertions are meaningless, so the test says so instead of
/// passing quietly.
void main() {
  final dart = _dartBinary();
  final packageConfig = File(
    '${Directory.current.path}/.dart_tool/package_config.json',
  );

  group('a tool planted in PATH cannot move the verdict', () {
    late Directory workspace;

    setUp(() {
      workspace = Directory.systemTemp.createTempSync('xveil-path-hijack-');
    });

    tearDown(() {
      if (workspace.existsSync()) workspace.deleteSync(recursive: true);
    });

    /// Runs the guard against [executable] in a child whose PATH starts with a
    /// directory holding a `stat` that answers [uid]/[mode] for everything.
    Future<Map<String, Object?>> inspectUnderHijackedPath(
      String executable, {
      required int uid,
      required String mode,
    }) async {
      final hijack = Directory('${workspace.path}/bin-$uid-$mode')
        ..createSync(recursive: true);
      final fakeStat = File('${hijack.path}/stat');
      fakeStat.writeAsStringSync('''
#!/bin/sh
# The control call: proves this script — and not /usr/bin/stat — is what the
# child's PATH resolves.
if [ "\$1" = "--xveil-control" ]; then echo HIJACKED; exit 0; fi
for a in "\$@"; do
  case "\$a" in -*) continue ;; %*) continue ;; esac
  printf '%s\\001$uid\\001$mode\\n' "\$a"
done
exit 0
''');
      // Through libc, not `Process.run('chmod', …)`: this test would be a poor
      // place to depend on a PATH-resolved tool.
      expect(posixChmod(fakeStat.path, 0x1ED), 0, reason: 'chmod 0755 the fake');

      final script = File('${workspace.path}/inspect_${uid}_$mode.dart');
      script.writeAsStringSync(r'''
import 'dart:convert';
import 'dart:io';

import 'package:xveil/data/vpn/privileged_launch_guard.dart';

Future<void> main(List<String> args) async {
  final verdict = await PrivilegedLaunchGuard(
    probe: const PosixPathSecurityProbe(),
    windows: false,
  ).inspect(args.first);
  String control;
  try {
    final answer = await Process.run('stat', <String>['--xveil-control']);
    control = (answer.stdout as String).trim();
  } on ProcessException catch (error) {
    control = 'no stat at all: ${error.message}';
  }
  stdout.writeln('XVEIL-RESULT ${jsonEncode(<String, Object?>{
    'allowed': verdict.isAllowed,
    'offending': verdict.offendingPath,
    'reason': verdict.reason,
    'control': control,
  })}');
}
''');

      final run = await Process.run(
        dart!,
        <String>[
          'run',
          '--packages=${packageConfig.path}',
          script.path,
          executable,
        ],
        environment: <String, String>{
          'PATH': '${hijack.path}:${Platform.environment['PATH'] ?? '/usr/bin'}',
        },
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      final line = const LineSplitter()
          .convert(run.stdout as String)
          .where((l) => l.startsWith('XVEIL-RESULT '))
          .toList();
      expect(
        line,
        hasLength(1),
        reason:
            'the child did not report a verdict.\n'
            'stdout:\n${run.stdout}\nstderr:\n${run.stderr}',
      );
      final decoded =
          jsonDecode(line.single.substring('XVEIL-RESULT '.length)) as Map;
      // THE CONTROL. Without this the test could pass because the fake was
      // never reachable, which would prove nothing about the guard.
      expect(
        decoded['control'],
        'HIJACKED',
        reason: 'the planted stat was not what the child resolved',
      );
      return decoded.cast<String, Object?>();
    }

    test('a stat that swears a user-writable install is root-owned is '
        'ignored', () async {
      final unpacked = Directory('${workspace.path}/xVeil')
        ..createSync(recursive: true);
      final binary = File('${unpacked.path}/xveil')..writeAsStringSync('#!/bin/sh\n');
      expect(posixChmod(binary.path, 0x1ED), 0);
      // The unpacked-tarball shape: a directory the ordinary user owns and can
      // rewrite, holding the binary that would be re-exec'd by pkexec.
      expect(posixChmod(unpacked.path, 0x1FF), 0); // 0777

      final result = await inspectUnderHijackedPath(
        binary.path,
        uid: 0,
        mode: '755',
      );
      expect(
        result['allowed'],
        isFalse,
        reason:
            'the planted stat claimed root/0755 for every path; the guard must '
            'have gone to libc instead',
      );
      // The canonical chain is walked first, so on macOS the offender is named
      // through /private/var rather than the /var symlink it was created under.
      expect(result['offending'], endsWith('/xVeil/xveil'));
    });

    test('a stat that swears a protected install is world-writable is '
        'ignored', () async {
      final protected = _protectedSystemExecutable();
      if (protected == null) {
        markTestSkipped('no root-owned, non-writable system binary to point at');
        return;
      }
      final result = await inspectUnderHijackedPath(
        protected,
        uid: 1000,
        mode: '777',
      );
      // The other direction, and the one a "fix" that simply refuses
      // everything would fail: the planted stat says this path is owned by an
      // ordinary user and world-writable, and the guard still allows it.
      expect(
        result['allowed'],
        isTrue,
        reason:
            'refused $protected: ${result['offending']} — ${result['reason']}',
      );
    });
  }, skip: dart == null || Platform.isWindows
      ? 'needs a POSIX host and the Dart SDK from FLUTTER_ROOT'
      : null);
}

String? _dartBinary() {
  final root = Platform.environment['FLUTTER_ROOT'];
  for (final candidate in <String>[
    if (root != null) '$root/bin/cache/dart-sdk/bin/dart',
    if (root != null) '$root/bin/dart',
  ]) {
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}

/// A real system binary whose whole chain is root-owned and not writable by
/// anybody else — the "protected installation" half of the check.
String? _protectedSystemExecutable() {
  for (final candidate in const ['/bin/ls', '/usr/bin/ls', '/bin/sh']) {
    var path = candidate;
    var safe = true;
    while (safe) {
      final facts = posixLstat(path);
      if (facts == null || facts.uid != 0 || facts.groupOrOtherWritable) {
        safe = false;
        break;
      }
      if (path == '/') break;
      final cut = path.lastIndexOf('/');
      path = cut <= 0 ? '/' : path.substring(0, cut);
    }
    if (safe) return candidate;
  }
  return null;
}
