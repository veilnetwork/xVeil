import 'dart:convert';
import 'dart:typed_data';

/// Application message type carried in the transport payload.
/// - [request]: a connection request (body = greeting).
/// - [accept]: approval of a request (body unused).
/// - [message]: a normal chat message (body = text).
enum WireKind { request, accept, message }

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
