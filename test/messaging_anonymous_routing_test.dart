import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/state/messaging.dart';

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

/// Records the `anonymous` flag of every outbound send so we can assert that an
/// anonymous identity routes EVERY frame (message, ack, accept) over the onion
/// path — a fail-closed safety property: a single clearnet frame would leak the
/// sender's network location. Delivers to a peer so the two-sided flow runs.
class _RecordingTransport implements VeilTransport {
  _RecordingTransport(this._me);
  final NodeId _me;
  final _inbound = StreamController<InboundMessage>.broadcast();
  _RecordingTransport? peer;
  final sends = <bool>[];

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
  Future<void> send(NodeId dst, Uint8List payload, {bool anonymous = false}) async {
    sends.add(anonymous);
    peer?._inbound.add(InboundMessage(src: _me, payload: payload));
  }

  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() async => _inbound.close();
}

SpaceOpener _memOpener() {
  final store = FakeKvLogStore();
  return ({required password, required bool create}) => store;
}

Future<void> _pump() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  late NodeId a, b;
  late _RecordingTransport tA, tB;
  late HiddenVolumeStorage sA, sB;

  // Sets up A's transport/storage and a plain peer B, returns B's service so the
  // test can drive B's acceptance. The test owns A's MessagingService so it
  // controls A's anonymity. A is built [anonymous] and a mutually-accepted
  // contact is established so the consent-gated send paths (text, file) all run.
  Future<MessagingService> wire({required bool aAnonymous}) async {
    a = _id(1);
    b = _id(2);
    tA = _RecordingTransport(a);
    tB = _RecordingTransport(b);
    tA.peer = tB;
    tB.peer = tA;
    sA = HiddenVolumeStorage(_memOpener());
    sB = HiddenVolumeStorage(_memOpener());
    await sA.open(password: 'a', createIfMissing: true);
    await sB.open(password: 'b', createIfMissing: true);
    final mB = MessagingService(tB, sB)..start();
    final mA = MessagingService(tA, sA, anonymous: aAnonymous)..start();
    // Handshake: A requests, B accepts; the accept flips A's contact to accepted
    // so the consent gate on sendText/sendFile lets them through.
    await mA.sendRequest(b, 'hi');
    await _pump();
    await mB.acceptContact(a);
    await _pump();
    return mA;
  }

  test('an anonymous identity routes EVERY outbound frame anonymously '
      '(text AND file)', () async {
    final mA = await wire(aAnonymous: true);
    await mA.sendText(b, 'meet at noon');
    await _pump();
    // Multi-chunk file so the fileMeta + several fileChunk frames all run.
    await mA.sendFile(b, Uint8List.fromList(List.generate(20000, (i) => i & 0xff)),
        'plan.bin');
    await _pump();

    // request + message + fileMeta + >=1 fileChunk — prove the paths actually ran.
    expect(tA.sends.length, greaterThanOrEqualTo(4),
        reason: 'expected request+text+file frames; got ${tA.sends.length}');
    // The safety invariant: not a single frame from an anonymous identity may
    // take the clearnet path — that would leak the sender's network location.
    expect(tA.sends.every((anon) => anon), isTrue,
        reason: 'anonymous identity leaked a clearnet frame: ${tA.sends}');
  });

  test('a non-anonymous identity routes clearnet (no onion overhead)', () async {
    final mA = await wire(aAnonymous: false);
    await mA.sendText(b, 'meet at noon');
    await _pump();
    await mA.sendFile(b, Uint8List.fromList(List.filled(5000, 7)), 'plan.bin');
    await _pump();

    expect(tA.sends, isNotEmpty);
    expect(tA.sends.any((anon) => anon), isFalse,
        reason: 'non-anonymous identity unexpectedly routed anonymously');
  });
}
