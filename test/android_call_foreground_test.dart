import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/android_call_foreground.dart';

void main() {
  tearDown(AndroidCallForegroundService.debugReset);

  test('activates only when the platform accepted the start', () async {
    final requests = <bool>[];
    AndroidCallForegroundService.debugInvokeOverride = (active) async {
      requests.add(active);
      return true;
    };

    await AndroidCallForegroundService.setActive(true);
    expect(requests, [true]);
    expect(AndroidCallForegroundService.isActive, isTrue);

    // Idempotent: an already-active service is not restarted.
    await AndroidCallForegroundService.setActive(true);
    expect(requests, [true]);

    await AndroidCallForegroundService.setActive(false);
    expect(requests, [true, false]);
    expect(AndroidCallForegroundService.isActive, isFalse);

    // Idempotent on the stop side too.
    await AndroidCallForegroundService.setActive(false);
    expect(requests, [true, false]);
  });

  test(
    'a refused start (no RECORD_AUDIO) leaves the service inactive',
    () async {
      AndroidCallForegroundService.debugInvokeOverride = (_) async => false;

      await AndroidCallForegroundService.setActive(true);
      expect(AndroidCallForegroundService.isActive, isFalse);
    },
  );

  test(
    'a platform exception degrades to inactive instead of throwing',
    () async {
      AndroidCallForegroundService.debugInvokeOverride = (_) async {
        throw Exception('channel unavailable');
      };

      await AndroidCallForegroundService.setActive(true);
      expect(AndroidCallForegroundService.isActive, isFalse);
    },
  );
  test('late permission grant retries a refused foreground start', () async {
    var granted = false;
    final requests = <bool>[];
    AndroidCallForegroundService.debugInvokeOverride = (active) async {
      requests.add(active);
      return !active || granted;
    };
    await AndroidCallForegroundService.setActive(true);
    expect(AndroidCallForegroundService.isActive, isFalse);
    final permission = Completer<bool>();
    final retry = AndroidCallForegroundService.activateWhenMicrophoneGranted(
      permission.future,
      isCurrent: () => true,
    );
    granted = true;
    permission.complete(true);
    await retry;
    expect(AndroidCallForegroundService.isActive, isTrue);
    expect(requests, [true, true]);
    await AndroidCallForegroundService.setActive(false);
  });

  test(
    'a hangup during native start cannot leave the service active',
    () async {
      final entered = Completer<void>();
      final release = Completer<bool>();
      final requests = <bool>[];
      AndroidCallForegroundService.debugInvokeOverride = (active) async {
        requests.add(active);
        if (active) {
          entered.complete();
          return release.future;
        }
        return true;
      };
      final start = AndroidCallForegroundService.setActive(true);
      await entered.future;
      final stop = AndroidCallForegroundService.setActive(false);
      release.complete(true);
      await Future.wait([start, stop]);
      expect(requests, [true, false]);
      expect(AndroidCallForegroundService.isActive, isFalse);
    },
  );

  test(
    'permission arriving after hangup does not reacquire the service',
    () async {
      var current = true;
      final requests = <bool>[];
      AndroidCallForegroundService.debugInvokeOverride = (active) async {
        requests.add(active);
        return true;
      };
      final permission = Completer<bool>();
      final retry = AndroidCallForegroundService.activateWhenMicrophoneGranted(
        permission.future,
        isCurrent: () => current,
      );
      current = false;
      permission.complete(true);
      await retry;
      expect(requests, isEmpty);
      expect(AndroidCallForegroundService.isActive, isFalse);
    },
  );
  test('concurrent starts share one native request', () async {
    final entered = Completer<void>();
    final release = Completer<bool>();
    final requests = <bool>[];
    AndroidCallForegroundService.debugInvokeOverride = (active) async {
      requests.add(active);
      if (active) {
        entered.complete();
        return release.future;
      }
      return true;
    };
    final first = AndroidCallForegroundService.setActive(true);
    await entered.future;
    final second = AndroidCallForegroundService.setActive(true);
    release.complete(true);
    await Future.wait([first, second]);
    expect(requests, [true]);
    await AndroidCallForegroundService.setActive(false);
  });

  test('denied permission never starts the typed service', () async {
    final requests = <bool>[];
    AndroidCallForegroundService.debugInvokeOverride = (active) async {
      requests.add(active);
      return true;
    };
    await AndroidCallForegroundService.activateWhenMicrophoneGranted(
      Future.value(false),
      isCurrent: () => true,
    );
    expect(requests, isEmpty);
    expect(AndroidCallForegroundService.isActive, isFalse);
  });
}
