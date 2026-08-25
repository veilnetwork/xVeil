import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/node/ratchet_ffi.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';
import 'package:xveil/state/ratchet_persistence.dart';

/// The reservation is what records, durably, that this send's message key and
/// nonce are spoken for. It used to log its own failure and let the ciphertext
/// go out anyway — which is the exact state it was added to prevent, reported
/// as success (report14 X14-H2).
///
/// A refused send costs a delivery the outbox still holds. A published one
/// whose key has no durable record costs a nonce reused for a different
/// plaintext, and anybody holding both ciphertexts gets the XOR of them.
NodeId _id(int fill) => NodeId(Uint8List.fromList(List.filled(32, fill)));

class _Link implements VeilTransport {
  _Link(this._me);
  final NodeId _me;
  final _inbound = StreamController<InboundMessage>.broadcast();
  /// `(destination, payload)` — the destination matters: a mailbox deposit is
  /// sealed by a different mechanism and spends no ratchet key, so it going
  /// out is not what this test forbids.
  final sent = <(NodeId, Uint8List)>[];

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
      {bool anonymous = false}) async {
    sent.add((dst, payload));
  }

  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() async => _inbound.close();
}

/// Refuses the one write the reservation is.
class _RefusesSettings extends HiddenVolumeStorage {
  _RefusesSettings(FakeKvLogStore backing)
      : super(({required password, required bool create}) => backing);

  bool refuse = false;

  @override
  Future<void> putSetting(String key, String value) {
    if (refuse && key.startsWith('ratchet_reserve:')) {
      throw StateError('the container refused the reservation');
    }
    return super.putSetting(key, value);
  }
}

class _Node implements RatchetStateHandle {
  final Map<String, int> _sent = {};
  int _version = 0;

  static String _hex(Uint8List k) =>
      [for (final b in k) b.toRadixString(16).padLeft(2, '0')].join();
  static Uint8List _chain(String hex) => Uint8List.fromList(
    List<int>.generate(32, (i) => hex.codeUnitAt(i % hex.length) & 0xff),
  );

  void seal(Uint8List key) {
    _sent[_hex(key)] = (_sent[_hex(key)] ?? 0) + 1;
    _version++;
  }

  @override
  RatchetSendPosition? sendPosition(Uint8List key) {
    final n = _sent[_hex(key)];
    return n == null ? null : RatchetSendPosition(_chain(_hex(key)), n);
  }

  @override
  int skipSendTo(Uint8List key, RatchetSendPosition to) => 0;
  @override
  int stateVersion() => _version;
  @override
  ({List<Uint8List> keys, int remaining, int generation}) peekDirty(int max) =>
      (keys: const [], remaining: 0, generation: _version);
  @override
  int ackDirty(List<Uint8List> keys, int generation) => 0;
  @override
  List<Uint8List> list() => [for (final k in _sent.keys) _unhex(k)];
  @override
  Uint8List? export(Uint8List key) => Uint8List(2);
  @override
  bool import(Uint8List key, Uint8List blob) => true;
  @override
  bool forget(Uint8List key) => _sent.remove(_hex(key)) != null;
  @override
  int expire() => 0;
  @override
  void close() {}

  static Uint8List _unhex(String hex) => Uint8List.fromList([
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}

Uint8List _convKey({required int peerNode}) {
  final out = Uint8List(kRatchetKeyLen);
  for (var i = 0; i < 32; i++) {
    out[kRatchetKeyPeerNodeOffset + i] = peerNode;
  }
  return out;
}

void main() {
  test('a reservation that cannot be written stops the send', () async {
    final me = _id(1);
    // TWO peers, and the reason is the reservation's own arithmetic: one write
    // covers `reserveAhead` indices, so a second send to the SAME peer is
    // already inside what is on disk and correctly writes nothing at all. It
    // would never meet the refusal, and a test built that way passes with the
    // guard removed. The refused send has to be one that genuinely needs a
    // write — a conversation with no reservation standing.
    final warmup = _id(2);
    final peer = _id(3);
    final link = _Link(me);
    final backing = FakeKvLogStore();
    final storage = _RefusesSettings(backing);
    await storage.open(password: 'pw', createIfMissing: true);
    for (final p in [warmup, peer]) {
      await storage.upsertContact(
        Contact(nodeId: p, status: ContactStatus.accepted),
      );
    }

    final node = _Node();
    final messaging = MessagingService(link, storage)
      ..ratchet = RatchetPersistence(native: node, storage: storage)
      ..start();
    addTearDown(messaging.dispose);

    // Conversations that have sealed before: there IS a position to reserve,
    // which is the case the guard is about. A chain that has never sealed
    // reserves nothing and is not a failure.
    node.seal(_convKey(peerNode: 2));
    node.seal(_convKey(peerNode: 3));

    // Vacuity guard first: this harness must actually put frames on the wire,
    // or "nothing was sent" below proves nothing. An earlier version of this
    // test skipped it and passed with the guard removed.
    await messaging.sendText(warmup, 'this one may go out');
    expect(
      link.sent.where((s) => s.$1 == warmup),
      isNotEmpty,
      reason: 'the fixture sends nothing at all, so the assertion below is '
          'about the fixture and not about the guard',
    );

    storage.refuse = true;
    link.sent.clear();
    // `sendText` itself does NOT throw, and that is the durable outbox doing
    // its job: it catches the refusal and keeps the frame queued for a retry
    // once storage recovers. What must be true is on the WIRE.
    try {
      await messaging.sendText(peer, 'this must not go out');
    } catch (_) {}
    expect(
      link.sent.where((s) => s.$1 == peer),
      isEmpty,
      reason:
          'a ciphertext published with no durable record of its key is the '
          'nonce reuse this guard exists to prevent — anything else the send '
          'fans out to (a mailbox deposit) spends no ratchet key and may go',
    );
  });
}
