import 'dart:convert';
import 'dart:typed_data';

/// Application message type carried in the transport payload.
/// - [request]: a connection request (body = greeting).
/// - [accept]: approval of a request (body unused).
/// - [message]: a normal chat message (body = text).
/// - [fileMeta]: start of a file transfer (body = JSON {tid,name,size,count}).
/// - [fileChunk]: one file chunk (body = JSON {tid,i,total,d=base64}).
/// - [ack]: delivery acknowledgement (id = the acked message's id, body unused).
/// - [edit]: edit of a previously-sent message (id = its id, body = new text).
/// - [del]: deletion of a previously-sent message (id = its id, body unused).
/// - [sync]: an event-log gap-fill beacon (body = JSON {hw,holes,ep}) — what the
///   sender holds per author, so the peer re-ships anything missing (§15, 3c).
/// - [voidSeq]: an inert seq placeholder (seq set, no id/body) advancing the
///   peer's high-water past a deleted/superseded slot so gap-fill never stalls
///   (R-VOID, §12.1 — id-less, no oracle).
/// - [fileQuery]: a gap-fill RE-SHIP PROBE for a file (body = the fileMeta JSON,
///   no chunks) — "I still hold file <tid>, tell me what you're missing." The
///   receiver answers with [fileNack]; the sender then re-sends only those chunks
///   (resumable, instead of re-pushing the whole blob each round).
/// - [fileNack]: the receiver's reply to a probe/transfer (body = JSON
///   {tid, m:[missing indices]}); `m` ABSENT means "send me everything" (a
///   receiver that holds no chunk yet, so it can't name them).
/// - [reconnect]: "we were connected — please re-establish" (body = greeting).
///   Sent when a message stays un-acked past a threshold (the peer may have
///   wiped its chat data and forgotten us, so our messages hit its consent gate
///   and drop). The receiver disambiguates by its OWN state — accepted → re-ack;
///   unknown/pending → surface as a pending re-intro; blocked → drop silently.
///   Offline-vs-wiped is deliberately indistinguishable (no presence oracle).
/// - [unknown]: a DECODE-ONLY sentinel for a structured (v:2) frame from a NEWER
///   build whose kind this build doesn't know — the dispatcher drops it instead
///   of rendering it as chat text (RULE WC). NEVER encoded onto the wire.
///
/// New kinds are APPENDED so existing wire indices (0..7) are unchanged; [sync]
/// onward carry a `v:2` structural marker (RULE WC). [unknown] stays LAST.
enum WireKind {
  request,
  accept,
  message,
  fileMeta,
  fileChunk,
  ack,
  edit,
  del,
  sync,
  voidSeq,
  fileQuery,
  fileNack,
  reconnect,
  fileStream,
  unknown,
}

/// Typed wrapper over the raw transport payload, so the receiver can tell a
/// connection request from a chat message (the consent gate). Serialised as
/// compact JSON `{"t": <kind index>, "b": <body>, "i": <message id?>}`.
///
/// [id] (when set) is the sender's message id — it travels so the receiver can
/// **dedup** re-sent messages (the local outbox re-sends un-acked ones) and the
/// receiver can **ack** by referencing it.
class WireEnvelope {
  const WireEnvelope(this.kind, this.body,
      {this.id, this.sentAtMs, this.seq});

  final WireKind kind;
  final String body;
  final String? id;

  /// The SENDER's send time (Unix ms). Travels so the receiver orders messages
  /// by when they were SENT, not when they happened to arrive — the live /
  /// mailbox / outbox-retry paths deliver with variable latency + reordering, so
  /// receive-order display scrambles a conversation. Null from older senders →
  /// the receiver falls back to its receive time.
  final int? sentAtMs;

  /// The SENDER's per-(conversation, author) event seq for this message/edit
  /// (event-log §15, R4). Travels so the receiver folds the event under the
  /// SAME (author, seq) the sender used — making the log convergent across
  /// devices and letting the receiver detect gaps (a missing seq) for gap-fill.
  /// Null from an older sender → the receiver allocates one locally (no gap
  /// detection for that peer until it upgrades).
  final int? seq;

