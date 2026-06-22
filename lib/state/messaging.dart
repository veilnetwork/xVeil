import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/ids.dart';
import '../crypto/blake3.dart';
import '../data/node/embedded_node.dart' show BootstrapPeerCfg;
import '../data/node/node_controller.dart';
import '../data/storage/storage.dart';
import '../data/transport/relay_key_cache.dart';
import '../data/transport/veil_flutter_transport.dart';
import '../data/transport/veil_transport.dart';
import '../data/transport/wire_envelope.dart';
import '../domain/chat.dart';
import '../domain/file_transfer.dart';
import 'mailbox_service.dart';
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

/// How long an inbound transfer may sit idle (no new chunk) before a fresh
/// transfer arriving at capacity may evict it to reclaim its slot. Without this,
/// an accepted peer that opens [kMaxConcurrentIncomingFiles] transfers and never
/// finishes them blocks all legitimate transfers until an app restart — an
/// availability problem (memory stays bounded regardless). Timeout-evict, not
/// LRU: LRU would let a hostile peer evict a victim's ACTIVE transfer. Tunable.
const kStaleIncomingFileTimeout = Duration(minutes: 5);

/// Max pre-consent intro messages we retain from a single not-yet-accepted
/// peer. Each [WireKind.request] carries an optional greeting we store so the
/// consent prompt can show it; a literal re-send dedups by id, but a hostile
/// peer minting a FRESH id per request could otherwise pile up unbounded
/// intros on the victim's device before they ever accept. We keep the most
/// recent [kMaxPreConsentIntros] and evict the oldest — bounding storage while
/// still surfacing a peer's latest introduction. The consent decision is about
/// the peer, not the text, so a small cap loses nothing. Tunable.
const kMaxPreConsentIntros = 5;

/// In-flight inbound file reassembly state.
class _Incoming {
  _Incoming({
    required this.src,
    required this.name,
    required this.reasm,
    required this.lastActivity,
  });
  final NodeId src;
  final String? name;
  final FileReassembler reasm;

  /// Wall-clock of the most recent meta/chunk for this transfer. Bumped on every
  /// chunk so an actively-progressing transfer is never seen as stale; only idle
  /// (stalled/abandoned) transfers are eligible for eviction.
  DateTime lastActivity;
}

/// Wires the [VeilTransport] inbound stream into [Storage] and exposes a send
/// path. Persists every message, then signals [changes] so the read providers
/// refresh. Intentionally Riverpod-free (no Ref) — it owns a plain broadcast
/// stream, which keeps it testable and avoids invalidating providers from
/// async stream callbacks.
class MessagingService {
  MessagingService(
    this._transport,
    this._storage, {
    this._anonymous = false,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// Wall-clock source, injectable so stale-transfer eviction is testable
  /// without real delays. Defaults to [DateTime.now].
  final DateTime Function() _now;

  final VeilTransport _transport;
  final Storage _storage;

  /// Whether this identity routes over the onion rendezvous (sender-location
  /// hidden). Fixed per identity at boot from its roster `anonymous` flag — an
  /// anonymous identity sends EVERYTHING (messages, acks, accepts, file frames)
  /// anonymously and never over clearnet, so no single frame leaks its network
  /// location. An undeliverable frame stays un-acked and is retried, never
  /// degraded to a clearnet send (see [VeilTransport.send]).
  final bool _anonymous;

  /// Single egress point so every outbound frame honours [_anonymous]. The real
  /// transport routes over an onion circuit when anonymous (and never falls back
  /// to clearnet); the loopback fake ignores the flag.
  Future<void> _send(NodeId dst, Uint8List payload) {
    debugPrint('xVeil[send]: live send dst=${dst.short} anonymous=$_anonymous '
        'bytes=${payload.length} transport=${_transport.runtimeType}');
    return _transport.send(dst, payload, anonymous: _anonymous);
  }
  final _changes = StreamController<void>.broadcast();
  StreamSubscription<InboundMessage>? _sub;
  Timer? _retryTimer;
  bool _flushing = false;
  final Map<String, _Incoming> _inFlight = {};

  /// Offline-delivery side-channel (null until wired by the provider, and null
  /// for the loopback/test transport). When present, un-acked outgoing messages
  /// are ALSO deposited at the recipient's mailbox relay so an offline peer
  /// receives them, and our own mailbox is drained into [deliverInbound].
  MailboxSink? _mailbox;

  /// Message ids already deposited to the mailbox this session — so a message
  /// is stashed once, not on every 15 s outbox flush. The relay also dedups by
  /// content id, so this is purely a network-traffic optimisation.
  final Set<String> _stashed = {};

  /// Attach the offline-delivery [MailboxService] after construction (it is
  /// built with [deliverInbound] as its drain sink, so it must exist first).
  void attachMailbox(MailboxSink mailbox) => _mailbox = mailbox;

  /// Route a message recovered from our mailbox through the normal inbound
  /// path — it is a `WireEnvelope`, so [_dispatch] decodes it, applies the
  /// consent gate, stores it, acks, and dedups by id against any live delivery.
  Future<void> deliverInbound(InboundMessage m) => _onInbound(m);

  /// How often to re-send still-un-acked messages. Covers the case where the
  /// RECIPIENT was offline (e.g. the peer switched to another identity, taking
  /// that identity's node down) — our node-connect flush only fires on OUR
  /// reconnect, so without this a message to a temporarily-offline peer would
  /// never be retried. Bounded: a message stops being re-sent once acked.
  // Re-send un-acked messages this often. Kept short so a live send that was
  // dropped (circuit not ready) is retried in a few seconds rather than feeling
  // stuck. Re-sends are cheap (dedup by id receiver-side; the deposit is skipped
  // once stashed), so a tight interval mainly buys lower delivery latency.
  static const _retryInterval = Duration(seconds: 5);

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
    DateTime? timestamp,
  }) async {
    final msgId = id ?? _uuid.v4();
    await _storage.appendMessage(Message(
      id: msgId,
      conversationId: peer.hex,
      direction: dir,
      body: body,
      // Incoming messages carry the SENDER's send time (env.sentAtMs) so the
      // conversation orders by send-order, not the scrambled arrival order.
      timestamp: timestamp ?? DateTime.now(),
      status: status,
      fileId: fileId,
      fileName: fileName,
    ));
    return msgId;
  }

