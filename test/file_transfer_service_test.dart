import 'dart:async';
import 'dart:convert';
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
  Future<void> send(NodeId dst, Uint8List payload) async =>
      peer?._inbound.add(InboundMessage(src: _me, payload: payload));
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
    mA = MessagingService(tA, sA)..start();
    mB = MessagingService(tB, sB)..start();
  });

  Future<void> accept() async {
    await mA.sendRequest(b, 'hi');
    await _pump();
    await mB.acceptContact(a);
    await _pump();
  }

  test('multi-chunk file send reassembles and stores on the receiver',
      () async {
    await accept();
    final data = _bytes(20000); // > wire chunk -> several chunks
    await mA.sendFile(b, data, 'pic.png');
    await _pump();
    await _pump();

    final msgs = await sB.loadMessages(a.hex);
    final fileMsg = msgs.firstWhere((m) => m.isFile);
    expect(fileMsg.fileName, 'pic.png');
    expect(fileMsg.direction, MessageDirection.incoming);
    expect(await sB.loadFile(fileMsg.fileId!), data);

    // Sender keeps a local copy too.
    final sent = (await sA.loadMessages(b.hex)).firstWhere((m) => m.isFile);
    expect(await sA.loadFile(sent.fileId!), data);
  });

  test('file from a non-accepted peer is dropped (consent gate)', () async {
    // No accept handshake. Bypass A's own gate by injecting raw file envelopes
    // (built with the real encoder) — B must still drop them.
    final data = _bytes(9000);
    final meta = WireEnvelope(WireKind.fileMeta,
            jsonEncode({'tid': 't1', 'name': 'x', 'size': data.length, 'count': 2}))
        .encode();
    final c0 = WireEnvelope(WireKind.fileChunk,
            jsonEncode({'tid': 't1', 'i': 0, 'total': 2, 'd': base64Encode(data.sublist(0, 6000))}))
        .encode();
    final c1 = WireEnvelope(WireKind.fileChunk,
            jsonEncode({'tid': 't1', 'i': 1, 'total': 2, 'd': base64Encode(data.sublist(6000))}))
        .encode();
    await tA.send(b, meta);
    await tA.send(b, c0);
    await tA.send(b, c1);
    await _pump();
    expect((await sB.loadMessages(a.hex)).where((m) => m.isFile), isEmpty);
  });
}
