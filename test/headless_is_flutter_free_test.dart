import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The headless daemon is a Flutter-free AOT binary. ONE
/// `package:flutter/...` import anywhere it reaches stops it building at all —
/// and the failure is a wall of errors inside Flutter's own sources, which
/// says nothing about which of our files caused it. That is how it broke
/// unnoticed: `lib/data/veil_stack.dart` reached for `kDebugMode`, and the
/// daemon stopped compiling while every app build stayed green.
///
/// ## It then broke unnoticed a SECOND time, through this test
///
/// The first version of this walk stopped at every pub package
/// (`if (target.startsWith('package:')) return null;`), so it could only ever
/// see a DIRECT `package:flutter` import from a first-party file. Flutter
/// reached THROUGH a package was invisible — and that is precisely what
/// happened next: `lib/data/node/bundled_seeds.dart` imported
/// `package:shared_preferences`, which imports `package:flutter`, which imports
/// `dart:ui`. `dart build cli` failed on every run; this test reported
/// "nothing the headless daemon imports reaches into Flutter" and exited 0 for
/// as long as it took someone to run the daemon build by hand (709f3b9).
///
/// A gate that cannot see the failure it names is worse than no gate, because
/// it is trusted. So the walk now crosses package boundaries: package URIs are
/// resolved through `.dart_tool/package_config.json` exactly as the compiler
/// resolves them, and the walk keeps going inside the package.
///
/// ## Why a walk and not a build
///
/// `scripts/build-headless.sh` is the ground truth and it would be the perfect
/// assertion — but it is a native release build plus an AOT link, it needs a
/// working `dart build cli` and a cargo toolchain, and no unit-test suite
/// should own that. This walk needs nothing but the files, runs in the time of
/// a couple of hundred small reads, and names the offending CHAIN, which the
/// compiler's own error only half does. The build is still what proves it: run
/// `scripts/build-headless.sh` when this test changes.
void main() {
  test('nothing the headless daemon imports reaches into Flutter', () {
    final root = Directory.current.path;
    final packages = _packageLibDirs(root);

    // The real entry point, not just the pieces it happens to use: a file
    // reached only from `bin/xveil.dart` (the secret-file reader, for one)
    // breaks the AOT build exactly the same way and was outside this walk.
    final queue = <String>[
      '$root/bin/xveil.dart',
      '$root/lib/headless/headless_runtime.dart',
      '$root/lib/headless/headless_config.dart',
    ];
    final resolved = <String>{};
    // file -> the file that imported it, so a violation can be reported as a
    // chain rather than as a lone name.
    final importedBy = <String, String>{};
    final offenders = <String>[];
    // Package URIs that could not be resolved at all. Not ignored: a URI this
    // walk cannot follow is a hole of exactly the shape that hid the last two
    // failures, so it is reported rather than skipped.
    final unresolved = <String>[];
    // Which packages the walk actually entered. The proof that it still
    // crosses package boundaries — see the structural assertion below.
    final visitedPackages = <String>{};

    String show(String path) =>
        path.startsWith('$root/') ? path.substring(root.length + 1) : path;

    String chainFrom(String file) {
      final chain = <String>[show(file)];
      var walk = file;
      while (importedBy.containsKey(walk)) {
        walk = importedBy[walk]!;
        chain.add(show(walk));
      }
      return chain.join(' <- ');
    }

    void reject(String target, String from) =>
        offenders.add('$target in ${show(from)} (via ${chainFrom(from)})');

    while (queue.isNotEmpty) {
      final current = queue.removeLast();
      if (!resolved.add(current)) continue;
      final file = File(current);
      if (!file.existsSync()) continue;
      for (final target in _targets(file.readAsStringSync())) {
        // `dart:ui` is the error the daemon build actually dies on. Reached
        // from Flutter's own sources here, but a first-party file could import
        // it directly and would break the build the same way.
        if (target == 'dart:ui' || target.startsWith('dart:ui_')) {
          reject(target, current);
          continue;
        }
        if (target.startsWith('dart:')) continue;
        if (target.startsWith('package:flutter/') ||
            target == 'package:flutter' ||
            target.startsWith('package:flutter_')) {
          reject(target, current);
          continue;
        }
        String next;
        if (target.startsWith('package:')) {
          final slash = target.indexOf('/');
          if (slash < 0) {
            unresolved.add('$target in ${show(current)}');
            continue;
          }
          final name = target.substring('package:'.length, slash);
          final lib = packages[name];
          if (lib == null) {
            unresolved.add('$target in ${show(current)}');
            continue;
          }
          visitedPackages.add(name);
          next = '$lib/${target.substring(slash + 1)}';
        } else {
          next = Uri.file(
            '${File(current).parent.path}/$target',
          ).normalizePath().toFilePath();
        }
        if (!File(next).existsSync()) {
          // A relative URI that does not exist is a typo the analyzer already
          // catches; a package one that does not is this walk resolving the
          // package layout wrongly, which is worth hearing about.
          if (target.startsWith('package:')) {
            unresolved.add('$target -> ${show(next)} (missing)');
          }
          continue;
        }
        if (resolved.contains(next)) continue;
        importedBy[next] = current;
        queue.add(next);
      }
    }

    expect(
      resolved.length,
      greaterThan(20),
      reason: 'the walk must actually have followed the graph',
    );
    expect(
      visitedPackages,
      isNotEmpty,
      reason:
          'the walk must follow package: imports INTO the package. It used to '
          'stop at every one of them, which is how a Flutter dependency '
          'reached through package:shared_preferences broke the daemon build '
          'with this test still green',
    );
    expect(
      unresolved,
      isEmpty,
      reason:
          'these imports could not be followed, so nothing behind them was '
          'checked:\n  ${unresolved.join("\n  ")}',
    );
    expect(
      offenders,
      isEmpty,
      reason:
          'these files are reachable from the headless entry points and reach '
          'Flutter, which breaks `dart build cli`:\n  ${offenders.join("\n  ")}',
    );
  });
}

