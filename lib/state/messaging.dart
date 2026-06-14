import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/ids.dart';
import '../data/storage/storage.dart';
import '../data/transport/veil_transport.dart';
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

  Future<void> _onInbound(InboundMessage m) async {
    final convId = m.src.hex;
    await _storage.upsertContact(Contact(nodeId: m.src));
    await _storage.appendMessage(Message(
      id: _uuid.v4(),
      conversationId: convId,
      direction: MessageDirection.incoming,
      body: utf8.decode(m.payload, allowMalformed: true),
      timestamp: DateTime.now(),
      status: MessageStatus.delivered,
    ));
    _signal();
  }

  Future<void> sendText(NodeId dst, String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final convId = dst.hex;
    await _storage.upsertContact(Contact(nodeId: dst));
    await _storage.appendMessage(Message(
      id: _uuid.v4(),
      conversationId: convId,
      direction: MessageDirection.outgoing,
      body: trimmed,
      timestamp: DateTime.now(),
      status: MessageStatus.sent,
    ));
    _signal();
    await _transport.send(dst, Uint8List.fromList(utf8.encode(trimmed)));
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
