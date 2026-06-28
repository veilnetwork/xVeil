import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

NodeId _id(int s) => NodeId(Uint8List.fromList(List.filled(32, s)));

/// Minimal transport — the clear path never touches the wire.
class _Noop implements VeilTransport {
  _Noop(this._me);
  final NodeId _me;
  final _in = StreamController<InboundMessage>.broadcast();
  @override
  Future<NodeId> nodeId() async => _me;
  @override
  Stream<InboundMessage> messages() => _in.stream;
  @override
  Future<void> send(NodeId dst, Uint8List payload, {bool anonymous = false}) async {}
  @override
  Future<void> sendWithReply(NodeId dst, Uint8List payload) async {}
  @override
  Future<void> sendReply(int replyId, Uint8List payload) async {}
  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() async => _in.close();
}

SpaceOpener _mem() {
  final s = FakeKvLogStore();
  return ({required password, required bool create}) => s;
}

/// A fake that rejects an over-large commit exactly like the real at-rest store
/// (which encodes one commit into a single ~4 KB batch with no auto-split). Lets
/// the clear path's recursive batch-split actually be exercised — a regression
/// once made it recurse into ITSELF (Stack Overflow) instead of splitting.
class _CapCommitStore extends FakeKvLogStore {
  _CapCommitStore(this.maxOps);
  final int maxOps;
  @override
  int commit(List<KvLogOp> ops) {
    if (ops.length > maxOps) {
      throw hv.HvException('PayloadTooLarge', 'too many records for one batch');
    }
    return super.commit(ops);
  }
}

void main() {
  test('clearConversation erases the history AND emits on changes '
      '(so messagesProvider reloads the now-empty chat)', () async {
    final me = _id(1);
    final peer = _id(2);
    final storage = HiddenVolumeStorage(_mem());
    await storage.open(password: 'p', createIfMissing: true);
    await storage.upsertContact(Contact(nodeId: peer, status: ContactStatus.accepted));
    final svc = MessagingService(_Noop(me), storage)..start();
    addTearDown(svc.dispose);

    // Seed a couple of messages in the conversation.
    await svc.sendText(peer, 'hello');
    await svc.sendText(peer, 'world');
    expect((await storage.loadMessages(peer.hex)).length, greaterThanOrEqualTo(2),
        reason: 'precondition: the chat has messages');

    // The UI re-renders only when the service emits on `changes`. Calling
    // storage.clearMessages directly (the old chat_actions path) cleared the
    // store but never signalled, so the screen kept showing the old messages.
    final changed = svc.changes.first.timeout(const Duration(seconds: 2));

    await svc.clearConversation(peer);

    await changed; // throws on timeout if the signal never fired
    expect((await storage.loadMessages(peer.hex)), isEmpty,
        reason: 'history is erased');
    // The contact stays — the conversation remains, just emptied.
    expect(await storage.getContact(peer), isNotNull);
  });

  test('clearConversation succeeds on a chat too big for ONE commit '
      '(recursive batch-split; no PayloadTooLarge, no stack overflow)', () async {
    final me = _id(1);
    final peer = _id(2);
    // Reject any commit over 8 records — a whole-chat tombstone of 40 messages
    // is one ~40-record commit, so the clear MUST split it to get through.
    final cap = _CapCommitStore(8);
    final storage = HiddenVolumeStorage(
        ({required password, required bool create}) => cap);
    await storage.open(password: 'p', createIfMissing: true);
    await storage.upsertContact(
        Contact(nodeId: peer, status: ContactStatus.accepted));
    final svc = MessagingService(_Noop(me), storage)..start();
    addTearDown(svc.dispose);
    for (var i = 0; i < 40; i++) {
      await svc.sendText(peer, 'm$i'); // small per-message commits — all fit
    }
    expect((await storage.loadMessages(peer.hex)).length,
        greaterThanOrEqualTo(40));

    // The one big tombstone commit overflows the cap; _commitBatched must split
    // it recursively until each batch fits — NOT recurse into itself (the typo
    // that stack-overflowed on device) and NOT abort with PayloadTooLarge.
    await svc.clearConversation(peer);

    expect((await storage.loadMessages(peer.hex)), isEmpty,
        reason: 'the oversized clear committed in batches');
  });
}
