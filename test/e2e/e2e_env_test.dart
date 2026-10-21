import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'e2e_env.dart';

void main() {
  test('a pending probe cannot outlive the overall deadline', () async {
    final watch = Stopwatch()..start();
    await expectLater(
      waitUntil(
        () => Completer<bool>().future,
        what: 'unresponsive storage',
        timeout: const Duration(milliseconds: 100),
      ),
      throwsA(isA<E2eTimeout>()),
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
  });

  test('a stuck diagnostic cannot prevent timeout', () async {
    final watch = Stopwatch()..start();
    await expectLater(
      waitUntil(
        () => false,
        what: 'unresponsive diagnostic',
        describe: () => Completer<String>().future,
        progressEvery: Duration.zero,
        timeout: const Duration(milliseconds: 100),
      ),
      throwsA(isA<E2eTimeout>()),
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
  });
}
