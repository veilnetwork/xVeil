import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

class ProfileLeaseProcess {
  ProfileLeaseProcess._(
    this.child,
    this.output,
    this.stderrDone,
    this.finished,
  );
  final Process child;
  final StreamIterator<String> output;
  final Future<void> stderrDone;
  final Future<int> finished;
  int serial = 0;
  bool terminal = false;
  static Future<ProfileLeaseProcess> start(String path) async {
    final child = await Process.start(
      'python3',
      [
        '-c',
        'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])',
        'dart',
        'run',
        'test/native/managed_profile_lease_probe.dart',
        path,
      ],
      environment: {
        'TMPDIR': Platform.isMacOS
            ? '/private/tmp/'
            : Directory.systemTemp.path,
      },
    );
    final lines = child.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .map((s) {
          final at = s.indexOf('XVEIL_PROFILE_');
          return at < 0 ? '' : s.substring(at);
        })
        .where((s) => s.isNotEmpty);
    final result = ProfileLeaseProcess._(
      child,
      StreamIterator(lines),
      child.stderr.drain<void>(),
      child.exitCode,
    );
    try {
      expect(
        await result.output.moveNext().timeout(const Duration(seconds: 45)),
        isTrue,
      );
      expect(result.output.current, 'XVEIL_PROFILE_READY');
      return result;
    } catch (_) {
      await result.dispose();
      rethrow;
    }
  }

  Future<String> ask(String command) async {
    final id = ++serial;
    child.stdin.writeln('$id $command');
    await child.stdin.flush();
    expect(
      await output.moveNext().timeout(const Duration(seconds: 30)),
      isTrue,
    );
    final prefix = 'XVEIL_PROFILE_LEASE:$id:';
    expect(output.current, startsWith(prefix));
    return output.current.substring(prefix.length);
  }

  Future<void> kill() async {
    final killed = await Process.run('python3', [
      '-c',
      'import os,signal,sys; os.killpg(int(sys.argv[1]),signal.SIGKILL)',
      '${child.pid}',
    ]);
    expect(killed.exitCode, 0);
    expect(await finished.timeout(const Duration(seconds: 30)), -9);
    terminal = true;
  }

  Future<void> dispose() async {
    try {
      if (!terminal) {
        try {
          expect(await ask('exit'), 'closed');
          expect(await finished.timeout(const Duration(seconds: 30)), 0);
          terminal = true;
        } catch (_) {
          await Process.run('python3', [
            '-c',
            'import os,signal,sys\ntry: os.killpg(int(sys.argv[1]),signal.SIGKILL)\nexcept ProcessLookupError: pass',
            '${child.pid}',
          ]);
          await finished;
          terminal = true;
          rethrow;
        }
      }
    } finally {
      await output.cancel();
      await stderrDone;
      await child.stdin.close();
    }
  }
}
