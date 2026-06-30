import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/ids.dart';
import '../crypto/blake3.dart';
import '../data/node/embedded_node.dart' show BootstrapPeerCfg;
import '../data/node/node_controller.dart';
import '../data/storage/file_store.dart' show kMaxStoredFileBytes;
import '../data/storage/storage.dart';
import '../data/transport/relay_key_cache.dart';
import '../data/transport/veil_flutter_transport.dart';
import '../data/transport/veil_transport.dart';
import '../data/transport/wire_envelope.dart';
import '../domain/chat.dart';
import '../domain/content_manifest.dart';
import '../domain/content_transfer.dart';
import '../data/serve_source.dart';
import '../domain/event.dart';
import '../domain/file_download_policy.dart';
import '../domain/file_transfer.dart';
import 'app_controller.dart';
import 'mailbox_service.dart';
import 'providers.dart';
import 'package:xveil/core/log.dart';

const _uuid = Uuid();

/// Raw bytes per wire chunk. The anonymous authenticated send (the live path,
/// veil's auth_deliver) caps ONE message at MAX_AUTH_DELIVER_MSG_BYTES = 6144
/// bytes and silently drops anything larger (fire-and-forget, no retry). A chunk
/// is base64 + JSON-wrapped (~1.35×) plus the AuthDeliver header/signature, so
/// 6000 inflated to ~8099 B and EVERY file chunk was dropped on the live path
/// (text survived only via its mailbox stash; files have none). 4000 → ~5.5 KB
/// encoded, a safe margin under 6144, so file chunks actually traverse the
/// onion. (Mailbox-deposited frames share the same ceiling.)
const _wireChunkBytes = 4000;

/// Hard ceiling on a file we will buffer in memory and store. Bound by the
/// at-rest layer: a stored file must be DELETABLE in one atomic commit (≤ 1024
/// records × 8 KiB), so a larger blob can neither be persisted nor scrubbed on
/// delete — see [kMaxStoredFileBytes]. It therefore doubles as (a) the inbound
/// memory-DoS backstop (a hostile accepted peer can't buffer more than this) and
/// (b) the send-side pre-check bound (the UI shows a friendly "too large" error
/// here, instead of the storage layer throwing PayloadTooLarge mid-attach).
const kMaxIncomingFileBytes =
    kMaxStoredFileBytes; // ~8 MiB (1024×8 KiB ceiling)

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
    this.seq,
    this.sentAtMs,
  });
  final NodeId src;
  final String? name;
  final FileReassembler reasm;

  /// The SENDER's event seq for this file (filePost, §15), carried on the meta
  /// so the completed file message folds under the same (author, seq) — keeping
  /// the log convergent and letting gap-fill heal a missing file. Null from an
  /// older sender → the receiver allocates a local seq (legacy, off-convergence).
  final int? seq;

  /// The SENDER's send-time (ms) for this file, carried on the meta so the
  /// completed file message folds under the sender's time — keeping the
  /// (effective_ts, author, seq) display order convergent. Null from an older
  /// sender → the receiver falls back to its receive time.
  final int? sentAtMs;

  /// Wall-clock of the most recent meta/chunk for this transfer. Bumped on every
  /// chunk so an actively-progressing transfer is never seen as stale; only idle
  /// (stalled/abandoned) transfers are eligible for eviction.
  DateTime lastActivity;
}

/// Max edit/delete ops we hold waiting for their target message to arrive (see
/// [MessagingService._pendingOps]). Bounds memory against an accepted peer that
/// spams ops for message ids we never receive; the cap evicts oldest-first. A
/// real conversation has at most a handful of in-flight out-of-order ops, so a
/// modest cap loses nothing legitimate. Tunable.
const kMaxPendingOps = 512;

/// A peer's edit/delete of one of THEIR messages that drained before the message
/// itself. Buffered until the target stores, then replayed. A delete is terminal
/// (a later edit can't revive a message the peer unsent), so [isDelete] wins over
/// a buffered edit for the same id.
class _PendingOp {
  _PendingOp.edit(String this.body) : isDelete = false;
  _PendingOp.delete() : isDelete = true, body = null;
  final bool isDelete;

  /// The replacement text for an edit; null for a delete.
  final String? body;
}

/// A genuinely-new incoming message, emitted on [MessagingService.incoming] for
/// the notification layer (NOT re-deliveries — those are deduped before this
/// fires). Carries only what a notification needs; the privacy decision (show
/// the text/sender or not) is made above, not here.
class IncomingNotice {
  const IncomingNotice({
    required this.from,
    required this.preview,
    required this.isFile,
  });
  final NodeId from;
  final String preview;
  final bool isFile;
}

/// Outcome of a user-initiated download ([MessagingService.downloadContent] /
/// [MessagingService.downloadContentToFile]).
enum ContentDownloadResult {
  /// The fetch began (or the bytes were already held).
  started,

  /// No live manifest handle — we asked the sender to re-advertise; the download
  /// continues automatically if the sender is still serving, else nothing comes.
  requestedReoffer,

  /// No live offer AND no peer to ask — the sender must re-send.
  noOffer,
}

/// A live byte source the SENDER serves a large file from directly — the user's
/// ORIGINAL file on disk — instead of a stored/duplicated copy. [read] returns
/// exactly [length] bytes at [offset]; [close] releases the underlying handle
/// (the file picker's RandomAccessFile) when serving ends. Held by
/// [MessagingService._serving] and closed on eviction/dispose. The dart:io
/// implementation lives in the UI layer so this stays transport-/io-free.
typedef _ServeSource = ({
  Future<Uint8List> Function(int offset, int length) read,
  Future<void> Function() close,
});

