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
  Future<void> send(NodeId dst, Uint8List payload, {bool anonymous = false}) async {
    sends.add(anonymous);
    peer?._inbound.add(InboundMessage(src: _me, payload: payload));
  }

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

  // Sets up A's transport/storage and a plain peer B (so the handshake + acks
  // complete). The test owns A's MessagingService so it controls A's anonymity.
  Future<void> wire() async {
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
    MessagingService(tB, sB).start();
  }

  test('an anonymous identity routes EVERY outbound frame anonymously', () async {
    await wire();
    final mA = MessagingService(tA, sA, anonymous: true)..start();
    // Drive the frame types that hit the wire: request, accept (reply), message.
    await mA.sendRequest(b, 'hi');
    await _pump();
    await mA.sendText(b, 'meet at noon');
    await _pump();

    expect(tA.sends, isNotEmpty);
    // Fail-closed: not a single frame may go clearnet from an anonymous identity.
    expect(tA.sends.every((anon) => anon), isTrue,
        reason: 'anonymous identity leaked a clearnet frame: ${tA.sends}');
  });

  test('a non-anonymous identity routes clearnet (no onion overhead)', () async {
    await wire();
    final mA = MessagingService(tA, sA)..start();
    await mA.sendRequest(b, 'hi');
    await _pump();
    await mA.sendText(b, 'meet at noon');
    await _pump();

    expect(tA.sends, isNotEmpty);
    expect(tA.sends.any((anon) => anon), isFalse,
        reason: 'non-anonymous identity unexpectedly routed anonymously');
  });
}
