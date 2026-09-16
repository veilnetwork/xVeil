// A look, in a form that can be carried between people.
//
// A THEME IS A SEED AND A BRIGHTNESS, not a palette. That is a security
// decision before it is a design one: a theme arrives from somebody else, and
// a theme that could name every colour could name the error colour — this app
// puts "this password opens a container that is already here", "the words
// restore a DIFFERENT identity" and "compaction drops what you do not name" in
// the error colour, and a theme that painted those the same as ordinary text
// would hide exactly the sentences a person cannot afford to miss.
//
// Material 3 derives a whole scheme from one seed with its own contrast rules,
// so a shared theme chooses the CHARACTER of the interface and cannot choose
// whether a warning looks like one. What a sender can do is make an app that
// is teal, or plum, or amber. What they cannot do is make it lie.
//
// The carried form is the same shape as a recovery certificate — a prefix, then
// base64url — because that is a shape this app already teaches people to
// recognise, paste and mistrust.

import 'dart:convert';

import 'package:flutter/material.dart';

/// How a theme travels between people.
const String kThemePrefix = 'xveil-theme:v1:';

/// Longest text this will look at. A theme is a few dozen bytes; anything
/// larger is not a theme, and deciding that before decoding keeps a hostile
/// paste from costing anything.
const int kMaxThemeTextBytes = 4 * 1024;

/// Longest a name may be. Long enough to say what a theme is, short enough
/// that it cannot push the rest of a settings row off the screen.
const int kMaxThemeNameChars = 48;

/// One look: what to call it, what colour it grows from, and whether it is a
/// dark theme or a light one.
@immutable
class ThemeSpec {
  const ThemeSpec({
    required this.id,
    required this.name,
    required this.seed,
    required this.dark,
    this.background,
  });

  /// Stable across renames — what a stored choice points at.
  final String id;

  /// What a person calls it. Never rendered as anything but text.
  final String name;

  final Color seed;

  final bool dark;

  /// The surface everything is drawn on, when this theme chose one.
  ///
  /// Null means "whatever the seed gives", which is what every theme did
  /// before this field existed and what all seven built-ins still do.
  ///
  /// Choosing it is the most dangerous thing a theme can do — it is the colour
  /// the warnings have to be legible against — and it is safe only because the
  /// repair happens on the FOREGROUNDS: see `AppTheme.of`, where the error and
  /// text colours are moved until they can be read on whatever arrived here.
  final Color? background;

