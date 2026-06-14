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

/// Wires the [VeilTransport] inbound stream into [Storage] and exposes a
/// send path. Persists every message, then invalidates the read providers so
/// the UI refreshes. This is the single seam where transport meets storage.
class MessagingService {
  MessagingService(this._transport, this._storage, this._ref);

  final VeilTransport _transport;
  final Storage _storage;
  final Ref _ref;
  StreamSubscription<InboundMessage>? _sub;

  void start() {
    _sub ??= _transport.messages().listen(_onInbound);
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
    _ref.invalidate(conversationsProvider);
    _ref.invalidate(messagesProvider(convId));
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
    _ref.invalidate(conversationsProvider);
    _ref.invalidate(messagesProvider(convId));
    await _transport.send(dst, Uint8List.fromList(utf8.encode(trimmed)));
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
  }
}

/// Constructed once and kept alive for the session; starts listening eagerly.
final messagingServiceProvider = Provider<MessagingService>((ref) {
  final service = MessagingService(
    ref.watch(veilTransportProvider),
    ref.watch(storageProvider),
    ref,
  );
  service.start();
  ref.onDispose(service.dispose);
  return service;
});

final conversationsProvider = FutureProvider<List<Conversation>>((ref) async {
  // Ensure inbound wiring is live whenever the chat list is shown.
  ref.watch(messagingServiceProvider);
  return ref.watch(storageProvider).loadConversations();
});

final messagesProvider =
    FutureProvider.family<List<Message>, String>((ref, conversationId) async {
  ref.watch(messagingServiceProvider);
  return ref.watch(storageProvider).loadMessages(conversationId);
});