  /// The sender's send time off the wire as a DateTime, or null (older sender
  /// without `sentAtMs` → caller falls back to receive time). Clamped to "not in
  /// the future" so a sender with a fast clock can't float its messages to the
  /// bottom of everyone's conversation forever.
  DateTime? _wireSentAt(WireEnvelope env) {
    final ms = env.sentAtMs;
    if (ms == null) return null;
    final now = DateTime.now();
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    return t.isAfter(now) ? now : t;
  }

  Future<bool> _hasMessage(NodeId peer, String id) async {
    final msgs = await _storage.loadMessages(peer.hex);
    return msgs.any((m) => m.id == id);
  }

  /// Bound the number of pre-consent intro messages held from a single
  /// not-yet-accepted [peer] (anti-spam). Each [WireKind.request] greeting is
  /// stored so the consent prompt can show it; before acceptance the only
  /// incoming messages from a peer ARE these intros (real messages are gated on
  /// `accepted`), so capping incoming-count == capping intros. We evict the
  /// oldest so that, after storing the new intro [newId], we retain at most
  /// [kMaxPreConsentIntros]. No-op for an accepted peer (we must never evict a
  /// real conversation) or a same-id re-send (it overwrites in place, not a new
  /// intro). Evicted bodies are scrubbed so they leave no recoverable trace.
  Future<void> _capPreConsentIntros(NodeId peer, String? newId) async {
    final contact = await _storage.getContact(peer);
    if (contact?.status == ContactStatus.accepted) return;
    final msgs = await _storage.loadMessages(peer.hex);
    if (newId != null && msgs.any((m) => m.id == newId)) return; // overwrite
    final intros = msgs
        .where((m) => m.direction == MessageDirection.incoming)
        .toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    // Make room for the one we're about to add: keep at most cap-1 of the old.
    final evict = intros.length - (kMaxPreConsentIntros - 1);
    if (evict <= 0) return;
    for (var i = 0; i < evict; i++) {
      await _storage.deleteMessage(intros[i].id);
    }
    await _storage.scrubDeleted();
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
    debugPrint('xVeil[recv]: INBOUND from=${m.src.short} bytes=${m.payload.length}');
    try {
      await _dispatch(m);
    } catch (e) {
      // A hostile or corrupt datagram (malformed JSON, missing/ill-typed
      // fields, bad base64) must never throw out of the stream listener and
      // disrupt delivery for everyone else — drop it silently. LOG it so a
      // legit message that fails to parse/store isn't invisibly dropped.
      debugPrint('xVeil[recv]: dispatch FAILED from=${m.src.short}: $e');
    }
  }

