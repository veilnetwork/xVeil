import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

/// A phone was measured re-driving one direct-endpoint frame every three
/// seconds for hours, to a peer its own P2P policy refused to talk to, while
/// the log ring dropped 31 414 lines around it.
///
/// Two things were wrong. The frame says "these are my dial addresses right
/// NOW" and had no expiry, so nothing would ever have stopped it. And the
/// flush pass re-offered every pending frame to the mailbox on every pass,
/// including the ones already sitting in it.
NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

SpaceOpener _memOpener() {
  final store = FakeKvLogStore();
  return ({required password, required bool create}) => store;
}

class _SilentTransport implements VeilTransport {
  _SilentTransport(this._me);
  final NodeId _me;
  final _inbound = StreamController<InboundMessage>.broadcast();

  /// Every send this transport was asked to make. The peer never answers, so
  /// nothing is ever acked — which is the state the defect lived in.
  final List<NodeId> sends = <NodeId>[];

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
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    sends.add(dst);
  }

  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() async => _inbound.close();
}

void main() {
  late HiddenVolumeStorage store;
  late _SilentTransport transport;
  late MessagingService svc;
  late DateTime clock;
  final peer = _id(7);

  Future<void> flush() => svc.debugFlushOutboxFrames();

  setUp(() async {
    // The storage stamps `enqueuedAtMs` from the REAL clock, so the injected
    // one has to start there: a fixed date in the past makes every frame's age
    // negative and nothing is ever stale. The first version of this test did
    // exactly that and reported the expiry as broken.
    clock = DateTime.now();
    store = HiddenVolumeStorage(_memOpener());
    await store.open(password: 'p', createIfMissing: true);
    transport = _SilentTransport(_id(1));
    svc = MessagingService(transport, store, now: () => clock);
    // An ACCEPTED contact, or the flush retires every frame for a different
    // reason — a stranger's queue is dropped on the first pass — and the
    // expiry under test would never have run. The first version of this test
    // passed on exactly that.
    await store.upsertContact(
      Contact(nodeId: peer, status: ContactStatus.accepted),
    );
  });

  tearDown(() async {
    await transport.dispose();
    await store.close();
  });

  Future<List<String>> pendingIds() async =>
      (await store.pendingOutboxFrames()).map((f) => f.frameId).toList();

  Future<void> enqueue(String frameId) => store.enqueueOutboxFrame(
    frameId,
    peer.hex,
    Uint8List.fromList([1, 2, 3]),
  );

  test('a stale endpoint share is dropped rather than re-driven forever',
      () async {
    await enqueue('p2p:ep:${clock.millisecondsSinceEpoch}');
    expect(await pendingIds(), contains(startsWith('p2p:ep:')));

    // Half an hour and a minute later the addresses it advertises are no
    // longer a fact about this device.
    clock = clock.add(const Duration(minutes: 31));
    await flush();

    expect(
      await pendingIds(),
      isNot(contains(startsWith('p2p:ep:'))),
      reason: 'an address list this old tells the peer to dial somewhere else',
    );
  });

  test('a fresh endpoint share is kept', () async {
    await enqueue('p2p:ep:${clock.millisecondsSinceEpoch}');
    clock = clock.add(const Duration(minutes: 5));
    await flush();
    expect(await pendingIds(), contains(startsWith('p2p:ep:')));
  });

  /// The expiry must be about what the frame CARRIES, not about age. A
  /// message someone sent while their peer was in a drawer for a day is user
  /// data, and the entire contract of a durable queue is that it is still
  /// there.
  test('an ordinary message of the same age is untouched', () async {
    await enqueue('msg-1');
    // Older than EVERY window this file defines, so a guard that stopped
    // asking what the frame carries would drop it. Five hours would sit under
    // the replication window and prove nothing.
    clock = clock.add(const Duration(hours: 7));
    await flush();
    expect(
      await pendingIds(),
      contains('msg-1'),
      reason: 'user data is never dropped by age',
    );
  });
}