  const WireEnvelope.request(String greeting, {String? id, int? sentAtMs})
      : this(WireKind.request, greeting, id: id, sentAtMs: sentAtMs);
  const WireEnvelope.accept() : this(WireKind.accept, '');
  const WireEnvelope.message(String text, {String? id, int? sentAtMs, int? seq})
      : this(WireKind.message, text, id: id, sentAtMs: sentAtMs, seq: seq);
  const WireEnvelope.ack(String id) : this(WireKind.ack, '', id: id);
  const WireEnvelope.edit(String id, String newText, {int? seq})
      : this(WireKind.edit, newText, id: id, seq: seq);
  const WireEnvelope.del(String id, {int? seq})
      : this(WireKind.del, '', id: id, seq: seq);

  /// Event-log gap-fill beacon (§15, 3c): [body] is the JSON sync summary
  /// `{hw:{author:hw}, holes:{author:[[lo,hi]]}, ep:epoch}`.
  const WireEnvelope.sync(String body) : this(WireKind.sync, body);

  /// Inert seq placeholder (R-VOID): advances the peer's high-water past a
  /// deleted/superseded slot at [seq] with NO id/body (§12.1 — no oracle).
  const WireEnvelope.voidSeq(int seq) : this(WireKind.voidSeq, '', seq: seq);

  /// "We were connected — please re-establish" (body = optional greeting). Sent
  /// when a message stays un-acked past a threshold; the receiver re-intros it if
  /// it no longer holds us as a contact (recovery handshake, §15.7).
  const WireEnvelope.reconnect(String greeting)
      : this(WireKind.reconnect, greeting);

  /// The decode-only sentinel for a structured (v:2) frame whose kind this build
  /// does not know — the dispatcher drops it (RULE WC).
  static const unknown = WireEnvelope(WireKind.unknown, '');

  /// Frames from [WireKind.sync] onward carry a `v:2` structural marker so an
  /// un-upgraded decoder DROPS them (RULE WC) instead of mis-rendering as chat.
  bool get _isV2 => kind.index >= WireKind.sync.index;

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode({
        't': kind.index,
        'b': body,
        if (id != null) 'i': id,
        if (sentAtMs != null) 's': sentAtMs,
        if (seq != null) 'q': seq,
        if (_isV2) 'v': 2,
      })));

  /// Decode a payload. A well-formed frame whose `t` this build KNOWS decodes to
  /// that kind. A structured `v:2` frame from a NEWER build (a `t` out of range,
  /// or the [WireKind.unknown] sentinel index) decodes to [unknown] so the
  /// dispatcher drops it — it is NEVER mis-rendered as chat text (RULE WC). Any
  /// other unrecognised payload (legacy, non-JSON) falls back to a plain
  /// [WireKind.message] (forward/back compatibility, unchanged).
  static WireEnvelope decode(Uint8List bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Map && decoded['t'] is int && decoded['b'] is String) {
        final t = decoded['t'] as int;
        // A known, real kind (never the unknown sentinel itself) — decode it.
        if (t >= 0 &&
            t < WireKind.values.length &&
            WireKind.values[t] != WireKind.unknown) {
          return WireEnvelope(
            WireKind.values[t],
            decoded['b'] as String,
            id: decoded['i'] is String ? decoded['i'] as String : null,
            sentAtMs: decoded['s'] is int ? decoded['s'] as int : null,
            seq: decoded['q'] is int ? decoded['q'] as int : null,
          );
        }
        // Out of this build's range. A structured v:2 frame (a kind a newer build
        // added) MUST be dropped, never shown as chat (RULE WC); a non-v2 unknown
        // t is legacy garble → fall through to the plain-message fallback.
        if (decoded['v'] == 2) return unknown;
      }
    } catch (_) {
      // fall through to plain-message fallback
    }
    return WireEnvelope(WireKind.message, utf8.decode(bytes, allowMalformed: true));
  }
}

/// Parsed body of a [WireKind.fileMeta] frame: the start of a file transfer.
/// [seq] is the SENDER's event seq for the file message (filePost, §15) — it
/// travels so the receiver folds the file under the same (author, seq) and
/// gap-fill can detect/heal a missing file. [sentAtMs] is the file message's
/// send-time, carried so it folds under the SENDER's time (like a text message's
/// `s`) — otherwise the receiver would stamp its receive time and the convergent
/// (effective_ts, author, seq) display order would diverge across devices. Both
/// null from an older sender.
typedef FileMetaFrame = ({
  String transferId,
  String? name,
  int? size,
  int? count,
  int? seq,
  int? sentAtMs,
});

