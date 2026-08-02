import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/cleanup_legs.dart';

/// Teardown written as a straight `await` chain fails badly: one throwing step
/// abandons every step after it. In the headless daemon that left the node
/// holding its ports and the container holding its exclusive lock, with the
/// `_closed` flag already set so a retry returned immediately (audit XV-16).
void main() {
  test('a throwing leg does not cancel the ones after it', () async {
    final ran = <String>[];

    final failure = await runCleanupLegs('t', [
      ('first', () async => ran.add('first')),
      ('boom', () async => throw StateError('stop failed')),
      ('after', () async => ran.add('after')),
      // The one that matters most is last in the real chain, so it is the one
      // a chained await would always lose.
      ('storage', () async => ran.add('storage')),
    ]);

    expect(
      ran,
      ['first', 'after', 'storage'],
      reason: 'the lock-releasing leg must run even when an earlier one throws',
    );
    expect(failure, isNotNull, reason: 'an unclean teardown is still reported');
    expect((failure!.error as StateError).message, 'stop failed');
  });

  test('several failures report the FIRST one', () async {
    // The first failure is the one that explains what went wrong; the ones
    // after it are often consequences of it.
    final failure = await runCleanupLegs('t', [
      ('a', () async => throw StateError('root cause')),
      ('b', () async => throw StateError('knock-on')),
    ]);
    expect((failure!.error as StateError).message, 'root cause');
  });

  test('a clean teardown reports nothing', () async {
    final ran = <String>[];
    final failure = await runCleanupLegs('t', [
      ('a', () async => ran.add('a')),
      ('b', () async => ran.add('b')),
    ]);
    expect(failure, isNull);
    expect(ran, ['a', 'b']);
  });

  test('legs run in order, not concurrently', () async {
    // Order is load-bearing during teardown: the API stops accepting before
    // the services it calls go away, and storage closes last because
    // everything above it writes.
    final order = <String>[];
    await runCleanupLegs('t', [
      (
        'slow',
        () async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          order.add('slow');
        },
      ),
      ('fast', () async => order.add('fast')),
    ]);
    expect(order, ['slow', 'fast']);
  });
}
