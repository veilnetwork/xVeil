import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';

void main() {
  late HiddenVolumeStorage storage;

  setUp(() async {
    final fake = FakeKvLogStore();
    storage = HiddenVolumeStorage(
      ({required password, required bool create}) => fake,
    );
    await storage.open(password: 'pw', createIfMissing: true);
  });

  Uint8List wire(String s) => Uint8List.fromList(s.codeUnits);

  test('enqueue surfaces a pending frame; ack retires it', () async {
    expect(await storage.pendingOutboxFrames(), isEmpty);

    await storage.enqueueOutboxFrame('sigreq:m1', 'peerA', wire('hello'));
    var pending = await storage.pendingOutboxFrames();
    expect(pending.length, 1);
    expect(pending.single.frameId, 'sigreq:m1');
    expect(pending.single.peerHex, 'peerA');
    expect(pending.single.wire, wire('hello'));

    await storage.ackOutboxFrame('sigreq:m1');
    expect(await storage.pendingOutboxFrames(), isEmpty);
  });

  test('enqueue is idempotent on frameId', () async {
    await storage.enqueueOutboxFrame('f', 'peer', wire('a'));
    await storage.enqueueOutboxFrame('f', 'peer', wire('a'));
    expect((await storage.pendingOutboxFrames()).length, 1);
  });

  test('acking an unknown id is a harmless no-op', () async {
    await storage.enqueueOutboxFrame('keep', 'peer', wire('x'));
    await storage.ackOutboxFrame('never-enqueued'); // must not touch 'keep'
    final pending = await storage.pendingOutboxFrames();
    expect(pending.length, 1);
    expect(pending.single.frameId, 'keep');
  });

  test('multiple frames fold independently', () async {
    await storage.enqueueOutboxFrame('a', 'p1', wire('1'));
    await storage.enqueueOutboxFrame('b', 'p2', wire('2'));
    await storage.enqueueOutboxFrame('c', 'p1', wire('3'));
    expect((await storage.pendingOutboxFrames()).map((f) => f.frameId).toSet(),
        {'a', 'b', 'c'});

    await storage.ackOutboxFrame('b');
    expect((await storage.pendingOutboxFrames()).map((f) => f.frameId).toSet(),
        {'a', 'c'});
  });

  test('re-enqueue after ack works (self-heal path)', () async {
    await storage.enqueueOutboxFrame('f', 'peer', wire('v1'));
    await storage.ackOutboxFrame('f');
    expect(await storage.pendingOutboxFrames(), isEmpty);
    // A later distinct frame with the same id (e.g. a fresh request) re-appears.
    await storage.enqueueOutboxFrame('f', 'peer', wire('v2'));
    final pending = await storage.pendingOutboxFrames();
    expect(pending.length, 1);
    expect(pending.single.wire, wire('v2'));
  });
}
