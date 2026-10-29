import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/post_receipt_queue.dart';

void main() {
  test(
    'a held lane preserves FIFO without blocking an independent lane',
    () async {
      final queue = PostReceiptQueue(maxConcurrent: 2);
      final release = Completer<void>();
      final sent = <String>[];
      final first = queue.submit(
        key: 'a1',
        lane: 'a',
        bytes: 1,
        send: () async {
          await release.future;
          sent.add('a1');
        },
      );
      final second = queue.submit(
        key: 'a2',
        lane: 'a',
        bytes: 1,
        send: () async => sent.add('a2'),
      );
      final other = queue.submit(
        key: 'b1',
        lane: 'b',
        bytes: 1,
        send: () async => sent.add('b1'),
      );
      try {
        await other;
        expect(sent, ['b1']);
        expect(queue.pendingJobs, 2);
      } finally {
        release.complete();
        await Future.wait([first, second]);
        await queue.close();
      }
      expect(sent, ['b1', 'a1', 'a2']);
    },
  );

  test('global active cap and shutdown join every active lane', () async {
    final queue = PostReceiptQueue(maxJobs: 5, maxBytes: 40, maxConcurrent: 3);
    final releases = [for (var i = 0; i < 3; i++) Completer<void>()];
    final started = <int>[];
    final work = <Future<void>>[];
    for (var i = 0; i < 5; i++) {
      work.add(
        queue.submit(
          key: 'job-$i',
          lane: 'lane-$i',
          bytes: 8,
          send: () async {
            started.add(i);
            if (i < 3) await releases[i].future;
          },
        ),
      );
    }
    expect(started, [0, 1, 2]);
    expect(queue.pendingBytes, 40);
    await queue.submit(
      key: 'overflow',
      lane: 'other',
      bytes: 1,
      send: () async =>
          fail('the global job/byte budget must include active lanes'),
    );
    expect(queue.dropped, 1);
    var closed = false;
    final close = queue.close().then((_) => closed = true);
    await Future.wait(work.skip(3));
    expect(queue.pendingBytes, 24);
    releases[0].complete();
    releases[1].complete();
    await Future.wait(work.take(2));
    expect(
      closed,
      isFalse,
      reason: 'the third active lane still owns transport work',
    );
    expect(queue.pendingBytes, 8);
    releases[2].complete();
    await close;
    expect(queue.pendingJobs, 0);
    expect(queue.pendingBytes, 0);
    expect(started, [0, 1, 2]);
  });
}
