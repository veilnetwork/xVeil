import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/log.dart';

void main() {
  /// Asking whether a directory is writable must not destroy anything in it.
  ///
  /// The probe was a fixed `.xveil-write-probe`, written with
  /// `writeAsStringSync('')` — which TRUNCATES an existing name — and then
  /// deleted. So a file somebody else had at that name was emptied and
  /// removed by a check that creates nothing and reports a path (report27
  /// X23).
  test('a writability check leaves a file at its probe name alone', () async {
    final dir = await Directory.systemTemp.createTemp('xveil-probe-');
    addTearDown(() async {
      devLogDirectoryOverride = null;
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    // Somebody else's file, at exactly the name the probe used.
    final victim = File('${dir.path}${Platform.pathSeparator}.xveil-write-probe');
    await victim.writeAsString('not the probe\'s to touch');

    devLogDirectoryOverride = dir.path;
    final path = debugNodeLogPath();

    expect(
      path,
      isNotNull,
      reason: 'premise: the directory is writable, so the probe must succeed',
    );
    expect(
      victim.existsSync(),
      isTrue,
      reason:
          'the writability check deleted a file it did not create — it was '
          'truncated first, so its contents are gone either way',
    );
    expect(
      await victim.readAsString(),
      'not the probe\'s to touch',
      reason: 'the file survived but its contents did not',
    );

    // And nothing of the probe's own is left behind.
    final leftovers = dir
        .listSync()
        .map((e) => e.path.split(Platform.pathSeparator).last)
        .where((n) => n.startsWith('.xveil-write-probe.'))
        .toList();
    expect(leftovers, isEmpty, reason: 'the probe left $leftovers behind');
  });
}
