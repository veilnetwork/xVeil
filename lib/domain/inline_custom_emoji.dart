import 'dart:convert';

/// Visible fallback kept in the ordinary message body. Clients that predate
/// inline custom emoji simply render this friendly glyph and ignore the
/// additive `ce` sidecar.
const String kInlineCustomEmojiFallback = '☺';

/// The authenticated app-delivery frame is capped at 6144 bytes. Four 768-byte
/// PNGs become at most 4096 base64 bytes, leaving comfortable room for the
/// message body, envelope, ids and signatures.
const int kInlineCustomEmojiMaxCount = 4;
const int kInlineCustomEmojiMaxBytes = 768;

class InlineCustomEmoji {
  const InlineCustomEmoji({required this.offset, required this.dataB64});

  /// UTF-16 offset of [kInlineCustomEmojiFallback] in the message body.
  final int offset;
  final String dataB64;

  Map<String, Object> toJson() => {'o': offset, 'd': dataB64};

  static InlineCustomEmoji? fromJson(Object? value) {
    if (value is! Map || value['o'] is! int || value['d'] is! String) {
      return null;
    }
    final offset = value['o'] as int;
    final data = value['d'] as String;
    if (offset < 0 || data.isEmpty || data.length > 1024) return null;
    try {
      final bytes = base64Decode(data);
      if (bytes.isEmpty || bytes.length > kInlineCustomEmojiMaxBytes) {
        return null;
      }
    } catch (_) {
      return null;
    }
    return InlineCustomEmoji(offset: offset, dataB64: data);
  }
}

/// Strictly validate a network/storage sidecar against its visible body.
/// Invalid metadata is ignored as a whole while the fallback text remains
/// readable; duplicate offsets and out-of-order rows are rejected so every
/// renderer produces the same sequence.
List<InlineCustomEmoji> parseInlineCustomEmoji(String body, Object? value) {
  if (value is! List ||
      value.isEmpty ||
      value.length > kInlineCustomEmojiMaxCount) {
    return const [];
  }
  final out = <InlineCustomEmoji>[];
  var previous = -1;
  for (final raw in value) {
    final item = InlineCustomEmoji.fromJson(raw);
    if (item == null ||
        item.offset <= previous ||
        item.offset >= body.length ||
        body.codeUnitAt(item.offset) !=
            kInlineCustomEmojiFallback.codeUnitAt(0)) {
      return const [];
    }
    previous = item.offset;
    out.add(item);
  }
  return List.unmodifiable(out);
}

List<Map<String, Object>> encodeInlineCustomEmoji(
  List<InlineCustomEmoji> items,
) => [for (final item in items) item.toJson()];

/// Validate an already-typed list before it enters a signed/encrypted frame.
/// Network/storage decoders use [parseInlineCustomEmoji]; this companion keeps
/// internal callers from accidentally creating metadata that receivers would
/// discard.
bool isValidInlineCustomEmoji(String body, List<InlineCustomEmoji> items) {
  if (items.isEmpty) return true;
  final parsed = parseInlineCustomEmoji(body, encodeInlineCustomEmoji(items));
  if (parsed.length != items.length) return false;
  for (var i = 0; i < items.length; i++) {
    if (parsed[i].offset != items[i].offset ||
        parsed[i].dataB64 != items[i].dataB64) {
      return false;
    }
  }
  return true;
}
