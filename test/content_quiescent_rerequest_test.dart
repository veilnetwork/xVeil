import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/content_manifest.dart';
import 'package:xveil/state/messaging.dart';

// A serve that ends SHORT leaves the receiver already knowing which chunks it
// is missing. It used to sit on that knowledge until the periodic tick came
// round — up to 20 s of silence with both sides idle and the answer already in
// hand. These tests pin the trigger that closes that gap, and the two bounds
// that keep it from becoming a second timer: it must not cut into a burst that
// is still arriving, and it must not fire at all for a holder that sends
// nothing.

NodeId _id(int s) => NodeId(Uint8List.fromList(List.filled(32, s)));

/// 1:1 link that can make a serve stop short, and counts the piece requests
/// leaving this side.
class _Link implements VeilTransport {
  _Link(this._me);
  final NodeId _me;
  final _in = StreamController<InboundMessage>.broadcast();
  _Link? peer;
  int pieceRequests = 0;

  /// Chunks to let through before the serve goes silent (null = all).
  int? chunkBudget;
  int chunksForwarded = 0;

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
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    final kind = WireEnvelope.decode(payload).kind;
    if (kind == WireKind.pieceRequest) pieceRequests++;
    if (kind == WireKind.pieceChunk) {
      final budget = chunkBudget;
      if (budget != null && chunksForwarded >= budget) {
        return; // the serve dies here — nothing tells the receiver
      }
      chunksForwarded++;
    }
    peer?._in.add(
      InboundMessage(
        src: _me,
        payload: payload,
        provenance: SenderProvenance.sessionPeer,
      ),
    );
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

  // Far enough away that nothing in these tests can be the periodic tick: any
  // request they observe came from the burst going quiet.
  const noTick = Duration(minutes: 10);

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
    mA = MessagingService(tA, sA, contentPacing: Duration.zero)..start();
    mB = MessagingService(
      tB,
      sB,
      contentReRequestInterval: noTick,
      contentPacing: Duration.zero,
    )..start();
    await sA.upsertContact(Contact(nodeId: b, status: ContactStatus.accepted));
    await sB.upsertContact(Contact(nodeId: a, status: ContactStatus.accepted));
  });

  tearDown(() async {
    await mA.dispose();
    await mB.dispose();
  });

  Uint8List body(int n) =>
      Uint8List.fromList(List.generate(n, (i) => (i * 31 + 7) & 0xff));

  /// A offers [data]; B asks for it. Returns the content id and B's request
  /// count once the pull is under way.
  Future<(String, int)> pull(Uint8List data) async {
    const name = 'burst.bin';
    final cid = ContentManifest.fromBytes(name, data).contentId;
    await mB.setFileDownloadPolicy(
      mB.fileDownloadPolicy.copyWith(autoMaxBytes: 0),
    );
    await mA.sendFileStreaming(
      b,
      name,
      data.length,
      (o, l) async => Uint8List.sublistView(data, o, o + l),
      close: () async {},
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await mB.downloadContent(a, cid);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    return (cid, tB.pieceRequests);
  }

  test('a serve that stops SHORT is re-requested within seconds, not at the '
      'next tick', () async {
    tA.chunkBudget = 2; // the holder dies after two chunks, silently
    final (_, opening) = await pull(body(64 * 1024));

    // Nothing more will arrive. With only the periodic tick this side would sit
    // on a known shortfall for the whole interval.
    await Future<void>.delayed(const Duration(seconds: 4));

    expect(
      tB.pieceRequests,
      greaterThan(opening),
      reason: 'the receiver knew what was missing and waited for the tick '
          'anyway — a ten-minute interval proves no tick fired',
    );
  });

  test('a holder that sends NOTHING is not asked any faster than before',
      () async {
    // The trigger is armed by arriving chunks alone. A holder that answers with
    // silence must fall back to the periodic tick, or a dead transfer would
    // become a request loop against an absent peer.
    tA.chunkBudget = 0;
    final (_, opening) = await pull(body(64 * 1024));

    await Future<void>.delayed(const Duration(seconds: 4));

    expect(
      tB.pieceRequests,
      opening,
      reason: 'nothing ever arrived, so nothing should have armed the trigger',
    );
  });

  test('a transfer that COMPLETES leaves no trigger behind', () async {
    // The last chunk of a finished transfer is still an arrival, so it arms the
    // trigger like any other. Completion has to disarm it: an extra request for
    // a file already held would ask its holder to serve it all over again.
    final data = body(64 * 1024);
    final (cid, _) = await pull(data);
    final held = await _waitHeld(sB, cid);
    expect(held, isTrue, reason: 'sanity: the transfer completed');

    final after = tB.pieceRequests;
    await Future<void>.delayed(const Duration(seconds: 4));

    expect(
      tB.pieceRequests,
      after,
      reason: 'a completed transfer asked for more chunks',
    );
  });
}

Future<bool> _waitHeld(HiddenVolumeStorage s, String cid) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (DateTime.now().isBefore(deadline)) {
    if (await s.hasFile(cid)) return true;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return false;
}
