part of 'messaging_core.dart';

const _uuid = Uuid();
Future<bool> _denyP2PStream(NodeId peer) async => false;
Future<String?> _noVideoThumb(String path) async => null;
Future<String?> _noImageThumb(Uint8List bytes) async => null;

/// Candidate mailbox relays derived from configured bootstrap identity keys.
/// Pure-Dart and shared by Flutter and headless hosts.
List<NodeId> mailboxRelayCandidates(List<BootstrapPeerCfg> peers) {
  final out = <NodeId>[];
  final seen = <NodeId>{};
  for (final p in peers) {
    try {
      final node = NodeId(blake3Hash(base64.decode(p.publicKey)));
      if (seen.add(node)) out.add(node);
    } catch (_) {
      // Malformed public key: skip without creating a config oracle.
    }
  }
  return out;
}

const _streamRangeParallelismDartDefine = int.fromEnvironment(
  'XVEIL_STREAM_RANGE_PARALLELISM',
  defaultValue: 0,
);
const _streamRangeTargetBytesDartDefine = int.fromEnvironment(
  'XVEIL_STREAM_RANGE_TARGET_BYTES',
  defaultValue: 0,
);
const _streamRangeEnabledDartDefine = bool.fromEnvironment(
  'XVEIL_STREAM_RANGE_ENABLED',
  defaultValue: true,
);
const _streamOpenWriteGraceMsDartDefine = int.fromEnvironment(
  'XVEIL_STREAM_OPEN_WRITE_GRACE_MS',
  defaultValue: 0,
);
const _streamRangePayloadIdleMsDartDefine = int.fromEnvironment(
  'XVEIL_STREAM_RANGE_PAYLOAD_IDLE_MS',
  defaultValue: 0,
);
const _streamPayloadIdleMsDartDefine = int.fromEnvironment(
  'XVEIL_STREAM_PAYLOAD_IDLE_MS',
  defaultValue: 0,
);
const _streamRangeOpenPaceMsDartDefine = int.fromEnvironment(
  'XVEIL_STREAM_RANGE_OPEN_PACE_MS',
  defaultValue: 0,
);
const _streamRangeStallAbandonMsDartDefine = int.fromEnvironment(
  'XVEIL_STREAM_RANGE_STALL_ABANDON_MS',
  defaultValue: 0,
);
const _streamRangeHedgeMsDartDefine = int.fromEnvironment(
  'XVEIL_STREAM_RANGE_HEDGE_MS',
  defaultValue: 0,
);
const _streamRangeRetryOpenMsDartDefine = int.fromEnvironment(
  'XVEIL_STREAM_RANGE_RETRY_OPEN_MS',
  defaultValue: 0,
);
const _streamRequestTimeoutMsDartDefine = int.fromEnvironment(
  'XVEIL_STREAM_REQUEST_TIMEOUT_MS',
  defaultValue: 0,
);
const _bulkStreamTraceDartDefine = bool.fromEnvironment(
  'XVEIL_BULK_STREAM_TRACE',
  defaultValue: false,
);
// Plain-file saves ride the reliable stream/range path by DEFAULT. This was
// an opt-in while the pinned circuit could reset before the manifest arrived
// and strand a chosen file at 0 bytes — that failure mode is gone (stream
// retries + piece-granular resume + stall-abandon + RACK loss detection, all
// device-proven), while the "safe" chunk fallback is impractically slow for
// large files (it was the pre-stream datagram-era path). The define remains
// an emergency off-switch: --dart-define=XVEIL_PLAIN_FILE_STREAM=false.
const _plainFileStreamDartDefine = bool.fromEnvironment(
  'XVEIL_PLAIN_FILE_STREAM',
  defaultValue: true,
);
const _contentServeBatchDartDefine = int.fromEnvironment(
  'XVEIL_CONTENT_SERVE_BATCH',
  defaultValue: 0,
);
const _contentPacingMsDartDefine = int.fromEnvironment(
  'XVEIL_CONTENT_PACING_MS',
  defaultValue: 0,
);

