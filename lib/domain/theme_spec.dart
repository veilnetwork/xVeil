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
  });

  /// Stable across renames — what a stored choice points at.
  final String id;

  /// What a person calls it. Never rendered as anything but text.
  final String name;

  final Color seed;

  final bool dark;

  Map<String, Object?> toJson() => {
    'id': id,
    'n': name,
    // Hex without the alpha: a theme does not get to make the interface
    // translucent, which is a way to make text unreadable without ever naming
    // a colour that looks wrong in a list.
    'c': (seed.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0'),
    'd': dark,
  };

  /// The carried form: `xveil-theme:v1:<base64url>`.
  String toText() =>
      '$kThemePrefix${base64Url.encode(utf8.encode(jsonEncode(toJson()))).replaceAll('=', '')}';

  /// Read one back, or answer null.
  ///
  /// Null rather than throwing, and clamped rather than refused where clamping
  /// is honest: a theme is a preference, and the worst outcome of a damaged one
  /// should be the default look, never a screen that will not build.
  static ThemeSpec? parse(String raw) {
    if (raw.length > kMaxThemeTextBytes) return null;
    final start = raw.indexOf(kThemePrefix);
    if (start < 0) return null;
    // Whitespace only: a theme copied through a chat comes back wrapped, and
    // the base64url run below is what decides where it ends.
    final body = raw
        .substring(start + kThemePrefix.length)
        .replaceAll(RegExp(r'\s'), '');
    final run = RegExp(r'^[A-Za-z0-9_-]+').firstMatch(body);
    if (run == null) return null;
    final encoded = run.group(0)!;
    try {
      final padded = encoded.padRight((encoded.length + 3) ~/ 4 * 4, '=');
      final decoded = jsonDecode(utf8.decode(base64Url.decode(padded)));
      if (decoded is! Map) return null;
      return fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

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
    );
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
      other.dark == dark;

  @override
  int get hashCode => Object.hash(id, name, seed.toARGB32(), dark);
}

/// The looks that ship with the app.
///
/// The first is what every install has had: a deep veil-teal, dark. It stays
/// first and stays the default, because a person who never opens this screen
/// must not have their app change under them.
const List<ThemeSpec> kBuiltInThemes = [
  ThemeSpec(
    id: 'veil-dark',
    name: 'Veil',
    seed: Color(0xFF1E8A7B),
    dark: true,
  ),
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
