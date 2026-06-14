import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/ids.dart';
import '../data/storage/storage.dart';
import '../data/transport/veil_transport.dart';
import '../data/transport/wire_envelope.dart';
import '../domain/chat.dart';
import 'providers.dart';

const _uuid = Uuid();

/// Wires the [VeilTransport] inbound stream into [Storage] and exposes a send
/// path. Persists every message, then signals [changes] so the read providers
/// refresh. Intentionally Riverpod-free (no Ref) — it owns a plain broadcast
/// stream, which keeps it testable and avoids invalidating providers from
/// async stream callbacks.
class MessagingService {
  MessagingService(this._transport, this._storage);

  final VeilTransport _transport;
  final Storage _storage;
  final _changes = StreamController<void>.broadcast();
  StreamSubscription<InboundMessage>? _sub;

  /// Emits whenever stored conversations/messages change.
  Stream<void> get changes => _changes.stream;

  void start() {
    _sub ??= _transport.messages().listen(_onInbound);
  }

  void _signal() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> _store(
    NodeId peer,
    MessageDirection dir,
    String body,
    MessageStatus status,
  ) {
    return _storage.appendMessage(Message(
      id: _uuid.v4(),
      conversationId: peer.hex,
      direction: dir,
      body: body,
      timestamp: DateTime.now(),
      status: status,
    ));
  }

  Future<void> _setStatus(NodeId peer, ContactStatus status) async {
    final existing = await _storage.getContact(peer);
    await _storage.upsertContact(
      (existing ?? Contact(nodeId: peer)).copyWith(status: status),
    );
  }

  Future<void> _onInbound(InboundMessage m) async {
    final env = WireEnvelope.decode(m.payload);
    final existing = await _storage.getContact(m.src);
    if (existing?.status == ContactStatus.blocked) return; // drop blocked

    switch (env.kind) {
      case WireKind.request:
        // Don't downgrade an already-accepted contact who re-requests.
        if (existing?.status != ContactStatus.accepted) {
          await _setStatus(m.src, ContactStatus.pendingIncoming);
        }
        if (env.body.isNotEmpty) {
          await _store(m.src, MessageDirection.incoming, env.body,
              MessageStatus.delivered);
        }
      case WireKind.accept:
        // Only honour an accept for a request we actually sent.
        if (existing?.status == ContactStatus.pendingOutgoing) {
          await _setStatus(m.src, ContactStatus.accepted);
        } else {
          return;
        }
      case WireKind.message:
        // Consent gate: only deliver from accepted peers; drop the rest.
        if (existing?.status != ContactStatus.accepted) return;
        await _store(m.src, MessageDirection.incoming, env.body,
            MessageStatus.delivered);
    }
    _signal();
  }

  /// Ask [dst] to connect, with an optional [greeting]. We can't freely
  /// message them until they accept.
  Future<void> sendRequest(NodeId dst, String greeting) async {
    final text = greeting.trim();
    await _setStatus(dst, ContactStatus.pendingOutgoing);
    if (text.isNotEmpty) {
      await _store(dst, MessageDirection.outgoing, text, MessageStatus.sent);
    }
    _signal();
    await _transport.send(dst, WireEnvelope.request(text).encode());
  }

  /// Approve an incoming request — both sides can now message freely.
  Future<void> acceptContact(NodeId peer) async {
    await _setStatus(peer, ContactStatus.accepted);
    _signal();
    await _transport.send(peer, const WireEnvelope.accept().encode());
  }

  /// Decline / block an incoming request — their messages are dropped.
  Future<void> blockContact(NodeId peer) async {
    await _setStatus(peer, ContactStatus.blocked);
    _signal();
  }

  Future<void> sendText(NodeId dst, String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    // Consent gate — only free-message an accepted contact.
    final contact = await _storage.getContact(dst);
    if (contact == null || contact.status != ContactStatus.accepted) return;
    await _store(dst, MessageDirection.outgoing, trimmed, MessageStatus.sent);
    _signal();
    await _transport.send(dst, WireEnvelope.message(trimmed).encode());
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    await _changes.close();
  }
}

/// Constructed once and kept alive for the session; starts listening eagerly.
final messagingServiceProvider = Provider<MessagingService>((ref) {
  final service = MessagingService(
    ref.watch(veilTransportProvider),
    ref.watch(storageProvider),
  );
  service.start();
  ref.onDispose(service.dispose);
  return service;
});

/// Conversations, re-loaded on first build and whenever the service signals a
/// change. StreamProvider yields the same AsyncValue the UI already consumes.
final conversationsProvider = StreamProvider<List<Conversation>>((ref) async* {
  final service = ref.watch(messagingServiceProvider);
  final storage = ref.watch(storageProvider);
  yield await storage.loadConversations();
  await for (final _ in service.changes) {
    yield await storage.loadConversations();
  }
});

final messagesProvider =
    StreamProvider.family<List<Message>, String>((ref, conversationId) async* {
  final service = ref.watch(messagingServiceProvider);
  final storage = ref.watch(storageProvider);
  yield await storage.loadMessages(conversationId);
  await for (final _ in service.changes) {
    yield await storage.loadMessages(conversationId);
  }
});

/// The stored contact (with relationship status) for a peer, refreshed on
/// every change. Null until we have a record of them.
final contactProvider =
    StreamProvider.family<Contact?, String>((ref, peerHex) async* {
  final service = ref.watch(messagingServiceProvider);
  final storage = ref.watch(storageProvider);
  final id = NodeId.fromHex(peerHex);
  yield await storage.getContact(id);
  await for (final _ in service.changes) {
    yield await storage.getContact(id);
  }
});
