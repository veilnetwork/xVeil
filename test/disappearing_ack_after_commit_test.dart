import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

/// The generic inbound gate ACKs a durable frame and remembers it as processed
/// BEFORE the specialised handler runs. The ack is what retires the frame from
/// the sender's outbox, so for `disappearingSet` an ack that goes first turns a
/// failed apply into a permanent divergence: the sender believes the
/// conversation is on a one-minute window and this device keeps everything,
/// forever, because the frame is also remembered and every re-drive is dropped.
///
/// Ten frame kinds already defer their ack until after persistence. This is the
/// one whose whole content is a durable write and which was not among them.
NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

class _Link implements VeilTransport {
  _Link(this._me);
  final NodeId _me;
  final _inbound = StreamController<InboundMessage>.broadcast();

  /// Everything this side put on the wire. The ack is in here or it is not.
  final sent = <Uint8List>[];
  int declined = 0;

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
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    sent.add(payload);
  }

  void inject(NodeId from, Uint8List payload) => _inbound.add(
    InboundMessage(
      src: from,
      payload: payload,
      provenance: SenderProvenance.sessionPeer,
      onDeclined: (_) => declined++,
    ),
  );

  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() async => _inbound.close();
}

/// Fail the actual contact commit, regardless of which storage API prepared it.
class _FlakyStore extends FakeKvLogStore {
  bool failContactWrites = false;
  @override
  int commit(List<KvLogOp> ops) {
    if (failContactWrites &&
        ops.whereType<PutOp>().any((op) => op.namespace == Ns.contacts)) {
      throw StateError('the container refused the write');
    }
    return super.commit(ops);
  }
}

int _sequence = 0;
Future<void> _settle(
  _Link link,
  MessagingService messaging,
  NodeId peer,
) async {
  final id = 'policy-barrier-${++_sequence}';
  final done = Completer<void>();
  messaging.onCallSignal = (_, signal) {
    if (signal.callId == id) done.complete();
  };
  link.inject(
    peer,
    WireEnvelope.callSignal(
      CallSignal(callId: id, type: CallSignalType.answer).encode(),
    ).encode(),
  );
  await done.future;
  messaging.onCallSignal = null;
}

void main() {
  test(
    'a disappearing window whose write fails is re-driven, not lost',
    () async {
      final a = _id(1);
      final b = _id(2);
      final link = _Link(b);
      final backing = _FlakyStore();
      final storage = HiddenVolumeStorage(
        ({required password, required bool create}) => backing,
      );
      await storage.open(password: 'b', createIfMissing: true);
      final messaging = MessagingService(link, storage)..start();
      addTearDown(messaging.dispose);
      await storage.upsertContact(
        Contact(nodeId: a, status: ContactStatus.accepted),
      );

      // A one-minute window, stamped now so the believable-clock check passes.
      final frame = WireEnvelope(
        WireKind.disappearingSet,
        jsonEncode({
          'v': 1,
          'ttl': 60,
          'ts': DateTime.now().millisecondsSinceEpoch,
        }),
      ).withFrameId('fid-disappearing-1').encode();

      backing.failContactWrites = true;
      link.sent.clear();
      link.inject(a, frame);
      await _settle(link, messaging, a);

      expect(
        (await storage.getContact(a))?.disappearingTtlSeconds,
        isNull,
        reason: 'the write failed, so nothing should have been adopted',
      );
      expect(
        link.sent,
        isEmpty,
        reason:
            'a frame whose durable apply failed must NOT be acked — the ack '
            'retires it from the sender and nothing would ever retry',
      );

      expect(
        link.declined,
        1,
        reason: 'a failed durable policy must not authorize relay deletion',
      );

      // The container recovers and the sender, never having been acked, sends
      // the same frame again. This is the whole point: it must be processed,
      // not dropped as already-seen.
      backing.failContactWrites = false;
      link.inject(a, frame);
      await _settle(link, messaging, a);

      expect(
        (await storage.getContact(a))?.disappearingTtlSeconds,
        60,
        reason: 'the re-drive must land the window the sender believes is set',
      );
      expect(
        link.sent,
        isNotEmpty,
        reason: 'and now that it is durable, the sender may retire it',
      );
      expect(
        link.declined,
        1,
        reason: 'successful re-drive adds no new refusal',
      );
    },
  );
}
