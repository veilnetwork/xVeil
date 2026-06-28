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
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

NodeId _id(int s) => NodeId(Uint8List.fromList(List.filled(32, s)));

/// 1:1 link that counts outgoing pieceRequest frames — so a test can prove the
/// receiver did NOT re-download (issued no piece requests) when it already held
/// the hash-keyed blob.
class _Link implements VeilTransport {
  _Link(this._me);
  final NodeId _me;
  final _in = StreamController<InboundMessage>.broadcast();
  _Link? peer;
  int pieceRequests = 0;

  @override
  Future<NodeId> nodeId() async => _me;
  @override
  Stream<InboundMessage> messages() => _in.stream;
  @override
  Future<void> sendWithReply(NodeId dst, Uint8List payload) =>
      send(dst, payload, anonymous: true);
  @override
  Future<void> sendReply(int replyId, Uint8List payload) async {}
  @override
  Future<void> send(NodeId dst, Uint8List payload, {bool anonymous = false}) async {
    if (WireEnvelope.decode(payload).kind == WireKind.pieceRequest) {
      pieceRequests++;
    }
    peer?._in.add(InboundMessage(src: _me, payload: payload));
  }

  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() async => _in.close();
}

SpaceOpener _mem() {
  final s = FakeKvLogStore();
  return ({required password, required bool create}) => s;
}

void main() {
  late NodeId a, b;
  late _Link tA, tB;
  late HiddenVolumeStorage sA, sB;
  late MessagingService mA, mB;

  setUp(() async {
    a = _id(1);
    b = _id(2);
    tA = _Link(a);
    tB = _Link(b);
    tA.peer = tB;
    tB.peer = tA;
    sA = HiddenVolumeStorage(_mem());
    sB = HiddenVolumeStorage(_mem());
    await sA.open(password: 'a', createIfMissing: true);
    await sB.open(password: 'b', createIfMissing: true);
    const fast = Duration(milliseconds: 60);
    mA = MessagingService(tA, sA,
        contentReRequestInterval: fast, contentPacing: Duration.zero)
      ..start();
    mB = MessagingService(tB, sB,
        contentReRequestInterval: fast, contentPacing: Duration.zero)
      ..start();
    await sA.upsertContact(Contact(nodeId: b, status: ContactStatus.accepted));
    await sB.upsertContact(Contact(nodeId: a, status: ContactStatus.accepted));
  });

  tearDown(() async {
    await mA.dispose();
    await mB.dispose();
  });

  Uint8List rnd(int n, int seed) {
    final r = Random(seed);
    return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
  }

  // Poll [s]'s view of the conversation with [peer] until it holds >= [n] file
  // messages (the content path surfaces asynchronously: manifest → pieces).
  Future<List<Message>> waitFiles(
    HiddenVolumeStorage s,
    NodeId peer,
    int n, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final files =
          (await s.loadMessages(peer.hex)).where((m) => m.isFile).toList();
      if (files.length >= n) return files;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return (await s.loadMessages(peer.hex)).where((m) => m.isFile).toList();
  }

  test('A re-send of a CLEARED file surfaces AGAIN as a NEW message — the '
      'per-send msgId is not tombstoned by the old delete (A semantics)',
      () async {
    final data = rnd(1024 * 1024 + 1, 11); // > 1 MiB → content path
    await mA.sendFile(b, data, 'pic.jpg');
    final first = await waitFiles(sB, a, 1);
    expect(first.length, 1, reason: 'B surfaced the first send');
    final firstId = first.single.id;

    // B clears the conversation — tombstones that file (by its msgId) + scrubs
    // the blob: exactly the user's clear-history scenario that used to suppress
    // every future identical send.
    await mB.clearConversation(a);
    expect((await sB.loadMessages(a.hex)).where((m) => m.isFile), isEmpty,
        reason: 'precondition: cleared');

    // A re-sends the SAME bytes. Same contentId (so bytes still dedup/verify),
    // but a FRESH msgId → a new filePost EVENT the old tombstone cannot suppress.
    await mA.sendFile(b, data, 'pic.jpg');
    final second = await waitFiles(sB, a, 1);
    expect(second.length, 1,
        reason: 'the re-sent file surfaces despite the prior clear (A)');
    expect(second.single.id, isNot(firstId),
        reason: 'a NEW event (fresh msgId), not the resurrected old one');
  });

  test('A re-send when B ALREADY HOLDS the blob surfaces a new message WITHOUT '
      're-downloading (content-hash dedup)', () async {
    final data = rnd(1024 * 1024 + 1, 12); // ~1 MiB <= 2 MiB → auto-downloads
    // The OFFER surfaces immediately; the blob arrives later. Wait for the first
    // send to fully DOWNLOAD (contentReceived) before snapshotting the count.
    final got1 = mB.contentReceived.first;
    await mA.sendFile(b, data, 'pic.jpg');
    await got1.timeout(const Duration(seconds: 20));
    await waitFiles(sB, a, 1);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final reqsAfterFirst = tB.pieceRequests;
    expect(reqsAfterFirst, greaterThan(0),
        reason: 'the first send genuinely downloaded the pieces');

    // Second send of identical bytes: B already holds the blob (keyed by
    // contentId), so the offer renders downloaded and B issues NO new requests.
    await mA.sendFile(b, data, 'pic.jpg');
    final two = await waitFiles(sB, a, 2);
    expect(two.length, 2, reason: 'a second, distinct file message surfaced');
    expect(tB.pieceRequests, reqsAfterFirst,
        reason: 'dedup: the second send issued NO new piece requests');
    expect(two.map((m) => m.id).toSet().length, 2,
        reason: 'two distinct events (msgIds)');
    expect(two.map((m) => m.fileContentId).toSet(), hasLength(1),
        reason: 'both reference the ONE hash-keyed blob (contentId)');
  });

  test('a LARGE file (> auto-download cap) is OFFERED, not auto-fetched, until '
      'the user calls downloadContent (anti-spam / disk control)', () async {
    final data = rnd(3 * 1024 * 1024, 21); // 3 MiB > 2 MiB cap → OFFER
    await mA.sendFile(b, data, 'big.bin');

    // The offer surfaces (metadata) but NOTHING downloads on its own.
    final offered = await waitFiles(sB, a, 1);
    expect(offered.single.fileContentId, isNotNull,
        reason: 'the offer carries the contentId to fetch');
    expect(offered.single.fileSize, data.length,
        reason: 'the offer carries the size so the user can decide');
    expect(offered.single.isDownloaded, isFalse, reason: 'no blob yet');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(tB.pieceRequests, 0, reason: 'a large file is NOT auto-downloaded');
    expect(await sB.hasFile(offered.single.fileContentId!), isFalse);

    // The user opts in → it downloads.
    final got = mB.contentReceived.first;
    await mB.downloadContent(a, offered.single.fileContentId!);
    await got.timeout(const Duration(seconds: 30));
    expect(tB.pieceRequests, greaterThan(0),
        reason: 'the opt-in download issues piece requests');
    expect(await sB.hasFile(offered.single.fileContentId!), isTrue,
        reason: 'the blob is present after the user-triggered download');
  });
}
