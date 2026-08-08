import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/storage.dart';

// A queue that keeps everything forever is how a device that was unlinked
// leaves 109 undeliverable frames behind it, with a healthy peer's traffic
// waiting in line. A queue that drops by age is how user data goes missing
// when someone's phone spends a day in a drawer. The rule has to tell those
// two apart, and these are the cases that say whether it does.

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

SpaceOpener _memOpener() {
  final store = FakeKvLogStore();
  return ({required password, required bool create}) => store;
}

void main() {
  late HiddenVolumeStorage store;
  final peer = _id(7);

  setUp(() async {
    store = HiddenVolumeStorage(_memOpener());
    await store.open(password: 'p', createIfMissing: true);
  });

  tearDown(() async => store.close());

  Future<void> enqueue(String frameId) => store.enqueueOutboxFrame(
    frameId,
    peer.hex,
    Uint8List.fromList([1, 2, 3]),
  );

  test('a queued frame carries the time it was queued', () async {
    // Without a stamp the only age signal is "how many times have we failed",
    // which counts retries rather than time and cannot tell a peer that is
    // gone from one that is merely asleep.
    final before = DateTime.now().millisecondsSinceEpoch;
    await enqueue('grpc:snapshot-1');
    final after = DateTime.now().millisecondsSinceEpoch;

    final pending = await store.pendingOutboxFrames();
    final frame = pending.firstWhere((f) => f.frameId == 'grpc:snapshot-1');
    expect(frame.enqueuedAtMs, isNotNull);
    expect(frame.enqueuedAtMs!, greaterThanOrEqualTo(before));
    expect(frame.enqueuedAtMs!, lessThanOrEqualTo(after));
  });

  test('every kind is stamped, not just the droppable ones', () async {
    // The stamp is a property of being queued. Restricting it to the kinds
    // that retention currently reads would leave the next rule blind again.
    for (final id in ['grp:s', 'grpc:s', 'doc:d', 'docc:d', 'msg-1', 'ack:x']) {
      await enqueue(id);
    }
    final pending = await store.pendingOutboxFrames();
    expect(pending, hasLength(6));
    for (final f in pending) {
      expect(
        f.enqueuedAtMs,
        isNotNull,
        reason: '${f.frameId} was queued without a time',
      );
    }
  });

  test('a frame written before stamping reads back with no time, not a fake '
      'one', () async {
    // Rows written by an older build have no `t`. Retention must see "unknown"
    // and keep them: inventing an age here would delete a day's worth of
    // someone's messages on first launch after an update.
    final frame = OutboxFrame(
      frameId: 'legacy',
      peerHex: 'ff',
      wire: Uint8List(0),
    );
    expect(frame.enqueuedAtMs, isNull);
  });
}