const _defaultContentPacing = Duration(milliseconds: 20);
const _defaultContentServeBatch = 2;

typedef _ContentManifestRef = ({
  String contentId,
  String name,
  int size,
  String? msgId,
  String? author,
  int? seq,
  int? ts,
  String? thumb,
});

int? xveilConfiguredStreamRangeParallelism() =>
    _streamRangeParallelismDartDefine > 0
    ? _streamRangeParallelismDartDefine
    : null;

int? xveilConfiguredStreamRangeTargetBytes() =>
    _streamRangeTargetBytesDartDefine > 0
    ? _streamRangeTargetBytesDartDefine
    : null;

bool xveilConfiguredStreamRangeEnabled() => _streamRangeEnabledDartDefine;

Duration _configuredStreamOpenWriteGrace() =>
    _streamOpenWriteGraceMsDartDefine > 0
    ? Duration(milliseconds: _streamOpenWriteGraceMsDartDefine)
    : MessagingService._defaultStreamOpenWriteGrace;

Duration _configuredStreamRangeStallAbandon() =>
    _streamRangeStallAbandonMsDartDefine > 0
    ? Duration(milliseconds: _streamRangeStallAbandonMsDartDefine)
    : const Duration(milliseconds: 2500);

Duration _configuredStreamRangeHedgeAfter() => _streamRangeHedgeMsDartDefine > 0
    ? Duration(milliseconds: _streamRangeHedgeMsDartDefine)
    : const Duration(milliseconds: 3000);

Duration _configuredStreamRequestTimeout() =>
    _streamRequestTimeoutMsDartDefine > 0
    ? Duration(milliseconds: _streamRequestTimeoutMsDartDefine)
    : MessagingService._defaultStreamRequestTimeout;

Duration _configuredStreamPayloadIdleTimeout() =>
    _streamPayloadIdleMsDartDefine > 0
    ? Duration(milliseconds: _streamPayloadIdleMsDartDefine)
    : MessagingService._defaultStreamPayloadIdleTimeout;

void _bulkStreamLog(String Function() message) {
  if (_bulkStreamTraceDartDefine) devLog(message);
}

Duration _configuredContentPacing() => _contentPacingMsDartDefine > 0
    ? Duration(milliseconds: _contentPacingMsDartDefine)
    : _defaultContentPacing;

int _configuredContentServeBatch() => _contentServeBatchDartDefine > 0
    ? _clampContentServeBatch(_contentServeBatchDartDefine)
    : _defaultContentServeBatch;

int _clampContentServeBatch(int value) {
  if (value < 1) return 1;
  if (value > 32) return 32;
  return value;
}

/// Raw bytes per wire chunk. The anonymous authenticated send (the live path,
/// veil's auth_deliver) caps ONE message at MAX_AUTH_DELIVER_MSG_BYTES = 6144
/// bytes and silently drops anything larger (fire-and-forget, no retry). A chunk
/// is base64 + JSON-wrapped (~1.35×) plus the AuthDeliver header/signature, so
/// 6000 inflated to ~8099 B and EVERY file chunk was dropped on the live path
/// (text survived only via its mailbox stash; files have none). 4000 → ~5.5 KB
/// encoded, a safe margin under 6144, so file chunks actually traverse the
/// onion. (Mailbox-deposited frames share the same ceiling.)
const _wireChunkBytes = 4000;

/// Group snapshot bytes per [WireKind.groupEntryChunk], and the threshold above
/// which a snapshot is chunked instead of shipped as one [WireKind.groupEntry].
///
/// Smaller than [_wireChunkBytes] because a group chunk is DURABLE: it is stored
/// in the outbox as `{id,p,w:base64(wire)}` in ONE ~4 KB container chunk, and the
/// chunk data is ALREADY base64 inside the frame — so the raw bytes pass through
/// TWO base64 layers (~1.78×) before hitting the outbox's PAYLOAD_CAP≈4040. 1800
/// raw → ~3.2 KB outbox payload, a safe margin (4000 raw threw PayloadTooLarge on
/// enqueueOutboxFrame). File chunks avoid this — they are NOT durable-outbox'd.
const _groupChunkBytes = 1800;

