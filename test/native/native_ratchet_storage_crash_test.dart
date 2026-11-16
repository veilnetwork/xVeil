@Timeout(Duration(minutes: 7))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'native_ratchet_storage_crash_writer.dart' show messagesPerDirection;

class _Writer {
  _Writer(this.process) {
    stdoutDone = process.stdout.transform(utf8.decoder).forEach(output.write);
    stderrDone = process.stderr.transform(utf8.decoder).forEach(output.write);
    finished = process.exitCode.then((code) => status = code);
  }
  final Process process;
  final output = StringBuffer();
  late final Future<void> stdoutDone, stderrDone;
  late final Future<int> finished;
  int? status;

  static Future<_Writer> start(
    Directory root,
    String mode, {
    bool cold = false,
  }) async => _Writer(
    await Process.start(
      'python3',
      [
        '-c',
        'import os,sys; os.setsid(); os.execvp(sys.argv[1],sys.argv[1:])',
        'flutter',
        'test',
        '--no-pub',
        '--concurrency=1',
        '--reporter=expanded',
        'test/native/native_ratchet_storage_crash_writer.dart',
      ],
      environment: {
        'TMPDIR': '/private/tmp/',
        'XVEIL_NATIVE_CRASH_ROOT': root.path,
        'XVEIL_NATIVE_CRASH_MODE': mode,
        'XVEIL_NATIVE_CRASH_COLD': cold ? '1' : '0',
      },
    ),
  );

  Future<Map> checkpoint(File marker) async {
    final watch = Stopwatch()..start();
    while (!marker.existsSync()) {
      if (status != null || watch.elapsed > const Duration(minutes: 3)) {
        fail('Native writer missed checkpoint (exit=$status): $output');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(status, isNull);
    final proof = jsonDecode(marker.readAsStringSync()) as Map;
    final group = await Process.run('python3', [
      '-c',
      'import os,sys; print(os.getpgid(int(sys.argv[1])))',
      '${proof['pid']}',
    ]);
    expect(group.exitCode, 0);
    expect(group.stdout.toString().trim(), '${process.pid}');
    return proof;
  }

  Future<void> join() async {
    await finished;
    await stdoutDone;
    await stderrDone;
    final watch = Stopwatch()..start();
    while (true) {
      final gone = await Process.run('python3', [
        '-c',
        'import os,sys\n'
            'try: os.killpg(int(sys.argv[1]),0)\n'
            'except ProcessLookupError: sys.exit(0)\n'
            'sys.exit(1)',
        '${process.pid}',
      ]);
      if (gone.exitCode == 0) return;
      expect(gone.exitCode, 1);
      if (watch.elapsed > const Duration(seconds: 15)) {
        fail('Native writer process group remains live');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<void> kill() async {
    if (status == null) {
      final result = await Process.run('python3', [
        '-c',
        'import os,signal,sys; os.killpg(int(sys.argv[1]),signal.SIGKILL)',
        '${process.pid}',
      ]);
      expect(result.exitCode, 0);
    }
    await join();
  }
}

void main() {
  final enabled = Platform.environment['XVEIL_NATIVE_RATCHET_CRASH'] == '1';
  for (final mode in ['hidden', 'encrypted', 'unencrypted']) {
    test(
      'native peer ACK and ratchet survive real process death ($mode)',
      () async {
        final root = Directory.systemTemp.createTempSync('xvrc-');
        _Writer? before, after;
        try {
          before = await _Writer.start(root, mode);
          final proof = await before.checkpoint(File('${root.path}/ready'));
          expect(proof['mode'], mode);
          expect(proof['members'], hasLength(2));
          for (final member in proof['members'] as List) {
            expect(member['positions'], isNotEmpty);
            expect(member['messages'], hasLength(2 * messagesPerDirection));
          }
          await before.kill();
          expect(before.status, -9);

        // A fresh native runtime imports the actual stored roots before
        // traffic, burns durable reservations and resumes bidirectional traffic.
          after = await _Writer.start(root, mode, cold: true);
          await after.join().timeout(const Duration(minutes: 3));
          expect(after.status, 0, reason: after.output.toString());
          final continued =
              jsonDecode(File('${root.path}/continued').readAsStringSync())
                  as Map;
          expect(continued['members'], hasLength(2));
          for (final member in continued['members'] as List) {
            expect(member['messages'], hasLength(4 * messagesPerDirection));
          }
        } finally {
          await after?.kill();
          await before?.kill();
          root.deleteSync(recursive: true);
        }
      },
      skip: enabled && (Platform.isMacOS || Platform.isLinux)
          ? false
          : 'set XVEIL_NATIVE_RATCHET_CRASH=1 and both native libraries on POSIX',
    );
  }
}
