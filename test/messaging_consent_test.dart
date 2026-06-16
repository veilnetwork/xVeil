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

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

/// Direct 1:1 fake link: send() delivers to the peer's inbound, tagged with
/// our node id as the source.
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
  Future<void> send(NodeId dst, Uint8List payload, {bool anonymous = false}) async {
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
  late _FakeTransport tA, tB;
  late HiddenVolumeStorage sA, sB;
  late MessagingService mA, mB;

  setUp(() async {
    a = _id(1);
    b = _id(2);
    tA = _FakeTransport(a);
    tB = _FakeTransport(b);
    tA.peer = tB;
    tB.peer = tA;
    sA = HiddenVolumeStorage(_memOpener());
    sB = HiddenVolumeStorage(_memOpener());
    await sA.open(password: 'a', createIfMissing: true);
    await sB.open(password: 'b', createIfMissing: true);
    mA = MessagingService(tA, sA)..start();
    mB = MessagingService(tB, sB)..start();
  });

  test('request -> accept -> message; gating blocks pre-accept and strangers',
      () async {
    // A requests B with a greeting.
    await mA.sendRequest(b, 'hi, can we connect?');
    await _pump();
    expect((await sA.getContact(b))!.status, ContactStatus.pendingOutgoing);
    expect((await sB.getContact(a))!.status, ContactStatus.pendingIncoming);
    expect((await sB.loadMessages(a.hex)).single.body, 'hi, can we connect?');

    // A cannot free-message before B accepts.
    await mA.sendText(b, 'let me in');
    await _pump();
    expect((await sB.loadMessages(a.hex)).length, 1); // greeting only

    // B accepts -> both accepted.
    await mB.acceptContact(a);
    await _pump();
    expect((await sB.getContact(a))!.status, ContactStatus.accepted);
    expect((await sA.getContact(b))!.status, ContactStatus.accepted);

    // Now free messaging works both ways.
    await mA.sendText(b, 'hello');
    await _pump();
    expect((await sB.loadMessages(a.hex)).map((m) => m.body), contains('hello'));
  });

  test('a plain message from a stranger is dropped (no auto-add)', () async {
    // B never requested/accepted A; A sends a raw message.
    await mA.sendText(b, 'spam'); // gated on A's side anyway (no contact)
    // Force a bare message even without a contact:
    await tA.send(b, const WireEnvelopeMessage('hi stranger').bytes);
    await _pump();
    expect(await sB.getContact(a), isNull);
    expect(await sB.loadMessages(a.hex), isEmpty);
  });

  test('blocking drops subsequent messages', () async {
    await mA.sendRequest(b, 'hi');
    await _pump();
    await mB.acceptContact(a);
    await _pump();
    await mB.blockContact(a);
    await mA.sendText(b, 'after block');
    await _pump();
    expect((await sB.loadMessages(a.hex)).any((m) => m.body == 'after block'),
        isFalse);
  });
}

/// Tiny helper to craft a raw message payload in the stranger test.
class WireEnvelopeMessage {
  const WireEnvelopeMessage(this.text);
  final String text;
  Uint8List get bytes =>
      Uint8List.fromList('{"t":2,"b":"$text"}'.codeUnits);
}
