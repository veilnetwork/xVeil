import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/state/messaging.dart';

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

class _RecordingTransport implements VeilTransport {
  _RecordingTransport(this._me);
  final NodeId _me;
  final _inbound = StreamController<InboundMessage>.broadcast();
  final sent = <(NodeId, WireEnvelope)>[];
  @override
  Future<NodeId> nodeId() async => _me;
  @override
  Stream<InboundMessage> messages() => _inbound.stream;
  @override
  Future<void> send(NodeId dst, Uint8List payload, {bool anonymous = false}) async {
    sent.add((dst, WireEnvelope.decode(payload)));
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

void main() {
  late NodeId a, b;
  late HiddenVolumeStorage sA;
  late _RecordingTransport tA;
  late MessagingService mA;

  setUp(() async {
    a = _id(1);
    b = _id(2);
    tA = _RecordingTransport(a);
    sA = HiddenVolumeStorage(_memOpener());
    await sA.open(password: 'a', createIfMissing: true);
    mA = MessagingService(tA, sA)..start();
  });

  test('resendRequest re-sends the same greeting + id while pendingOutgoing',
      () async {
    await mA.sendRequest(b, 'hi there');
    final firstReq = tA.sent.where((s) => s.$2.kind == WireKind.request).toList();
    expect(firstReq, hasLength(1));
    final id = firstReq.single.$2.id;

    tA.sent.clear();
    await mA.resendRequest(b);
    final resent = tA.sent.where((s) => s.$2.kind == WireKind.request).toList();
    expect(resent, hasLength(1));
    expect(resent.single.$1, b);
    expect(resent.single.$2.body, 'hi there');
    expect(resent.single.$2.id, id); // same id so the peer dedups
  });

  test('cancelRequest removes the contact + conversation', () async {
    await mA.sendRequest(b, 'hi');
    expect(await sA.getContact(b), isNotNull);
    expect((await sA.loadConversations()).any((c) => c.peer.nodeId == b), isTrue);

    await mA.cancelRequest(b);
    expect(await sA.getContact(b), isNull); // peer is unknown again
    expect((await sA.loadConversations()).any((c) => c.peer.nodeId == b),
        isFalse);

    // A fresh request can be sent again after cancelling.
    await mA.resendRequest(b); // no-op (not pending) — must not throw
    await mA.sendRequest(b, 'second try');
    expect(await sA.getContact(b), isNotNull);
  });
}
