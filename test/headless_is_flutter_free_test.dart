import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The headless daemon is a Flutter-free AOT binary. ONE
/// `package:flutter/...` import anywhere it reaches stops it building at all —
/// and the failure is a wall of errors inside Flutter's own sources, which
/// says nothing about which of our files caused it. That is how it broke
/// unnoticed: `lib/data/veil_stack.dart` reached for `kDebugMode`, and the
/// daemon stopped compiling while every app build stayed green.
///
/// This walks the real import graph from the daemon's entry points and names
/// the offending file, so the next person learns it in a second instead of an
/// afternoon.
void main() {
  test('nothing the headless daemon imports reaches into Flutter', () {
    final resolved = <String>{};
    final queue = <String>[
      'lib/headless/headless_runtime.dart',
      'lib/headless/headless_config.dart',
    ];
    // file -> the file that imported it, so a violation can be reported as a
    // chain rather than as a lone name.
    final importedBy = <String, String>{};
    final offenders = <String>[];

    String? resolve(String from, String target) {
      if (target.startsWith('dart:')) return null;
      if (target.startsWith('package:flutter')) return target;
      if (target.startsWith('package:xveil/')) {
        return 'lib/${target.substring('package:xveil/'.length)}';
      }
      if (target.startsWith('package:')) return null;
      final dir = File(from).parent.path;
      return File('$dir/$target').uri.normalizePath().toFilePath();
    }

    while (queue.isNotEmpty) {
      final current = queue.removeLast();
      if (!resolved.add(current)) continue;
      final file = File(current);
      if (!file.existsSync()) continue;
      for (final match in RegExp(
        r"^\s*import\s+'([^']+)'",
        multiLine: true,
      ).allMatches(file.readAsStringSync())) {
        final target = resolve(current, match.group(1)!);
        if (target == null) continue;
        if (target.startsWith('package:flutter')) {
          final chain = <String>[current];
          var walk = current;
          while (importedBy.containsKey(walk)) {
            walk = importedBy[walk]!;
            chain.add(walk);
          }
          offenders.add('${match.group(1)} in $current (via ${chain.join(" <- ")})');
          continue;
        }
        final relative = target.startsWith('lib/')
            ? target
            : target.replaceFirst(RegExp(r'^.*/xVeil/'), '');
        if (relative.startsWith('lib/') && !resolved.contains(relative)) {
          importedBy[relative] = current;
          queue.add(relative);
        }
      }
    }

    expect(
      resolved.length,
      greaterThan(20),
      reason: 'the walk must actually have followed the graph',
    );
    expect(
      offenders,
      isEmpty,
      reason:
          'these files are reachable from the headless entry points and import '
          'Flutter, which breaks `dart build cli`:\n  ${offenders.join("\n  ")}',
    );
  });
}
