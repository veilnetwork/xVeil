import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/state/mailbox_service.dart';
import 'package:xveil/state/messaging.dart';

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

/// A transport whose live send goes NOWHERE — models two NAT'd nodes that
/// cannot reach each other directly, so the ONLY delivery path is the mailbox.
class _BlackholeTransport implements VeilTransport {
  _BlackholeTransport(this._me);
  final NodeId _me;
  final _inbound = StreamController<InboundMessage>.broadcast();
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
  Future<void> send(NodeId dst, Uint8List payload,
      {bool anonymous = false}) async {}
  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() async => _inbound.close();
}

/// Records every stash so we can assert the offline-deposit path fired.
class _RecordingSink implements MailboxSink {
  final stashed = <(NodeId, Uint8List)>[];
  @override
  Future<void> stash({
    required NodeId recipient,
    required Uint8List payload,
    required Uint8List contentId,
  }) async {
    stashed.add((recipient, payload));
  }
}

SpaceOpener _memOpener() {
  final store = FakeKvLogStore();
  return ({required password, required bool create}) => store;
}

void main() {
  late NodeId a, b;
  late HiddenVolumeStorage sA;
  late MessagingService mA;
  late _RecordingSink sink;

  setUp(() async {
    a = _id(1);
    b = _id(2);
    sA = HiddenVolumeStorage(_memOpener());
    await sA.open(password: 'a', createIfMissing: true);
    mA = MessagingService(_BlackholeTransport(a), sA)..start();
    sink = _RecordingSink();
    mA.attachMailbox(sink);
  });

  test('a connection request is deposited at the recipient mailbox', () async {
    await mA.sendRequest(b, 'hi, it is me');
    expect(sink.stashed.length, 1);
    final (recipient, payload) = sink.stashed.single;
    expect(recipient, b);
    final env = WireEnvelope.decode(payload);
    expect(env.kind, WireKind.request);
    expect(env.body, 'hi, it is me');
  });

  test('an accept is deposited at the requester mailbox', () async {
    // Simulate an inbound request from b so a has a pendingIncoming contact.
    await mA.acceptContact(b);
    expect(sink.stashed.any((s) {
      final env = WireEnvelope.decode(s.$2);
      return s.$1 == b && env.kind == WireKind.accept;
    }), isTrue);
  });

  test('a free message to an accepted contact is deposited immediately',
      () async {
    await mA.acceptContact(b); // marks b accepted on a's side
    sink.stashed.clear();
    await mA.sendText(b, 'first real message');
    expect(sink.stashed.any((s) {
      final env = WireEnvelope.decode(s.$2);
      return s.$1 == b &&
          env.kind == WireKind.message &&
          env.body == 'first real message';
    }), isTrue);
  });
}
