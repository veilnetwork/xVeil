import 'dart:convert';
import 'dart:typed_data';

/// Application message type carried in the transport payload.
/// - [request]: a connection request (body = greeting).
/// - [accept]: approval of a request (body unused).
/// - [message]: a normal chat message (body = text).
/// - [fileMeta]: start of a file transfer (body = JSON {tid,name,size,count}).
/// - [fileChunk]: one file chunk (body = JSON {tid,i,total,d=base64}).
///
/// New kinds are APPENDED so existing wire indices (0/1/2) are unchanged.
enum WireKind { request, accept, message, fileMeta, fileChunk }

/// Typed wrapper over the raw transport payload, so the receiver can tell a
/// connection request from a chat message (the consent gate). Serialised as
/// compact JSON `{"t": <kind index>, "b": <body>}`.
class WireEnvelope {
  const WireEnvelope(this.kind, this.body);

  final WireKind kind;
  final String body;

  const WireEnvelope.request(String greeting) : this(WireKind.request, greeting);
  const WireEnvelope.accept() : this(WireKind.accept, '');
  const WireEnvelope.message(String text) : this(WireKind.message, text);

  Uint8List encode() =>
      Uint8List.fromList(utf8.encode(jsonEncode({'t': kind.index, 'b': body})));

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
