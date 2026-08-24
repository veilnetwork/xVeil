import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../bin/xveil.dart';

/// The daemon waits on a completer that only a watched signal completes, and
/// the ordered close — node down, encrypted container's exclusive lock
/// released — runs in that future's `finally`. A blanket
/// `if (!Platform.isWindows)` skipped BOTH signals there, so on Windows the
/// future never completed: the stop hung, and the only way out was a forced
/// kill, which is the ordered close being skipped.
void main() {
  test('SIGINT is watched on every platform, Windows included', () {
    // Dart's own contract: of the watchable signals only SIGTERM, SIGUSR1,
    // SIGUSR2 and SIGWINCH are marked "Not available on Windows". SIGINT is
    // what Ctrl-C and a console stop deliver there.
    expect(
      stopSignals(isWindows: true),
      contains(ProcessSignal.sigint),
      reason: 'without it nothing can ask a Windows daemon to stop',
    );
    expect(stopSignals(isWindows: false), contains(ProcessSignal.sigint));
  });

  test('SIGTERM is asked for only where it exists', () {
    expect(
      stopSignals(isWindows: true),
      isNot(contains(ProcessSignal.sigterm)),
      reason: 'watching it on Windows throws, and would take the wiring down '
          'with it',
    );
    expect(stopSignals(isWindows: false), contains(ProcessSignal.sigterm));
  });

  test('no platform is left with nothing to listen for', () {
    for (final isWindows in [true, false]) {
      expect(stopSignals(isWindows: isWindows), isNotEmpty);
    }
  });
}
