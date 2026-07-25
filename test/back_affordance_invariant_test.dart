import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:xveil/routing/back_affordance.dart';

/// Screens that ARE a root: nothing is meant to sit below them, so an AppBar
/// without a leading is correct there (and a back arrow would be a lie).
const _rootScreens = {
  'SplashScreen',
  'OnboardingScreen',
  'LockScreen',
  'IdentityPickerScreen',
  'PreparingScreen',
  'HomeShell',
};

/// Everything inside [source]'s `AppBar(...)` argument list, with nested calls
/// stripped, so a `leading:` on a ListTile in the body cannot be mistaken for
/// the AppBar's own.
String _appBarTopLevelArgs(String source, int openParenEnd) {
  var depth = 1;
  var i = openParenEnd;
  while (i < source.length && depth > 0) {
    if (source[i] == '(') {
      depth++;
    } else if (source[i] == ')') {
      depth--;
    }
    i++;
  }
  final args = source.substring(openParenEnd, i);
  final buffer = StringBuffer();
  var nested = 0;
  for (final ch in args.split('')) {
    if (ch == '(') {
      nested++;
    } else if (ch == ')') {
      nested--;
    } else if (nested == 0) {
      buffer.write(ch);
    }
  }
  return buffer.toString();
}

Map<String, File> _classIndex() {
  final index = <String, File>{};
  final classPattern = RegExp(r'class\s+(\w+)\s+extends\s+\w*Widget\b');
  for (final entity in Directory('lib').listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final source = entity.readAsStringSync();
    for (final match in classPattern.allMatches(source)) {
      index.putIfAbsent(match.group(1)!, () => entity);
    }
  }
  return index;
}

void main() {
  // THE INVARIANT. The router in lib/routing/router.dart is FLAT: no
  // ShellRoute, no nested GoRoute tree. So a screen entered by anything other
  // than a push — a bare go(), a redirect (the post-`preparing` settings
  // resume), a deep link — has an EMPTY stack beneath it, and Flutter only
  // synthesises AppBar.leading when Navigator.canPop is true. Such a screen
  // renders with its title flush to the edge and NO way out.
  //
  // Relying on every call site to remember to root the stack has failed
  // repeatedly, so the rule is structural instead: every routed screen states
  // its leading explicitly. RootedBackButton pops when it can and falls back
  // to home when it cannot, so passing it is never wrong.
  test('every routed screen declares an explicit AppBar leading', () {
    final router = File('lib/routing/router.dart').readAsStringSync();
    final classes = _classIndex();

    // Screen classes named in the route table's builders.
    final routed = <String>{};
    for (final match in RegExp(
      r'''(?:builder|pageBuilder):\s*\([^)]*\)\s*=>\s*(?:const\s+)?(\w+)\(''',
    ).allMatches(router)) {
      routed.add(match.group(1)!);
    }
    // NoTransitionPage(child: PreparingScreen()) and friends wrap the screen.
    for (final match in RegExp(
      r'''(?:NoTransitionPage|MaterialPage|CupertinoPage)\(\s*child:\s*(?:const\s+)?(\w+)\(''',
    ).allMatches(router)) {
      routed.add(match.group(1)!);
    }

    expect(
      routed.length,
      greaterThan(20),
      reason: 'route-table parse looks wrong — it found almost no screens',
    );

    final offenders = <String>[];
    for (final screen in routed) {
      if (_rootScreens.contains(screen)) continue;
      final file = classes[screen];
      if (file == null) continue; // wrappers like NoTransitionPage
      final source = file.readAsStringSync();
      for (final match in RegExp(
        r'appBar:\s*(?:const\s+)?AppBar\(',
      ).allMatches(source)) {
        final args = _appBarTopLevelArgs(source, match.end);
        final line =
            '\n'.allMatches(source.substring(0, match.start)).length + 1;
        if (!args.contains('leading:')) {
          offenders.add('$screen (${file.path}:$line) — no leading');
          continue;
        }
        // A CONDITIONAL leading that can evaluate to null is the same dead end
        // wearing a disguise: `leading: x ? null : BackButton(...)` reads as
        // covered but falls back to the automatic leading, which is absent
        // exactly when the stack is empty. Storage's cloud root shipped this.
        final leading = args.substring(args.indexOf('leading:'));
        final end = leading.indexOf(RegExp(r',\s*$|,\n'));
        final expr = end == -1 ? leading : leading.substring(0, end);
        if (RegExp(r'[?:]\s*null\b').hasMatch(expr)) {
          offenders.add('$screen (${file.path}:$line) — leading can be null');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'These routed screens have an AppBar with no explicit leading, so '
          'they become dead ends when entered with an empty stack. Add '
          '`leading: const RootedBackButton()`:\n  ${offenders.join('\n  ')}',
    );
  });

  testWidgets('RootedBackButton pops when there is a stack below', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/home',
      routes: [
        GoRoute(path: '/home', builder: (_, _) => const Text('home')),
        GoRoute(
          path: '/deep',
          builder: (_, _) => Scaffold(
            appBar: AppBar(
              leading: const RootedBackButton(),
              title: const Text('deep'),
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    router.push('/deep');
    await tester.pumpAndSettle();
    expect(find.text('deep'), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('RootedBackButton falls back to home with an empty stack', (
    tester,
  ) async {
    final router = GoRouter(
      // Straight onto the deep screen — exactly what a redirect or deep link
      // produces, and where the automatic leading would not appear at all.
      initialLocation: '/deep',
      routes: [
        GoRoute(path: '/home', builder: (_, _) => const Text('home')),
        GoRoute(
          path: '/deep',
          builder: (_, _) => Scaffold(
            appBar: AppBar(
              leading: const RootedBackButton(),
              title: const Text('deep'),
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    expect(find.text('deep'), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
  });
}
