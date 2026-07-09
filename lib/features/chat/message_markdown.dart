import 'package:flutter/material.dart';

/// Inline formatting a message run can carry. Non-nested in v1: the content of
/// a styled span is literal (no formatting inside `code`, and styles don't
/// stack) — robust and covers the common cases; nesting can come later.
enum FmtKind { plain, bold, italic, underline, strike, code, codeBlock, spoiler }

/// One parsed run of a message body.
class FmtToken {
  const FmtToken(this.kind, this.text);
  final FmtKind kind;
  final String text;

  @override
  bool operator ==(Object other) =>
      other is FmtToken && other.kind == kind && other.text == text;

  @override
  int get hashCode => Object.hash(kind, text);

  @override
  String toString() => 'FmtToken($kind, ${text.replaceAll("\n", "\\n")})';
}

// Markers, checked longest-first so `**` beats `*` and ``` beats `. Each maps
// an opening/closing delimiter to a kind; content between a matched pair is the
// styled run (literal for code kinds).
const _markers = <(String, FmtKind)>[
  ('```', FmtKind.codeBlock),
  ('**', FmtKind.bold),
  ('__', FmtKind.underline),
  ('~~', FmtKind.strike),
  ('||', FmtKind.spoiler),
  ('`', FmtKind.code),
  ('*', FmtKind.italic),
  ('_', FmtKind.italic),
];

/// Parse a message body into styled runs. Unmatched markers render literally,
/// so ordinary text with a stray `*` is never mangled. Adjacent plain runs are
/// coalesced. Pure — unit-tested.
List<FmtToken> parseFormatted(String body) {
  final out = <FmtToken>[];
  final plain = StringBuffer();
  void flushPlain() {
    if (plain.isNotEmpty) {
      out.add(FmtToken(FmtKind.plain, plain.toString()));
      plain.clear();
    }
  }

  var i = 0;
  outer:
  while (i < body.length) {
    for (final (marker, kind) in _markers) {
      if (!_startsWith(body, i, marker)) continue;
      final contentStart = i + marker.length;
      final close = body.indexOf(marker, contentStart);
      // A marker needs a non-empty, closed span; else it's literal text.
      if (close > contentStart) {
        flushPlain();
        out.add(FmtToken(kind, body.substring(contentStart, close)));
        i = close + marker.length;
        continue outer;
      }
    }
    plain.write(body[i]);
    i++;
  }
  flushPlain();
  return out;
}

bool _startsWith(String s, int at, String marker) {
  if (at + marker.length > s.length) return false;
  for (var k = 0; k < marker.length; k++) {
    if (s[at + k] != marker[k]) return false;
  }
  return true;
}

/// Wrap the current [selection] of [text] in [marker] (e.g. `**` for bold),
/// returning the new text and the selection to restore. With a real selection
/// the wrapped content stays selected; with a collapsed cursor the markers are
/// inserted and the cursor lands between them. Pure — unit-tested.
({String text, TextSelection selection}) applyMarker(
  String text,
  TextSelection selection,
  String marker,
) {
  final start = selection.isValid ? selection.start : text.length;
  final end = selection.isValid ? selection.end : text.length;
  final before = text.substring(0, start);
  final middle = text.substring(start, end);
  final after = text.substring(end);
  final newText = '$before$marker$middle$marker$after';
  return (
    text: newText,
    selection: TextSelection(
      baseOffset: start + marker.length,
      extentOffset: end + marker.length,
    ),
  );
}

/// Renders a message body with the [parseFormatted] subset. Bold / italic /
/// underline / strikethrough / inline `code` / ``` code blocks / ||spoiler||.
/// Spoilers are tap-to-reveal.
class FormattedText extends StatefulWidget {
  const FormattedText(this.body, {super.key, this.style});
  final String body;
  final TextStyle? style;

  @override
  State<FormattedText> createState() => _FormattedTextState();
}

class _FormattedTextState extends State<FormattedText> {
  // Indices of spoiler tokens the user has revealed (by tap).
  final _revealed = <int>{};

  @override
  Widget build(BuildContext context) {
    final tokens = parseFormatted(widget.body);
    final base = widget.style ?? DefaultTextStyle.of(context).style;
    final scheme = Theme.of(context).colorScheme;
    final mono = base.copyWith(
      fontFamily: 'monospace',
      backgroundColor: scheme.surfaceContainerHighest,
    );
    final spans = <InlineSpan>[];
    for (var idx = 0; idx < tokens.length; idx++) {
      final t = tokens[idx];
      switch (t.kind) {
        case FmtKind.plain:
          spans.add(TextSpan(text: t.text, style: base));
        case FmtKind.bold:
          spans.add(
            TextSpan(
              text: t.text,
              style: base.copyWith(fontWeight: FontWeight.bold),
            ),
          );
        case FmtKind.italic:
          spans.add(
            TextSpan(
              text: t.text,
              style: base.copyWith(fontStyle: FontStyle.italic),
            ),
          );
        case FmtKind.underline:
          spans.add(
            TextSpan(
              text: t.text,
              style: base.copyWith(decoration: TextDecoration.underline),
            ),
          );
        case FmtKind.strike:
          spans.add(
            TextSpan(
              text: t.text,
              style: base.copyWith(decoration: TextDecoration.lineThrough),
            ),
          );
        case FmtKind.code:
        case FmtKind.codeBlock:
          spans.add(TextSpan(text: t.text, style: mono));
        case FmtKind.spoiler:
          final shown = _revealed.contains(idx);
          spans.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: GestureDetector(
                onTap: shown ? null : () => setState(() => _revealed.add(idx)),
                child: Container(
                  color: shown ? null : scheme.onSurface,
                  child: Text(
                    t.text,
                    style: base.copyWith(
                      color: shown ? null : Colors.transparent,
                    ),
                  ),
                ),
              ),
            ),
          );
      }
    }
    return Text.rich(TextSpan(children: spans));
  }
}