  Future<void> _dispatch(InboundMessage m) async {
    final env = WireEnvelope.decode(m.payload);
    final existing = await _storage.getContact(m.src);
    if (existing?.status == ContactStatus.blocked) return; // drop blocked

    switch (env.kind) {
      case WireKind.request:
        // Self-healing accept: a peer who re-sends a request is one who never
        // saw our accept (it was lost — e.g. their rendezvous ad wasn't
        // resolvable when we first accepted). Re-send + re-stash the accept so
        // the consent handshake completes on their resend, instead of stranding
        // them on "waiting" forever. (Accepts, unlike requests, aren't in the
        // outbox, so without this a lost accept is never retried.)
        if (existing?.status == ContactStatus.accepted) {
          final accept = const WireEnvelope.accept().encode();
          await _send(m.src, accept);
          _stashed.remove('accept:${m.src.hex}'); // force a fresh deposit
          await _maybeStash(m.src, 'accept:${m.src.hex}', accept);
          return;
        }
        await _setStatus(m.src, ContactStatus.pendingIncoming);
        if (env.body.isNotEmpty &&
            !(env.id != null && await _storage.isMessageDeleted(env.id!))) {
          // Bound pre-consent intros: a hostile peer minting a fresh id per
          // request would otherwise pile up unbounded greetings before we ever
          // accept. Evict the oldest down to the cap, keeping the most recent.
          // Only when this is a NEW id (a same-id re-send overwrites in place).
          await _capPreConsentIntros(m.src, env.id);
          // Store the greeting under the REQUEST's id so a later outbox re-send
          // of the same greeting (as a WireKind.message) dedups instead of
          // creating a second copy. Skip if we already deleted this id (don't
          // resurrect, same as the message case).
          await _store(m.src, MessageDirection.incoming, env.body,
              MessageStatus.delivered, id: env.id, timestamp: _wireSentAt(env));
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
            MessageStatus.delivered, id: id, timestamp: _wireSentAt(env));
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
        // At capacity: first reclaim slots held by transfers that have gone idle
        // past the stale timeout, so a stalled/abandoned transfer can't block
        // legitimate ones until restart. Actively-progressing transfers (a recent
        // chunk bumped lastActivity) are untouched.
        if (_inFlight.length >= kMaxConcurrentIncomingFiles) {
          final cutoff = _now();
          _inFlight.removeWhere((_, inc) =>
              cutoff.difference(inc.lastActivity) > kStaleIncomingFileTimeout);
        }
        // Bound concurrent transfers so the per-transfer cap actually bounds
        // total memory: a new transfer is dropped when we are STILL at capacity
        // (i.e. every slot holds a live, non-stale transfer).
        if (_inFlight.length >= kMaxConcurrentIncomingFiles) return;
        _inFlight[meta.transferId] = _Incoming(
          src: m.src,
          name: meta.name,
          reasm: FileReassembler(),
          lastActivity: _now(),
        );
        return; // nothing to show until the file completes
      case WireKind.fileChunk:
        if (existing?.status != ContactStatus.accepted) return;
        final frame = parseFileChunk(env.body);
        final inc = _inFlight[frame.transferId];
        // Unknown transfer (chunk before meta), or a different peer trying to
        // contribute to someone else's in-flight transfer — drop it.
        if (inc == null || inc.src != m.src) return;
        inc.lastActivity = _now(); // progress — keep this transfer non-stale
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
    final sentAt = DateTime.now();
    if (text.isNotEmpty) {
      await _store(dst, MessageDirection.outgoing, text, MessageStatus.sent,
          id: id, timestamp: sentAt);
    }
    _signal();
    final wire = WireEnvelope.request(text,
            id: id, sentAtMs: sentAt.millisecondsSinceEpoch)
        .encode();
    await _send(dst, wire);
    // Also deposit the request at the recipient's mailbox relay so a NAT'd /
    // offline peer receives it. The live send above only lands if they're
    // directly reachable — which for two nodes behind NAT they never are, so
    // WITHOUT this first contact could never be established. (flushOutbox only
    // re-stashes ACCEPTED contacts, so the request must stash itself here.)
    await _maybeStash(dst, id, wire);
  }

  /// Re-send a pending outgoing request that hasn't been accepted yet (e.g. it
  /// didn't reach the peer because a relay was momentarily unresolvable). Re-uses
  /// the original greeting + id (so the peer dedups), re-sends live AND forces a
  /// fresh mailbox deposit. No-op unless the contact is still pendingOutgoing.
  Future<void> resendRequest(NodeId dst) async {
    final contact = await _storage.getContact(dst);
    if (contact?.status != ContactStatus.pendingOutgoing) return;
    String? body;
    String? id;
    for (final m in await _storage.loadMessages(dst.hex)) {
      if (m.direction == MessageDirection.outgoing) {
        body = m.body;
        id = m.id;
        break;
      }
    }
    id ??= _uuid.v4();
    final wire = WireEnvelope.request(body ?? '', id: id).encode();
    await _send(dst, wire);
    _stashed.remove(id); // allow the deposit to happen again
    await _maybeStash(dst, id, wire);
    _signal();
  }

  /// Cancel (retract) a pending outgoing request: remove the conversation +
  /// contact locally so the peer is unknown again and a fresh request can be
  /// sent later. The peer can't be un-notified (if it already arrived they may
  /// have seen it), but our side is cleaned up.
  Future<void> cancelRequest(NodeId peer) async {
    await _storage.removeConversation(peer);
    _signal();
  }

  /// Approve an incoming request — both sides can now message freely.
  Future<void> acceptContact(NodeId peer) async {
    await _setStatus(peer, ContactStatus.accepted);
    _signal();
    final wire = const WireEnvelope.accept().encode();
    await _send(peer, wire);
    // The requester is likely NAT'd too — deposit the accept at their mailbox
    // so they learn they were accepted (and can start free-messaging) even if
    // they aren't directly reachable. Stable id keys relay dedup per peer.
    await _maybeStash(peer, 'accept:${peer.hex}', wire);
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
    // One send time, used for BOTH our stored copy and the wire `sentAtMs`, so
    // both ends order this message identically.
    final sentAt = DateTime.now();
    final id = await _store(dst, MessageDirection.outgoing, trimmed,
        MessageStatus.sent, timestamp: sentAt);
    _signal();
    // Stays `sent` until the peer acks; the local outbox re-sends un-acked ones
    // on reconnect, so a message written offline goes out when we come back.
    final wire = WireEnvelope.message(trimmed,
            id: id, sentAtMs: sentAt.millisecondsSinceEpoch)
        .encode();
    await _send(dst, wire);
    // Deposit at the peer's mailbox as a BACKGROUND fallback (don't await): the
    // seal+put is a slow onion round-trip, and blocking the send on it made every
    // message feel laggy even when the live path delivers instantly. If the peer
    // is offline the deposit (or the outbox retry) still gets there.
    unawaited(_maybeStash(dst, id, wire));
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
          // Re-send with the ORIGINAL send time so a retried message keeps its
          // place in the conversation instead of jumping to "now".
          final wire = WireEnvelope.message(m.body,
                  id: m.id, sentAtMs: m.timestamp.millisecondsSinceEpoch)
              .encode();
          await _send(conv.peer.nodeId, wire);
          // Also deposit at the recipient's mailbox relay so an OFFLINE peer
          // receives it (live re-send above only lands if they're online). Once
          // per message per session; the relay dedups by content id, and the
          // recipient dedups the recovered envelope by its message id.
          await _maybeStash(conv.peer.nodeId, m.id, wire);
        }
      }
    }
  }

  /// Best-effort offline deposit of [wire] (the message envelope) for [peer],
  /// keyed by a stable 32-byte content id derived from the message [id]. No-op
  /// when there is no mailbox side-channel or we already stashed this message.
  Future<void> _maybeStash(NodeId peer, String id, Uint8List wire) async {
    final mailbox = _mailbox;
    if (mailbox == null) {
      debugPrint('xVeil[send]: stash SKIP dst=${peer.short} id=$id '
          '— NO mailbox (transport not VeilFlutter or no relays)');
      return;
    }
    if (_stashed.contains(id)) {
      debugPrint('xVeil[send]: stash SKIP dst=${peer.short} id=$id — already stashed');
      return;
    }
    try {
      await mailbox.stash(
        recipient: peer,
        payload: wire,
        contentId: _contentIdFor(id),
      );
      _stashed.add(id);
      debugPrint('xVeil[send]: stash OK dst=${peer.short} id=$id '
          '(deposited at recipient relay)');
    } catch (e, st) {
      // No relay / no route yet — leave it un-stashed so a later flush retries.
      // LOG the real reason: this is the offline-delivery path, and a swallowed
      // failure here is invisible "message never arrived".
      debugPrint('xVeil[send]: stash FAILED dst=${peer.short} id=$id: $e\n$st');
    }
  }

  /// Stable 32-byte mailbox content id for a message [id] (the relay keys dedup
  /// + eviction on this). Distinct from the on-wire message id the recipient
  /// dedups on; this only needs to be deterministic per message.
  static Uint8List _contentIdFor(String id) =>
      blake3DeriveKey('veil.mailbox.content_id.v1', utf8.encode(id));

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
  // Anonymity-first: route sends over the LIVE onion-rendezvous path by default.
  // This resolves the recipient's rendezvous ad and delivers through their relay
  // over the already-held mesh sessions — so a NAT'd peer who is ONLINE gets the
  // message in ~seconds (no 30s mailbox poll), AND the sender's location stays
  // private. The mailbox deposit below remains the fallback for an OFFLINE peer.
  // (Pairs with the node booting anonymous — see AppController._activeAnonymous —
  // so it can receive the introduce.) The loopback fake ignores the flag.
  final transport = ref.watch(veilTransportProvider);
  final storage = ref.watch(storageProvider);
  final service = MessagingService(
    transport,
    storage,
    anonymous: true,
  );
  service.start();

  // Offline delivery: over the real veil transport, advertise a mailbox relay
  // (a configured bootstrap peer) and drain our mailbox into the inbound path.
  // Best-effort + inert on the loopback transport or when no bootstrap peers
  // are configured — live delivery is unaffected if this never registers.
  final relays = _mailboxRelayCandidates(
      ref.read(deniableBootProvider)?.bootstrapPeers ?? const []);
  debugPrint('xVeil[mailbox]: setup — transport=${transport.runtimeType} '
      'relays=${relays.length}');
  MailboxService? mailbox;
  // The provider rebuilds whenever the real stack changes (node reboot, identity
  // create/switch tears down then re-boots — TWO rapid rebuilds). buildMailboxService
  // is async, so its `.then` can resolve AFTER this provider was already disposed.
  // If we attached then, the orphaned mailbox's retry timer would run forever on
  // a dead veil handle ("handle already closed" spam). Track disposal and drop a
  // late-arriving mailbox instead of leaking it.
  var providerDisposed = false;
  ref.onDispose(() => providerDisposed = true);
  if (transport is VeilFlutterTransport && relays.isNotEmpty) {
    // Persist verified relay keys INSIDE the active deniable space so a cold
    // restart can stay reachable through a transient resolve failure (the fresh
    // one-hop resolve is still preferred — see MailboxService._register).
    final relayKeyCache = StorageRelayKeyCache(storage);
    transport
        .buildMailboxService(
      deliver: service.deliverInbound,
      relayKeyCache: relayKeyCache,
    )
        .then((m) {
      if (providerDisposed) {
        // This stack/transport is already gone — don't start a timer on it.
        unawaited(m.dispose());
        return;
      }
      mailbox = m;
      service.attachMailbox(m);
      ref.onDispose(m.dispose);
      unawaited(m.start(relays: relays));
    }).catchError((e) {
      debugPrint('xVeil[mailbox]: build/start FAILED: $e');
    });
  } else {
    debugPrint('xVeil[mailbox]: NOT started '
        '(transport=${transport.runtimeType}, relays=${relays.length})');
  }

  // Flush the local outbox whenever the node (re)connects: messages composed
  // while offline stay `sent` and go out the moment transport is up again. Also
  // (re)attempt mailbox registration — the DHT resolve needs the node connected.
  ref.listen<AsyncValue<NodeStatus>>(nodeStatusProvider, (prev, next) {
    final was = prev?.valueOrNull?.phase;
    final now = next.valueOrNull?.phase;
    if (now == NodePhase.connected && was != NodePhase.connected) {
      service.flushOutbox();
      unawaited(mailbox?.start(relays: relays) ?? Future.value());
    }
  });
  ref.onDispose(service.dispose);
  return service;
});

/// Candidate mailbox-relay node_ids derived from configured bootstrap peers: a
/// node_id is `BLAKE3(identity_pubkey)` (veil `compute_node_id`) and a bootstrap
/// peer's `public_key` is base64. Malformed entries are skipped. The relay-key
/// DHT resolve validates each candidate (an entry that isn't relay-capable
/// simply won't resolve), so a wrong derivation is non-fatal.
///
/// Verified live: `BLAKE3(base64(public_key))` reproduces the exact node_ids of
/// all three testnet bootstrap peers, so this derivation matches veil's
/// `compute_node_id` and the bootstrap-relay selection addresses real nodes.
List<NodeId> _mailboxRelayCandidates(List<BootstrapPeerCfg> peers) {
  final out = <NodeId>[];
  for (final p in peers) {
    try {
      out.add(NodeId(blake3Hash(base64.decode(p.publicKey))));
    } catch (_) {
      // Malformed public_key — skip this candidate.
    }
  }
  return out;
}

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
