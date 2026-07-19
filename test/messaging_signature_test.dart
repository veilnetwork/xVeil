import 'dart:async';
import 'dart:convert';
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

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

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
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    peer?._inbound.add(InboundMessage(src: _me, payload: payload));
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
  Future<void> dispose() => _inbound.close();
}

SpaceOpener _memOpener() {
  final store = FakeKvLogStore();
  return ({required password, required bool create}) => store;
}

Future<void> _pump() => Future<void>.delayed(const Duration(milliseconds: 40));

void main() {
  late NodeId alice;
  late NodeId bob;
  late _FakeTransport aliceTransport;
  late _FakeTransport bobTransport;
  late HiddenVolumeStorage aliceStorage;
  late HiddenVolumeStorage bobStorage;
  late MessagingService aliceMessaging;
  late MessagingService bobMessaging;

  setUp(() async {
    alice = _id(1);
    bob = _id(2);
    aliceTransport = _FakeTransport(alice);
    bobTransport = _FakeTransport(bob);
    aliceTransport.peer = bobTransport;
    bobTransport.peer = aliceTransport;
    aliceStorage = HiddenVolumeStorage(_memOpener());
    bobStorage = HiddenVolumeStorage(_memOpener());
    await aliceStorage.open(password: 'alice', createIfMissing: true);
    await bobStorage.open(password: 'bob', createIfMissing: true);
    aliceMessaging = MessagingService(aliceTransport, aliceStorage)..start();
    bobMessaging = MessagingService(bobTransport, bobStorage)..start();

    await aliceMessaging.sendRequest(bob, 'hello');
    await _pump();
    await bobMessaging.acceptContact(alice);
    await _pump();
  });

  tearDown(() async {
    await aliceMessaging.dispose();
    await bobMessaging.dispose();
    await aliceTransport.dispose();
    await bobTransport.dispose();
    await aliceStorage.close();
    await bobStorage.close();
  });

  Future<Message> aliceSends(String body) async {
    await aliceMessaging.sendText(bob, body);
    await _pump();
    return (await bobStorage.loadMessages(
      alice.hex,
    )).firstWhere((message) => message.body == body);
  }

  test(
    'a valid request prompts the author and refusal reaches requester',
    () async {
      final received = await aliceSends('authored text');
      final askFuture = aliceMessaging.signatureAsks.first.timeout(
        const Duration(seconds: 2),
      );

      await bobMessaging.requestSignature(alice, received.id, received.body);
      final ask = await askFuture;
      expect(ask.peer, bob);
      expect(ask.msgId, received.id);
      expect(ask.body, received.body);

      await aliceMessaging.resolveSignatureAsk(ask, approve: false);
      await _pump();
      final updated = (await bobStorage.loadMessages(
        alice.hex,
      )).firstWhere((message) => message.id == received.id);
      expect(updated.signature, MessageSignature.refused);
    },
  );

  test('auto policy refuses a body the author never sent', () async {
    final received = await aliceSends('real text');
    aliceMessaging.signaturePolicyResolver = () => SignaturePolicy.auto;

    await bobMessaging.requestSignature(
      alice,
      received.id,
      'forged replacement',
    );
    await _pump();

    final updated = (await bobStorage.loadMessages(
      alice.hex,
    )).firstWhere((message) => message.id == received.id);
    expect(
      updated.signature,
      MessageSignature.refused,
      reason: 'auto-sign must bind to an actual outgoing message body',
    );
  });

  test(
    'a stale refusal cannot downgrade an already verified message',
    () async {
      final received = await aliceSends('already verified');
      await bobStorage.markMessageSignature(
        alice.hex,
        received.id,
        MessageSignature.verified,
      );
      final response = WireEnvelope.signResponse(
        jsonEncode({'mid': received.id, 'refused': true}),
      ).encode();

      await aliceTransport.send(bob, response);
      await _pump();

      final updated = (await bobStorage.loadMessages(
        alice.hex,
      )).firstWhere((message) => message.id == received.id);
      expect(updated.signature, MessageSignature.verified);
    },
  );
}
