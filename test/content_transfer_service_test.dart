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

/// 1:1 link that can selectively drop pieceChunk frames (to exercise the
/// re-request path) — everything else is delivered.
class _Link implements VeilTransport {
  _Link(this._me);
  final NodeId _me;
  final _in = StreamController<InboundMessage>.broadcast();
  _Link? peer;
  // Drop the first delivery of these (pieceIndex) chunks, once each.
  final Set<int> dropPiecesOnce = {};

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
    final env = WireEnvelope.decode(payload);
    if (env.kind == WireKind.pieceChunk) {
      final f = parsePieceChunk(env.body);
      if (dropPiecesOnce.remove(f.pieceIndex)) return; // drop once → forces re-request
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
    // Short re-request cadence so the drop-recovery test doesn't wait seconds.
    const fast = Duration(milliseconds: 120);
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

  Uint8List _rnd(int n, int seed) {
    final r = Random(seed);
    return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
  }

  test('content transfer: advertise → request → serve → verify → reassemble '
      '(multi-piece, hash-verified end to end)', () async {
    final data = _rnd(300000, 7); // ~2 pieces at the 256 KiB adaptive size
    final got = mB.contentReceived.first;
    await mA.sendContent(b, data, 'movie.bin');
    final received = await got.timeout(const Duration(seconds: 10));
    expect(received.name, 'movie.bin');
    expect(received.bytes, data, reason: 'verified whole == original');
  });

  test('a dropped piece is re-requested and the transfer still completes',
      () async {
    final data = _rnd(300000, 8);
    // Content flows A→B over tA.send — drop a piece-1 chunk there, once.
    tA.dropPiecesOnce.add(1);
    final got = mB.contentReceived.first;
    await mA.sendContent(b, data, 'doc.bin');
    // B's re-request timer asks A again for the missing piece; it lands next time.
    final received = await got.timeout(const Duration(seconds: 10));
    expect(received.bytes, data, reason: 'recovered the dropped piece');
  });
}
