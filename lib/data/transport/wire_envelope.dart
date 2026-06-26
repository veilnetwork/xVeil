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
///
/// New kinds are APPENDED so existing wire indices (0/1/2) are unchanged.
enum WireKind { request, accept, message, fileMeta, fileChunk, ack, edit, del }

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

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode({
        't': kind.index,
        'b': body,
        if (id != null) 'i': id,
        if (sentAtMs != null) 's': sentAtMs,
        if (seq != null) 'q': seq,
      })));

  /// Decode a payload. Anything that isn't a well-formed envelope is treated
  /// as a plain [WireKind.message] (forward/back compatibility).
  static WireEnvelope decode(Uint8List bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Map &&
          decoded['t'] is int &&
          decoded['b'] is String &&
          (decoded['t'] as int) >= 0 &&
          (decoded['t'] as int) < WireKind.values.length) {
        return WireEnvelope(
          WireKind.values[decoded['t'] as int],
          decoded['b'] as String,
          id: decoded['i'] is String ? decoded['i'] as String : null,
          sentAtMs: decoded['s'] is int ? decoded['s'] as int : null,
          seq: decoded['q'] is int ? decoded['q'] as int : null,
        );
      }
    } catch (_) {
      // fall through to plain-message fallback
    }
    return WireEnvelope(WireKind.message, utf8.decode(bytes, allowMalformed: true));
  }
}

/// Parsed body of a [WireKind.fileMeta] frame: the start of a file transfer.
typedef FileMetaFrame = ({String transferId, String? name, int? size, int? count});

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
}) =>
    WireEnvelope(
      WireKind.fileMeta,
      jsonEncode({
        'tid': transferId,
        'name': ?name,
        'size': ?size,
        'count': ?count,
      }),
    );

FileMetaFrame parseFileMeta(String body) {
  final j = jsonDecode(body) as Map<String, dynamic>;
  return (
    transferId: j['tid'] as String,
    name: j['name'] as String?,
    size: j['size'] is int ? j['size'] as int : null,
    count: j['count'] is int ? j['count'] as int : null,
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
