import 'package:characters/characters.dart';

/// A bounded display preview, with the routing payload kept byte-for-byte.
/// Windows rejects oversized XML; its native exception must not kill the app.
/// These budgets leave room for the plugin's fixed XML template and attributes.
({String title, String body})? windowsToastContent({
  required String title,
  required String body,
  String? payload,
}) {
  if (payload != null && _xmlBytes(payload, 1024) > 1024) return null;
  return (title: _clip(title, 384), body: _clip(body, 2048));
}

int _xmlBytes(String value, int limit) {
  var bytes = 0;
  for (final rune in value.runes) {
    bytes += switch (rune) {
      0x26 => 5, // &amp;
      0x3c || 0x3e => 4, // &lt; and &gt;
      0x22 || 0x27 => 6, // conservative for quoted attributes, too
      <= 0x20 => 16, // allow for escaped/indented whitespace
      <= 0x7f => 1,
      <= 0x7ff => 2,
      <= 0xffff => 3,
      _ => 4,
    };
    if (bytes > limit) return bytes;
  }
  return bytes;
}

String _clip(String value, int limit) {
  var bytes = 0;
  var end = 0;
  var ellipsisEnd = 0;
  for (final character in value.characters) {
    bytes += _xmlBytes(character, limit - bytes);
    if (bytes > limit) return '${value.substring(0, ellipsisEnd)}…';
    end += character.length;
    if (bytes <= limit - 3) ellipsisEnd = end;
  }
  return value;
}
