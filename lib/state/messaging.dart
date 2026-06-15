import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/ids.dart';
import '../data/storage/storage.dart';
import '../data/transport/veil_transport.dart';
import '../data/transport/wire_envelope.dart';
import '../domain/chat.dart';
import '../domain/file_transfer.dart';
import 'providers.dart';

const _uuid = Uuid();

/// Raw bytes per wire chunk. Base64 + JSON wrap keeps the datagram modest.
const _wireChunkBytes = 6000;

/// Hard ceiling on an inbound file we will buffer in memory before it is
/// stored. A backstop so a hostile (but accepted) peer cannot exhaust memory
/// with a giant transfer. Purely a local safety bound — tune to product taste;
/// it is not a protocol constant and both sides need not agree on it.
const kMaxIncomingFileBytes = 100 * 1024 * 1024; // 100 MiB

/// Max simultaneous inbound transfers we will buffer. Without this the
/// per-transfer [kMaxIncomingFileBytes] cap is not enough: a peer could open
/// many transfers at once and still exhaust memory. Together they bound the
/// worst-case buffered total to ~this × [kMaxIncomingFileBytes]. Tunable.
const kMaxConcurrentIncomingFiles = 8;

/// In-flight inbound file reassembly state.
class _Incoming {
  _Incoming({required this.src, required this.name, required this.reasm});
  final NodeId src;
  final String? name;
  final FileReassembler reasm;
}

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
  final Map<String, _Incoming> _inFlight = {};

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
    MessageStatus status, {
    String? fileId,
    String? fileName,
  }) {
    return _storage.appendMessage(Message(
      id: _uuid.v4(),
      conversationId: peer.hex,
      direction: dir,
      body: body,
      timestamp: DateTime.now(),
      status: status,
      fileId: fileId,
      fileName: fileName,
    ));
  }

  Future<void> _setStatus(NodeId peer, ContactStatus status) async {
    final existing = await _storage.getContact(peer);
    await _storage.upsertContact(
      (existing ?? Contact(nodeId: peer)).copyWith(status: status),
    );
  }

  Future<void> _onInbound(InboundMessage m) async {
    try {
      await _dispatch(m);
    } catch (_) {
      // A hostile or corrupt datagram (malformed JSON, missing/ill-typed
      // fields, bad base64) must never throw out of the stream listener and
      // disrupt delivery for everyone else — drop it silently.
    }
  }

  Future<void> _dispatch(InboundMessage m) async {
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
      case WireKind.fileMeta:
        if (existing?.status != ContactStatus.accepted) return;
        final meta = parseFileMeta(env.body);
        // Refuse over-budget transfers up front (the declared size is a hint;
        // the per-chunk guard below enforces it even if the peer lies here).
        if (meta.size != null && meta.size! > kMaxIncomingFileBytes) return;
        // Bound concurrent transfers so the per-transfer cap actually bounds
        // total memory. A re-sent meta for a known transfer is fine (no growth);
        // a new one is dropped when we are already at capacity.
        if (!_inFlight.containsKey(meta.transferId) &&
            _inFlight.length >= kMaxConcurrentIncomingFiles) {
          return;
        }
        _inFlight[meta.transferId] = _Incoming(
          src: m.src,
          name: meta.name,
          reasm: FileReassembler(),
        );
        return; // nothing to show until the file completes
      case WireKind.fileChunk:
        if (existing?.status != ContactStatus.accepted) return;
        final frame = parseFileChunk(env.body);
        final inc = _inFlight[frame.transferId];
        // Unknown transfer (chunk before meta), or a different peer trying to
        // contribute to someone else's in-flight transfer — drop it.
        if (inc == null || inc.src != m.src) return;
        inc.reasm.add(FileChunk(
          transferId: frame.transferId,
          index: frame.index,
          total: frame.total,
          data: frame.data,
        ));
        // Enforce the memory budget even if the peer lied about size — abort
        // and discard the partial transfer rather than buffer unboundedly.
        if (inc.reasm.bufferedBytes > kMaxIncomingFileBytes) {
          _inFlight.remove(frame.transferId);
          return;
        }
        if (!inc.reasm.isComplete) return; // wait for the rest
        await _storage.storeFile(
            frame.transferId, inc.reasm.assemble(), name: inc.name);
        await _store(m.src, MessageDirection.incoming, '📎 ${inc.name ?? 'file'}',
            MessageStatus.delivered, fileId: frame.transferId, fileName: inc.name);
        _inFlight.remove(frame.transferId);
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

  /// Send a file to [dst] (gated to accepted contacts). Stores a local copy,
  /// records an outgoing file message, then streams the bytes as fileMeta +
  /// fileChunk envelopes.
  Future<void> sendFile(NodeId dst, Uint8List bytes, String name) async {
    final contact = await _storage.getContact(dst);
    if (contact == null || contact.status != ContactStatus.accepted) return;

    final fileId = _uuid.v4();
    await _storage.storeFile(fileId, bytes, name: name);
    await _store(dst, MessageDirection.outgoing, '📎 $name', MessageStatus.sent,
        fileId: fileId, fileName: name);
    _signal();

    final chunks = chunkBytes(bytes, transferId: fileId, maxChunk: _wireChunkBytes);
    await _transport.send(
      dst,
      fileMetaEnvelope(
        transferId: fileId,
        name: name,
        size: bytes.length,
        count: chunks.length,
      ).encode(),
    );
    for (final c in chunks) {
      await _transport.send(
        dst,
        fileChunkEnvelope(
          transferId: c.transferId,
          index: c.index,
          total: c.total,
          data: c.data,
        ).encode(),
      );
    }
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