/// Parsed body of a [WireKind.fileChunk] frame: one piece of a transfer.
typedef FileChunkFrame = ({String transferId, int index, int total, Uint8List data});

/// The file-transfer frame wire format (key names, base64 of chunk bytes)
/// lives here as the single source of truth, so the send and receive sides
/// cannot drift apart. [parseFileMeta]/[parseFileChunk] throw on a body that
/// is missing a required field or has the wrong type — the caller is expected
/// to drop such (hostile/corrupt) datagrams.
WireEnvelope fileMetaEnvelope({
  required String transferId,
  String? name,
  int? size,
  int? count,
  int? seq,
  int? sentAtMs,
}) =>
    WireEnvelope(
      WireKind.fileMeta,
      jsonEncode({
        'tid': transferId,
        'name': ?name,
        'size': ?size,
        'count': ?count,
        'seq': ?seq,
        's': ?sentAtMs,
      }),
    );

/// Start of a STREAMED (large, > the small-file threshold) file transfer. Same
/// body shape as [fileMetaEnvelope] (parse with [parseFileMeta]; `count` is
/// absent — a stream is not pre-chunked) but the blob arrives over a reliable,
/// flow-controlled veil STREAM (no burst loss) and is persisted in the external
/// encrypted blob store, NOT the deniable container. The receiver, on this
/// frame, accepts the inbound stream keyed by [transferId].
WireEnvelope fileStreamEnvelope({
  required String transferId,
  String? name,
  int? size,
  int? seq,
  int? sentAtMs,
}) =>
    WireEnvelope(
      WireKind.fileStream,
      jsonEncode({
        'tid': transferId,
        'name': ?name,
        'size': ?size,
        'seq': ?seq,
        's': ?sentAtMs,
      }),
    );

FileMetaFrame parseFileMeta(String body) {
  final j = jsonDecode(body) as Map<String, dynamic>;
  return (
    transferId: j['tid'] as String,
    name: j['name'] as String?,
    size: j['size'] is int ? j['size'] as int : null,
    count: j['count'] is int ? j['count'] as int : null,
    seq: j['seq'] is int ? j['seq'] as int : null,
    sentAtMs: j['s'] is int ? j['s'] as int : null,
  );
}

/// A gap-fill RE-SHIP PROBE for a file (§15 3c, resumable). Same body shape as
/// [fileMetaEnvelope] (so the receiver parses it with [parseFileMeta]) but with
/// NO chunks following — carries the seq + send-time so the receiver can fold the
/// completed file convergently. The receiver replies with [fileNackEnvelope].
WireEnvelope fileQueryEnvelope({
  required String transferId,
  String? name,
  int? seq,
  int? sentAtMs,
}) =>
    WireEnvelope(
      WireKind.fileQuery,
      jsonEncode({
        'tid': transferId,
        'name': ?name,
        'seq': ?seq,
        's': ?sentAtMs,
      }),
    );

/// Parsed body of a [WireKind.fileNack]: which chunks of [transferId] the
/// receiver still needs. [missing] == null means "send me ALL of them" — a
/// receiver that holds no chunk yet (so cannot enumerate the gaps).
typedef FileNackFrame = ({String transferId, List<int>? missing});

/// The receiver's reply listing the chunks it still needs (or null = all).
WireEnvelope fileNackEnvelope({
  required String transferId,
  required List<int>? missing,
}) =>
    WireEnvelope(
      WireKind.fileNack,
      jsonEncode({
        'tid': transferId,
        if (missing != null) 'm': missing,
      }),
    );

FileNackFrame parseFileNack(String body) {
  final j = jsonDecode(body) as Map<String, dynamic>;
  final m = j['m'];
  return (
    transferId: j['tid'] as String,
    missing: m is List ? m.whereType<int>().toList() : null,
  );
}

WireEnvelope fileChunkEnvelope({
  required String transferId,
  required int index,
  required int total,
  required Uint8List data,
}) =>
    WireEnvelope(
      WireKind.fileChunk,
      jsonEncode({
        'tid': transferId,
        'i': index,
        'total': total,
        'd': base64.encode(data),
      }),
    );

FileChunkFrame parseFileChunk(String body) {
  final j = jsonDecode(body) as Map<String, dynamic>;
  return (
    transferId: j['tid'] as String,
    index: j['i'] as int,
    total: j['total'] as int,
    data: base64.decode(j['d'] as String),
  );
}