/// Every import/export/part URI in one file, as the AOT compiler would take
/// them.
///
/// Conditional imports are followed on the DEFAULT branch and on any
/// `dart.library.io` branch — those are the two an AOT `dart build cli` can
/// take. Deliberately not the `dart.library.js_interop`/`html` ones: those
/// exist to reach web-only code that imports `dart:ui_web`, and following them
/// would fail this test for imports the daemon never compiles.
Iterable<String> _targets(String source) sync* {
  final directive = RegExp(
    '''^\\s*(?:import|export|part)\\s+(?!of[\\s'"])['"]([^'"]+)['"]([^;]*);''',
    multiLine: true,
  );
  final ioBranch = RegExp(
    '''if\\s*\\(\\s*dart\\.library\\.io\\s*\\)\\s*['"]([^'"]+)['"]''',
  );
  for (final match in directive.allMatches(source)) {
    yield match.group(1)!;
    for (final branch in ioBranch.allMatches(match.group(2) ?? '')) {
      yield branch.group(1)!;
    }
  }
}

/// package name -> absolute lib/ directory, straight out of the file the
/// compiler itself resolves with.
///
/// Its absence is a hard failure, not a skip: without it every `package:` URI
/// would silently resolve to nothing and this test would go green having
/// checked only the first-party files — which is the exact failure it exists
/// to stop happening a third time.
Map<String, String> _packageLibDirs(String root) {
  final file = File('$root/.dart_tool/package_config.json');
  expect(
    file.existsSync(),
    isTrue,
    reason:
        'no .dart_tool/package_config.json — run `flutter pub get`. Without '
        'it package: imports cannot be resolved and this gate can only see '
        'first-party files, which is how it missed the last failure',
  );
  final decoded = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final out = <String, String>{};
  for (final entry in (decoded['packages'] as List).cast<Map<String, dynamic>>()) {
    final name = entry['name'] as String;
    // rootUri is relative to .dart_tool/ when relative at all, and is a
    // DIRECTORY — without the trailing slash `resolve('lib/')` would replace
    // the package's own directory instead of descending into it, which is how
    // this resolved every hosted package to `.pub-cache/hosted/pub.dev/lib`.
    final raw = entry['rootUri'] as String;
    final rootUri = Uri.parse(raw.endsWith('/') ? raw : '$raw/');
    final base = rootUri.hasScheme
        ? rootUri
        : Uri.directory('$root/.dart_tool/').resolveUri(rootUri);
    final packageUri = '${entry['packageUri'] ?? 'lib/'}';
    final lib = base.resolve(
      packageUri.endsWith('/') ? packageUri : '$packageUri/',
    );
    out[name] = Directory.fromUri(lib).path.replaceAll(RegExp(r'/$'), '');
  }
  return out;
}
