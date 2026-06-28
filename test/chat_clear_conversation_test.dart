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
}
