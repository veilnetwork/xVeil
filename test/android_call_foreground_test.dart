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

  test('a refused start (no RECORD_AUDIO) leaves the service inactive', () async {
    AndroidCallForegroundService.debugInvokeOverride = (_) async => false;

    await AndroidCallForegroundService.setActive(true);
    expect(AndroidCallForegroundService.isActive, isFalse);
  });

  test('a platform exception degrades to inactive instead of throwing', () async {
    AndroidCallForegroundService.debugInvokeOverride = (_) async {
      throw Exception('channel unavailable');
    };

    await AndroidCallForegroundService.setActive(true);
    expect(AndroidCallForegroundService.isActive, isFalse);
  });
}