  Map<String, Object?> toJson() => {
    'id': id,
    'n': name,
    // Hex without the alpha: a theme does not get to make the interface
    // translucent, which is a way to make text unreadable without ever naming
    // a colour that looks wrong in a list.
    'c': (seed.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0'),
    'd': dark,
    if (background != null)
      'b': (background!.toARGB32() & 0xFFFFFF)
          .toRadixString(16)
          .padLeft(6, '0'),
  };

  /// The carried form: `xveil-theme:v1:<base64url>`.
  String toText() =>
      '$kThemePrefix${base64Url.encode(utf8.encode(jsonEncode(toJson()))).replaceAll('=', '')}';

  /// Read one back, or answer null.
  ///
  /// Null rather than throwing, and clamped rather than refused where clamping
  /// is honest: a theme is a preference, and the worst outcome of a damaged one
  /// should be the default look, never a screen that will not build.
  static ThemeSpec? parse(String raw) => locate(raw)?.spec;

  /// Find a theme inside whatever it arrived in, and say what surrounded it.
  ///
  /// A theme travels in a chat message, so it arrives wrapped across lines and
  /// usually with words on either side ("try this one" / "made it last
  /// night"). Both have to survive: the theme must still be readable, and the
  /// sender's own sentence must still be shown as a sentence.
  ///
  /// Where the encoded part ENDS is decided by the decoded JSON, not by where
  /// the base64 alphabet happens to stop. Ordinary prose after a theme is made
  /// of base64url characters too — "enjoy" is a valid run — so a parser that
  /// took the longest run would swallow the next word and refuse a theme that
  /// is perfectly good. (The recovery certificate learned this the hard way,
  /// where the same paste glued trailing prose onto the ciphertext.)
  static ThemeInText? locate(String raw) {
    if (raw.length > kMaxThemeTextBytes) return null;
    final start = raw.indexOf(kThemePrefix);
    if (start < 0) return null;
    final tail = raw.substring(start + kThemePrefix.length);

    // The base64url characters, in order, remembering where each one sat so
    // the end of the theme can be pointed at in the ORIGINAL text. Whitespace
    // is stepped over rather than ending the run: a chat wraps a long line
    // wherever it likes.
    final chars = StringBuffer();
    final at = <int>[];
    for (var i = 0; i < tail.length; i++) {
      final c = tail.codeUnitAt(i);
      final space = c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d;
      if (space) continue;
      final b64 =
          (c >= 0x41 && c <= 0x5a) ||
          (c >= 0x61 && c <= 0x7a) ||
          (c >= 0x30 && c <= 0x39) ||
          c == 0x2d ||
          c == 0x5f;
      if (!b64) break;
      chars.writeCharCode(c);
      at.add(i);
    }
    final encoded = chars.toString();
    if (encoded.length < 4) return null;

    // Two attempts, because the run's END is not known yet. As it stands it
    // may be the theme exactly (a length that needs padding), or the theme
    // plus the beginning of a sentence — and padding a run that was cut
    // mid-word is a format error, not a short read. Falling back to whole
    // four-character groups always decodes, and the JSON inside decides where
    // the theme really ended.
    List<int>? bytes;
    for (final candidate in [
      encoded,
      encoded.substring(0, encoded.length ~/ 4 * 4),
    ]) {
      if (candidate.length < 4) continue;
      try {
        bytes = base64Url.decode(
          candidate.padRight((candidate.length + 3) ~/ 4 * 4, '='),
        );
        break;
      } catch (_) {
        // The next candidate, or nothing.
      }
    }
    if (bytes == null) return null;

    try {
      final end = _objectEnd(bytes);
      if (end < 0) return null;
      final decoded = jsonDecode(utf8.decode(bytes.sublist(0, end)));
      if (decoded is! Map) return null;
      final spec = fromJson(decoded);
      if (spec == null) return null;
      final used = _base64Length(end);
      final after = used <= at.length ? at[used - 1] + 1 : tail.length;
      return ThemeInText(
        spec: spec,
        before: raw.substring(0, start),
        after: tail.substring(after),
      );
    } catch (_) {
      return null;
    }
  }

  /// One past the closing brace of the JSON object these bytes start with, or
  /// -1 if they do not start with one. Braces, brackets and quotes are ASCII
  /// and every byte of a multi-byte character is >= 0x80, so scanning bytes is
  /// as correct as scanning characters and costs nothing.
  static int _objectEnd(List<int> bytes) {
    var i = 0;
    while (i < bytes.length &&
        (bytes[i] == 0x20 ||
            bytes[i] == 0x09 ||
            bytes[i] == 0x0a ||
            bytes[i] == 0x0d)) {
      i++;
    }
    if (i >= bytes.length || bytes[i] != 0x7b) return -1;
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (; i < bytes.length; i++) {
      final b = bytes[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (b == 0x5c) {
          escaped = true;
        } else if (b == 0x22) {
          inString = false;
        }
        continue;
      }
      if (b == 0x22) {
        inString = true;
      } else if (b == 0x7b || b == 0x5b) {
        depth++;
      } else if (b == 0x7d || b == 0x5d) {
        depth--;
        if (depth == 0) return i + 1;
        if (depth < 0) return -1;
      }
    }
    return -1;
  }

  /// How many base64 characters carry [bytes] bytes, unpadded.
  static int _base64Length(int bytes) =>
      bytes ~/ 3 * 4 + const [0, 2, 3][bytes % 3];

  static ThemeSpec? fromJson(Map<dynamic, dynamic> raw) {
    final hex = raw['c'];
    if (hex is! String) return null;
    final value = int.tryParse(hex.replaceAll('#', ''), radix: 16);
    if (value == null) return null;
    final name = raw['n'];
    final id = raw['id'];
    return ThemeSpec(
      id: id is String && id.isNotEmpty ? _tidy(id, 64) : 'imported',
      // A theme with no name is not broken — it is a theme somebody did not
      // name, and the list can say so.
      name: name is String && name.trim().isNotEmpty
          ? _tidy(name, kMaxThemeNameChars)
          : 'Imported',
      // Alpha is ours, never the sender's.
      seed: Color(0xFF000000 | (value & 0xFFFFFF)),
      dark: raw['d'] != false,
      background: _colour(raw['b']),
    );
  }

  /// A colour from somebody else, opaque, or nothing.
  static Color? _colour(Object? raw) {
    if (raw is! String) return null;
    final value = int.tryParse(raw.replaceAll('#', ''), radix: 16);
    if (value == null) return null;
    return Color(0xFF000000 | (value & 0xFFFFFF));
  }

  /// Names arrive from other people. Control characters and newlines would let
  /// one draw over the row it sits in, and length would push the rest off the
  /// screen — neither is a colour choice, so neither is honoured.
  static String _tidy(String raw, int max) {
    final cleaned = raw
        // Control characters and the bidi overrides that let a name draw
        // over the row it sits in. Written as escapes, because a literal
        // here would do to this file what it does to a settings list.
        .replaceAll(
          RegExp('[\u0000-\u001f\u007f\u200b-\u200f\u202a-\u202e]'),
          '',
        )
        .trim();
    if (cleaned.isEmpty) return 'Imported';
    return cleaned.length <= max ? cleaned : cleaned.substring(0, max);
  }

  @override
  bool operator ==(Object other) =>
      other is ThemeSpec &&
      other.id == id &&
      other.name == name &&
      other.seed.toARGB32() == seed.toARGB32() &&
      other.dark == dark &&
      other.background?.toARGB32() == background?.toARGB32();

  @override
  int get hashCode =>
      Object.hash(id, name, seed.toARGB32(), dark, background?.toARGB32());
}

/// A theme as it arrived: the look itself, and the words it came wrapped in.
///
/// A chat needs both. Showing only the card would eat the sentence somebody
/// wrote; showing only the text would print sixty characters of base64 at a
/// person who was sent a colour.
@immutable
class ThemeInText {
  const ThemeInText({
    required this.spec,
    required this.before,
    required this.after,
  });

