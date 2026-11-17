import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

Future<void> killErasureWriter(
  String fixture,
  String phase,
  void Function() beforeKill, {
  String script = 'test/native/managed_root_erasure_writer.dart',
  List<String> writerArguments = const [],
}) async {
  final child = await Process.start(
    'python3',
    [
      '-c',
      'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])',
      'dart',
      'run',
      script,
      fixture,
      phase,
      ...writerArguments,
    ],
    environment: {
      'TMPDIR': Platform.isMacOS ? '/private/tmp/' : Directory.systemTemp.path,
    },
  );
  final output = StringBuffer();
  final stdoutDone = child.stdout.transform(utf8.decoder).forEach(output.write);
  final stderrDone = child.stderr.transform(utf8.decoder).forEach(output.write);
  int? status;
  final exit = child.exitCode.then((value) => status = value);
  Future<void> killGroup() async {
    final killed = await Process.run('python3', [
      '-c',
      'import os,signal,sys; os.killpg(int(sys.argv[1]),signal.SIGKILL)',
      '${child.pid}',
    ]);
    expect(killed.exitCode, 0);
  }

  try {
    final marker = File('$fixture/ready');
    final watch = Stopwatch()..start();
    while (!marker.existsSync()) {
      if (status != null) fail('Writer exited before $phase: $output');
      if (watch.elapsed > const Duration(seconds: 45)) {
        fail('Writer did not reach $phase: $output');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final ready = marker.readAsStringSync().split(':');
    expect(ready.length, 2);
    expect(ready.last, phase);
    final group = await Process.run('python3', [
      '-c',
      'import os,sys; print(os.getpgid(int(sys.argv[1])))',
      ready.first,
    ]);
    expect(group.exitCode, 0);
    expect(group.stdout.toString().trim(), '${child.pid}');
    expect(status, isNull);
    beforeKill();
    await killGroup();
    await exit;
    expect(status, -9);
  } finally {
    if (status == null) {
      await killGroup();
      await exit;
    }
    await stdoutDone;
    await stderrDone;
  }
}
