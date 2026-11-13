import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/storage_protection.dart';

Future<String> probeManagedIdentityLease(
  String path, {
  StorageProtection protection = StorageProtection.encrypted,
}) async {
  final child = await Process.start(
    'python3',
    [
      '-c',
      'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])',
      'dart',
      'run',
      'test/native/managed_identity_lease_probe.dart',
      path,
      protection.name,
    ],
    environment: {'TMPDIR': '/private/tmp/'},
  );
  final stdoutDone = child.stdout.transform(utf8.decoder).join();
  final stderrDone = child.stderr.transform(utf8.decoder).join();
  int? status;
  final finished = child.exitCode.then((value) => status = value);
  try {
    await finished.timeout(const Duration(seconds: 45));
    final output = await stdoutDone;
    final errors = await stderrDone;
    expect(status, 0, reason: errors);
    // Hook announcements can share the result's line. Require the explicit
    // protocol marker exactly once instead of treating an arbitrary suffix as
    // proof of contention or success.
    final results = RegExp(
      r'XVEIL_LEASE_RESULT:(busy|opened)(?:\r?\n|$)',
    ).allMatches(output).toList();
    expect(results.length, 1, reason: output);
    return results.single.group(1)!;
  } finally {
    if (status == null) {
      await Process.run('python3', [
        '-c',
        'import os,signal,sys; os.killpg(int(sys.argv[1]),signal.SIGKILL)',
        '${child.pid}',
      ]);
      await finished;
    }
    await stdoutDone;
    await stderrDone;
  }
}
