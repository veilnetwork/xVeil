import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/ids.dart';
import '../data/node/node_controller.dart';
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
  MessagingService(this._transport, this._storage, {this._anonymous = false});

  final VeilTransport _transport;
  final Storage _storage;

  /// Whether this identity routes over the onion rendezvous (sender-location
  /// hidden). Fixed per identity at boot from its roster `anonymous` flag — an
  /// anonymous identity sends EVERYTHING (messages, acks, accepts, file frames)
  /// anonymously, fail-closed, so no single frame leaks its network location.
  final bool _anonymous;

  /// Single egress point so every outbound frame honours [_anonymous]. The real
  /// transport routes over an onion circuit when anonymous (throwing rather than
  /// leaking if it can't); the loopback fake ignores the flag.
  Future<void> _send(NodeId dst, Uint8List payload) =>
      _transport.send(dst, payload, anonymous: _anonymous);
  final _changes = StreamController<void>.broadcast();
  StreamSubscription<InboundMessage>? _sub;
  Timer? _retryTimer;
  bool _flushing = false;
  final Map<String, _Incoming> _inFlight = {};

  /// How often to re-send still-un-acked messages. Covers the case where the
  /// RECIPIENT was offline (e.g. the peer switched to another identity, taking
  /// that identity's node down) — our node-connect flush only fires on OUR
  /// reconnect, so without this a message to a temporarily-offline peer would
  /// never be retried. Bounded: a message stops being re-sent once acked.
  static const _retryInterval = Duration(seconds: 15);

  /// Emits whenever stored conversations/messages change.
  Stream<void> get changes => _changes.stream;

  void start() {
    _sub ??= _transport.messages().listen(_onInbound);
    _retryTimer ??= Timer.periodic(_retryInterval, (_) => _retryFlush());
  }

  Future<void> _retryFlush() async {
    if (_flushing) return; // don't stack overlapping flushes
    _flushing = true;
    try {
      await flushOutbox();
    } catch (_) {
      // Transport hiccup — the next tick retries.
    } finally {
      _flushing = false;
    }
  }

  void _signal() {
    if (!_changes.isClosed) _changes.add(null);
  }

  /// Persist a message and return its id. [id] lets the receiver reuse the
  /// SENDER's id (so re-sends dedup) instead of minting a fresh one.
  Future<String> _store(
    NodeId peer,
    MessageDirection dir,
    String body,
    MessageStatus status, {
    String? fileId,
    String? fileName,
    String? id,
  }) async {
    final msgId = id ?? _uuid.v4();
    await _storage.appendMessage(Message(
      id: msgId,
      conversationId: peer.hex,
      direction: dir,
      body: body,
      timestamp: DateTime.now(),
      status: status,
      fileId: fileId,
      fileName: fileName,
    ));
    return msgId;
  }

  Future<bool> _hasMessage(NodeId peer, String id) async {
    final msgs = await _storage.loadMessages(peer.hex);
    return msgs.any((m) => m.id == id);
  }

  /// True only if [id] is a message we hold from [peer] that THEY sent us
  /// (incoming). The authorization gate for peer-driven edit/delete: a peer may
  /// only modify their own messages, never our outgoing ones.
  Future<bool> _isIncomingFrom(NodeId peer, String id) async {
    for (final m in await _storage.loadMessages(peer.hex)) {
      if (m.id == id) return m.direction == MessageDirection.incoming;
    }
    return false;
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
        if (env.body.isNotEmpty &&
            !(env.id != null && await _storage.isMessageDeleted(env.id!))) {
          // Store the greeting under the REQUEST's id so a later outbox re-send
          // of the same greeting (as a WireKind.message) dedups instead of
          // creating a second copy. Skip if we already deleted this id (don't
          // resurrect, same as the message case).
          await _store(m.src, MessageDirection.incoming, env.body,
              MessageStatus.delivered, id: env.id);
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
        final id = env.id;
        // Dedup re-sent messages (the sender's local outbox re-sends un-acked
        // ones): if we already have this id, just re-ack so they stop.
        if (id != null && await _hasMessage(m.src, id)) {
          await _send(m.src, WireEnvelope.ack(id).encode());
          return;
        }
        // Deniability: if we DELETED this message, a re-delivery must NOT
        // resurrect it. Re-ack so the sender stops re-sending, then drop.
        if (id != null && await _storage.isMessageDeleted(id)) {
          await _send(m.src, WireEnvelope.ack(id).encode());
          return;
        }
        await _store(m.src, MessageDirection.incoming, env.body,
            MessageStatus.delivered, id: id);
        if (id != null) {
          await _send(m.src, WireEnvelope.ack(id).encode());
        }
      case WireKind.ack:
        // The peer confirms delivery of our message [env.id] — stop re-sending.
        if (env.id != null) {
          await _storage.markMessageStatus(env.id!, MessageStatus.delivered);
        }
      case WireKind.edit:
        // The peer edited a message THEY sent us. Apply only to an INCOMING
        // message we hold from this peer — a peer must never be able to rewrite
        // our own outgoing messages (the id travels on the wire, so they know
        // it; the direction check is the real authorization gate).
        if (existing?.status != ContactStatus.accepted) return;
        if (env.id != null && await _isIncomingFrom(m.src, env.id!)) {
          await _storage.editMessage(env.id!, env.body);
          await _storage.scrubDeleted();
        }
      case WireKind.del:
        // The peer unsent a message THEY sent us — purge + scrub our copy too.
        // Same authorization gate: only their incoming messages, never ours.
        if (existing?.status != ContactStatus.accepted) return;
        if (env.id != null && await _isIncomingFrom(m.src, env.id!)) {
          await _storage.deleteMessage(env.id!);
          await _storage.scrubDeleted();
        }
      case WireKind.fileMeta:
        if (existing?.status != ContactStatus.accepted) return;
        final meta = parseFileMeta(env.body);
        // Refuse over-budget transfers up front (the declared size is a hint;
        // the per-chunk guard below enforces it even if the peer lies here).
        if (meta.size != null && meta.size! > kMaxIncomingFileBytes) return;
        // Ignore a duplicate meta for a transfer we are ALREADY tracking —
        // overwriting it would reset the reassembler and discard chunks already
        // received (sendFile mints a fresh id per transfer, so the same id never
        // legitimately restarts).
        if (_inFlight.containsKey(meta.transferId)) return;
        // Bound concurrent transfers so the per-transfer cap actually bounds
        // total memory: a new transfer is dropped when we are already at
        // capacity.
        if (_inFlight.length >= kMaxConcurrentIncomingFiles) return;
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
        final tid = frame.transferId;
        _inFlight.remove(tid);
        // Use the transfer id AS the message id (symmetry with the sender), so
        // a re-delivered transfer dedups and — crucially — a file we DELETED
        // never resurrects (deniability: deleted stays deleted, same guard the
        // text path has). Re-ack either way so the sender stops re-sending.
        if (await _hasMessage(m.src, tid) || await _storage.isMessageDeleted(tid)) {
          await _send(m.src, WireEnvelope.ack(tid).encode());
          return;
        }
        await _storage.storeFile(tid, inc.reasm.assemble(), name: inc.name);
        await _store(m.src, MessageDirection.incoming, '📎 ${inc.name ?? 'file'}',
            MessageStatus.delivered,
            fileId: tid, fileName: inc.name, id: tid);
        // Ack the completed transfer so the sender's file message flips
        // sent -> delivered — the same delivery feedback text messages get.
        await _send(m.src, WireEnvelope.ack(tid).encode());
    }
    _signal();
  }

  /// Ask [dst] to connect, with an optional [greeting]. We can't freely
  /// message them until they accept.
  Future<void> sendRequest(NodeId dst, String greeting) async {
    final text = greeting.trim();
    await _setStatus(dst, ContactStatus.pendingOutgoing);
    // Tag the greeting with a stable id shared between our stored copy and the
    // request on the wire. The greeting is stored `sent`, so the outbox re-sends
    // it as a WireKind.message after the peer accepts; without a shared id the
    // recipient (who stored the request body) couldn't dedup it and would show
    // the greeting twice.
    final id = _uuid.v4();
    if (text.isNotEmpty) {
      await _store(dst, MessageDirection.outgoing, text, MessageStatus.sent,
          id: id);
    }
    _signal();
    await _send(dst, WireEnvelope.request(text, id: id).encode());
  }

  /// Approve an incoming request — both sides can now message freely.
  Future<void> acceptContact(NodeId peer) async {
    await _setStatus(peer, ContactStatus.accepted);
    _signal();
    await _send(peer, const WireEnvelope.accept().encode());
  }

  /// Decline / block an incoming request — their messages are dropped.
  Future<void> blockContact(NodeId peer) async {
    await _setStatus(peer, ContactStatus.blocked);
    _signal();
  }

  /// Mark a conversation read (its unread badge resets) and refresh the UI.
  /// Best-effort — never throw from a screen's open hook (e.g. storage not yet
  /// open in a test/loopback context).
  Future<void> markRead(String conversationId) async {
    try {
      await _storage.markRead(conversationId);
      _signal();
    } catch (_) {
      // storage locked / unavailable — skip the badge clear.
    }
  }

  Future<void> sendText(NodeId dst, String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    // Consent gate — only free-message an accepted contact.
    final contact = await _storage.getContact(dst);
    if (contact == null || contact.status != ContactStatus.accepted) return;
    final id =
        await _store(dst, MessageDirection.outgoing, trimmed, MessageStatus.sent);
    _signal();
    // Stays `sent` until the peer acks; the local outbox re-sends un-acked ones
    // on reconnect, so a message written offline goes out when we come back.
    await _send(dst, WireEnvelope.message(trimmed, id: id).encode());
  }

  /// Re-send every outgoing text message still awaiting a delivery ack (i.e.
  /// `sent`, not yet `delivered`) to accepted contacts. Driven on node-connect /
  /// app-start so messages composed while offline are delivered on reconnect;
  /// the receiver dedups by id, so re-sending an already-delivered one is safe.
  Future<void> flushOutbox() async {
    final convs = await _storage.loadConversations();
    for (final conv in convs) {
      if (conv.peer.status != ContactStatus.accepted) continue;
      final msgs = await _storage.loadMessages(conv.id);
      for (final m in msgs) {
        if (m.direction == MessageDirection.outgoing &&
            m.status == MessageStatus.sent &&
            !m.isFile) {
          await _send(
              conv.peer.nodeId, WireEnvelope.message(m.body, id: m.id).encode());
        }
      }
    }
  }

  /// Delete a message from THIS device only and scrub it from the container so
  /// the plaintext is no longer recoverable — works for a received message too
  /// (the highest-value deniability operation: purge what was sent to you). The
  /// peer's copy is untouched; use [deleteForEveryone] to also unsend it.
  Future<void> deleteMessageLocally(String messageId) async {
    await _storage.deleteMessage(messageId);
    // Scrub immediately: the whole point is the text is gone NOW, before any
    // coercion — not merely hidden behind a tombstone.
    await _storage.scrubDeleted();
    _signal();
  }

  /// Delete one of OUR sent messages here AND ask the recipient to delete their
  /// copy (best-effort: if they are offline the request is simply lost, and we
  /// can never guarantee they hadn't already copied the text). No-op for a
  /// received message — you can only unsend your own.
  Future<void> deleteForEveryone(String messageId) async {
    final msg = await _find(messageId);
    if (msg == null || msg.direction != MessageDirection.outgoing) return;
    await deleteMessageLocally(messageId);
    await _send(NodeId.fromHex(msg.conversationId),
        WireEnvelope.del(messageId).encode());
  }

  /// Edit the body of one of OUR sent messages: replace the stored text in
  /// place (the prior text is scrubbed), mark it edited, and propagate the new
  /// text to the recipient (best-effort). No-op for a received message.
  Future<void> editOwnMessage(String messageId, String newBody) async {
    final trimmed = newBody.trim();
    if (trimmed.isEmpty) return;
    final msg = await _find(messageId);
    if (msg == null || msg.direction != MessageDirection.outgoing) return;
    await _storage.editMessage(messageId, trimmed);
    await _storage.scrubDeleted();
    _signal();
    await _send(NodeId.fromHex(msg.conversationId),
        WireEnvelope.edit(messageId, trimmed).encode());
  }

  /// Locate a stored message by id across conversations (used before an
  /// edit/delete needs its conversation / direction). Null if not found.
  Future<Message?> _find(String messageId) async {
    for (final c in await _storage.loadConversations()) {
      for (final m in await _storage.loadMessages(c.id)) {
        if (m.id == messageId) return m;
      }
    }
    return null;
  }

  /// Send a file to [dst] (gated to accepted contacts). Stores a local copy,
  /// records an outgoing file message, then streams the bytes as fileMeta +
  /// fileChunk envelopes.
  Future<void> sendFile(NodeId dst, Uint8List bytes, String name) async {
    final contact = await _storage.getContact(dst);
    if (contact == null || contact.status != ContactStatus.accepted) return;

    final fileId = _uuid.v4();
    await _storage.storeFile(fileId, bytes, name: name);
    // Use the transfer id AS the message id so the receiver's completion ack
    // (keyed by transfer id) flips this message sent -> delivered. The file
    // wire frames carry only the transfer id, not the message id.
    await _store(dst, MessageDirection.outgoing, '📎 $name', MessageStatus.sent,
        fileId: fileId, fileName: name, id: fileId);
    _signal();

    final chunks = chunkBytes(bytes, transferId: fileId, maxChunk: _wireChunkBytes);
    await _send(
      dst,
      fileMetaEnvelope(
        transferId: fileId,
        name: name,
        size: bytes.length,
        count: chunks.length,
      ).encode(),
    );
    for (final c in chunks) {
      await _send(
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
    _retryTimer?.cancel();
    _retryTimer = null;
    await _sub?.cancel();
    _sub = null;
    await _changes.close();
  }
}

/// Constructed once and kept alive for the session; starts listening eagerly.
final messagingServiceProvider = Provider<MessagingService>((ref) {
  // All-online: use the ACTIVE identity's OWN pipeline from the session, so we
  // don't spin up a second service on its transport (which would double-process
  // its inbound). The session owns/disposes it; switching just re-resolves here.
  final session = ref.watch(sessionProvider);
  final active = ref.watch(activeIdentityProvider);
  if (session != null && active != null) {
    final m = session.messagingFor(active);
    if (m != null) return m;
  }
  // Single / one-active mode: the global service. Single mode has no roster, so
  // it is non-anonymous EXCEPT under the debug-only, env-gated force-flag (the
  // same affordance AppController uses for the shield indicator and the testnet
  // live run) — honour it here too so the force-flag actually routes over the
  // onion path, not just lights the indicator.
  final forceAnon = kDebugMode &&
      Platform.environment['XVEIL_FORCE_ANONYMOUS'] == '1';
  final service = MessagingService(
    ref.watch(veilTransportProvider),
    ref.watch(storageProvider),
    anonymous: forceAnon,
  );
  service.start();
  // Flush the local outbox whenever the node (re)connects: messages composed
  // while offline stay `sent` and go out the moment transport is up again.
  ref.listen<AsyncValue<NodeStatus>>(nodeStatusProvider, (prev, next) {
    final was = prev?.valueOrNull?.phase;
    final now = next.valueOrNull?.phase;
    if (now == NodePhase.connected && was != NodePhase.connected) {
      service.flushOutbox();
    }
  });
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
