import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/call_media_route_operations.dart';

void main() {
  test(
    'route switch waits for native teardown without opening twice',
    () async {
      final operations = CallMediaRouteOperations();
      final cameraStopped = Completer<void>();
      final events = <String>[];
      final repair = operations.runForCall('old', () => 'old', () async {
        events.add('close');
        await cameraStopped.future;
        events.add('restore direct');
        return true;
      });
      final relay = operations.runForCall('old', () => 'old', () async {
        events.add('open relay');
        return true;
      });
      await pumpEventQueue();
      expect(events, ['close']);
      expect(operations.busy, isTrue);
      cameraStopped.complete();
      expect(await repair, isTrue);
      expect(await relay, isTrue);
      expect(events, ['close', 'restore direct', 'open relay']);
      expect(operations.busy, isFalse);
    },
  );

  for (final replacement in <String?>[null, 'new']) {
    test('queued route does not revive retired call ($replacement)', () async {
      final operations = CallMediaRouteOperations();
      final cameraStopped = Completer<void>();
      String? activeCall = 'old';
      var opens = 0;
      final teardown = operations.run(() => cameraStopped.future);
      final queued = operations.runForCall('old', () => activeCall, () async {
        opens++;
        return true;
      });
      activeCall = replacement;
      cameraStopped.complete();
      await teardown;
      expect(await queued, isFalse);
      expect(opens, 0);
    });
  }

  test('failed teardown releases multiple waiters one at a time', () async {
    final operations = CallMediaRouteOperations();
    final first = Completer<void>();
    final second = Completer<void>();
    final events = <int>[];
    final failed = operations.run(() async {
      await first.future;
      throw StateError('native teardown failed');
    });
    final failure = expectLater(failed, throwsStateError);
    final next = operations.run(() async {
      events.add(2);
      await second.future;
    });
    final last = operations.run(() async => events.add(3));
    first.complete();
    await failure;
    await pumpEventQueue();
    expect(events, [2]);
    second.complete();
    await next;
    await last;
    expect(events, [2, 3]);
    expect(operations.busy, isFalse);
  });
}