/// Where a RECEIVE writes each verified piece when the user chose to download a
/// large file UNENCRYPTED, straight to a plaintext file they picked — instead of
/// the encrypted on-disk tier. [write] places [bytes] at byte [offset];
/// [close] finalises the file. The dart:io sink lives in the UI layer so the
/// messaging service stays io-free. Null fetch sink ⇒ store via the Storage port
/// (encrypted tier / in-volume) as usual.
typedef _FetchSink = ({
  Future<void> Function(int offset, Uint8List bytes) write,
  Future<void> Function() close,
});

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
    Duration contentReRequestInterval = const Duration(seconds: 20),
    Duration contentPacing = const Duration(milliseconds: 20),
    Duration? streamPayloadIdleTimeout,
    int? streamPullMaxAttempts,
  }) : _now = now ?? DateTime.now,
       _contentReRequestInterval = contentReRequestInterval,
       _contentPacing = contentPacing,
       _streamPayloadIdleTimeout =
           streamPayloadIdleTimeout ?? _defaultStreamPayloadIdleTimeout,
       _streamPullMaxAttempts =
           streamPullMaxAttempts ?? _defaultStreamPullMaxAttempts;

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
    devLog(
      () =>
          'xVeil[send]: live send dst=${dst.short} anonymous=$_anonymous '
          'wantReply=$wantReply bytes=${payload.length} '
          'transport=${_transport.runtimeType}',
    );
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
  Future<void> _ackTo(
    InboundMessage m,
    String id, {
    bool direct = false,
  }) async {
    final ack = WireEnvelope.ack(id).encode();
    final viaReply = !direct && m.replyId != 0;
    // [timeline] which ACK path we took (reply = fast one-time circuit; direct =
    // durable resolve+circuit). id + path enum only — no body/keys.
    devLog(
      () =>
          'xVeil[timeline]: ack id=$id via=${viaReply ? 'reply' : 'direct'} '
          't=${DateTime.now().millisecondsSinceEpoch}',
    );
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
  // Genuinely-new incoming messages (post-dedup), for the notification layer.
  final _incoming = StreamController<IncomingNotice>.broadcast();
  StreamSubscription<InboundMessage>? _sub;
  Timer? _retryTimer;
  bool _flushing = false;
  final Map<String, _Incoming> _inFlight = {};

  /// Edit/delete ops that arrived BEFORE the message they target. Mailbox blobs
  /// have no delivery order, so when a peer sends a message and then edits (or
  /// unsends) it while we are offline, both deposits drain on reconnect in
  /// arbitrary order — the edit/del can come first. Without this the op would be
  /// dropped (its target isn't stored yet), so the offline edit/delete never
  /// lands. Keyed by `<peerHex>|<messageId>`; replayed when the message stores.
  ///
  /// In-memory + bounded ([kMaxPendingOps]): nothing about a pending op touches
  /// disk (no metadata at rest), and a hostile accepted peer can't grow it
  /// without bound. Lost on restart — durable cross-session op ordering is the
  /// event-log's job (doc/EVENT-LOG-SYNC-DESIGN.md §15), this is the tactical
  /// fix for the common same-session drain.
  final Map<String, _PendingOp> _pendingOps = {};

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

  /// Message ids we've seen a DELIVERED ack for this session. A peer's mailbox
  /// drain re-acks every cycle until its relay blob ages out, so duplicate acks
  /// arrive in a storm; this makes the ack handler idempotent (mark + log once)
  /// and lets the outbox flush cancel a re-send synchronously on the first ack,
  /// before the durable status write resolves. Durable `MessageStatus.delivered`
  /// remains the source of truth across restart — this is only an early-cancel.
  final Set<String> _delivered = {};

  /// Per-PEER escalating backoff for a contact whose mailbox seal keeps failing
  /// `PeerUnresolved` (a dead/old identity — e.g. a peer that re-provisioned).
  /// Without it the 3s flush re-sends to such a ghost forever. Escalates
  /// 30s→1m→…→30m (cap); cleared on any successful stash for the peer, and reset
  /// on restart (a fresh resolve attempt) — it NEVER permanently drops, so if the
  /// identity resolves again delivery resumes.
  final Map<String, ({int count, DateTime nextAt})> _peerUnresolvedBackoff = {};
  static const _peerUnresolvedCap = Duration(minutes: 30);

  /// Event-log gap-fill (§15, 3c). A [WireKind.sync] beacon advertises our
  /// per-author high-water + holes to a peer; the peer re-ships every event we
  /// are missing above it (and vice-versa), so a flaky transport (lost live send,
  /// usable(KEM)=0 mailbox) self-heals to the full log — on top of the live +
  /// outbox + ack path, which stays as the fast path.
  ///
  /// Throttle per peer: we beacon at most once per [_syncSendInterval] (it costs
  /// a live send) and ACT on a peer's beacon at most once per [_syncActInterval]
  /// (a flood of sync{hw:0} must not make us re-ship in a storm — anti-
  /// amplification). Each re-ship round is bounded to [_syncReshipCap] events.
  final Map<String, DateTime> _lastSyncSentAt = {};
  final Map<String, DateTime> _lastSyncActedAt = {};
  static const _syncSendInterval = Duration(seconds: 20);
  static const _syncActInterval = Duration(seconds: 5);
  static const _syncReshipCap = 100;

  /// Resumable-file re-ship (§15 3c): answer a peer's [WireKind.fileNack] for a
  /// given (peer, transfer) at most once per [_fileNackInterval] (a flood can't
  /// drive a blob re-read + chunk re-send storm), and cap the chunks one NACK
  /// answers — the rest heal on the next round. The map is bounded: entries are
  /// written only AFTER the NACK resolves to a real outgoing file in THIS peer's
  /// conversation (a fresh-tid flood inserts nothing), inert entries (older than
  /// the interval) are evicted on each call, and it is cleared on reconnect — so
  /// it stays O(active transfers), never O(every tid ever seen).
  final Map<String, DateTime> _lastFileNackAt = {};
  static const _fileNackInterval = Duration(seconds: 3);
  static const _fileNackChunkCap = 256;

  /// Bounded reconnect (recovery handshake, §15.7). When a message stays un-acked
  /// past [_reconnectThreshold] the peer may have wiped its chat data + forgotten
  /// us (so our sends hit its consent gate and drop). We send a
  /// [WireKind.reconnect] re-intro at most every [_reconnectInterval] (throttled
  /// per peer via [_lastReconnectAt]). Give-up is PER MESSAGE, anchored to the
  /// message's OWN age: once a message stays un-acked past [_reconnectGiveUpAge]
  /// it flips to [MessageStatus.failed] ("not delivered"). This is deliberately
  /// NOT a shared per-peer counter — a chatty conversation to a dead peer would
  /// keep resetting such a counter and an old undelivered message would never
  /// terminate. The send throttle resets only when the peer acks (reachable);
  /// a later gap-fill beacon can still heal a failed message if the peer returns.
  final Map<String, DateTime> _lastReconnectAt = {};
  static const _reconnectThreshold = Duration(minutes: 2);
  static const _reconnectInterval = Duration(minutes: 15);
  static const _reconnectGiveUpAge = Duration(minutes: 90);

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

  /// Fires once per genuinely-new incoming message (after the consent gate +
  /// dedup), so the notification layer can alert without re-alerting on a
  /// re-delivery. The active identity's service is the one observed.
  Stream<IncomingNotice> get incoming => _incoming.stream;

  void start() {
    _sub ??= _transport.messages().listen(_onInbound);
    _retryTimer ??= Timer.periodic(_retryInterval, (_) => _retryFlush());
    unawaited(_loadFilePolicy()); // this identity's auto-download policy (A1)
    // Serve inbound bulk file streams (S2) when the transport supports them.
    if (_transport is StreamTransport) unawaited(_acceptStreamLoop());
  }

  /// Set in [dispose]; stops the stream accept loop.
  bool _disposed = false;

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

  /// Our node (re)connected — reconcile now. Clear the per-peer gap-fill throttle
  /// so the [WireKind.sync] beacon fires IMMEDIATELY for every peer (a reconnect
  /// is exactly when a peer may have missed our events while we were down), then
  /// flush the outbox (which sends the beacons + re-sends un-acked messages).
  Future<void> reconcileOnConnect() async {
    _lastSyncSentAt.clear();
    _lastSyncActedAt.clear();
    _lastFileNackAt.clear(); // bound the throttle map across reconnects
    await flushOutbox();
  }

  void _signal() {
    if (!_changes.isClosed) _changes.add(null);
  }

  void _emitIncoming(NodeId from, String preview, {required bool isFile}) {
    if (!_incoming.isClosed) {
      _incoming.add(
        IncomingNotice(from: from, preview: preview, isFile: isFile),
      );
    }
  }

  /// Persist a message and return its id. [id] lets the receiver reuse the
  /// SENDER's id (so re-sends dedup) instead of minting a fresh one.
  /// Our own node-id hex, cached after the first resolve — the event-log author
  /// of every OUTGOING message (R1). The transport exposes it only async, so we
  /// memoise it rather than awaiting a round-trip on every store.
  String? _selfHexCache;
  Future<String> _selfHex() async =>
      _selfHexCache ??= (await _transport.nodeId()).hex;

  Future<Message> _store(
    NodeId peer,
    MessageDirection dir,
    String body,
    MessageStatus status, {
    String? fileId,
    String? fileName,
    int? fileSize,
    String? fileContentId,
    String? id,
    DateTime? timestamp,
    int? seq,
  }) async {
    final msgId = id ?? _uuid.v4();
    return _storage.appendMessage(
      Message(
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
        fileSize: fileSize,
        fileContentId: fileContentId,
        // Event-log author (R1): the message originator's node id, bound to the
        // AUTHENTICATED side — our own for an outgoing message, the peer (the
        // server-authenticated conversation id) for an incoming one. Never
        // inferred from an in-band wire field.
        author: dir == MessageDirection.outgoing ? await _selfHex() : peer.hex,
        // The SENDER's seq when this is a wire-delivered incoming event (keeps
        // the log convergent, R4); null for our own outgoing message → storage
        // allocates the next gap-free value, which the caller puts on the wire.
        seq: seq,
      ),
    );
  }

  /// The sender's send time off the wire as a DateTime, or null (older sender
  /// without `sentAtMs` → caller falls back to receive time).
  ///
  /// Stored VERBATIM (no receiver-side clamp) so it is byte-identical on both
  /// devices — the basis for the convergent (effective_ts, author, seq) display
  /// order. The old future-clamp made the value receiver-dependent (it used the
  /// receiver's local now), which silently diverged the cross-author interleave
  /// across devices. It also never addressed the real skew concern (R9: a peer
  /// stamping ts=0 to float ABOVE my messages) — that is handled deterministically
  /// by the author-monotone effective_ts FLOOR in loadMessages. A future-stamped
  /// message now simply sorts to the bottom (convergently) on both devices — and
  /// since the floor carries that author's later messages down with it, a fast
  /// clock only buries the SENDER's own stream, never floats it above others.
  DateTime? _wireSentAt(WireEnvelope env) => _wireSentAtMs(env.sentAtMs);

  /// [DateTime] for a wire send-time in ms (the file-meta path has no envelope).
  DateTime? _wireSentAtMs(int? ms) =>
      ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);

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
    final intros =
        msgs.where((m) => m.direction == MessageDirection.incoming).toList()
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

  String _opKey(NodeId peer, String id) => '${peer.hex}|$id';

  /// Hold [op] until [peer]'s message [id] arrives (it drained out of order).
  /// Delete is terminal: once a delete is buffered, a later edit for the same id
  /// is ignored. Insertion-ordered + bounded — evict the oldest when full so a
  /// peer flooding ops for ids we never receive can't grow this without bound.
  void _bufferPendingOp(NodeId peer, String id, _PendingOp op) {
    final key = _opKey(peer, id);
    final existing = _pendingOps[key];
    if (existing != null && existing.isDelete) return; // delete already wins
    if (!_pendingOps.containsKey(key) && _pendingOps.length >= kMaxPendingOps) {
      _pendingOps.remove(_pendingOps.keys.first); // evict oldest insertion
    }
    _pendingOps[key] = op;
  }

  Future<void> _setStatus(NodeId peer, ContactStatus status) async {
    final existing = await _storage.getContact(peer);
    await _storage.upsertContact(
      (existing ?? Contact(nodeId: peer)).copyWith(status: status),
    );
  }

  /// Shared handling for a [WireKind.request] AND a [WireKind.reconnect] — both
  /// (re-)establish consent. [status] is the sender's CURRENT contact status.
  ///
  /// * accepted — they re-sent because they never saw our accept (a lost accept,
  ///   or THEY wiped + re-intro'd and we still hold them): re-send + re-stash the
  ///   accept so the handshake completes, instead of stranding either side.
  /// * unknown / pending — surface as a pendingIncoming intro (the greeting),
  ///   bounded by [kMaxPreConsentIntros]; the user accepting heals delivery.
  /// (blocked is dropped before dispatch — no "you're blocked" oracle. The sender
  /// emits reconnect unconditionally after a no-ack threshold, so this path can't
  /// tell whether the peer was merely offline or actually wiped — by design.)
  Future<void> _handleRequestOrReconnect(
    InboundMessage m,
    WireEnvelope env,
    ContactStatus? status,
  ) async {
    if (status == ContactStatus.accepted) {
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
      // request/reconnect would otherwise pile up unbounded greetings before we
      // ever accept. Evict the oldest down to the cap, keeping the most recent.
      await _capPreConsentIntros(m.src, env.id);
      // Store the greeting under its id so a later outbox re-send of the same
      // greeting (as a WireKind.message) dedups instead of creating a second copy.
      await _store(
        m.src,
        MessageDirection.incoming,
        env.body,
        MessageStatus.delivered,
        id: env.id,
        timestamp: _wireSentAt(env),
      );
    }
  }

  /// Serializes inbound handling. The stream listener ([start]) does NOT await
  /// our async handler, and [deliverInbound] (mailbox drain) feeds the SAME
  /// path, so without this two frames interleave at their `await` points. That
  /// let concurrent pre-consent intros each read the stored count below the cap
  /// in [_capPreConsentIntros] and both store — busting [kMaxPreConsentIntros]
  /// (an unbounded-greeting hole on a victim's device) — and more generally
  /// raced the consent gate / id-dedup check-then-act sequences. We process at
  /// most one frame at a time. [_handleInbound] is fully try/catch-guarded so
  /// the chained future never rejects and the queue can't be poisoned.
  Future<void> _inboundChain = Future<void>.value();

  Future<void> _onInbound(InboundMessage m) {
    final next = _inboundChain.then((_) => _handleInbound(m));
    _inboundChain = next;
    return next;
  }

  Future<void> _handleInbound(InboundMessage m) async {
    devLog(
      () =>
          'xVeil[recv]: INBOUND from=${m.src.short} bytes=${m.payload.length}',
    );
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
        await _handleRequestOrReconnect(m, env, existing?.status);
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
        devLog(
          () =>
              'xVeil[timeline]: recv id=$id replyId=${m.replyId} '
              't=${DateTime.now().millisecondsSinceEpoch}',
        );
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
        // The peer's edit/delete of this message may have DRAINED FIRST (mailbox
        // blobs are unordered): when they sent then edited/unsent it while we
        // were offline, both deposits arrive on reconnect in arbitrary order.
        final pending = id == null
            ? null
            : _pendingOps.remove(_opKey(m.src, id));
        if (pending != null && pending.isDelete) {
          // Honor the unsend: store then tombstone so the message never shows AND
          // a later re-delivery is refused (isMessageDeleted above) — deniable
          // erasure, not a transient hide. No notification for an unsent message.
          await _store(
            m.src,
            MessageDirection.incoming,
            env.body,
            MessageStatus.delivered,
            id: id,
            timestamp: _wireSentAt(env),
          );
          await _storage.deleteMessage(m.src.hex, id!);
          await _storage.scrubDeleted();
          await _ackTo(m, id, direct: true);
          return;
        }
        // Apply a buffered edit by storing the edited body directly, so the
        // latest text shows on first paint (no flash of the superseded text, and
        // the original body never hits the container — nothing to scrub).
        final body = pending?.body ?? env.body;
        await _store(
          m.src,
          MessageDirection.incoming,
          body,
          MessageStatus.delivered,
          id: id,
          timestamp: _wireSentAt(env),
          // Fold under the SENDER's seq (R4) so the (author, seq) is identical on
          // both devices — the basis for gap detection. Null from an older sender
          // → storage allocates locally (no cross-device convergence for them).
          seq: env.seq,
        );
        _emitIncoming(m.src, body, isFile: false);
        if (id != null) {
          await _ackTo(m, id);
        }
      case WireKind.ack:
        // Consent gate, like every other inbound arm: only an accepted contact
        // can flip our message state. Without this any non-blocked peer could
        // ack an arbitrary (guessed) id to forge a "delivered" mark and cancel
        // our retry backoff in any conversation. A legit ack only comes from a
        // peer we already accepted (we send messages — hence acks — only to them).
        if (existing?.status != ContactStatus.accepted) return;
        // The peer confirms delivery of our message [env.id] — stop re-sending.
        final ackId = env.id;
        if (ackId != null) {
          _retryBackoff.remove(ackId); // stop backing off a delivered message
          // The peer is reachable + still holds us — reset the reconnect throttle.
          _lastReconnectAt.remove(m.src.hex);
          // Idempotent: the peer's drain re-acks every cycle until its relay
          // blob ages out, so duplicate acks arrive in a storm. Mark delivered +
          // log + write storage only ONCE per id — re-doing it on every dup was
          // hammering the store (the user-visible "storage opens slowly").
          if (_delivered.add(ackId)) {
            // [timeline] sender-side "delivered" moment — pair with the send t0
            // to get the full perceived round-trip. id + time only.
            devLog(
              () =>
                  'xVeil[timeline]: delivered id=$ackId '
                  't=${DateTime.now().millisecondsSinceEpoch}',
            );
            // Scope by the sender's conversation (m.src.hex) so the status can
            // only land on a message that lives in THIS peer's chat.
            await _storage.markMessageStatus(
              m.src.hex,
              ackId,
              MessageStatus.delivered,
            );
          }
        }
      case WireKind.edit:
        // The peer edited a message THEY sent us. Apply only to an INCOMING
        // message we hold from this peer — a peer must never be able to rewrite
        // our own outgoing messages (the id travels on the wire, so they know
        // it; the direction check is the real authorization gate).
        if (existing?.status != ContactStatus.accepted) return;
        final editId = env.id;
        if (editId == null) break;
        if (await _isIncomingFrom(m.src, editId)) {
          // Fold under the EDITOR's seq (env.seq), like an incoming post — the
          // edit event's (author, seq) is then identical on both devices, so
          // conversationSync converges and gap-fill can re-ship a missed edit.
          // Null from an older sender → editMessage allocates locally (legacy).
          await _storage.editMessage(m.src.hex, editId, env.body, seq: env.seq);
          await _storage.scrubDeleted();
        } else if (!await _hasMessage(m.src, editId)) {
          // Target not arrived yet (offline send+edit drains out of order) —
          // buffer and replay when the message stores. NOT buffered when the id
          // IS present but outgoing (our own message): a peer can't edit ours.
          _bufferPendingOp(m.src, editId, _PendingOp.edit(env.body));
        }
      case WireKind.del:
        // The peer unsent a message THEY sent us — purge + scrub our copy too.
        // Same authorization gate: only their incoming messages, never ours.
        if (existing?.status != ContactStatus.accepted) return;
        final delId = env.id;
        if (delId == null) break;
        if (await _isIncomingFrom(m.src, delId)) {
          await _storage.deleteMessage(m.src.hex, delId);
          await _storage.scrubDeleted();
        } else if (!await _hasMessage(m.src, delId)) {
          // Same out-of-order case as edit: hold the unsend until the message
          // arrives, then the message arm tombstones it instead of resurrecting.
          _bufferPendingOp(m.src, delId, _PendingOp.delete());
        }
      case WireKind.sync:
        // Event-log gap-fill beacon (§15, 3c): the peer tells us what it holds
        // per author; we re-ship every event it is missing above its high-water.
        // Consent-gated (R2) — never reconcile a conversation with a non-accepted
        // node. We also beacon back so the peer heals OUR gaps in the same round.
        if (existing?.status != ContactStatus.accepted) return;
        await _handlePeerSync(m.src, env.body);
        return;
      case WireKind.voidSeq:
        // An inert seq placeholder from the peer's gap-fill: record the void slot
        // so our high-water for the peer's stream advances past a deleted/
        // superseded event it never delivered (renders nothing, no resurrection).
        if (existing?.status != ContactStatus.accepted) return;
        final vseq = env.seq;
        if (vseq != null) {
          await _storage.applyRemoteVoid(m.src.hex, m.src.hex, vseq);
        }
        return;
      case WireKind.clear:
        // The peer CLEARED the conversation up to a per-author seq watermark
        // (clear-for-everyone). Consent-gated (R2); the author is bound to the
        // AUTHENTICATED sender (R1, m.src). v1 policy: an accepted contact's clear
        // is APPLIED (the "delete for everyone" the sender intends) — a future
        // per-contact toggle can decline it; and once multi-device lands, a clear
        // from our OWN identity is authoritative for our devices the same way.
        if (existing?.status != ContactStatus.accepted) return;
        final cseq = env.seq;
        if (cseq != null) {
          Map<String, int> wm;
          try {
            final raw = jsonDecode(env.body);
            wm = raw is Map
                ? raw.map((k, v) => MapEntry(k as String, v as int))
                : <String, int>{};
          } catch (_) {
            return; // malformed watermark → drop
          }
          await _storage.applyRemoteClear(m.src, m.src.hex, cseq, wm);
          _signal();
        }
        return;
      case WireKind.fileQuery:
        // A gap-fill probe for a file (§15 3c, resumable): the peer still holds
        // file <tid> and asks what we're missing. Reply with a fileNack naming
        // the gaps (or "all" if we hold no chunk yet). The peer then re-sends only
        // those chunks, instead of re-pushing the whole blob each round.
        if (existing?.status != ContactStatus.accepted) return;
        await _handleFileQuery(m, parseFileMeta(env.body));
        return;
      case WireKind.fileNack:
        // The receiver lists the chunks it still needs of a file WE sent
        // (null = all). Re-send only those, rate-limited per (peer, transfer) so
        // a NACK flood can't drive a re-send storm.
        if (existing?.status != ContactStatus.accepted) return;
        final nack = parseFileNack(env.body);
        await _handleFileNack(m.src, nack.transferId, nack.missing);
        return;
      case WireKind.reconnect:
        // "We were connected — re-establish." Treated exactly like a request: a
        // peer who wiped its chat data (Case-A) no longer holds us, so our normal
        // messages/beacons hit its consent gate and drop; this re-intros us so it
        // can re-accept. Disambiguated by OUR state in _handleRequestOrReconnect
        // (accepted→re-ack; unknown/pending→pending intro; blocked→already
        // dropped). Falls through to _signal() so the pending surfaces in the UI.
        await _handleRequestOrReconnect(m, env, existing?.status);
      case WireKind.fileStream:
        // Large-file STREAM transfer announcement (any-size feature). The blob
        // arrives over a reliable veil stream into the external encrypted store;
        // the receive accept-loop + size-routed send are wired in a later stage.
        // Until then drop it gracefully — the sender's gap-fill re-announces, so
        // no message is lost once the receive path lands.
        if (existing?.status != ContactStatus.accepted) return;
        devLog(
          () =>
              'xVeil[recv]: fileStream announce '
              '${parseFileMeta(env.body).transferId} — receive not yet wired',
        );
        return;
      case WireKind.contentManifest:
        // A peer advertises a content manifest (the "torrent"): verify it,
        // register a transfer, request the pieces we lack.
        if (existing?.status != ContactStatus.accepted) return;
        await _onContentManifest(m.src, env.body);
        return;
      case WireKind.contentReoffer:
        // A peer lost the manifest handle (restart) but still holds the offer —
        // re-advertise if we are still serving (or can re-open a durable source).
        if (existing?.status != ContactStatus.accepted) return;
        await _onContentReoffer(m.src, env.body);
        return;
      case WireKind.pieceRequest:
        // A peer asks for pieces of content we serve — send the requested
        // pieces as chunks (paced).
        if (existing?.status != ContactStatus.accepted) return;
        _onPieceRequest(m.src, parsePieceRequest(env.body));
        return;
      case WireKind.pieceChunk:
        // One chunk of one piece: buffer + verify-on-complete; finish the
        // transfer when every piece is verified.
        if (existing?.status != ContactStatus.accepted) return;
        await _onPieceChunk(parsePieceChunk(env.body));
        return;
      case WireKind.unknown:
        // A structured (v:2) frame from a NEWER build whose kind we don't know —
        // the decoder already mapped it to this drop sentinel (RULE WC). Ignore.
        return;
      case WireKind.fileMeta:
        if (existing?.status != ContactStatus.accepted) {
          devLog(
            () =>
                'xVeil[recv]: fileMeta DROPPED — ${m.src.short} '
                'not accepted (status=${existing?.status})',
          );
          return;
        }
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
          _inFlight.removeWhere(
            (_, inc) =>
                cutoff.difference(inc.lastActivity) > kStaleIncomingFileTimeout,
          );
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
          seq:
              meta.seq, // the sender's filePost seq (null from an older sender)
          sentAtMs: meta.sentAtMs, // the sender's send-time (convergent order)
        );
        devLog(
          () =>
              'xVeil[recv]: fileMeta ${meta.transferId} "${meta.name}" '
              'count=${meta.count} size=${meta.size} <- ${m.src.short} — tracking',
        );
        return; // nothing to show until the file completes
      case WireKind.fileChunk:
        if (existing?.status != ContactStatus.accepted) {
          devLog(
            () =>
                'xVeil[recv]: fileChunk DROPPED — ${m.src.short} '
                'not accepted (status=${existing?.status})',
          );
          return;
        }
        final frame = parseFileChunk(env.body);
        final inc = _inFlight[frame.transferId];
        // Unknown transfer (chunk before meta), or a different peer trying to
        // contribute to someone else's in-flight transfer — drop it.
        if (inc == null || inc.src != m.src) {
          devLog(
            () =>
                'xVeil[recv]: fileChunk DROPPED — no meta for transfer '
                '${frame.transferId} (idx ${frame.index}/${frame.total}) <- ${m.src.short}'
                '${inc != null ? " (src mismatch)" : " (META LOST or not yet arrived)"}',
          );
          return;
        }
        inc.lastActivity = _now(); // progress — keep this transfer non-stale
        inc.reasm.add(
          FileChunk(
            transferId: frame.transferId,
            index: frame.index,
            total: frame.total,
            data: frame.data,
          ),
        );
        // Enforce the memory budget even if the peer lied about size — abort
        // and discard the partial transfer rather than buffer unboundedly.
        if (inc.reasm.bufferedBytes > kMaxIncomingFileBytes) {
          _inFlight.remove(frame.transferId);
          return;
        }
        if (!inc.reasm.isComplete) return; // wait for the rest
        final tid = frame.transferId;
        devLog(
          () =>
              'xVeil[recv]: file $tid "${inc.name}" COMPLETE — assembling + storing',
        );
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
        // Store the blob under a LOCALLY-minted id, NOT the sender-chosen
        // transferId: storeFile keys the blob globally (file:<id>) and overwrites,
        // so reusing the wire tid would let a colliding id from another
        // conversation clobber that chat's blob. The message id stays `tid` (its
        // dedup + deleted-resurrect guards are already conversation-scoped); only
        // the blob's storage key is decoupled.
        final localFileId = _uuid.v4();
        try {
          await _storage.storeFile(
            localFileId,
            inc.reasm.assemble(),
            name: inc.name,
          );
        } catch (e) {
          // Over the storage cap (the buffer cap should have aborted it first) or
          // a transient store error — drop the transfer rather than crash the
          // inbound chain. The sender's gap-fill can retry; no half-stored blob.
          devLog(() => 'xVeil[recv]: storeFile failed for $tid — dropped: $e');
          return;
        }
        await _store(
          m.src,
          MessageDirection.incoming,
          '📎 ${inc.name ?? 'file'}',
          MessageStatus.delivered,
          fileId: localFileId,
          fileName: inc.name,
          id: tid,
          // Fold the file under the SENDER's filePost seq + send-time (R4) so the
          // (author, seq) AND the convergent display time are identical on both
          // devices, and gap-fill can heal a missing file. Null from an older
          // sender → storage allocates a seq / falls back to receive time.
          seq: inc.seq,
          timestamp: _wireSentAtMs(inc.sentAtMs),
        );
        _emitIncoming(m.src, '📎 ${inc.name ?? 'file'}', isFile: true);
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
      await _store(
        dst,
        MessageDirection.outgoing,
        text,
        MessageStatus.sent,
        id: id,
        timestamp: sentAt,
      );
    }
    _signal();
    final wire = WireEnvelope.request(
      text,
      id: id,
      sentAtMs: sentAt.millisecondsSinceEpoch,
    ).encode();
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

  /// Lift a block — the peer becomes an accepted contact again so their
  /// messages are delivered (and we can message them). Local-only: the peer is
  /// never told they were blocked or unblocked (no presence/relationship
  /// oracle). A still-buffered re-send from them will flow on its next arrival.
  Future<void> unblockContact(NodeId peer) async {
    await _setStatus(peer, ContactStatus.accepted);
    _signal();
  }

  /// Set (or clear, when [name] is null/blank) a LOCAL display alias for [peer].
  /// Lives only in the encrypted contact record on this device — never sent on
  /// the wire, so it leaks nothing and is purely a readability aid over the raw
  /// node id. No-op if we hold no contact for the peer. Built directly (not via
  /// copyWith) so a blank name actually CLEARS the alias (copyWith's `?? old`
  /// can only set, never unset).
  Future<void> setContactName(NodeId peer, String? name) async {
    final existing = await _storage.getContact(peer);
    if (existing == null) return;
    final trimmed = name?.trim();
    await _storage.upsertContact(
      Contact(
        nodeId: existing.nodeId,
        name: (trimmed == null || trimmed.isEmpty) ? null : trimmed,
        status: existing.status,
        muted: existing.muted,
        pinned: existing.pinned,
      ),
    );
    _signal();
  }

  /// Mute (or unmute) notifications for [peer]'s conversation. Local-only — the
  /// flag lives in the encrypted contact record and is never sent. The
  /// notification layer reads it to suppress alerts; messages still arrive and
  /// store as normal. No-op if we hold no contact for the peer.
  Future<void> setContactMuted(NodeId peer, bool muted) async {
    final existing = await _storage.getContact(peer);
    if (existing == null) return;
    await _storage.upsertContact(existing.copyWith(muted: muted));
    _signal();
  }

  /// Pin (or unpin) [peer]'s conversation to the top of the chat list.
  /// Local-only, stored in the encrypted contact record. No-op if unknown.
  Future<void> setContactPinned(NodeId peer, bool pinned) async {
    final existing = await _storage.getContact(peer);
    if (existing == null) return;
    await _storage.upsertContact(existing.copyWith(pinned: pinned));
    _signal();
  }

  /// Set [peer]'s message-retention window in DAYS (null/<=0 = unlimited, the
  /// default). Persisted in the encrypted contact record, then applied
  /// immediately (prunes anything already past the window). Local-only; built
  /// directly so null actually CLEARS the policy (copyWith's `?? old` can't).
  Future<void> setContactRetention(NodeId peer, int? days) async {
    final existing = await _storage.getContact(peer);
    if (existing == null) return;
    final window = (days == null || days <= 0) ? null : days;
    await _storage.upsertContact(
      Contact(
        nodeId: existing.nodeId,
        name: existing.name,
        status: existing.status,
        muted: existing.muted,
        pinned: existing.pinned,
        retentionDays: window,
      ),
    );
    _signal();
    if (window != null) {
      await _storage.pruneConversation(peer, window);
      _signal();
    }
  }

  /// Apply [peer]'s retention policy now (called when a chat is opened, so an
  /// expired message disappears even without a periodic sweep). No-op when the
  /// conversation has no retention window.
  Future<void> pruneConversation(NodeId peer) async {
    try {
      final c = await _storage.getContact(peer);
      final days = c?.retentionDays;
      if (days == null || days <= 0) return;
      final pruned = await _storage.pruneConversation(peer, days);
      if (pruned > 0) _signal();
    } catch (_) {
      // Best-effort on open (like markRead): storage locked/unavailable → skip.
    }
  }

  /// Delete the whole conversation with [peer] from THIS device: removes the
  /// contact + every message from the encrypted store and drops the peer's
  /// in-memory send state so the outbox stops re-sending to it (this is how a
  /// user clears a dead/old "ghost" identity that can no longer be reached).
  /// Local-only — the peer is not notified.
  Future<void> deleteConversation(NodeId peer) async {
    await _storage.removeConversation(peer);
    _peerUnresolvedBackoff.remove(peer.hex);
    _signal();
  }

  /// Clear the message HISTORY of [peer]'s conversation but keep the contact —
  /// the chat stays in the list, emptied. Forensic (tombstone + scrub), so a
  /// re-delivery can't resurrect the cleared messages. Local-only — the peer is
  /// not told. Also forget any deposited-once markers for those ids so a future
  /// edit/del with a recycled id can still be deposited.
  Future<void> clearConversation(NodeId peer) async {
    // Clear locally AND emit a clear EVENT carrying a per-author seq watermark, so
    // the peer (and — once multi-device lands — our OWN other devices) converge to
    // the same emptied state on replay. Only the watermark travels (no oracle).
    final selfHex = await _selfHex();
    final ev = await _storage.emitClearConversation(peer, selfHex);
    final wire = WireEnvelope.clear(
      jsonEncode(ev.watermark),
      seq: ev.seq,
    ).encode();
    await _send(peer, wire);
    unawaited(_maybeStash(peer, 'clear:${ev.seq}', wire)); // offline carrier
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
    // both ends order this message identically. From the service clock ([_now])
    // so the per-message reconnect give-up age (and tests) share one timeline.
    final sentAt = _now();
    final stored = await _store(
      dst,
      MessageDirection.outgoing,
      trimmed,
      MessageStatus.sent,
      timestamp: sentAt,
    );
    final id = stored.id;
    _signal();
    // Stays `sent` until the peer acks; the local outbox re-sends un-acked ones
    // on reconnect, so a message written offline goes out when we come back. The
    // event seq travels so the peer folds it under OUR (author, seq) and can spot
    // a gap for gap-fill.
    final wire = WireEnvelope.message(
      trimmed,
      id: id,
      sentAtMs: sentAt.millisecondsSinceEpoch,
      seq: stored.seq,
    ).encode();
    // wantReply: embed a one-time reply path so the peer's delivery-ACK comes
    // back over THIS circuit (fast), flipping us to "delivered" without a full
    // resolve+circuit-build round-trip on their side.
    // [timeline] id + send-time only (random uuid + ms clock — no body/keys), so
    // receive-latency vs ACK-latency can be measured per message from the logs.
    devLog(
      () =>
          'xVeil[timeline]: send id=$id '
          't0=${sentAt.millisecondsSinceEpoch} wantReply=true',
    );
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
      // Event-log gap-fill beacon (§15, 3c): advertise what we hold so the peer
      // re-ships anything we are missing — and our beacon-back heals the peer.
      // Throttled per peer ([_syncSendInterval]); live-only, so it is independent
      // of the mailbox backoff below. The first tick after a (re)connect fires
      // immediately (no throttle entry yet), so reconnect triggers reconciliation.
      unawaited(_sendSyncTo(conv.peer.nodeId));
      final msgs = await _storage.loadMessages(conv.id);
      // Bounded reconnect + terminal "not delivered" (§15.7). Runs BEFORE the
      // resolve-backoff `continue` below so even a never-resolving peer's messages
      // eventually terminate at failed instead of retrying forever.
      await _maybeReconnect(conv.peer.nodeId, msgs);
      // Ghost give-up: a contact whose mailbox seal keeps failing
      // `PeerUnresolved` (a dead/old identity) is backed off per-peer, so we stop
      // re-sending to it every 3s forever. Escalating + non-permanent — the next
      // allowed tick retries, so a peer that resolves again still gets delivered.
      final pb = _peerUnresolvedBackoff[conv.peer.nodeId.hex];
      if (pb != null && DateTime.now().isBefore(pb.nextAt)) continue;
      for (final m in msgs) {
        if (m.direction == MessageDirection.outgoing &&
            m.status == MessageStatus.sent &&
            // Synchronous early-cancel: the durable status flips to `delivered`
            // a moment later (async write), so without this the next flush could
            // re-send a just-acked message in that window.
            !_delivered.contains(m.id) &&
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
          _retryBackoff[m.id] = (
            count: count,
            nextAt: now.add(Duration(milliseconds: delayMs)),
          );
          // Re-send with the ORIGINAL send time AND seq so a message recovered
          // via the outbox retry (not gap-fill) folds under OUR (author, seq) on
          // the peer — without the seq it would land under a divergent locally-
          // allocated seq, breaking convergence for the common retry path.
          final wire = WireEnvelope.message(
            m.body,
            id: m.id,
            sentAtMs: m.timestamp.millisecondsSinceEpoch,
            seq: m.seq,
          ).encode();
          // Re-sends do NOT request a reply: the first send already attached one
          // (sendText), and building a fresh one-time reply circuit on EVERY 3s
          // retry was the dominant circuit-build load (the reply path can't be
          // reused anyway). A plain re-send arrives with replyId==0, so the peer
          // ACKs over the durable resolve+circuit path — reliable, and it stops
          // the retry once it lands. This keeps the fast-ACK chance (first send)
          // without the per-retry circuit storm.
          // [timeline] one line per re-send so a session's retry count per id is
          // countable (a high count = the ACK round-trip is lagging). id only.
          devLog(
            () =>
                'xVeil[timeline]: retry id=${m.id} '
                't=${DateTime.now().millisecondsSinceEpoch}',
          );
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

  /// Bounded reconnect handshake (§15.7) for one peer. [msgs] is that peer's
  /// conversation. If a message has stayed un-acked past [_reconnectThreshold],
  /// the peer may have wiped its chat data and forgotten us — send a re-intro
  /// ([WireKind.reconnect]) so it can re-accept; throttled per peer to one every
  /// [_reconnectInterval]. Give-up is PER MESSAGE: a message un-acked past
  /// [_reconnectGiveUpAge] flips to [MessageStatus.failed] ("not delivered") so
  /// it stops retrying — anchored to the message's OWN age, NOT a shared counter
  /// (a steady drip of new sends to a dead peer must not keep an old undelivered
  /// message alive forever). A later gap-fill beacon can still heal it if the
  /// peer returns. (Offline-vs-wiped is indistinguishable — no presence oracle;
  /// an online accepted peer just re-acks the reconnect, harmless.)
  Future<void> _maybeReconnect(NodeId peer, List<Message> msgs) async {
    final now = _now();
    var failedAny = false;
    var anyTrying = false; // a stuck message still within the give-up window
    for (final m in msgs) {
      if (m.direction != MessageDirection.outgoing ||
          m.status != MessageStatus.sent ||
          _delivered.contains(m.id) ||
          now.difference(m.timestamp) <= _reconnectThreshold) {
        continue;
      }
      if (now.difference(m.timestamp) > _reconnectGiveUpAge) {
        // Terminal "not delivered" for THIS message. Stops the outbox retry
        // (status no longer `sent`); a later gap-fill beacon can still recover it.
        await _storage.markMessageStatus(peer.hex, m.id, MessageStatus.failed);
        failedAny = true;
      } else {
        anyTrying = true;
      }
    }
    if (failedAny) _signal();
    if (!anyTrying) {
      _lastReconnectAt.remove(peer.hex); // nothing left to re-intro → reset
      return;
    }
    final last = _lastReconnectAt[peer.hex];
    if (last != null && now.difference(last) < _reconnectInterval) return;
    _lastReconnectAt[peer.hex] = now;
    // Re-intro with an empty greeting — the contact only needs to surface as a
    // pending intro on a peer that forgot us; the user accepting heals delivery.
    final wire = const WireEnvelope.reconnect('').encode();
    await _send(peer, wire);
    final id = 'reconnect:${peer.hex}';
    _stashed.remove(id); // allow a fresh deposit each attempt
    unawaited(_maybeStash(peer, id, wire));
    devLog(() => 'xVeil[reconnect]: -> ${peer.short}');
  }

  /// Send an event-log gap-fill beacon ([WireKind.sync]) to [peer] over the LIVE
  /// path (no mailbox deposit — a beacon is only useful while the peer is online;
  /// an offline peer beacons us when it returns). The frame carries our per-author
  /// high-water + holes for this conversation, so the peer re-ships anything we
  /// are missing. Throttled per peer to [_syncSendInterval] unless [force]d.
  Future<void> _sendSyncTo(NodeId peer, {bool force = false}) async {
    final now = DateTime.now();
    final last = _lastSyncSentAt[peer.hex];
    if (!force && last != null && now.difference(last) < _syncSendInterval) {
      return;
    }
    _lastSyncSentAt[peer.hex] = now;
    final sync = await _storage.conversationSync(peer.hex);
    // Records don't JSON-encode → flatten each hole tuple to a [lo, hi] list.
    final holes = <String, List<List<int>>>{
      for (final e in sync.holes.entries)
        e.key: [
          for (final h in e.value) [h.$1, h.$2],
        ],
    };
    final body = jsonEncode({
      'hw': sync.highWater,
      if (holes.isNotEmpty) 'holes': holes,
      'ep': now.millisecondsSinceEpoch,
    });
    devLog(
      () =>
          'xVeil[sync]: -> ${peer.short} hw=${sync.highWater} '
          'holes=${holes.length}',
    );
    await _send(peer, WireEnvelope.sync(body).encode());
  }

  /// Handle a peer's gap-fill beacon: re-ship every event WE authored above the
  /// peer's high-water for our stream (oldest-first, bounded), then beacon back
  /// so the peer heals OUR gaps in the same round. Rate-limited per peer
  /// ([_syncActInterval]) so a flood of sync{hw:0} can't drive a re-ship storm.
  Future<void> _handlePeerSync(NodeId peer, String body) async {
    final now = DateTime.now();
    final lastActed = _lastSyncActedAt[peer.hex];
    if (lastActed != null && now.difference(lastActed) < _syncActInterval) {
      // Still beacon back (cheap, throttled) so the peer's gaps heal, but don't
      // re-run the (heavier) re-ship scan this often.
      unawaited(_sendSyncTo(peer));
      return;
    }
    _lastSyncActedAt[peer.hex] = now;

    Map<String, dynamic> j;
    try {
      j = jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      return; // malformed beacon — drop
    }
    final hw = j['hw'];
    if (hw is! Map) return;
    final selfHex = await _selfHex();
    // The peer's high-water for OUR author stream = how far it has folded us.
    final claimed = hw[selfHex];
    var peerHw = claimed is int && claimed >= 0 ? claimed : 0;
    // RULE HW: clamp to what we actually emitted — a peer can't ack/own a seq it
    // was never sent (anti-forgery). Our own stream is gap-free, so high-water ==
    // our max self seq; re-shipping above it would be a no-op anyway.
    final ours = await _storage.conversationSync(peer.hex);
    final ourMax = ours.highWater[selfHex] ?? 0;
    if (peerHw > ourMax) peerHw = ourMax;

    // Re-ship everything above the clamped high-water, oldest-first, bounded.
    // seq > hw already covers every named hole (all holes sit above the
    // contiguous high-water), so v1 needs no separate hole handling.
    final events = await _storage.loadEventsSince(
      peer.hex,
      selfHex,
      peerHw,
      limit: _syncReshipCap,
    );
    if (events.isNotEmpty) {
      devLog(
        () =>
            'xVeil[sync]: <- ${peer.short} peerHw(me)=$peerHw '
            'reship=${events.length}',
      );
      // Resolve ids → Messages once, so a file post can re-ship its BLOB (not
      // just the caption text). A file message is a post with a fileId.
      final byId = {
        for (final mm in await _storage.loadMessages(peer.hex)) mm.id: mm,
      };
      for (final ev in events) {
        switch (ev.kind) {
          case EventKind.post:
          case EventKind.filePost:
            final stored = byId[ev.id];
            final isFile =
                ev.kind == EventKind.filePost || (stored?.isFile ?? false);
            if (isFile) {
              // A file event: send a CHEAP probe (no blob load), never the caption
              // text. The receiver replies with a fileNack listing the chunks it
              // lacks and we re-send only those (resumable) — instead of pushing
              // the whole blob every round. A filePost whose row/blob is gone is
              // simply not probed (it heals as a void later).
              if (stored == null || stored.fileId == null) continue;
              await _send(
                peer,
                fileQueryEnvelope(
                  transferId: ev.id,
                  name: stored.fileName,
                  seq: ev.seq,
                  sentAtMs: ev.ts, // keep the file's ORIGINAL send-time
                ).encode(),
              );
              continue;
            }
            await _send(
              peer,
              WireEnvelope.message(
                ev.body ?? '',
                id: ev.id,
                sentAtMs: ev.ts,
                seq: ev.seq,
              ).encode(),
            );
          case EventKind.edit:
            if (ev.target == null) continue;
            await _send(
              peer,
              WireEnvelope.edit(
                ev.target!,
                ev.body ?? '',
                seq: ev.seq,
              ).encode(),
            );
          case EventKind.void_:
            await _send(peer, WireEnvelope.voidSeq(ev.seq).encode());
          case EventKind.delete:
          case EventKind.clear:
            // delete: never a stored event kind on this path. clear: the storage
            // re-ship maps a clear row to an inert void_ (its effect travels via
            // its own WireEnvelope.clear), so a clear LogEvent never reaches here.
            continue;
        }
      }
    }
    // Beacon back so the peer re-ships what WE are missing (throttled).
    unawaited(_sendSyncTo(peer));
  }

  /// Best-effort offline deposit of [wire] (the message envelope) for [peer],
  /// keyed by a stable 32-byte content id derived from the message [id]. No-op
  /// when there is no mailbox side-channel or we already stashed this message.
  Future<void> _maybeStash(NodeId peer, String id, Uint8List wire) async {
    final mailbox = _mailbox;
    if (mailbox == null) {
      devLog(
        () =>
            'xVeil[send]: stash SKIP dst=${peer.short} id=$id '
            '— NO mailbox (transport not VeilFlutter or no relays)',
      );
      return;
    }
    if (_stashed.contains(id)) {
      devLog(
        () =>
            'xVeil[send]: stash SKIP dst=${peer.short} id=$id — already stashed',
      );
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
      _peerUnresolvedBackoff.remove(
        peer.hex,
      ); // peer resolves again — un-ghost it
      devLog(
        () =>
            'xVeil[send]: stash OK dst=${peer.short} id=$id '
            '(deposited at recipient relay)',
      );
    } catch (e, st) {
      // No relay / no route yet — leave it un-stashed so a later flush retries
      // (after the backoff). LOG the real reason: this is the offline-delivery
      // path, and a swallowed failure here is invisible "message never arrived".
      _stashFailedAt[id] = DateTime.now();
      // A persistent `PeerUnresolved` means the recipient identity can't be
      // resolved at all (a dead/old identity — the ghost). Escalate a PER-PEER
      // backoff so the flush stops hammering it every 3s; cleared on any later
      // success, reset on restart — never a permanent drop.
      if (e.toString().contains('PeerUnresolved')) {
        final pb = _peerUnresolvedBackoff[peer.hex];
        final count = (pb?.count ?? 0) + 1;
        final secs = (30 * (1 << (count - 1))).clamp(
          30,
          _peerUnresolvedCap.inSeconds,
        );
        _peerUnresolvedBackoff[peer.hex] = (
          count: count,
          nextAt: DateTime.now().add(Duration(seconds: secs)),
        );
      }
      devLog(
        () =>
            'xVeil[send]: stash FAILED dst=${peer.short} id=$id '
            '(backoff ${_stashRetryBackoff.inSeconds}s): $e\n$st',
      );
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
    final dst = NodeId.fromHex(msg.conversationId);
    await deleteMessageLocally(messageId);
    final wire = WireEnvelope.del(messageId).encode();
    await _send(dst, wire);
    // Offline fallback (mirrors sendText): the live _send above only lands if
    // the peer is ONLINE — without this an unsend made while they are offline
    // is lost. Deposit it at the peer's mailbox relay so they purge their copy
    // on their next drain. Distinct stash id ('del:') so the relay does not
    // dedup it against the original message's deposit; cleared first so it
    // re-attempts a fresh deposit if a prior try is still recorded.
    final stashId = 'del:$messageId';
    _stashed.remove(stashId);
    unawaited(_maybeStash(dst, stashId, wire));
  }

  /// Edit the body of one of OUR sent messages: replace the stored text in
  /// place (the prior text is scrubbed), mark it edited, and propagate the new
  /// text to the recipient (best-effort). No-op for a received message.
  Future<void> editOwnMessage(String messageId, String newBody) async {
    final trimmed = newBody.trim();
    if (trimmed.isEmpty) return;
    final msg = await _find(messageId);
    if (msg == null || msg.direction != MessageDirection.outgoing) return;
    // The edit event allocates the next gap-free seq for our author stream; it
    // travels so the peer folds under the SAME (author, seq) we used (R4/R5) and
    // gap-fill can re-ship a missed edit. Null only if the id vanished mid-edit.
    final editSeq = await _storage.editMessage(
      msg.conversationId,
      messageId,
      trimmed,
    );
    await _storage.scrubDeleted();
    _signal();
    final dst = NodeId.fromHex(msg.conversationId);
    final wire = WireEnvelope.edit(messageId, trimmed, seq: editSeq).encode();
    await _send(dst, wire);
    // Offline fallback (mirrors sendText): the live _send above only lands if
    // the peer is ONLINE — without this an edit made while they are offline is
    // lost. Deposit it at the peer's mailbox relay so they apply the new text
    // on their next drain. Distinct stash id ('edit:') so the relay does not
    // dedup it against the original message's deposit; cleared first so a
    // re-edit of the same message re-attempts a fresh deposit.
    final stashId = 'edit:$messageId';
    _stashed.remove(stashId);
    unawaited(_maybeStash(dst, stashId, wire));
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
  /// records an outgoing file message (filePost, on the seq stream), then streams
  /// the bytes as fileMeta + fileChunk envelopes — the meta carrying the file's
  /// event seq so the receiver folds it convergently and gap-fill can heal it.
  Future<void> sendFile(NodeId dst, Uint8List bytes, String name) async {
    final contact = await _storage.getContact(dst);
    if (contact == null || contact.status != ContactStatus.accepted) return;
    // Large files take the content layer (hash-verified pieces over datagrams —
    // the path that actually crosses NAT) instead of the per-chunk fileMeta push.
    if (bytes.length > _contentThreshold) {
      await _sendAsContent(dst, bytes, name);
      return;
    }
    // Backstop the storage ceiling: the UI pre-checks the same bound and shows a
    // friendly error, but a direct caller must not drive storeFile past its
    // atomic-delete cap (which throws). Drop silently here — the UI owns the UX.
    if (bytes.length > kMaxStoredFileBytes) {
      devLog(() => 'xVeil[sendFile]: ${bytes.length}B over cap — dropped');
      return;
    }

    final fileId = _uuid.v4();
    await _storage.storeFile(fileId, bytes, name: name);
    // Use the transfer id AS the message id so the receiver's completion ack
    // (keyed by transfer id) flips this message sent -> delivered. The file
    // wire frames carry only the transfer id, not the message id.
    final stored = await _store(
      dst,
      MessageDirection.outgoing,
      '📎 $name',
      MessageStatus.sent,
      fileId: fileId,
      fileName: name,
      id: fileId,
      // Stamp from the service clock (like sendText) so the per-message reconnect
      // give-up age sees a consistent timeline for file messages too.
      timestamp: _now(),
    );
    _signal();
    await _sendFileFrames(
      dst,
      fileId,
      name,
      bytes,
      stored.seq,
      stored.timestamp.millisecondsSinceEpoch,
    );
  }

  /// Stream a file's wire frames (one fileMeta carrying [seq] + [sentAtMs] + the
  /// fileChunks) to [peer]. Shared by [sendFile] and the gap-fill re-ship so the
  /// frame format (and the seq/send-time on the meta) has one source of truth. A
  /// re-shipped file keeps its ORIGINAL send-time, not a fresh one.
  Future<void> _sendFileFrames(
    NodeId peer,
    String transferId,
    String? name,
    Uint8List bytes,
    int? seq,
    int? sentAtMs,
  ) async {
    final chunks = chunkBytes(
      bytes,
      transferId: transferId,
      maxChunk: _wireChunkBytes,
    );
    await _send(
      peer,
      fileMetaEnvelope(
        transferId: transferId,
        name: name,
        size: bytes.length,
        count: chunks.length,
        seq: seq,
        sentAtMs: sentAtMs,
      ).encode(),
    );
    for (final c in chunks) {
      await _send(
        peer,
        fileChunkEnvelope(
          transferId: c.transferId,
          index: c.index,
          total: c.total,
          data: c.data,
        ).encode(),
      );
      // Native send completes when the fragmented onion cells are queued, not
      // when the session drains them. Without pacing, a sub-MiB attachment can
      // enqueue >4K cells in one burst and silently trip LIMIT tx_queue.
      await Future<void>.delayed(_contentPacing);
    }
  }

  /// Respond to a gap-fill file PROBE (§15 3c, resumable): tell the sender which
  /// chunks of [meta].transferId we still need (or `null` = all, when we hold no
  /// chunk yet). We register an in-flight slot carrying the sender's seq/send-time
  /// so the completed file folds convergently when the re-sent chunks arrive.
  Future<void> _handleFileQuery(InboundMessage m, FileMetaFrame meta) async {
    final tid = meta.transferId;
    // Already complete (or deliberately deleted) → ACK it again. The sender may
    // be probing precisely because our original completion ACK was lost; staying
    // silent here leaves its UI stuck or lets an unrelated sync receipt be
    // mistaken for file completion.
    if (await _hasMessage(m.src, tid) ||
        await _storage.isMessageDeleted(m.src.hex, tid)) {
      await _ackTo(m, tid, direct: true);
      return;
    }
    var inc = _inFlight[tid];
    if (inc == null) {
      // Same capacity discipline as the fileMeta arm: reclaim stale slots first,
      // then refuse a NEW transfer only when still at capacity.
      if (_inFlight.length >= kMaxConcurrentIncomingFiles) {
        final cutoff = _now();
        _inFlight.removeWhere(
          (_, x) =>
              cutoff.difference(x.lastActivity) > kStaleIncomingFileTimeout,
        );
      }
      if (_inFlight.length >= kMaxConcurrentIncomingFiles) return;
      inc = _Incoming(
        src: m.src,
        name: meta.name,
        reasm: FileReassembler(),
        lastActivity: _now(),
        seq: meta.seq,
        sentAtMs: meta.sentAtMs,
      );
      _inFlight[tid] = inc;
    } else if (inc.src != m.src) {
      return; // someone else can't probe another peer's in-flight transfer
    }
    // What we're missing. Until a chunk has set the total we hold NONE, so ask
    // for everything (null) — the sender knows its own chunk count.
    final total = inc.reasm.total;
    final missing = total == null ? null : inc.reasm.missingIndices(total);
    await _send(
      m.src,
      fileNackEnvelope(transferId: tid, missing: missing).encode(),
    );
  }

  /// Re-send the chunks a peer's [WireKind.fileNack] asked for ([missing] == null
  /// → all) of a file WE sent THEM. Rate-limited per (peer, transfer) + chunk-
  /// capped so a NACK flood can't drive a blob-reread / chunk re-send storm.
  Future<void> _handleFileNack(
    NodeId peer,
    String transferId,
    List<int>? missing,
  ) async {
    // Resolve the file message WITHIN this peer's conversation — the transfer id
    // is attacker-chosen on the wire, so a GLOBAL lookup would let an accepted
    // peer pull ANOTHER conversation's file blob by naming its id (a cross-
    // conversation leak). Same conversation-scoped boundary as _hasMessage.
    Message? msg;
    for (final m in await _storage.loadMessages(peer.hex)) {
      if (m.id == transferId &&
          m.direction == MessageDirection.outgoing &&
          m.fileId != null) {
        msg = m;
        break;
      }
    }
    if (msg == null) return; // not a file WE sent THIS peer → ignore (no leak)
    // Rate-limit AFTER the ownership check, so a fresh-tid flood neither re-sends
    // a blob nor grows the throttle map. Evict inert entries (older than the
    // interval) so the map stays O(active transfers), not O(every tid ever).
    final now = DateTime.now();
    _lastFileNackAt.removeWhere(
      (_, v) => now.difference(v) > _fileNackInterval,
    );
    final key = '${peer.hex}:$transferId';
    final last = _lastFileNackAt[key];
    if (last != null && now.difference(last) < _fileNackInterval) return;
    _lastFileNackAt[key] = now;
    final bytes = await _storage.loadFile(msg.fileId!);
    if (bytes == null) return;
    final want = missing?.toSet();
    final chunks = chunkBytes(
      bytes,
      transferId: transferId,
      maxChunk: _wireChunkBytes,
    );
    var sent = 0;
    for (final c in chunks) {
      if (want != null && !want.contains(c.index)) continue;
      await _send(
        peer,
        fileChunkEnvelope(
          transferId: c.transferId,
          index: c.index,
          total: c.total,
          data: c.data,
        ).encode(),
      );
      await Future<void>.delayed(_contentPacing);
      if (++sent >= _fileNackChunkCap) break; // rest heal on the next round
    }
  }

  // ── Content layer: decentralized, hash-verified piece transfer (Stage 2) ────
  // Sender: advertise a manifest, then serve requested pieces as paced chunks.
  // Receiver: verify the manifest, request missing pieces, verify each piece on
  // arrival, reassemble + verify the WHOLE, then surface it. Order/loss-tolerant.

  /// Content we SERVE, by contentId — the MANIFEST plus, for a LARGE send, a live
  /// [source] over the user's ORIGINAL file. [_serveChunks] reads each requested
  /// chunk either from [source] (serve-from-source: no copy of the file is kept —
  /// the sender already HAS it, so storing one would just duplicate it, and for a
  /// big file that copy is what overflows the hidden-volume index) or, when
  /// [source] is null (small / in-RAM sends), from the on-disk blob store
  /// ([readFileRange]). Either way only a small manifest sits in RAM.
  /// [servedAt] is refreshed on every advertise/request so an ACTIVE transfer
  /// stays; an idle one is evicted by [_evictServing], which closes its [source].
  final Map<
    String,
    ({ContentManifest manifest, _ServeSource? source, DateTime servedAt})
  >
  _serving = {};

  /// A served manifest is dropped from [_serving] this long after its last
  /// advertise/request — the on-disk blob remains, so a later re-request simply
  /// re-advertises and re-seeds [_serving], reading the bytes back from disk.
  static const _servingTtl = Duration(minutes: 10);

  /// A long serve aborts if the receiver hasn't re-requested within this window
  /// (it refreshes [_serving] freshness on every request) — i.e. it abandoned the
  /// download. Comfortably above the receiver's re-request interval so an active
  /// transfer is never cut, but well under the idle [_servingTtl].
  static const _serveAbandonTimeout = Duration(seconds: 50);

  /// When a same-content re-send replaces a live serve source, the old source may
  /// still be feeding an already-accepted stream. Closing it immediately makes
  /// that stream fail with "File closed" mid-piece. Retire replaced handles after
  /// a grace window; stream serves normally use a per-stream reopened handle, so
  /// this is mostly a safety net for legacy/datagram reads.
  static const _serveSourceRetireGrace = Duration(minutes: 15);

  /// Active stream serves by content id. A same-content re-send may arrive while
  /// a large file is already being streamed; in that case we must not replace the
  /// live source/path underneath the running stream. This is especially important
  /// for Android file_picker cache paths, where a second pick of the same file can
  /// invalidate the previous temporary handle.
  final Map<String, int> _activeStreamServes = {};
  final Map<String, List<_ServeSource>> _retiredAfterStream = {};

  /// Cap on the number of concurrently-served manifests; the OLDEST are evicted
  /// first when over it. Manifests are small (piece hashes), but bound the count
  /// anyway so a long-lived node doesn't accumulate them without limit.
  static const _servingMaxEntries = 256;

  /// Re-opens a serve source for a persisted file path (DURABLE offers): on a
  /// reoffer request after our [_serving] entry is gone (restart / TTL), the
  /// sender re-opens the original file and re-serves. Injected because the
  /// dart:io open lives in the data layer (the service stays io-free). Null ⇒
  /// durable re-serve is off (tests / not wired) — a stale offer then needs a
  /// re-send. Returns null if the path can't be opened (file moved / SAF expired).
  Future<_ServeSource?> Function(String path)? sourceOpener;

  /// Content we are FETCHING: the verified manifest + the reassembler + the peer,
  /// plus an optional [_FetchSink] when the user chose to download UNENCRYPTED to
  /// a plaintext file (null ⇒ store via the Storage port — encrypted tier or
  /// in-volume).
  final Map<
    String,
    ({
      ContentManifest manifest,
      ContentTransfer xfer,
      NodeId peer,
      String name,
      _FetchSink? sink,
    })
  >
  _fetching = {};

  /// Last-progress wall-clock per fetched contentId, so a transfer ABANDONED
  /// mid-flight (the sender vanished) has its reassembler buffers evicted instead
  /// of leaking. An actively-progressing fetch (a recent chunk) is untouched.
  final Map<String, DateTime> _fetchActivity = {};
  static const _fetchStaleTimeout = Duration(minutes: 5);

  /// Test seam: how many files are currently cached for serving / being fetched
  /// (so a test can assert the RAM caches stay bounded by the eviction logic).
  @visibleForTesting
  int get servingCount => _serving.length;
  @visibleForTesting
  int get fetchingCount => _fetching.length;

  /// Manifests of OFFERED-but-not-yet-downloaded files (by contentId), retained so
  /// [downloadContent] can fetch on the user's opt-in. Bounded by [_maxOffered]
  /// (the manifest is small — piece hashes — but cap it anyway); the OFFER chat
  /// message is what persists, this is just the fetch handle.
  final Map<String, ({ContentManifest manifest, NodeId peer})> _offered = {};
  static const _maxOffered = 256;

  /// Per-identity auto-download policy (size cap + blocked types): which incoming
  /// files download silently vs. surface as an OFFER the user must accept — so a
  /// peer can't silently fill the disk or push an executable unbidden (Phase A1).
  /// Loaded from THIS identity's storage on [start]; the safe default applies
  /// until then (and for a fresh identity). Edited via [setFileDownloadPolicy].
  FileDownloadPolicy _filePolicy = FileDownloadPolicy.defaults;
  static const _kFilePolicySetting = 'file_policy';

  /// This identity's current incoming-file policy (read by the settings UI).
  FileDownloadPolicy get fileDownloadPolicy => _filePolicy;

  /// Apply + persist a new auto-download policy for THIS identity. Takes effect
  /// immediately (the next offer is judged against it) and survives restart.
  Future<void> setFileDownloadPolicy(FileDownloadPolicy policy) async {
    _filePolicy = policy;
    await _storage.putSetting(_kFilePolicySetting, jsonEncode(policy.toJson()));
  }

  /// Load this identity's stored policy (called from [start]); a missing or
  /// corrupt blob leaves the safe default in place.
  Future<void> _loadFilePolicy() async {
    try {
      final raw = await _storage.getSetting(_kFilePolicySetting);
      if (raw != null && raw.isNotEmpty) {
        _filePolicy = FileDownloadPolicy.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
      }
    } catch (_) {
      // Unparseable / store hiccup → keep defaults (fail safe, not open).
    }
  }

  /// Fires when a content transfer COMPLETES (all pieces streamed to disk). No
  /// bytes — the blob is on disk under contentId; read it via loadFile /
  /// readFileRange rather than holding the whole file in RAM.
  /// [savedToPath] is set only for an unencrypted download-to-file completion —
  /// the plaintext file's path (so the UI can say where it landed); null for a
  /// normal store (encrypted tier / in-volume).
  final _contentReceived =
      StreamController<
        ({String contentId, String name, String? savedToPath})
      >.broadcast();
  Stream<({String contentId, String name, String? savedToPath})>
  get contentReceived => _contentReceived.stream;

  /// Download progress for an in-flight fetch (verified/total pieces), emitted as
  /// each piece is stored/written — the UI shows it on the file bubble. The final
  /// emit has done == total; a fetch that never starts emits nothing.
  final _contentProgress =
      StreamController<({String contentId, int done, int total})>.broadcast();
  Stream<({String contentId, int done, int total})> get contentProgress =>
      _contentProgress.stream;

  /// Fires when a user download can't proceed — the re-advertise request timed
  /// out (the sender no longer serves the file). The UI clears any empty
  /// destination file and tells the user to ask for a re-send.
  final _contentFailed = StreamController<String>.broadcast();
  Stream<String> get contentDownloadFailed => _contentFailed.stream;

  Timer? _contentTimer;

  /// Re-request cadence for still-missing pieces (injectable for tests).
  final Duration _contentReRequestInterval;
  // Wire chunk per piece. Over the onion path a chunk is ONE auth_deliver message
  // (cap MAX_AUTH_DELIVER_MSG_BYTES 6144, base64+JSON framed) that fragments into
  // ceil(size/≈150 B) cells which must ALL arrive (no per-cell ARQ), so per-chunk
  // delivery is (1-p^redundancy)^cells. 512 B (~6 cells) was tuned for the BUGGY
  // rendezvous era (~50 % cell loss; 4000 B/~27 cells delivered ~2 %). With the
  // rendezvous fix delivery is now high, and a 512 B chunk wastes ~88 % of an
  // auth_deliver — millions of tiny messages for a big file. On a reliable
  // transport push it near the ceiling: 4096 B (base64+JSON ≈ 5.6 KB < 6144) is
  // the practical max, ~8× fewer messages than 512 B. Any chunk the queue/path
  // drops is healed by the chunk-granular re-request (self-correcting — never
  // lossy). Drop it back only if device logs show pieces stalling (per-chunk
  // delivery falling on a lossy path).
  static const _contentChunkBytes = 4096;
  // Per-chunk pacing: feed the local onion circuit builder steadily without
  // overflowing the per-session TX queue (a too-fast burst trips the silent
  // tx_queue drop — now logged as `LIMIT tx_queue`). Many small chunks, so keep
  // it short; tune against the tx_queue / delivery logs. Injectable so tests
  // (which deliver instantly) don't wait real-time per chunk.
  final Duration _contentPacing;

  /// How many not-yet-verified pieces a single re-request covers. Bounds the
  /// re-request size (each piece adds a ceil(chunkCount/8)-byte bitmap) so the
  /// re-request itself stays small enough to survive the lossy path, and focuses
  /// serving on a few pieces at a time so they complete sooner.
  static const _reRequestPieceWindow = 4;

  /// How many content chunks to put on the wire CONCURRENTLY before the next
  /// anti-burst pace. The serve loop used to send one chunk per [_contentPacing]
  /// (20 ms) — so a ~2250-chunk 1 MiB file spent ~45 s purely pacing. Emitting a
  /// small batch at once ("parallel parts") fills the session TX queue closer to
  /// the circuit's drain rate for a ~Nx speedup, while staying well under the
  /// all-at-once burst that trips the LIMIT tx_queue guard. Self-correcting: any
  /// chunk the queue drops under load is refilled by the chunk-granular
  /// re-request, so an over-eager batch is never lossy, only (at worst) no faster.
  static const _serveBatch = 6;

  /// Files larger than this go via the content layer (hash-verified pieces over
  /// the NAT-traversing datagram path) instead of the per-chunk fileMeta push.
  // Keep the legacy fileMeta/fileChunk burst below the native session queue's
  // cell budget. Larger attachments use the paced, hash-verified content path
  // with chunk-granular retries; this includes ordinary camera screenshots.
  static const _contentThreshold = 128 * 1024;

  /// Piece size that keeps the manifest inside one datagram (≤ ~70 pieces — the
  /// hex piece-hash list dominates the manifest JSON).
  static int _adaptivePieceSize(int size) {
    const maxPieces = 70;
    final needed = (size + maxPieces - 1) ~/ maxPieces;
    return needed > ContentManifest.defaultPieceSize
        ? needed
        : ContentManifest.defaultPieceSize;
  }

  /// Persist [bytes] as a streamed (uncapped) blob keyed by the manifest's
  /// contentId — the SAME on-disk piece layout the receiver builds — so the
  /// sender SERVES it from disk ([readFileRange]) without holding it in RAM and
  /// without the whole-file [storeFile] cap (which is what bounded send size).
  /// Idempotent: a blob already present (a re-send / re-advertise of identical
  /// bytes) is left as-is, so the de-dup store happens at most once.
  Future<void> _storeServedBlob(
    ContentManifest manifest,
    Uint8List bytes,
  ) async {
    final cid = manifest.contentId;
    if (await _storage.hasFile(cid)) return;
    for (var p = 0; p < manifest.pieceCount; p++) {
      final start = p * manifest.pieceSize;
      final end = start + manifest.pieceLength(p);
      await _storage.storeFilePiece(
        cid,
        p,
        manifest.pieceCount,
        manifest.pieceSize,
        bytes.length,
        Uint8List.sublistView(bytes, start, end),
        name: manifest.name,
      );
    }
  }

  /// Register [manifest] for serving and advertise it to [dst]. The bytes are
  /// read on request either from [source] (a large send, served straight from the
  /// user's original file) or — when [source] is null — from the on-disk blob
  /// store keyed by contentId. Shared tail of every advertise path. A prior
  /// [source] for this contentId is closed if we replace it (no leaked handle).
  Future<void> _advertiseStored(
    NodeId dst,
    ContentManifest manifest, {
    _ServeSource? source,
  }) async {
    final cid = manifest.contentId;
    final prev = _serving[cid];
    if (prev?.source != null &&
        source != null &&
        !_sameServeSource(prev!.source!, source)) {
      _retireServeSourceForContent(cid, prev.source!);
    } else if (prev?.source != null && source == null) {
      _retireServeSourceForContent(cid, prev!.source!);
    }
    _serving[cid] = (manifest: manifest, source: source, servedAt: _now());
    _evictServing();
    _ensureContentTimer();
    await _send(
      dst,
      contentManifestEnvelope(jsonEncode(manifest.toJson())).encode(),
    );
    final mid = manifest.msgId;
    devLog(
      () =>
          'xVeil[content]: advertise ${manifest.contentId.substring(0, 12)} '
          '(${manifest.pieceCount} pieces'
          '${mid != null ? ', msg ${mid.substring(0, 8)}' : ''}) -> ${dst.short}',
    );
  }

  bool _sameServeSource(_ServeSource a, _ServeSource b) =>
      identical(a, b) ||
      (identical(a.read, b.read) && identical(a.close, b.close));

  void _retireServeSourceForContent(String cid, _ServeSource source) {
    if ((_activeStreamServes[cid] ?? 0) > 0) {
      (_retiredAfterStream[cid] ??= []).add(source);
      return;
    }
    _retireServeSourceLater(source);
  }

  void _retireServeSourceLater(_ServeSource source) {
    Timer(_serveSourceRetireGrace, () async {
      try {
        await source.close();
      } catch (_) {}
    });
  }

  /// Persist [bytes] to the blob store (streamed pieces) and advertise. One
  /// source of truth for the in-RAM serve+advertise tail (the bare-content API
  /// and the in-RAM message path); [bytes] is not retained past the store.
  Future<void> _advertise(
    NodeId dst,
    ContentManifest manifest,
    Uint8List bytes,
  ) async {
    try {
      await _storeServedBlob(manifest, bytes);
    } catch (e) {
      devLog(
        () => 'xVeil[content]: serve-store failed for ${manifest.name}: $e',
      );
    }
    await _advertiseStored(dst, manifest);
  }

  /// Offer [bytes] as a bare content transfer to [dst] (no chat message / event
  /// identity): build the manifest, serve it, advertise it. Returns the contentId
  /// (the bytes' self-authenticating address). Used by tests + the recovery
  /// re-ship; user file sends go through [_sendAsContent] (which adds the event).
  Future<String> sendContent(NodeId dst, Uint8List bytes, String name) async {
    final manifest = ContentManifest.fromBytes(
      name,
      bytes,
      pieceSize: _adaptivePieceSize(bytes.length),
      chunkBytes: _contentChunkBytes,
    );
    final contact = await _storage.getContact(dst);
    if (contact?.status == ContactStatus.accepted) {
      await _advertise(dst, manifest, bytes);
    }
    return manifest.contentId;
  }

  /// Send a LARGE file via the content layer as a first-class filePost EVENT.
  /// The BYTES are content-addressed (stored + served by contentId, de-duped);
  /// the MESSAGE is a per-send event under a fresh [msgId] + the (author,seq) the
  /// log allocates — so a re-send (even of previously-DELETED content) surfaces
  /// as a NEW message (A), while identical bytes are never re-stored/re-fetched.
  Future<void> _sendAsContent(NodeId dst, Uint8List bytes, String name) async {
    // Hash the file ONCE → the manifest + contentId (the blob key).
    final base = ContentManifest.fromBytes(
      name,
      bytes,
      pieceSize: _adaptivePieceSize(bytes.length),
      chunkBytes: _contentChunkBytes,
    );
    final cid = base.contentId;
    // Store the blob under its HASH as streamed pieces (uncapped), de-duped: a
    // re-send of identical bytes keeps ONE copy, and a receiver that already
    // holds it skips the re-download. ([_advertise] would also ensure-store, but
    // do it here too so a send to a not-yet-accepted contact still retains the
    // local copy for a later re-ship.)
    try {
      await _storeServedBlob(base, bytes);
    } catch (e) {
      devLog(() => 'xVeil[content]: local store failed for $name: $e');
    }
    // Fresh per-send msgId = a NEW event each send (the (author,seq) event is the
    // identity, NOT the byte-hash → re-send surfaces, even after a delete).
    // fileId = contentId binds the message to its hash-keyed blob.
    final msgId = _uuid.v4();
    final stored = await _store(
      dst,
      MessageDirection.outgoing,
      '📎 $name',
      MessageStatus.sent,
      fileId: cid,
      fileName: name,
      id: msgId,
      timestamp: _now(),
    );
    _signal();
    // Advertise carrying THIS send's event identity so the receiver folds a
    // first-class filePost and acks by msgId (not the shared contentId).
    final contact = await _storage.getContact(dst);
    if (contact?.status != ContactStatus.accepted) return;
    await _advertise(
      dst,
      base.withEvent(msgId: msgId, author: stored.author, seq: stored.seq),
      bytes,
    );
  }

  /// Send a LARGE file by SERVING IT STRAIGHT FROM THE SOURCE — the user's
  /// original file on disk — with no stored or encrypted copy. [read] returns
  /// [length] bytes at [offset] of the source; [close] releases its handle when
  /// serving ends; [size] is the total. The sender already HAS the file, so
  /// keeping a copy would (a) duplicate it — 2× disk for a TB attachment — and
  /// (b) be exactly what overflowed the hidden-volume index on a big send. So we
  /// only HASH the source (one RAM-bounded pass → the manifest), record the
  /// filePost, and register the live source for serving; [_serveChunks] then
  /// reads each requested chunk from it on demand. Same content layer + contentId
  /// as the in-RAM path (so a streamed and an in-RAM send of the same bytes still
  /// share a swarm address). The source is owned by [_serving] and closed on
  /// eviction/dispose — the UI must NOT close it after this returns.
  Future<void> sendFileStreaming(
    NodeId dst,
    String name,
    int size,
    Future<Uint8List> Function(int offset, int length) read, {
    required Future<void> Function() close,
    String? sourcePath,
  }) async {
    final contact = await _storage.getContact(dst);
    if (contact == null || contact.status != ContactStatus.accepted) {
      await close(); // not serving this peer → release the handle now
      return;
    }
    // Hash the source piece-by-piece → manifest (contentId + per-piece hashes).
    // Holds at most one piece in RAM; on failure release the handle + surface.
    final ContentManifest base;
    try {
      base = await ContentManifest.fromReader(
        name: name,
        size: size,
        pieceSize: _adaptivePieceSize(size),
        chunkBytes: _contentChunkBytes,
        readRange: read,
      );
    } catch (e) {
      await close();
      devLog(() => 'xVeil[content]: stream hash failed for $name: $e');
      rethrow;
    }
    final cid = base.contentId;
    // Fresh per-send msgId = a NEW filePost event (identity is (author,seq), not
    // the byte-hash → a re-send surfaces even after a delete). fileId = contentId.
    final msgId = _uuid.v4();
    final stored = await _store(
      dst,
      MessageDirection.outgoing,
      '📎 $name',
      MessageStatus.sent,
      fileId: cid,
      fileName: name,
      fileSize: size,
      id: msgId,
      timestamp: _now(),
    );
    _signal();
    final m = base.withEvent(
      msgId: msgId,
      author: stored.author,
      seq: stored.seq,
    );
    final activeExisting = (_activeStreamServes[cid] ?? 0) > 0
        ? _serving[cid]
        : null;
    final activeSource = activeExisting?.source;
    // DURABLE offer: persist the manifest + the source PATH so a reoffer after a
    // restart can re-open the file and re-serve (best-effort; the file must still
    // be at that path). The manifest exceeds the KV value cap → file store.
    if (sourcePath != null && activeSource == null) {
      try {
        await _storage.storeFile(
          'mf:$cid',
          Uint8List.fromList(utf8.encode(jsonEncode(m.toJson()))),
          name: 'manifest',
        );
        await _storage.putSetting('served:$cid', sourcePath);
      } catch (e) {
        devLog(
          () => 'xVeil[content]: durable-offer persist failed for $cid: $e',
        );
      }
    } else if (sourcePath != null) {
      devLog(
        () =>
            'xVeil[content]: keep active source/path for '
            '${cid.substring(0, 12)} — same-content resend while streaming',
      );
    }
    if (activeSource != null) {
      // We only needed this newly-opened handle to hash/identify the resend. The
      // bytes are identical (same contentId), and an active stream is already
      // using the previous source/path; replacing it mid-flight can close or
      // invalidate the stream's file handle on Android file_picker cache paths.
      await close();
      await _advertiseStored(dst, m, source: activeSource);
    } else {
      // Register the live source + advertise — NO stored copy.
      await _advertiseStored(dst, m, source: (read: read, close: close));
    }
  }

  Future<void> _onContentManifest(NodeId peer, String body) async {
    final m = ContentManifest.fromJson(
      jsonDecode(body) as Map<String, dynamic>,
    );
    if (m == null) {
      devLog(
        () => 'xVeil[content]: manifest DROPPED (malformed) <- ${peer.short}',
      );
      return; // malformed / not self-consistent → untrusted, drop
    }
    // Surface the file as an OFFER first — metadata only (name/size + the
    // contentId to fetch), NO blob yet — idempotent on the sender's per-send
    // msgId. The receiver decides whether to download (anti-spam + disk control).
    await _surfaceFileOffer(peer, m);

    // We ALREADY hold these exact bytes (a re-offer / dedup) → the offer renders
    // as downloaded; ack so the sender flips sent->delivered.
    if (await _storage.hasFile(m.contentId)) {
      devLog(
        () =>
            'xVeil[content]: ${m.contentId.substring(0, 12)} ALREADY HELD '
            '<- ${peer.short} (no re-download)',
      );
      await _send(peer, WireEnvelope.ack(m.msgId ?? m.contentId).encode());
      _signal();
      return;
    }
    // Already pulling it (a re-advertise mid-download) → keep the latest identity.
    if (_fetching.containsKey(m.contentId)) {
      final cur = _fetching[m.contentId]!;
      _fetching[m.contentId] = (
        manifest: m,
        xfer: cur.xfer,
        peer: peer,
        name: m.name,
        sink: cur.sink,
      );
      return;
    }
    // Retain the manifest so the user (or auto-download) can fetch on demand.
    if (_offered.length >= _maxOffered && !_offered.containsKey(m.contentId)) {
      _offered.remove(_offered.keys.first);
    }
    _offered[m.contentId] = (manifest: m, peer: peer);

    // A user download was PARKED waiting for this manifest (re-advertise after a
    // restart) → start it now with its destination (sink for unencrypted-to-file,
    // null for the encrypted tier), regardless of the auto-download policy.
    if (_pendingDownload.containsKey(m.contentId)) {
      final sink = _pendingDownload.remove(m.contentId);
      _pendingTimers.remove(m.contentId)?.cancel();
      devLog(
        () =>
            'xVeil[content]: re-advertised manifest arrived for '
            '${m.contentId.substring(0, 12)} — resuming the parked download',
      );
      await _beginFetch(peer, m, sink: sink);
      return;
    }

    if (_filePolicy.allowsAuto(m.size, m.name)) {
      devLog(
        () =>
            'xVeil[content]: ${m.contentId.substring(0, 12)} '
            '(${m.size}B "${m.name}") <- ${peer.short} — auto-downloading (<= cap)',
      );
      await _beginFetch(peer, m);
    } else {
      devLog(
        () =>
            'xVeil[content]: ${m.contentId.substring(0, 12)} '
            '(${m.size}B "${m.name}") <- ${peer.short} — OFFERED (awaiting user)',
      );
    }
  }

  /// Register a fetch for [m] + request all its pieces. Evicts any abandoned
  /// reassembler first (RAM bound). [sink] (non-null) diverts each verified piece
  /// to a plaintext file the user picked, instead of the Storage port. Shared by
  /// auto-download and [downloadContent]/[downloadContentToFile].
  Future<void> _beginFetch(
    NodeId peer,
    ContentManifest m, {
    _FetchSink? sink,
  }) async {
    if (_fetching.containsKey(m.contentId)) {
      if (sink != null) {
        await sink.close(); // already fetching → drop the dupe sink
      }
      return;
    }
    final cutoff = _now();
    _fetching.removeWhere((cid, _) {
      final last = _fetchActivity[cid];
      final stale =
          last != null && cutoff.difference(last) > _fetchStaleTimeout;
      if (stale) _fetchActivity.remove(cid);
      return stale;
    });
    _fetching[m.contentId] = (
      manifest: m,
      xfer: ContentTransfer(m),
      peer: peer,
      name: m.name,
      sink: sink,
    );
    _fetchActivity[m.contentId] = _now();
    _ensureContentTimer();
    await _send(
      peer,
      pieceRequestEnvelope(contentId: m.contentId, indices: null).encode(),
    );
  }

  /// The user opted to download an OFFERED file into local STORAGE (the encrypted
  /// on-disk tier for a large file, or the hidden volume for a small one). No-op
  /// if we already hold the blob. If the in-memory manifest handle is gone (app
  /// restart — the offer MESSAGE synced via the event log but the one-shot
  /// manifest did not), ask the sender (over [peer]) to re-advertise; the
  /// download then continues automatically when the manifest arrives. The
  /// download choice itself is the §16.5 consent — a large file lands as an
  /// encrypted on-disk blob.
  Future<ContentDownloadResult> downloadContent(
    NodeId peer,
    String contentId,
  ) async {
    if (await _storage.hasFile(contentId)) {
      _signal();
      return ContentDownloadResult.started;
    }
    devLog(() => 'xVeil[content]: user download ${contentId.substring(0, 12)}');
    _markContentDownloadStarted(contentId);
    // Reliable STREAM path (fast + flow-controlled): fetches the manifest itself,
    // so it works even without a live offer handle (no reoffer dance needed).
    if (await _pullStream(peer, contentId, null)) {
      return ContentDownloadResult.started;
    }
    // Datagram fallback (transport has no streams — e.g. a loopback fake).
    final offered = _offered[contentId];
    if (offered == null) {
      return _requestReoffer(peer, contentId, null);
    }
    await _beginFetch(offered.peer, offered.manifest);
    return ContentDownloadResult.started;
  }

  /// The user opted to download an OFFERED file UNENCRYPTED, straight to a
  /// plaintext file they picked. [write]/[close] is the file sink (created in the
  /// UI); each verified piece is written at its byte offset, nothing is kept in
  /// the app. On completion the file is closed and a [contentReceived] event
  /// fires carrying [savedPath]. If the manifest handle is gone, the sender is
  /// asked to re-advertise (the sink is held until it arrives or times out).
  Future<ContentDownloadResult> downloadContentToFile(
    NodeId peer,
    String contentId,
    String savedPath, {
    required Future<void> Function(int offset, Uint8List bytes) write,
    required Future<void> Function() close,
  }) async {
    final sink = (write: write, close: close);
    devLog(
      () =>
          'xVeil[content]: user download-to-file (unencrypted) '
          '${contentId.substring(0, 12)} -> $savedPath',
    );
    _markContentDownloadStarted(contentId);
    // Reliable STREAM path (fast). Works without a live offer handle.
    if (await _pullStream(peer, contentId, sink, savedPath: savedPath)) {
      return ContentDownloadResult.started;
    }
    // Datagram fallback.
    _fetchSavePath[contentId] = savedPath;
    final offered = _offered[contentId];
    if (offered == null) {
      return _requestReoffer(peer, contentId, sink);
    }
    await _beginFetch(offered.peer, offered.manifest, sink: sink);
    return ContentDownloadResult.started;
  }

  /// Surface user intent immediately. The stream path may spend seconds opening
  /// an anonymous circuit before the manifest / first verified piece arrives;
  /// without this, the file bubble looks like the tap was ignored.
  void _markContentDownloadStarted(String contentId) {
    if (!_contentProgress.isClosed) {
      _contentProgress.add((contentId: contentId, done: 0, total: 1));
    }
  }

  /// Destination paths for in-flight unencrypted-to-file downloads (so the
  /// completion event can report where the plaintext file landed).
  final Map<String, String> _fetchSavePath = {};

  /// The plaintext path an UNENCRYPTED download of [contentId] was saved to —
  /// the UI OPENS it on tap instead of re-offering (it isn't in the app store).
  /// Null if it was never downloaded unencrypted.
  Future<String?> contentSavedPath(String contentId) =>
      _storage.getSetting('saved:$contentId');

  /// Downloads waiting for a re-advertised manifest (contentId → its sink, null
  /// for an encrypted/in-volume download). [_onContentManifest] consumes these.
  final Map<String, _FetchSink?> _pendingDownload = {};
  final Map<String, Timer> _pendingTimers = {};
  static const _reofferTimeout = Duration(seconds: 20);

  /// Ask [peer] to re-advertise [contentId] (we have the offer but not the live
  /// manifest) and park the download until the manifest arrives. A timeout frees
  /// a parked file sink (so a RandomAccessFile handle isn't leaked if the sender
  /// can no longer serve — then the user must re-send).
  ContentDownloadResult _requestReoffer(
    NodeId peer,
    String contentId,
    _FetchSink? sink,
  ) {
    devLog(
      () =>
          'xVeil[content]: no live manifest for '
          '${contentId.substring(0, 12)} — requesting re-advertise <- ${peer.short}',
    );
    _pendingDownload[contentId] = sink;
    _pendingTimers[contentId]?.cancel();
    _pendingTimers[contentId] = Timer(_reofferTimeout, () {
      _pendingTimers.remove(contentId);
      final parked = _pendingDownload.remove(contentId);
      if (parked != null) unawaited(parked.close()); // release the file handle
      _fetchSavePath.remove(contentId);
      devLog(
        () =>
            'xVeil[content]: re-advertise TIMED OUT for '
            '${contentId.substring(0, 12)} — sender not serving; re-send needed',
      );
      if (!_contentFailed.isClosed) _contentFailed.add(contentId);
    });
    unawaited(_send(peer, contentReofferEnvelope(contentId).encode()));
    return ContentDownloadResult.requestedReoffer;
  }

  /// A peer asked us to re-advertise [contentId] (their manifest handle is gone).
  /// Re-send the manifest if we are still serving it (refreshing its TTL), or —
  /// DURABLE offer — re-open the persisted source file and re-serve from the
  /// persisted manifest (so an offer survives our restart / the serve TTL). Fails
  /// quietly (→ receiver times out → re-send) if there is no durable record, no
  /// opener, or the file is gone.
  Future<void> _onContentReoffer(NodeId peer, String contentId) async {
    final served = _serving[contentId];
    if (served != null) {
      _serving[contentId] = (
        manifest: served.manifest,
        source: served.source,
        servedAt: _now(),
      );
      devLog(
        () =>
            'xVeil[content]: re-advertising ${contentId.substring(0, 12)} '
            '-> ${peer.short} (live serving)',
      );
      unawaited(
        _send(
          peer,
          contentManifestEnvelope(
            jsonEncode(served.manifest.toJson()),
          ).encode(),
        ),
      );
      return;
    }
    if (sourceOpener == null) {
      devLog(
        () =>
            'xVeil[content]: reoffer for UNSERVED '
            '${contentId.substring(0, 12)} <- ${peer.short} (no opener — re-send)',
      );
      return;
    }
    try {
      final path = await _storage.getSetting('served:$contentId');
      final mfBytes = await _storage.loadFile('mf:$contentId');
      if (path == null || mfBytes == null) {
        devLog(
          () =>
              'xVeil[content]: reoffer ${contentId.substring(0, 12)} — no '
              'durable record <- ${peer.short} (re-send)',
        );
        return;
      }
      final m = ContentManifest.fromJson(
        jsonDecode(utf8.decode(mfBytes)) as Map<String, dynamic>,
      );
      if (m == null) return;
      final src = await sourceOpener!(path);
      if (src == null) {
        devLog(
          () =>
              'xVeil[content]: reoffer ${contentId.substring(0, 12)} — '
              'source GONE ($path) <- ${peer.short} (re-send)',
        );
        return;
      }
      _serving[contentId] = (manifest: m, source: src, servedAt: _now());
      _evictServing();
      _ensureContentTimer();
      devLog(
        () =>
            'xVeil[content]: re-advertising ${contentId.substring(0, 12)} '
            '-> ${peer.short} (DURABLE — re-opened $path)',
      );
      unawaited(
        _send(peer, contentManifestEnvelope(jsonEncode(m.toJson())).encode()),
      );
    } catch (e) {
      devLog(
        () =>
            'xVeil[content]: durable reoffer failed for '
            '${contentId.substring(0, 12)}: $e',
      );
    }
  }

  /// Content ids with a [_serveChunks] loop currently running — only ONE serve
  /// per content at a time. A serve-from-source [RandomAccessFile] is a single
  /// cursor, so two concurrent serves thrash it ("An async operation is currently
  /// pending", and almost every read fails → the transfer crawls). A request that
  /// lands mid-serve is skipped; the receiver's re-request loop re-asks for
  /// whatever is still missing once the current serve finishes.
  final Set<String> _servingNow = {};

  void _onPieceRequest(NodeId peer, PieceRequestFrame req) {
    final served = _serving[req.contentId];
    if (served == null) {
      devLog(
        () =>
            'xVeil[content]: pieceRequest for UNSERVED '
            '${req.contentId.substring(0, 12)} <- ${peer.short} (ignored)',
      );
      return; // not serving this content
    }
    // Refresh freshness on EVERY request (even one we skip) — it isn't evicted
    // mid-flight, and the live serve loop reads this to know the receiver is
    // still interested (it STOPS when the requests stop — see [_serveChunks]).
    _serving[req.contentId] = (
      manifest: served.manifest,
      source: served.source,
      servedAt: _now(),
    );
    if (_servingNow.contains(req.contentId)) {
      devLog(
        () =>
            'xVeil[content]: pieceRequest ${req.contentId.substring(0, 12)} '
            '— a serve is already in flight, skipping <- ${peer.short}',
      );
      return; // one serve loop per content (single-cursor source)
    }
    final m = served.manifest;
    // gaps: pieceIndex → chunk indices to serve (null ⇒ every chunk of the piece).
    final Map<int, List<int>?> gaps;
    final bm = req.bitmaps;
    if (bm != null && bm.isNotEmpty) {
      gaps = {
        for (final e in bm.entries)
          if (e.key >= 0 && e.key < m.pieceCount)
            e.key: _chunksFromBitmap(m, e.key, e.value),
      };
      final total = gaps.values.fold<int>(0, (a, b) => a + (b?.length ?? 0));
      devLog(
        () =>
            'xVeil[content]: pieceRequest ${req.contentId.substring(0, 12)} '
            'CHUNK-granular ($total chunks over ${gaps.length} pieces) '
            '<- ${peer.short} -> serving',
      );
    } else {
      final indices = req.indices ?? [for (var i = 0; i < m.pieceCount; i++) i];
      gaps = {for (final p in indices) p: null};
      devLog(
        () =>
            'xVeil[content]: pieceRequest ${req.contentId.substring(0, 12)} '
            '(${indices.length}/${m.pieceCount} whole pieces) <- ${peer.short} '
            '-> serving',
      );
    }
    _servingNow.add(req.contentId);
    unawaited(
      _serveChunks(
        peer,
        m,
        served.source,
        gaps,
      ).whenComplete(() => _servingNow.remove(req.contentId)),
    );
  }

  /// Drop served manifests idle past [_servingTtl], then — if still over
  /// [_servingMaxEntries] — evict the OLDEST until under it. A serve-from-source
  /// entry's [_ServeSource.close] is called as it leaves (release the file
  /// handle); a later re-request to an evicted entry simply finds nothing served
  /// and the receiver gives up (a re-send re-opens the source).
  void _evictServing() {
    final now = _now();
    _serving.removeWhere((cid, v) {
      if ((_activeStreamServes[cid] ?? 0) > 0) return false;
      if (now.difference(v.servedAt) <= _servingTtl) return false;
      if (v.source != null) unawaited(v.source!.close());
      return true;
    });
    if (_serving.length <= _servingMaxEntries) return;
    final byAge = _serving.entries.toList()
      ..sort((a, b) => a.value.servedAt.compareTo(b.value.servedAt));
    for (final e in byAge) {
      if (_serving.length <= _servingMaxEntries) break;
      if ((_activeStreamServes[e.key] ?? 0) > 0) continue;
      if (e.value.source != null) unawaited(e.value.source!.close());
      _serving.remove(e.key);
    }
  }

  /// Decode a missing-chunk bitmap into the chunk indices it marks for piece [p].
  List<int> _chunksFromBitmap(ContentManifest m, int p, Uint8List bm) {
    final cc = m.chunkCount(p);
    return [
      for (var c = 0; c < cc; c++)
        if ((c >> 3) < bm.length && (bm[c >> 3] & (1 << (c & 7))) != 0) c,
    ];
  }

  /// Serve [gaps] (pieceIndex → chunk indices, null ⇒ all chunks of the piece)
  /// of content [m] to [peer]. Each chunk's bytes are read either from [source]
  /// (the sender's original file, for a large serve-from-source send) or — when
  /// [source] is null — from the on-disk blob ([readFileRange]) at the derived
  /// offset; the file is never held in RAM. Chunk coordinates come from the
  /// manifest's [ContentManifest.chunkBytes] so they match the receiver.
  Future<void> _serveChunks(
    NodeId peer,
    ContentManifest m,
    _ServeSource? source,
    Map<int, List<int>?> gaps,
  ) async {
    // Flatten the requested (piece, chunk) coordinates into one list so we can
    // emit them in bounded batches across pieces, not strictly piece-by-piece.
    final coords = <({int p, int c})>[];
    for (final entry in gaps.entries) {
      final p = entry.key;
      if (p < 0 || p >= m.pieceCount) continue;
      final n = m.chunkCount(p);
      final chunks = entry.value ?? [for (var c = 0; c < n; c++) c];
      for (final c in chunks) {
        if (c >= 0 && c < n) coords.add((p: p, c: c));
      }
    }
    for (var i = 0; i < coords.length; i += _serveBatch) {
      // Stop a long serve the receiver has ABANDONED: if it stopped re-requesting
      // (its fetch completed / went stale), our [_serving] freshness goes stale
      // (refreshed on every pieceRequest). Otherwise the sender grinds out a
      // whole big file nobody is fetching (the receiver logs "pieceChunk DROPPED"
      // for every late chunk) — wasted bandwidth + log spam.
      final cur = _serving[m.contentId];
      if (cur == null ||
          _now().difference(cur.servedAt) > _serveAbandonTimeout) {
        devLog(
          () =>
              'xVeil[content]: serve STOPPED ${m.contentId.substring(0, 12)} '
              'at chunk $i/${coords.length} — receiver no longer requesting',
        );
        return;
      }
      final end = (i + _serveBatch < coords.length)
          ? i + _serveBatch
          : coords.length;
      // READ the batch sequentially (a serve-from-source RandomAccessFile is a
      // single cursor — concurrent reads would race it; on-disk readFileRange is
      // fine either way), then SEND the batch CONCURRENTLY for throughput — the
      // re-request loop refills anything the TX queue sheds under load.
      final batch = <({int p, int c, Uint8List data})>[];
      for (var j = i; j < end; j++) {
        final p = coords[j].p, c = coords[j].c;
        final cb = m.chunkBytes;
        final plen = m.pieceLength(p);
        final cstart = p * m.pieceSize + c * cb;
        final clen = (c * cb + cb <= plen) ? cb : plen - c * cb;
        Uint8List? data;
        try {
          data = source != null
              ? await source.read(cstart, clen)
              : await _storage.readFileRange(m.contentId, cstart, clen);
        } catch (e) {
          devLog(
            () =>
                'xVeil[content]: serve read failed '
                '${m.contentId.substring(0, 12)} p$p c$c: $e',
          );
        }
        if (data != null) batch.add((p: p, c: c, data: data));
      }
      await Future.wait([
        for (final ch in batch)
          _send(
            peer,
            pieceChunkEnvelope(
              contentId: m.contentId,
              pieceIndex: ch.p,
              chunkIndex: ch.c,
              chunkCount: m.chunkCount(ch.p),
              data: ch.data,
            ).encode(),
          ),
      ]);
      await Future<void>.delayed(
        _contentPacing,
      ); // anti-burst pace between batches
    }
  }

  // ── Stream-based bulk transfer (S2/S3) ──────────────────────────────────────
  // Large files ride veil's RELIABLE, window-flow-controlled stream instead of
  // fire-and-forget datagrams + manual re-request: the transport's congestion
  // control fills the circuit without overflowing the tx_queue (the datagram path
  // blasted ~6:1 → ~80% drops). Wire: the receiver opens a stream and writes the
  // 32-byte contentId; the sender replies [u32 manifest-len][manifest JSON][file
  // bytes…] then closes (EOF). The receiver checks the manifest binds the
  // REQUESTED cid (cid binds manifest binds pieces → a malicious sender can't
  // substitute), then verifies each piece as it reassembles from the byte stream.

  static const int _streamReadChunk =
      256 * 1024; // source read / wire write unit
  static const int _streamRequestBytes =
      2048; // fixed request frame: cid + padding
  static const Duration _streamRequestTimeout = Duration(seconds: 20);
  static const Duration _streamManifestTimeout = Duration(seconds: 25);
  static const Duration _streamSourceReadTimeout = Duration(seconds: 30);
  static const Duration _defaultStreamPayloadIdleTimeout = Duration(
    seconds: 60,
  );
  static const Duration _streamPayloadWriteTimeout = Duration(seconds: 120);
  static const int _streamServeMaxParallelPerContent = 3;
  static const int _defaultStreamPullMaxAttempts = 24;
  final Duration _streamPayloadIdleTimeout;
  final int _streamPullMaxAttempts;
  bool _acceptingStreams = false;

  bool _beginStreamServe(String cid) {
    final active = _activeStreamServes[cid] ?? 0;
    if (active >= _streamServeMaxParallelPerContent) return false;
    _activeStreamServes[cid] = active + 1;
    return true;
  }

  void _endStreamServe(String cid) {
    final active = (_activeStreamServes[cid] ?? 0) - 1;
    if (active > 0) {
      _activeStreamServes[cid] = active;
      return;
    }
    _activeStreamServes.remove(cid);
    final retired = _retiredAfterStream.remove(cid);
    if (retired != null) {
      for (final source in retired) {
        _retireServeSourceLater(source);
      }
    }
  }

  /// Accept inbound bulk streams + serve the requested file. Started by [start]
  /// when the transport supports streams; ends on [dispose].
  Future<void> _acceptStreamLoop() async {
    if (_acceptingStreams) return;
    _acceptingStreams = true;
    final st = _transport as StreamTransport;
    while (!_disposed) {
      try {
        final r = await st.acceptStream(timeout: const Duration(seconds: 2));
        if (r != null) {
          devLog(() => 'xVeil[content]: stream-accept <- ${r.src.short}');
          unawaited(_serveStream(r.src, r.stream));
        }
      } catch (e) {
        devLog(() => 'xVeil[content]: acceptStream error: $e');
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
  }

  /// Serve one inbound bulk stream: read the 32-byte contentId, then write the
  /// manifest + the file bytes from our source (live serve-from-source, or a
  /// durable re-open). Closes the stream (EOF) when done / on any failure.
  Future<void> _serveStream(NodeId peer, ReliableStream stream) async {
    _ServeSource? durable; // opened just for this serve (closed in finally)
    String? activeCid;
    try {
      devLog(() => 'xVeil[content]: stream-serve accepted <- ${peer.short}');
      final reqBytes = await _readExactly(
        stream,
        _streamRequestBytes,
      ).timeout(_streamRequestTimeout, onTimeout: () => null);
      if (reqBytes == null) {
        devLog(
          () =>
              'xVeil[content]: stream-serve EOF/timeout before request '
              '<- ${peer.short}',
        );
        return; // peer hung up before requesting
      }
      final cidBytes = Uint8List.sublistView(reqBytes, 0, 32);
      final cid = _hexEncode(cidBytes);
      final requestedOffset = reqBytes.length >= 40
          ? _readU64be(Uint8List.sublistView(reqBytes, 32, 40))
          : 0;
      devLog(
        () =>
            'xVeil[content]: stream-serve request '
            '${cid.substring(0, 12)}'
            '${requestedOffset > 0 ? ' @ $requestedOffset' : ''} '
            '<- ${peer.short}',
      );
      if (!_beginStreamServe(cid)) {
        devLog(
          () =>
              'xVeil[content]: stream-serve too many active '
              '${cid.substring(0, 12)} <- ${peer.short} (closing retry)',
        );
        return;
      }
      activeCid = cid;
      ContentManifest? manifest;
      _ServeSource? source;
      final live = _serving[cid];
      if (live != null) {
        manifest = live.manifest;
        // Prefer a per-stream file handle when we persisted the source path.
        // A repeated send of the same bytes has the same contentId and replaces
        // the shared live source; if this stream borrowed that shared handle, the
        // replacement could close it mid-transfer ("File closed"). A reopened
        // handle is independent and is closed in this method's finally.
        if (sourceOpener != null) {
          final path = await _storage.getSetting('served:$cid');
          if (path != null) {
            source = durable = await sourceOpener!(path);
          }
        }
        source ??= live.source;
      } else if (sourceOpener != null) {
        final path = await _storage.getSetting('served:$cid');
        final mfBytes = await _storage.loadFile('mf:$cid');
        if (path != null && mfBytes != null) {
          manifest = ContentManifest.fromJson(
            jsonDecode(utf8.decode(mfBytes)) as Map<String, dynamic>,
          );
          if (manifest != null) source = durable = await sourceOpener!(path);
        }
      }
      if (manifest == null || source == null) {
        devLog(
          () =>
              'xVeil[content]: stream-serve UNSERVED '
              '${cid.substring(0, 12)} <- ${peer.short} (close → re-send)',
        );
        return; // close → receiver sees EOF before the manifest
      }
      final m = manifest; // promoted non-null (closures need a final)
      final src = source;
      devLog(
        () =>
            'xVeil[content]: stream-serve ${cid.substring(0, 12)} '
            '(${m.size}B) -> ${peer.short}',
      );
      final mf = Uint8List.fromList(utf8.encode(jsonEncode(m.toJson())));
      await stream.write(_u32be(mf.length)).timeout(_streamPayloadWriteTimeout);
      await stream.write(mf).timeout(_streamPayloadWriteTimeout);
      devLog(
        () =>
            'xVeil[content]: stream-serve manifest sent '
            '${cid.substring(0, 12)} (${mf.length}B) -> ${peer.short}',
      );
      final size = m.size;
      var off = requestedOffset.clamp(0, size).toInt();
      if (off > 0) {
        devLog(
          () =>
              'xVeil[content]: stream-serve resume '
              '${cid.substring(0, 12)} from $off/${size}B -> ${peer.short}',
        );
      }
      final serveSw = Stopwatch()..start();
      var lastServeLogBytes = off;
      var lastServeLogMs = 0;
      while (off < size) {
        final n =
            ((size - off) < _streamReadChunk ? (size - off) : _streamReadChunk)
                .toInt();
        final data = await src
            .read(off, n)
            .timeout(
              _streamSourceReadTimeout,
              onTimeout: () => throw TimeoutException(
                'source idle at $off/$size',
                _streamSourceReadTimeout,
              ),
            );
        if (data.isEmpty) break; // source truncated
        await stream
            .write(data)
            .timeout(
              _streamPayloadWriteTimeout,
              onTimeout: () => throw TimeoutException(
                'payload write idle at $off/$size',
                _streamPayloadWriteTimeout,
              ),
            ); // flow-controlled (back-pressures)
        off += data.length;
        final elapsedMs = serveSw.elapsedMilliseconds;
        if (off == data.length ||
            off >= size ||
            off - lastServeLogBytes >= 1024 * 1024 ||
            elapsedMs - lastServeLogMs >= 2000) {
          devLog(
            () =>
                'xVeil[content]: stream-serve queued '
                '${cid.substring(0, 12)} $off/${size}B -> ${peer.short}',
          );
          lastServeLogBytes = off;
          lastServeLogMs = elapsedMs;
        }
      }
      devLog(
        () =>
            'xVeil[content]: stream-serve complete '
            '${cid.substring(0, 12)} $off/${size}B -> ${peer.short}',
      );
    } catch (e) {
      devLog(() => 'xVeil[content]: stream-serve failed <- ${peer.short}: $e');
    } finally {
      final cid = activeCid;
      if (cid != null) _endStreamServe(cid);
      if (durable != null) {
        try {
          await durable.close();
        } catch (_) {}
      }
      try {
        await stream.close();
      } catch (_) {}
    }
  }

  /// Try to download [cid] from [peer] over a RELIABLE stream. Returns true if it
  /// took ownership (runs async to completion / failure); false if streams aren't
  /// available so the caller falls back to the datagram path. The bytes land in
  /// [sink] (unencrypted-to-file) or the Storage port (encrypted tier / in-volume)
  /// with per-piece verification + progress. Works WITHOUT a live offer handle —
  /// the manifest arrives on the stream, so no reoffer dance.
  Future<bool> _pullStream(
    NodeId peer,
    String cid,
    _FetchSink? sink, {
    String? savedPath,
  }) async {
    final t = _transport;
    if (t is! StreamTransport) return false;
    final sw = Stopwatch()..start();
    devLog(
      () =>
          'xVeil[content]: stream-open ${cid.substring(0, 12)} '
          '-> ${peer.short}',
    );
    final slowLog = Timer(const Duration(seconds: 5), () {
      devLog(
        () =>
            'xVeil[content]: stream-open still pending '
            '${cid.substring(0, 12)} -> ${peer.short} '
            '(${sw.elapsedMilliseconds}ms)',
      );
    });
    ReliableStream? stream;
    try {
      stream = await (t as StreamTransport).openStream(peer);
    } finally {
      slowLog.cancel();
    }
    if (stream == null) {
      devLog(
        () =>
            'xVeil[content]: stream-open unavailable '
            '${cid.substring(0, 12)} -> ${peer.short} '
            '(${sw.elapsedMilliseconds}ms), using datagram fallback',
      );
      return false; // no circuit → caller falls back
    }
    devLog(
      () =>
          'xVeil[content]: stream-open ok ${cid.substring(0, 12)} '
          '-> ${peer.short} (${sw.elapsedMilliseconds}ms)',
    );
    unawaited(_runPull(peer, cid, sink, stream, savedPath));
    return true;
  }

  Future<void> _runPull(
    NodeId peer,
    String cid,
    _FetchSink? sink,
    ReliableStream initialStream,
    String? savedPath,
  ) async {
    var ok = false;
    Object? lastError;
    ReliableStream? stream = initialStream;
    ContentManifest? resumeManifest;
    var resumePiece = 0;
    try {
      for (
        var attempt = 1;
        attempt <= _streamPullMaxAttempts && !_disposed;
        attempt++
      ) {
        var payloadStarted = false;
        var readBytes = 0;
        var committedPieces = 0;
        Timer? manifestWait;
        final attemptStream = stream;
        stream = null;
        ReliableStream? current;
        try {
          current = attemptStream ?? await _openRetryStream(peer, cid, attempt);
          if (current == null) {
            throw StateError('stream retry-open unavailable');
          }
          devLog(
            () =>
                'xVeil[content]: stream-pull request '
                '${cid.substring(0, 12)} -> ${peer.short} '
                '(attempt $attempt)',
          );
          final resumeFrom = resumeManifest;
          final resumeOffset = resumeFrom == null
              ? 0
              : (resumePiece * resumeFrom.pieceSize)
                    .clamp(0, resumeFrom.size)
                    .toInt();
          // The sender consumes the whole fixed-size request frame. The first
          // 32 bytes are contentId; bytes 32..40 carry an optional big-endian
          // resume offset. The rest stays padding. A multi-cell first write
          // nudges the pinned-circuit path out of the observed
          // SYN/accept/no-DATA hole without leaving unread padding in the
          // peer's receive window.
          final req = Uint8List(_streamRequestBytes)
            ..setAll(0, _hexDecode(cid))
            ..setAll(32, _u64be(resumeOffset));
          await current.write(req).timeout(_streamRequestTimeout);
          devLog(
            () =>
                'xVeil[content]: stream-pull request sent '
                '${cid.substring(0, 12)} -> ${peer.short} '
                '(${req.length}B'
                '${resumeOffset > 0 ? ', resume=$resumeOffset' : ''}, '
                'attempt $attempt)',
          );
          manifestWait = Timer(const Duration(seconds: 5), () {
            devLog(
              () =>
                  'xVeil[content]: stream-pull waiting manifest '
                  '${cid.substring(0, 12)} <- ${peer.short} '
                  '(attempt $attempt)',
            );
          });
          final lenB = await _readExactly(
            current,
            4,
          ).timeout(_streamManifestTimeout, onTimeout: () => null);
          manifestWait.cancel();
          manifestWait = null;
          if (lenB == null) {
            throw StateError('no manifest (sender not serving)');
          }
          final mfLen = _readU32be(lenB);
          if (mfLen <= 0 || mfLen > (1 << 20)) {
            throw StateError('bad manifest len');
          }
          final mfBytes = await _readExactly(
            current,
            mfLen,
          ).timeout(_streamManifestTimeout, onTimeout: () => null);
          if (mfBytes == null) throw StateError('manifest truncated');
          final m = ContentManifest.fromJson(
            jsonDecode(utf8.decode(mfBytes)) as Map<String, dynamic>,
          );
          if (m == null || m.contentId != cid) {
            throw StateError('manifest does not bind the requested cid');
          }
          final previous = resumeManifest;
          if (previous != null &&
              (previous.size != m.size ||
                  previous.pieceSize != m.pieceSize ||
                  previous.pieceCount != m.pieceCount ||
                  previous.contentId != m.contentId)) {
            throw StateError('manifest changed across resume');
          }
          resumeManifest ??= m;
          final startPiece = resumeOffset > 0
              ? (resumeOffset ~/ m.pieceSize).clamp(0, m.pieceCount)
              : 0;
          readBytes = (startPiece * m.pieceSize).clamp(0, m.size).toInt();
          payloadStarted = true;
          devLog(
            () =>
                'xVeil[content]: stream-pull ${cid.substring(0, 12)} '
                '(${m.size}B, ${m.pieceCount} pieces) <- ${peer.short} '
                '(attempt $attempt'
                '${readBytes > 0 ? ', resume=$readBytes' : ''})',
          );
          if (!_contentProgress.isClosed) {
            _contentProgress.add((
              contentId: cid,
              done: readBytes,
              total: m.size,
            ));
          }
          var lastProgressBytes = readBytes;
          var lastProgressMs = 0;
          final progressSw = Stopwatch()..start();
          const minProgressBytes = 1024 * 1024; // avoid UI backpressure
          const minProgressMs = 1000;
          void emitReadProgress() {
            if (_contentProgress.isClosed || m.size <= 0) return;
            final elapsedMs = progressSw.elapsedMilliseconds;
            if (readBytes < m.size &&
                readBytes - lastProgressBytes < minProgressBytes &&
                elapsedMs - lastProgressMs < minProgressMs) {
              return;
            }
            final visibleDone = readBytes < m.size ? readBytes : m.size - 1;
            _contentProgress.add((
              contentId: cid,
              done: visibleDone,
              total: m.size,
            ));
            lastProgressBytes = readBytes;
            lastProgressMs = elapsedMs;
          }

          final buf = BytesBuilder(copy: false);
          var bufLen = 0;
          for (var pi = startPiece; pi < m.pieceCount; pi++) {
            final pieceLen = m.pieceLength(pi);
            while (bufLen < pieceLen) {
              final chunk = await current
                  .read(maxBytes: _streamReadChunk)
                  .timeout(
                    _streamPayloadIdleTimeout,
                    onTimeout: () => throw TimeoutException(
                      'payload idle after $readBytes/${m.size}B',
                      _streamPayloadIdleTimeout,
                    ),
                  );
              if (chunk.isEmpty) throw StateError('stream EOF mid-piece $pi');
              buf.add(chunk);
              bufLen += chunk.length;
              readBytes = (readBytes + chunk.length).clamp(0, m.size).toInt();
              emitReadProgress();
            }
            final acc = buf.takeBytes(); // clears buf
            final piece = acc.length == pieceLen
                ? acc
                : Uint8List.sublistView(acc, 0, pieceLen);
            if (!m.verifyPiece(pi, piece)) {
              throw StateError('piece $pi failed verify');
            }
            if (sink != null) {
              await sink.write(pi * m.pieceSize, piece);
            } else {
              await _storage.storeFilePiece(
                cid,
                pi,
                m.pieceCount,
                m.pieceSize,
                m.size,
                piece,
                name: m.name,
              );
            }
            committedPieces++;
            if (acc.length > pieceLen) {
              buf.add(Uint8List.sublistView(acc, pieceLen));
              bufLen = acc.length - pieceLen;
            } else {
              bufLen = 0;
            }
          }
          ok = true;
          await _finishReceived(peer, m, sink, savedPath);
          if (!_contentProgress.isClosed) {
            _contentProgress.add((contentId: cid, done: m.size, total: m.size));
          }
          break;
        } catch (e) {
          lastError = e;
          if (payloadStarted && committedPieces > 0) {
            final completed = (resumePiece + committedPieces)
                .clamp(
                  0,
                  resumeManifest?.pieceCount ?? resumePiece + committedPieces,
                )
                .toInt();
            if (completed > resumePiece) {
              resumePiece = completed;
              final m = resumeManifest;
              final resumeBytes = m == null
                  ? 0
                  : (resumePiece * m.pieceSize).clamp(0, m.size).toInt();
              devLog(
                () =>
                    'xVeil[content]: stream-pull resume point '
                    '${cid.substring(0, 12)} piece=$resumePiece '
                    'offset=$resumeBytes after attempt $attempt',
              );
            }
          }
          devLog(
            () =>
                'xVeil[content]: stream-pull attempt $attempt failed '
                '${cid.substring(0, 12)}: $e',
          );
          if (attempt == _streamPullMaxAttempts || _disposed) {
            break;
          }
        } finally {
          manifestWait?.cancel();
          try {
            await current?.close();
          } catch (_) {}
        }

        await Future<void>.delayed(_streamPullRetryDelay(attempt));
      }
    } finally {
      if (!ok && lastError != null) {
        devLog(
          () =>
              'xVeil[content]: stream-pull failed '
              '${cid.substring(0, 12)}: $lastError',
        );
      }
      if (!ok && sink != null) {
        try {
          await sink.close();
        } catch (_) {}
      }
      if (!ok && !_contentFailed.isClosed) _contentFailed.add(cid);
    }
  }

  Future<ReliableStream?> _openRetryStream(
    NodeId peer,
    String cid,
    int attempt,
  ) async {
    final t = _transport;
    if (t is! StreamTransport) return null;
    final streamTransport = t as StreamTransport;
    devLog(
      () =>
          'xVeil[content]: stream-pull retry-open '
          '${cid.substring(0, 12)} -> ${peer.short} '
          '(attempt $attempt)',
    );
    try {
      return await streamTransport
          .openStream(peer)
          .timeout(_streamRequestTimeout, onTimeout: () => null);
    } catch (e) {
      devLog(
        () =>
            'xVeil[content]: stream-pull retry-open failed '
            '${cid.substring(0, 12)} -> ${peer.short}: $e',
      );
      return null;
    }
  }

  static Duration _streamPullRetryDelay(int attempt) {
    final ms = 250 * attempt;
    return Duration(milliseconds: ms > 3000 ? 3000 : ms);
  }

  /// Finalise a completed RECEIVE: an unencrypted-to-file download closes the
  /// sink, remembers the path (tap → open), and reports it; an in-app store
  /// surfaces offer→downloaded. Acks the sender either way (flips sent→delivered).
  Future<void> _finishReceived(
    NodeId peer,
    ContentManifest m,
    _FetchSink? sink,
    String? savedPath,
  ) async {
    final ackId = m.msgId ?? m.contentId;
    if (sink != null) {
      try {
        await sink.close();
      } catch (_) {}
      if (savedPath != null) {
        try {
          await _storage.putSetting('saved:${m.contentId}', savedPath);
        } catch (_) {}
      }
      devLog(
        () =>
            'xVeil[content]: COMPLETE ${m.contentId.substring(0, 12)} '
            '(${m.size}B) saved to $savedPath',
      );
      await _send(peer, WireEnvelope.ack(ackId).encode());
      if (!_contentReceived.isClosed) {
        _contentReceived.add((
          contentId: m.contentId,
          name: m.name,
          savedToPath: savedPath,
        ));
      }
      return;
    }
    devLog(
      () =>
          'xVeil[content]: COMPLETE ${m.contentId.substring(0, 12)} '
          '(${m.size}B) stored',
    );
    final persisted = await _persistReceivedContent(peer, m);
    if (persisted) await _send(peer, WireEnvelope.ack(ackId).encode());
    if (!_contentReceived.isClosed) {
      _contentReceived.add((
        contentId: m.contentId,
        name: m.name,
        savedToPath: null,
      ));
    }
  }

  /// Read EXACTLY [n] bytes (looping); null on EOF before [n] arrives.
  static Future<Uint8List?> _readExactly(ReliableStream s, int n) async {
    final out = BytesBuilder(copy: false);
    var got = 0;
    while (got < n) {
      final chunk = await s.read(maxBytes: n - got);
      if (chunk.isEmpty) return null; // EOF
      out.add(chunk);
      got += chunk.length;
    }
    return out.takeBytes();
  }

  static Uint8List _u32be(int v) =>
      Uint8List(4)..buffer.asByteData().setUint32(0, v);
  static int _readU32be(Uint8List b) =>
      b.buffer.asByteData(b.offsetInBytes, 4).getUint32(0);
  static Uint8List _u64be(int v) =>
      Uint8List(8)..buffer.asByteData().setUint64(0, v);
  static int _readU64be(Uint8List b) =>
      b.buffer.asByteData(b.offsetInBytes, 8).getUint64(0);

  static String _hexEncode(Uint8List b) {
    const d = '0123456789abcdef';
    final sb = StringBuffer();
    for (final x in b) {
      sb
        ..write(d[(x >> 4) & 0xf])
        ..write(d[x & 0xf]);
    }
    return sb.toString();
  }

  static Uint8List _hexDecode(String s) {
    final out = Uint8List(s.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  Future<void> _onPieceChunk(PieceChunkFrame f) async {
    final fetch = _fetching[f.contentId];
    if (fetch == null) {
      // The manifest never arrived (or this content was already completed/
      // deleted): we hold no reassembler, so the chunk is dropped. A burst of
      // these means a LOST MANIFEST — the receiver can't reassemble or
      // re-request without it.
      devLog(
        () =>
            'xVeil[content]: pieceChunk DROPPED — no manifest/fetch for '
            '${f.contentId.substring(0, 12)} (p${f.pieceIndex} c${f.chunkIndex})',
      );
      return; // not fetching this content
    }
    _fetchActivity[f.contentId] =
        _now(); // progress — keep this fetch non-stale
    final piece = fetch.xfer.addChunk(
      f.pieceIndex,
      f.chunkIndex,
      f.chunkCount,
      f.data,
    );
    if (piece != null) {
      // Stream the verified piece STRAIGHT to its destination; the reassembler
      // keeps no piece bytes, so the whole file never sits in RAM (any size).
      final m = fetch.manifest;
      try {
        if (fetch.sink != null) {
          // UNENCRYPTED download → write the piece to the user's plaintext file
          // at its byte offset; nothing is kept in the app.
          await fetch.sink!.write(f.pieceIndex * m.pieceSize, piece);
        } else {
          // Store via the Storage port (encrypted on-disk tier / in-volume).
          await _storage.storeFilePiece(
            m.contentId,
            f.pieceIndex,
            m.pieceCount,
            m.pieceSize,
            m.size,
            piece,
            name: m.name,
          );
        }
      } catch (e) {
        fetch.xfer.unverify(f.pieceIndex); // write failed → re-request it
        devLog(
          () =>
              'xVeil[content]: piece ${f.pieceIndex} store/write failed '
              'for ${m.contentId.substring(0, 12)}: $e',
        );
        return;
      }
      devLog(
        () =>
            'xVeil[content]: piece ${f.pieceIndex} VERIFIED+'
            '${fetch.sink != null ? 'WRITTEN' : 'STORED'} for '
            '${m.contentId.substring(0, 12)} '
            '(${fetch.xfer.verifiedCount}/${fetch.xfer.pieceCount})',
      );
      if (!_contentProgress.isClosed) {
        _contentProgress.add((
          contentId: f.contentId,
          done: fetch.xfer.verifiedCount,
          total: fetch.xfer.pieceCount,
        ));
      }
    }
    if (!fetch.xfer.isComplete) return;
    // Every piece verified AND written → done.
    _fetching.remove(f.contentId);
    _fetchActivity.remove(f.contentId);
    final ackId = fetch.manifest.msgId ?? f.contentId;
    final sink = fetch.sink;
    if (sink != null) {
      // UNENCRYPTED-to-file: the bytes are on the user's disk, NOT in the app —
      // so no offer→downloaded flip; just finalise the file, ack (we received
      // it), and tell the UI where it landed.
      final savedPath = _fetchSavePath.remove(f.contentId);
      try {
        await sink.close();
      } catch (_) {
        /* best-effort finalise */
      }
      // Remember where it landed so a later tap OPENS the file instead of
      // re-offering it (it isn't in the app store → hasFile is false).
      if (savedPath != null) {
        try {
          await _storage.putSetting('saved:${f.contentId}', savedPath);
        } catch (_) {
          /* non-fatal */
        }
      }
      devLog(
        () =>
            'xVeil[content]: COMPLETE ${f.contentId.substring(0, 12)} '
            '(${fetch.manifest.size}B) saved UNENCRYPTED to $savedPath',
      );
      await _send(fetch.peer, WireEnvelope.ack(ackId).encode());
      if (!_contentReceived.isClosed) {
        _contentReceived.add((
          contentId: f.contentId,
          name: fetch.name,
          savedToPath: savedPath,
        ));
      }
      return;
    }
    // Stored in the app (encrypted tier / in-volume) → surface offer→downloaded.
    devLog(
      () =>
          'xVeil[content]: COMPLETE ${f.contentId.substring(0, 12)} '
          '(${fetch.manifest.size}B) streamed to disk',
    );
    final persisted = await _persistReceivedContent(fetch.peer, fetch.manifest);
    // Ack by the per-send msgId (the EVENT identity) so the SENDER's specific
    // file message flips sent->delivered = actually received (a legacy sender
    // without msgId falls back to the contentId — old behaviour).
    if (persisted) {
      devLog(
        () =>
            'xVeil[timeline]: content-ack id=$ackId '
            'via=direct t=${DateTime.now().millisecondsSinceEpoch}',
      );
      await _send(fetch.peer, WireEnvelope.ack(ackId).encode());
    }
    if (!_contentReceived.isClosed) {
      _contentReceived.add((
        contentId: f.contentId,
        name: fetch.name,
        savedToPath: null,
      ));
    }
  }

  /// A content transfer completed: its pieces were already streamed to disk
  /// (storeFilePiece in [_onPieceChunk]), so the blob is hasFile-complete. Ensure
  /// the OFFER message exists (idempotent) so it flips offer → downloaded, then
  /// signal. Returns true (safe to ack = delivered = actually received).
  Future<bool> _persistReceivedContent(NodeId peer, ContentManifest m) async {
    _offered.remove(m.contentId);
    await _surfaceFileOffer(peer, m);
    _signal();
    return true;
  }

  /// Surface a received file as an incoming filePost — an OFFER carrying the
  /// descriptor (name/size + the contentId to download on demand), NOT the blob.
  /// Idempotent on the sender's per-send msgId. A re-send of previously-DELETED
  /// content surfaces as a NEW message (A); a re-delivery of the SAME (deleted)
  /// event stays gone. The "downloaded" state is derived from hasFile(contentId),
  /// so no message rewrite is needed when the blob later lands.
  Future<void> _surfaceFileOffer(NodeId peer, ContentManifest m) async {
    final msgId = m.msgId ?? m.contentId; // legacy sender → hash id
    if (await _hasMessage(peer, msgId) ||
        await _storage.isMessageDeleted(peer.hex, msgId)) {
      return; // already surfaced / deliberately deleted
    }
    await _store(
      peer,
      MessageDirection.incoming,
      '📎 ${m.name}',
      MessageStatus.delivered,
      fileContentId: m.contentId,
      fileSize: m.size,
      fileName: m.name,
      id: msgId,
      seq: m.seq,
      timestamp: m.ts != null
          ? DateTime.fromMillisecondsSinceEpoch(m.ts!)
          : _now(),
    );
    _emitIncoming(peer, '📎 ${m.name}', isFile: true);
    _signal();
    devLog(
      () =>
          'xVeil[content]: offered ${m.contentId.substring(0, 12)} as msg '
          '${msgId.substring(0, 8)} (${m.size}B) <- ${peer.short}',
    );
  }

  void _ensureContentTimer() {
    _contentTimer ??= Timer.periodic(
      _contentReRequestInterval,
      (_) => _contentReRequest(),
    );
  }

  void _contentReRequest() {
    if (_fetching.isEmpty) {
      _contentTimer?.cancel();
      _contentTimer = null;
      return;
    }
    for (final fetch in _fetching.values) {
      // Window the re-request to a few unverified pieces and ask for only their
      // MISSING chunks (bitmaps) — so each round re-sends just the gaps, and the
      // request itself stays small enough to survive the lossy path.
      final pieces = fetch.xfer.nextUnverifiedPieces(_reRequestPieceWindow);
      if (pieces.isEmpty) continue;
      final bitmaps = {
        for (final p in pieces) p: fetch.xfer.missingChunkBitmap(p),
      };
      final remaining = fetch.xfer.missingPieces().length;
      devLog(
        () =>
            'xVeil[content]: re-request '
            '${fetch.manifest.contentId.substring(0, 12)} — chunk-granular over '
            'pieces $pieces ($remaining/${fetch.manifest.pieceCount} unverified) '
            '-> ${fetch.peer.short}',
      );
      unawaited(
        _send(
          fetch.peer,
          pieceRequestEnvelope(
            contentId: fetch.manifest.contentId,
            bitmaps: bitmaps,
          ).encode(),
        ),
      );
    }
  }

  Future<void> dispose() async {
    _disposed = true; // stops the stream accept loop
    _retryTimer?.cancel();
    _retryTimer = null;
    _contentTimer?.cancel();
    _contentTimer = null;
    await _sub?.cancel();
    _sub = null;
    // Release any open serve-from-source file handles.
    for (final v in _serving.values) {
      if (v.source != null) unawaited(v.source!.close());
    }
    _serving.clear();
    for (final sources in _retiredAfterStream.values) {
      for (final source in sources) {
        unawaited(source.close());
      }
    }
    _retiredAfterStream.clear();
    _activeStreamServes.clear();
    // Cancel reoffer timers + close any parked download sinks.
    for (final t in _pendingTimers.values) {
      t.cancel();
    }
    _pendingTimers.clear();
    for (final s in _pendingDownload.values) {
      if (s != null) unawaited(s.close());
    }
    _pendingDownload.clear();
    await _changes.close();
    await _incoming.close();
    await _contentReceived.close();
    await _contentProgress.close();
    await _contentFailed.close();
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
  devLog(
    () =>
        'xVeil[messaging]: fallback service (no session pipeline) '
        'anonymous=$anonymous',
  );
  final service = MessagingService(transport, storage, anonymous: anonymous);
  service.sourceOpener = veilSourceOpener; // DURABLE offers: re-open by path
  service.start();

  // Offline delivery: over the real veil transport, advertise a mailbox relay
  // (a configured bootstrap peer) and drain our mailbox into the inbound path.
  // Best-effort + inert on the loopback transport or when no bootstrap peers
  // are configured — live delivery is unaffected if this never registers.
  final relays = _mailboxRelayCandidates(
    ref.read(deniableBootProvider)?.bootstrapPeers ?? const [],
  );
  devLog(
    () =>
        'xVeil[mailbox]: setup — transport=${transport.runtimeType} '
        'relays=${relays.length}',
  );
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
        })
        .catchError((e) {
          devLog(() => 'xVeil[mailbox]: build/start FAILED: $e');
        });
  } else {
    devLog(
      () =>
          'xVeil[mailbox]: NOT started '
          '(transport=${transport.runtimeType}, relays=${relays.length})',
    );
  }

  // Flush the local outbox whenever the node (re)connects: messages composed
  // while offline stay `sent` and go out the moment transport is up again. Also
  // (re)attempt mailbox registration — the DHT resolve needs the node connected.
  ref.listen<AsyncValue<NodeStatus>>(nodeStatusProvider, (prev, next) {
    final was = prev?.valueOrNull?.phase;
    final now = next.valueOrNull?.phase;
    if (now == NodePhase.connected && was != NodePhase.connected) {
      // Reconcile on reconnect: fire the gap-fill beacons immediately + flush the
      // outbox so messages composed while offline (and any the peer missed) heal.
      unawaited(service.reconcileOnConnect());
      unawaited(mailbox?.start(relays: relays) ?? Future.value());
    }
  });
  ref.onDispose(service.dispose);
  return service;
});

/// In-flight download progress (contentId → fraction 0..1), fed by
/// [MessagingService.contentProgress]. A completed transfer's entry is cleared
/// shortly after the final emit so the file bubble flips to its downloaded/saved
/// state instead of lingering at 100%.
class ContentProgressNotifier extends StateNotifier<Map<String, double>> {
  ContentProgressNotifier(MessagingService svc) : super(const {}) {
    _sub = svc.contentProgress.listen((e) {
      final frac = e.total <= 0 ? 0.0 : e.done / e.total;
      state = {...state, e.contentId: frac};
      if (e.done >= e.total) {
        Future<void>.delayed(const Duration(milliseconds: 800), () {
          if (mounted) state = {...state}..remove(e.contentId);
        });
      }
    });
    _failedSub = svc.contentDownloadFailed.listen((contentId) {
      state = {...state}..remove(contentId);
    });
  }

  StreamSubscription<({String contentId, int done, int total})>? _sub;
  StreamSubscription<String>? _failedSub;

  @override
  void dispose() {
    _sub?.cancel();
    _failedSub?.cancel();
    super.dispose();
  }
}

/// contentId → download fraction (0..1) for transfers currently in flight.
final contentProgressProvider =
    StateNotifierProvider<ContentProgressNotifier, Map<String, double>>(
      (ref) => ContentProgressNotifier(ref.watch(messagingServiceProvider)),
    );

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

/// Chat pagination: the number of newest messages a chat loads initially and
/// the step "load earlier" grows the visible window by. (A per-chat setting can
/// override this later — the user asked for it to be configurable; a const is
/// the v1.)
const int kInitialMessageWindow = 100;
const int kMessageWindowStep = 100;

/// The current visible window (a newest-N count) for a chat, grown by the chat
/// screen's "load earlier" action. `autoDispose` so it resets to
/// [kInitialMessageWindow] each time the chat is (re)opened — reopening lands on
/// the latest page, not a previously-expanded one. Reading it inside
/// [messagesProvider] makes the window reactive: growing it re-yields a larger
/// tail without re-subscribing the changes stream by hand.
final chatWindowProvider = StateProvider.autoDispose.family<int, String>(
  (ref, _) => kInitialMessageWindow,
);

final messagesProvider = StreamProvider.autoDispose.family<List<Message>, String>((
  ref,
  conversationId,
) async* {
  final service = ref.watch(messagingServiceProvider);
  final storage = ref.watch(storageProvider);
  // Load only the newest `window` messages, not the whole conversation — bounds
  // the decrypt + the ListView build to the page the user actually sees.
  final window = ref.watch(chatWindowProvider(conversationId));
  yield await storage.loadMessages(conversationId, limit: window);
  // Each `changes` tick re-loads + DECRYPTS the conversation window from the
  // container and rebuilds the ListView (+ auto-scroll). A burst of state
  // signals (sends, inbound re-sends, status flips) therefore thrashed the UI
  // isolate into a visible freeze. Coalesce bursts: reload at most ~5x/s
  // (trailing edge), so the latest state still renders within ~200ms but a
  // flurry collapses into ONE decrypt+rebuild.
  await for (final _ in service.changes.auditTrailing(
    const Duration(milliseconds: 200),
  )) {
    yield await storage.loadMessages(conversationId, limit: window);
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
final contactProvider = StreamProvider.family<Contact?, String>((
  ref,
  peerHex,
) async* {
  final service = ref.watch(messagingServiceProvider);
  final storage = ref.watch(storageProvider);
  final id = NodeId.fromHex(peerHex);
  yield await storage.getContact(id);
  await for (final _ in service.changes) {
    yield await storage.getContact(id);
  }
});
