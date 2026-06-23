import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/state/messaging.dart';

/// Stale-transfer eviction (audit finding #1, availability): an accepted peer
/// that opens [kMaxConcurrentIncomingFiles] transfers and never finishes them
/// must NOT block legitimate transfers forever. A fresh transfer arriving at
/// capacity evicts transfers idle past [kStaleIncomingFileTimeout] — but never
/// an actively-progressing one (timeout-evict, not LRU).
NodeId _id(int s) => NodeId(Uint8List.fromList(List.filled(32, s)));
Uint8List _bytes(int n) {
  final r = Random(n);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

class _FakeTransport implements VeilTransport {
  _FakeTransport(this._me);
  final NodeId _me;
  final _inbound = StreamController<InboundMessage>.broadcast();
  _FakeTransport? peer;
  @override
  Future<NodeId> nodeId() async => _me;
  @override
  Stream<InboundMessage> messages() => _inbound.stream;

  @override
  Future<void> sendWithReply(NodeId dst, Uint8List payload) =>
      send(dst, payload, anonymous: true);
  @override
  Future<void> sendReply(int replyId, Uint8List payload) async {}
  @override
  Future<void> send(NodeId dst, Uint8List payload, {bool anonymous = false}) async =>
      peer?._inbound.add(InboundMessage(src: _me, payload: payload));
  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() async => _inbound.close();
}

SpaceOpener _mem() {
  final s = FakeKvLogStore();
  return ({required password, required bool create}) => s;
}

Future<void> _pump() => Future<void>.delayed(const Duration(milliseconds: 30));

void main() {
  late NodeId a, b;
  late _FakeTransport tA, tB;
  late HiddenVolumeStorage sA, sB;
  late MessagingService mA, mB;
  late DateTime clock; // B's controllable wall-clock

  setUp(() async {
    a = _id(1);
    b = _id(2);
    tA = _FakeTransport(a);
    tB = _FakeTransport(b);
    tA.peer = tB;
    tB.peer = tA;
    sA = HiddenVolumeStorage(_mem());
    sB = HiddenVolumeStorage(_mem());
    await sA.open(password: 'a', createIfMissing: true);
    await sB.open(password: 'b', createIfMissing: true);
    clock = DateTime(2026, 1, 1, 12);
    mA = MessagingService(tA, sA)..start();
    mB = MessagingService(tB, sB, now: () => clock)..start();
  });

  Future<void> accept() async {
    await mA.sendRequest(b, 'hi');
    await _pump();
    await mB.acceptContact(a);
    await _pump();
  }

  Future<void> fillWithIncompleteTransfers() async {
    // Open the maximum number of transfers (meta only — never completed).
    for (var i = 0; i < kMaxConcurrentIncomingFiles; i++) {
      await tA.send(
          b,
          fileMetaEnvelope(transferId: 'stall$i', name: 'f$i', size: 10, count: 5)
              .encode());
    }
    await _pump();
  }

  Future<Iterable> incomingFiles() async =>
      (await sB.loadMessages(a.hex)).where((m) => m.isFile);

  test('a fresh transfer evicts a stale one and gets delivered', () async {
    await accept();
    await fillWithIncompleteTransfers();

    // All open transfers go idle past the stale timeout.
    clock = clock.add(kStaleIncomingFileTimeout + const Duration(seconds: 1));

    // A new, COMPLETE transfer must now find a slot (a stale one is evicted)
    // and deliver — without eviction it would be dropped at capacity forever.
    final data = _bytes(9000);
    await mA.sendFile(b, data, 'new.png');
    await _pump();
    await _pump();

    final files = await incomingFiles();
    expect(files.length, 1, reason: 'the new transfer should have been accepted');
    expect(await sB.loadFile(files.first.fileId!), data);
  });

  test('an actively-progressing transfer is NOT evicted (no hostile eviction)',
      () async {
    await accept();
    await fillWithIncompleteTransfers();

    // The slots are full of FRESH transfers (no time has passed). A hostile peer
    // opening a new transfer must NOT be able to evict them — the cap holds and
    // the new transfer is dropped.
    final data = _bytes(9000);
    await mA.sendFile(b, data, 'blocked.png');
    await _pump();
    await _pump();

    expect(await incomingFiles(), isEmpty,
        reason: 'fresh transfers must be protected from eviction');
  });
}
