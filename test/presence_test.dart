import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/state/messaging.dart';

NodeId _id(int s) => NodeId(Uint8List.fromList(List.filled(32, s)));

class _Capture implements VeilTransport {
  _Capture(this._me);
  final NodeId _me;
  final _in = StreamController<InboundMessage>.broadcast();
  final sent = <(NodeId, WireKind, String)>[];

  @override
  Future<NodeId> nodeId() async => _me;
  @override
  Stream<InboundMessage> messages() => _in.stream;
  @override
  Future<void> send(NodeId dst, Uint8List payload, {bool anonymous = false}) async {
    final env = WireEnvelope.decode(payload);
    sent.add((dst, env.kind, env.body));
  }

  @override
  Future<void> sendWithReply(NodeId dst, Uint8List payload) =>
      send(dst, payload, anonymous: true);
  @override
  Future<void> sendReply(int replyId, Uint8List payload) async {}
  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() async => _in.close();
}

Future<MessagingService> _service(_Capture t) async {
  final store = FakeKvLogStore();
  final storage = HiddenVolumeStorage(
    ({required password, required bool create}) => store,
  );
  await storage.open(password: 'pw', createIfMissing: true);
  return MessagingService(t, storage)..start();
}

void main() {
  // A device away for over a day no longer gets new frames dialled live; the
  // owner's decision (2026-09-27) is that a device coming online says so to
  // its siblings, and they react — so it is not left waiting for a probe.
  final identity = _id(0x90);
  final sibling = _id(0x92);

  test('a device that comes online tells my other devices', () async {
    final t = _Capture(_id(0x91));
    final m = await _service(t);
    addTearDown(m.dispose);
    m.myOtherDevices = () async => [sibling];

    await m.reconcileOnConnect();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(
      t.sent.where((e) => e.$2 == WireKind.presence).map((e) => e.$1),
      [sibling],
    );
  });

  test('a sibling that hears it answers once, at the device, not forever',
      () async {
    final t = _Capture(sibling);
    final m = await _service(t);
    addTearDown(m.dispose);
    m.selfIdentityHex = () async => identity.hex;
    m.isOwnDevice = (p) async => p == identity || p == _id(0x91);
    final device = _id(0x91);
    m.myOtherDevices = () async => [device];

    await m.deliverInbound(
      InboundMessage(
        src: identity,
        srcDevice: device,
        payload: WireEnvelope.presence(device.hex).encode(),
        provenance: SenderProvenance.signed,
      ),
    );
    await m.deliverInbound(
      InboundMessage(
        src: identity,
        srcDevice: device,
        payload: WireEnvelope.presence(device.hex, reply: true).encode(),
        provenance: SenderProvenance.signed,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final answers = [
      for (final e in t.sent)
        if (e.$2 == WireKind.presence) e,
    ];
    expect(answers, hasLength(1), reason: 'an answer was answered again');
    expect(answers.single.$1, device);
    expect(answers.single.$3, '${sibling.hex}|r');
  });

  test('a stranger saying it is online gets no answer', () async {
    final t = _Capture(sibling);
    final m = await _service(t);
    addTearDown(m.dispose);
    m.selfIdentityHex = () async => identity.hex;
    m.isOwnDevice = (p) async => false;
    await m.deliverInbound(
      InboundMessage(
        src: _id(0x55),
        srcDevice: _id(0x56),
        payload: WireEnvelope.presence(_id(0x56).hex).encode(),
        provenance: SenderProvenance.signed,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(t.sent.where((e) => e.$2 == WireKind.presence), isEmpty);
  });

  test('named only in the body (a relayed frame), the device is still '
      'answered', () async {
    final t = _Capture(sibling);
    final m = await _service(t);
    addTearDown(m.dispose);
    final device = _id(0x91);
    m.selfIdentityHex = () async => identity.hex;
    m.isOwnDevice = (p) async => p == identity || p == device;
    m.myOtherDevices = () async => [device];
    await m.deliverInbound(
      InboundMessage(
        src: identity,
        payload: WireEnvelope.presence(device.hex).encode(),
        provenance: SenderProvenance.signed,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      [for (final e in t.sent) if (e.$2 == WireKind.presence) e.$1],
      [device],
      reason: 'a relayed presence was not traced to its device',
    );
  });
}