  final ThemeSpec spec;

  /// What the sender wrote before the encoded theme, and after it.
  final String before;
  final String after;

  /// The sender's own words, with the machine-readable part taken out.
  String get words =>
      [before.trim(), after.trim()].where((s) => s.isNotEmpty).join('\n');
}

/// The looks that ship with the app.
///
/// The first is what every install has had: a deep veil-teal, dark. It stays
/// first and stays the default, because a person who never opens this screen
/// must not have their app change under them.
const List<ThemeSpec> kBuiltInThemes = [
  ThemeSpec(id: 'veil-dark', name: 'Veil', seed: Color(0xFF1E8A7B), dark: true),
  ThemeSpec(
    id: 'veil-light',
    name: 'Veil light',
    seed: Color(0xFF1E8A7B),
    dark: false,
  ),
  ThemeSpec(id: 'slate', name: 'Slate', seed: Color(0xFF4A5A6A), dark: true),
  ThemeSpec(id: 'plum', name: 'Plum', seed: Color(0xFF7B4A8A), dark: true),
  ThemeSpec(id: 'amber', name: 'Amber', seed: Color(0xFF8A6A1E), dark: true),
  ThemeSpec(id: 'ink', name: 'Ink', seed: Color(0xFF2A3A6A), dark: true),
  ThemeSpec(id: 'moss', name: 'Moss', seed: Color(0xFF4A7A3A), dark: false),
];

/// The look an install has when nobody has chosen one.
ThemeSpec get kDefaultTheme => kBuiltInThemes.first;