/// Bound the in-RAM group-snapshot reassembly so a hostile peer can't grow it
/// without limit: a single snapshot over this many bytes (matching the stored
/// file cap) is refused, and no more than this many snapshots reassemble at
/// once (older partials evicted). A snapshot lost to eviction / restart re-heals
/// on the sender's next full re-broadcast.
const _kMaxGroupReasmBytes = kMaxStoredFileBytes;
const _kMaxGroupReasmConcurrent = 8;

/// Hard ceiling on a file we will buffer in memory and store. Bound by the
/// at-rest layer: a stored file must be DELETABLE in one atomic commit (≤ 1024
/// records × 8 KiB), so a larger blob can neither be persisted nor scrubbed on
/// delete — see [kMaxStoredFileBytes]. It therefore doubles as (a) the inbound
/// memory-DoS backstop (a hostile accepted peer can't buffer more than this) and
/// (b) the send-side pre-check bound (the UI shows a friendly "too large" error
/// here, instead of the storage layer throwing PayloadTooLarge mid-attach).
const kMaxIncomingFileBytes =
    kMaxStoredFileBytes; // ~8 MiB (1024×8 KiB ceiling)

/// Largest streamed IMAGE we will read back whole (transiently) to generate
/// its embedded micro-thumb. Image decode needs the full file, so this bounds
/// the RAM spike of thumb generation on the sendFileStreaming path; a bigger
/// image simply ships without a thumb (the preview is optional by design).
const kThumbSourceReadCapBytes = 24 * 1024 * 1024;

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

/// Max edit/delete ops we hold waiting for their target message to arrive (see
/// [_MessagingMutations._pending]). Bounds memory against an accepted peer that
/// spams ops for message ids we never receive; the cap evicts oldest-first. A
/// real conversation has at most a handful of in-flight out-of-order ops, so a
/// modest cap loses nothing legitimate. Tunable.
const kMaxPendingOps = 512;

/// A peer's edit/delete of one of THEIR messages that drained before the message
/// itself. Buffered until the target stores, then replayed. A delete is terminal
/// (a later edit can't revive a message the peer unsent), so [isDelete] wins over
/// a buffered edit for the same id.
class _PendingOp {
  _PendingOp.edit(String this.body, this.customEmoji) : isDelete = false;
  _PendingOp.delete() : isDelete = true, body = null, customEmoji = const [];
  final bool isDelete;

  /// The replacement text for an edit; null for a delete.
  final String? body;
  final List<InlineCustomEmoji> customEmoji;
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
    this.messageId,
    this.fileName,
    this.sidecar,
  });
  final NodeId from;
  final String preview;
  final bool isFile;
  final String? messageId;

  /// The attachment's container name when [isFile] — voice/vnote/sticker names
  /// are opaque uuids, so the notification layer derives a kind label from it
  /// instead of echoing [preview] (which keeps the raw `📎 <name>` body for
  /// API/headless consumers).
  final String? fileName;

  /// The attachment's `thumb` sidecar (`vw1:`/`vn1:` carry the clip length)
  /// when it already travelled with the offer; null otherwise.
  final String? sidecar;
}

/// An author-side prompt: [peer] asked us to attest authorship of message
/// [msgId] whose text is [body]. Surfaced on [MessagingService.signatureAsks]
/// under [SignaturePolicy.ask]; resolved via
/// [MessagingService.resolveSignatureAsk].
class SignatureAsk {
  const SignatureAsk({
    required this.peer,
    required this.msgId,
    required this.body,
  });
  final NodeId peer;
  final String msgId;
  final String body;
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
typedef ServeSource = ({
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
  // Non-null only on a RESUME reopen of a plain file: reads a piece back so the
  // swarm can hash-verify it off disk and skip the ones a previous run already
  // wrote (byte-level restart resume). Null on a fresh download / encrypted
  // tier (nothing prior to trust).
  Future<Uint8List?> Function(int offset, int length)? read,
});
