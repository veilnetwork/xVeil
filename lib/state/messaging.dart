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
import 'app_controller.dart';
import 'mailbox_service.dart';
import 'providers.dart';
import 'package:xveil/core/log.dart';

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
  /// Live-send [payload] to [dst]. [wantReply] (only meaningful when anonymous)
  /// attaches a one-time reply block so the recipient can ACK over THIS send's
  /// circuit (surfacing as a non-zero [InboundMessage.replyId]) instead of doing
  /// a full resolve + circuit-build of its own — used for chat messages so the
  /// delivery-ACK round-trip is ~halved. Anonymity is unchanged (one-shot block,
  /// not a reused circuit).
  Future<void> _send(NodeId dst, Uint8List payload, {bool wantReply = false}) {
    devLog(() => 'xVeil[send]: live send dst=${dst.short} anonymous=$_anonymous '
        'wantReply=$wantReply bytes=${payload.length} '
        'transport=${_transport.runtimeType}');
    if (_anonymous && wantReply) {
      return _transport.sendWithReply(dst, payload);
    }
    return _transport.send(dst, payload, anonymous: _anonymous);
  }

  /// Send a delivery ACK for [id] back to the sender of inbound [m]. When [m]
  /// carried a one-time reply path ([InboundMessage.replyId] != 0, set because
  /// the sender used `wantReply`), route the ACK over it — no fresh resolve +
  /// circuit-build — which is the latency win that flips the sender's message to
  /// "delivered" fast. Falls back to a normal anonymous send otherwise.
  ///
  /// [direct] forces the reliable full anonymous send even when a reply path is
  /// available. We set it on RE-receipts of an already-seen message: a repeat
  /// means our previous (reply-path) ACK never reached the sender — the one-time
  /// reply circuit can silently die on a NAT'd/mobile peer — so the second time
  /// we ACK over the durable resolve+circuit path instead of looping forever on
  /// a dead reply path. First receipt → fast reply path; repeat → reliable path.
  Future<void> _ackTo(InboundMessage m, String id, {bool direct = false}) async {
    final ack = WireEnvelope.ack(id).encode();
    final viaReply = !direct && m.replyId != 0;
    // [timeline] which ACK path we took (reply = fast one-time circuit; direct =
    // durable resolve+circuit). id + path enum only — no body/keys.
    devLog(() => 'xVeil[timeline]: ack id=$id via=${viaReply ? 'reply' : 'direct'} '
        't=${DateTime.now().millisecondsSinceEpoch}');
    if (viaReply) {
      // Fast path: ride the sender's one-time reply circuit. Lowest latency, but
      // the circuit can silently die on a NAT'd/mobile sender — covered by the
      // durable path below on any re-receipt.
      await _transport.sendReply(m.replyId, ack);
      return;
    }
    // Durable path. A live send reaches the sender ONLY over a direct session, so
    // a NAT'd/offline sender never sees the ack and re-sends the message forever
    // — the observed delivery "storm" (hundreds of duplicate INBOUNDs that the
    // receiver dedups but the sender keeps generating because nothing flips the
    // message to "delivered"). The MESSAGE itself reaches a NAT'd peer only
    // because it is DEPOSITED at their mailbox and pushed over rendezvous; the
    // ack was missing that leg. Deposit the ack at the sender's mailbox too so it
    // rides the same push. Deduped per id via the '_stashed' set (at most one
    // deposit per message), and fire-and-forget so the seal/PUT round-trip never
    // stalls the receive path — the live send above still covers the online case
    // at lower latency.
    await _send(m.src, ack);
    unawaited(_maybeStash(m.src, 'ack:$id', ack));
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
  /// is stashed once, not on every outbox flush. The relay also dedups by
  /// content id, so this is purely a network-traffic optimisation.
  final Set<String> _stashed = {};

  /// When a stash of a given id last FAILED. A failed deposit is never added to
  /// [_stashed] (so a later flush retries it — correct for offline delivery),
  /// but EACH `mailbox.stash` spawns a worker isolate that does a DHT relay-key
  /// resolve + ML-KEM seal and blocks ~12s when the relay can't be resolved. The
  /// 3s outbox flush therefore re-spawned a seal isolate every tick for every
  /// not-yet-deliverable message — a self-inflicted isolate/CPU storm competing
  /// with live onion delivery (observed: 140 "stash FAILED" in one session). We
  /// back off re-attempts of a FAILED id by [_stashRetryBackoff]; the deposit is
  /// never dropped (it still retries, just not every 3s), so offline delivery is
  /// unaffected.
  final Map<String, DateTime> _stashFailedAt = {};
  static const _stashRetryBackoff = Duration(seconds: 30);

  /// Per-message live-resend backoff. The outbox flush fires every
  /// [_retryInterval] (3s), but re-sending EVERY un-acked message on EVERY tick
  /// is a storm when delivery is lossy (observed 789 re-sends in one session,
  /// each a full onion send + an FFI hop that, in bulk, starved the UI isolate
  /// into a freeze). Instead each message backs off exponentially after its
  /// first re-send: 3s, 6s, 12s, 24s, capped at [_maxRetryBackoff]. The first
  /// send (sendText) and the first re-send are unchanged, so a transient loss
  /// still recovers in seconds; only a persistently-undeliverable message stops
  /// hammering. Cleared when the message is acked (delivered).
  final Map<String, ({int count, DateTime nextAt})> _retryBackoff = {};
  static const _maxRetryBackoff = Duration(seconds: 24);

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
  static const _retryInterval = Duration(seconds: 3);

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
      await _storage.deleteMessage(peer.hex, intros[i].id);
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
    devLog(() => 'xVeil[recv]: INBOUND from=${m.src.short} bytes=${m.payload.length}');
    try {
      await _dispatch(m);
    } catch (e) {
      // A hostile or corrupt datagram (malformed JSON, missing/ill-typed
      // fields, bad base64) must never throw out of the stream listener and
      // disrupt delivery for everyone else — drop it silently. LOG it so a
      // legit message that fails to parse/store isn't invisibly dropped.
      devLog(() => 'xVeil[recv]: dispatch FAILED from=${m.src.short}: $e');
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
            !(env.id != null &&
                await _storage.isMessageDeleted(m.src.hex, env.id!))) {
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
        // [timeline] inbound receipt: id + whether it carried a reply path. id +
        // replyId only (no body) — lets us separate receive-latency from the ACK
        // round-trip when reading a session's logs.
        devLog(() => 'xVeil[timeline]: recv id=$id replyId=${m.replyId} '
            't=${DateTime.now().millisecondsSinceEpoch}');
        // Dedup re-sent messages (the sender's local outbox re-sends un-acked
        // ones): if we already have this id, just re-ack so they stop.
        if (id != null && await _hasMessage(m.src, id)) {
          await _ackTo(m, id, direct: true);
          return;
        }
        // Deniability: if we DELETED this message, a re-delivery must NOT
        // resurrect it. Re-ack so the sender stops re-sending, then drop.
        if (id != null && await _storage.isMessageDeleted(m.src.hex, id)) {
          await _ackTo(m, id, direct: true);
          return;
        }
        await _store(m.src, MessageDirection.incoming, env.body,
            MessageStatus.delivered, id: id, timestamp: _wireSentAt(env));
        if (id != null) {
          await _ackTo(m, id);
        }
      case WireKind.ack:
        // The peer confirms delivery of our message [env.id] — stop re-sending.
        if (env.id != null) {
          // [timeline] sender-side "delivered" moment — pair with the send t0 to
          // get the full perceived round-trip. id + time only.
          devLog(() => 'xVeil[timeline]: delivered id=${env.id} '
              't=${DateTime.now().millisecondsSinceEpoch}');
          _retryBackoff.remove(env.id); // stop backing off a delivered message
          await _storage.markMessageStatus(env.id!, MessageStatus.delivered);
        }
      case WireKind.edit:
        // The peer edited a message THEY sent us. Apply only to an INCOMING
        // message we hold from this peer — a peer must never be able to rewrite
        // our own outgoing messages (the id travels on the wire, so they know
        // it; the direction check is the real authorization gate).
        if (existing?.status != ContactStatus.accepted) return;
        if (env.id != null && await _isIncomingFrom(m.src, env.id!)) {
          await _storage.editMessage(m.src.hex, env.id!, env.body);
          await _storage.scrubDeleted();
        }
      case WireKind.del:
        // The peer unsent a message THEY sent us — purge + scrub our copy too.
        // Same authorization gate: only their incoming messages, never ours.
        if (existing?.status != ContactStatus.accepted) return;
        if (env.id != null && await _isIncomingFrom(m.src, env.id!)) {
          await _storage.deleteMessage(m.src.hex, env.id!);
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
        if (await _hasMessage(m.src, tid) ||
            await _storage.isMessageDeleted(m.src.hex, tid)) {
          await _ackTo(m, tid, direct: true);
          return;
        }
        await _storage.storeFile(tid, inc.reasm.assemble(), name: inc.name);
        await _store(m.src, MessageDirection.incoming, '📎 ${inc.name ?? 'file'}',
            MessageStatus.delivered,
            fileId: tid, fileName: inc.name, id: tid);
        // Ack the completed transfer so the sender's file message flips
        // sent -> delivered — the same delivery feedback text messages get.
        await _ackTo(m, tid);
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
    // wantReply: embed a one-time reply path so the peer's delivery-ACK comes
    // back over THIS circuit (fast), flipping us to "delivered" without a full
    // resolve+circuit-build round-trip on their side.
    // [timeline] id + send-time only (random uuid + ms clock — no body/keys), so
    // receive-latency vs ACK-latency can be measured per message from the logs.
    devLog(() => 'xVeil[timeline]: send id=$id '
        't0=${sentAt.millisecondsSinceEpoch} wantReply=true');
    await _send(dst, wire, wantReply: true);
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
          // Exponential per-message backoff: skip this flush if the message is
          // still within its backoff window (delivery is lossy, so re-sending
          // every un-acked message every 3s is a storm). First re-send fires
          // immediately (no entry yet); each subsequent one doubles 3->6->12->24
          // capped, so a persistent loss stops hammering the UI/onion path.
          final now = DateTime.now();
          final bo = _retryBackoff[m.id];
          if (bo != null && now.isBefore(bo.nextAt)) continue;
          final count = (bo?.count ?? 0) + 1;
          final delayMs = (_retryInterval.inMilliseconds * (1 << (count - 1)))
              .clamp(0, _maxRetryBackoff.inMilliseconds);
          _retryBackoff[m.id] =
              (count: count, nextAt: now.add(Duration(milliseconds: delayMs)));
          // Re-send with the ORIGINAL send time so a retried message keeps its
          // place in the conversation instead of jumping to "now".
          final wire = WireEnvelope.message(m.body,
                  id: m.id, sentAtMs: m.timestamp.millisecondsSinceEpoch)
              .encode();
          // Re-sends do NOT request a reply: the first send already attached one
          // (sendText), and building a fresh one-time reply circuit on EVERY 3s
          // retry was the dominant circuit-build load (the reply path can't be
          // reused anyway). A plain re-send arrives with replyId==0, so the peer
          // ACKs over the durable resolve+circuit path — reliable, and it stops
          // the retry once it lands. This keeps the fast-ACK chance (first send)
          // without the per-retry circuit storm.
          // [timeline] one line per re-send so a session's retry count per id is
          // countable (a high count = the ACK round-trip is lagging). id only.
          devLog(() => 'xVeil[timeline]: retry id=${m.id} '
              't=${DateTime.now().millisecondsSinceEpoch}');
          await _send(conv.peer.nodeId, wire);
          // Also deposit at the recipient's mailbox relay so an OFFLINE peer
          // receives it (live re-send above only lands if they're online). Keep
          // this in the background: sealing/PUT can take a full anonymous
          // round-trip, and should not block later live retries in this pass.
          unawaited(_maybeStash(conv.peer.nodeId, m.id, wire));
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
      devLog(() => 'xVeil[send]: stash SKIP dst=${peer.short} id=$id '
          '— NO mailbox (transport not VeilFlutter or no relays)');
      return;
    }
    if (_stashed.contains(id)) {
      devLog(() => 'xVeil[send]: stash SKIP dst=${peer.short} id=$id — already stashed');
      return;
    }
    // Back off re-attempts of a recently-FAILED id: a failed seal isolate blocks
    // ~12s and the 3s flush would otherwise re-spawn one every tick. The deposit
    // is NOT dropped — it just waits [_stashRetryBackoff] before the next try, so
    // a genuinely-offline peer still gets it (eventually), without the storm.
    final failedAt = _stashFailedAt[id];
    if (failedAt != null &&
        DateTime.now().difference(failedAt) < _stashRetryBackoff) {
      return; // still in backoff — skip this flush, retry on a later one
    }
    try {
      await mailbox.stash(
        recipient: peer,
        payload: wire,
        contentId: _contentIdFor(id),
      );
      _stashed.add(id);
      _stashFailedAt.remove(id);
      devLog(() => 'xVeil[send]: stash OK dst=${peer.short} id=$id '
          '(deposited at recipient relay)');
    } catch (e, st) {
      // No relay / no route yet — leave it un-stashed so a later flush retries
      // (after the backoff). LOG the real reason: this is the offline-delivery
      // path, and a swallowed failure here is invisible "message never arrived".
      _stashFailedAt[id] = DateTime.now();
      devLog(() => 'xVeil[send]: stash FAILED dst=${peer.short} id=$id '
          '(backoff ${_stashRetryBackoff.inSeconds}s): $e\n$st');
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
    // Resolve the owning conversation: deleteMessage is conversation-scoped (a
    // bare id never resolves across chats), and a local delete can target a
    // received message too, so look it up rather than assume our own peer.
    final msg = await _find(messageId);
    if (msg == null) return;
    await _storage.deleteMessage(msg.conversationId, messageId);
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
    await _storage.editMessage(msg.conversationId, messageId, trimmed);
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
  // The send anonymity MUST match the value the node booted with
  // (AppController._activeAnonymous): an anonymous send needs the node's onion
  // service armed, and a non-anonymous send goes clearnet/direct. Hardcoding
  // `true` here (the old anonymity-first default) ignored the user's per-space
  // anonymity toggle — so disabling anonymity had NO effect on send, and the
  // forced-anonymous send had no onion path on a node that booted non-anon, so
  // it never delivered. Track the live setting instead. The loopback fake
  // ignores the flag.
  final anonymous = ref.read(appControllerProvider.notifier).activeIsAnonymous;
  final transport = ref.watch(veilTransportProvider);
  final storage = ref.watch(storageProvider);
  devLog(() => 'xVeil[messaging]: fallback service (no session pipeline) '
      'anonymous=$anonymous');
  final service = MessagingService(
    transport,
    storage,
    anonymous: anonymous,
  );
  service.start();

  // Offline delivery: over the real veil transport, advertise a mailbox relay
  // (a configured bootstrap peer) and drain our mailbox into the inbound path.
  // Best-effort + inert on the loopback transport or when no bootstrap peers
  // are configured — live delivery is unaffected if this never registers.
  final relays = _mailboxRelayCandidates(
      ref.read(deniableBootProvider)?.bootstrapPeers ?? const []);
  devLog(() => 'xVeil[mailbox]: setup — transport=${transport.runtimeType} '
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
      devLog(() => 'xVeil[mailbox]: build/start FAILED: $e');
    });
  } else {
    devLog(() => 'xVeil[mailbox]: NOT started '
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
  // Each `changes` tick re-loads + DECRYPTS the whole conversation from the
  // container and rebuilds the ListView (+ auto-scroll). A burst of state
  // signals (sends, inbound re-sends, status flips) therefore thrashed the UI
  // isolate into a visible freeze. Coalesce bursts: reload at most ~5x/s
  // (trailing edge), so the latest state still renders within ~200ms but a
  // flurry collapses into ONE decrypt+rebuild.
  await for (final _
      in service.changes.auditTrailing(const Duration(milliseconds: 200))) {
    yield await storage.loadMessages(conversationId);
  }
});

extension _AuditTrailing<T> on Stream<T> {
  /// Trailing-edge throttle: collapses a burst of events into a single
  /// downstream event carrying the LATEST value, emitted at most once per
  /// [window]. Quiet periods pass through with at most [window] added latency;
  /// no event is emitted for an idle window.
  Stream<T> auditTrailing(Duration window) {
    StreamController<T>? controller;
    StreamSubscription<T>? sub;
    Timer? timer;
    late T latest;
    var has = false;
    controller = StreamController<T>(
      onListen: () {
        sub = listen(
          (e) {
            latest = e;
            has = true;
            timer ??= Timer(window, () {
              timer = null;
              if (has) {
                has = false;
                controller!.add(latest);
              }
            });
          },
          onError: (Object err, StackTrace st) => controller!.addError(err, st),
          onDone: () {
            timer?.cancel();
            controller!.close();
          },
        );
      },
      onCancel: () {
        timer?.cancel();
        final s = sub;
        sub = null;
        return s?.cancel();
      },
    );
    return controller.stream;
  }
}

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
