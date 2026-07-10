import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';

/// Inline formatting a message run can carry. Non-nested in v1: the content of
/// a styled span is literal (no formatting inside `code`, and styles don't
/// stack) — robust and covers the common cases; nesting can come later.
enum FmtKind {
  plain,
  bold,
  italic,
  underline,
  strike,
  code,
  codeBlock,
  spoiler,
  link,
}

/// http/https URLs, terminated at whitespace. Trailing sentence punctuation is
/// trimmed by [_splitLinks] so "see https://x.org." doesn't swallow the dot.
final _urlPattern = RegExp(r'https?://[^\s]+', caseSensitive: false);

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
  // Split http(s) URLs out of plain runs into tappable link tokens. Done as a
  // post-pass so a URL inside `code` (already a non-plain run) stays literal.
  final withLinks = <FmtToken>[];
  for (final t in out) {
    if (t.kind != FmtKind.plain) {
      withLinks.add(t);
      continue;
    }
    withLinks.addAll(_splitLinks(t.text));
  }
  return withLinks;
}

/// Split a plain string into plain/link runs on [_urlPattern], trimming a URL's
/// trailing sentence punctuation back into the following plain run.
List<FmtToken> _splitLinks(String text) {
  final out = <FmtToken>[];
  var last = 0;
  for (final m in _urlPattern.allMatches(text)) {
    var url = m.group(0)!;
    var end = m.end;
    // Trailing . , ) ! ? : ; belong to the sentence, not the URL.
    while (url.isNotEmpty && '.,)!?:;'.contains(url[url.length - 1])) {
      url = url.substring(0, url.length - 1);
      end--;
    }
    if (m.start > last) {
      out.add(FmtToken(FmtKind.plain, text.substring(last, m.start)));
    }
    out.add(FmtToken(FmtKind.link, url));
    last = end;
  }
  if (last < text.length) {
    out.add(FmtToken(FmtKind.plain, text.substring(last)));
  }
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

/// A body splits into block-level runs before inline parsing: normal text and
/// block quotes (`>` line prefix). A quote renders with a left rule; its inner
/// text still flows through [parseFormatted].
enum MdBlockKind { normal, quote }

class MdBlock {
  const MdBlock(this.kind, this.text);
  final MdBlockKind kind;
  final String text;

  @override
  bool operator ==(Object other) =>
      other is MdBlock && other.kind == kind && other.text == text;

  @override
  int get hashCode => Object.hash(kind, text);

  @override
  String toString() => 'MdBlock($kind, ${text.replaceAll("\n", "\\n")})';
}

/// Char ranges `[start, end)` covered by ``` fenced code spans, paired the same
/// way [parseFormatted] pairs them (an open ``` to the next ```). An
/// unterminated fence yields no span — its ``` stays literal, matching inline
/// parsing.
List<(int, int)> _fencedSpans(String body) {
  final spans = <(int, int)>[];
  var i = 0;
  while (true) {
    final open = body.indexOf('```', i);
    if (open < 0) break;
    final close = body.indexOf('```', open + 3);
    if (close < 0) break;
    spans.add((open, close + 3));
    i = close + 3;
  }
  return spans;
}

/// Split [body] into normal and block-quote blocks. A quote block is a maximal
/// run of lines whose first non-space char is `>` and whose start lies outside
/// a ``` fence (so `>` inside a code block stays literal). The `>` and one
/// optional following space are stripped from each quoted line; a non-quote
/// line ends the quote. Pure — unit-tested.
List<MdBlock> parseBlocks(String body) {
  final fences = _fencedSpans(body);
  bool inFence(int offset) {
    for (final (s, e) in fences) {
      if (offset >= s && offset < e) return true;
    }
    return false;
  }

  final blocks = <MdBlock>[];
  final buf = StringBuffer();
  var kind = MdBlockKind.normal;
  var offset = 0;
  void flush() {
    if (buf.isEmpty) return;
    blocks.add(MdBlock(kind, buf.toString()));
    buf.clear();
  }

  for (final line in body.split('\n')) {
    final isQuote = line.trimLeft().startsWith('>') && !inFence(offset);
    final lineKind = isQuote ? MdBlockKind.quote : MdBlockKind.normal;
    if (buf.isNotEmpty && lineKind != kind) flush();
    if (buf.isNotEmpty) buf.write('\n');
    kind = lineKind;
    if (isQuote) {
      var content = line.trimLeft().substring(1);
      if (content.startsWith(' ')) content = content.substring(1);
      buf.write(content);
    } else {
      buf.write(line);
    }
    offset += line.length + 1;
  }
  flush();
  return blocks;
}

/// Split [text] into spans, giving every case-insensitive occurrence of [query]
/// a [highlight] background over [style]. Returns a single unstyled-background
/// span when [query] is null/empty or has no match. Pure — unit-tested.
List<TextSpan> highlightSpans(
  String text,
  TextStyle style,
  String? query,
  Color highlight,
) {
  if (query == null || query.isEmpty) {
    return [TextSpan(text: text, style: style)];
  }
  final hay = text.toLowerCase();
  final needle = query.toLowerCase();
  final spans = <TextSpan>[];
  var start = 0;
  while (true) {
    final idx = hay.indexOf(needle, start);
    if (idx < 0) break;
    if (idx > start) {
      spans.add(TextSpan(text: text.substring(start, idx), style: style));
    }
    spans.add(
      TextSpan(
        text: text.substring(idx, idx + needle.length),
        style: style.copyWith(backgroundColor: highlight),
      ),
    );
    start = idx + needle.length;
  }
  if (spans.isEmpty) return [TextSpan(text: text, style: style)];
  if (start < text.length) {
    spans.add(TextSpan(text: text.substring(start), style: style));
  }
  return spans;
}

/// Renders a message body with the [parseFormatted] subset. Bold / italic /
/// underline / strikethrough / inline `code` / ``` code blocks / ||spoiler|| /
/// `>` block quotes. Spoilers are tap-to-reveal.
class FormattedText extends StatefulWidget {
  const FormattedText(this.body, {super.key, this.style, this.highlight});
  final String body;
  final TextStyle? style;

  /// When set (an active search query), case-insensitive occurrences of it get
  /// a highlight background. Applied to text runs only — not links (keeps the
  /// tap target) or spoilers (would reveal hidden text).
  final String? highlight;

  @override
  State<FormattedText> createState() => _FormattedTextState();
}

class _FormattedTextState extends State<FormattedText> {
  // Indices of spoiler tokens the user has revealed (by tap).
  final _revealed = <int>{};
  // Tap recognizers for link spans — rebuilt each build, disposed here.
  final _recognizers = <TapGestureRecognizer>[];

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  void _copyLink(String url) {
    Clipboard.setData(ClipboardData(text: url));
    final l = AppL10n.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l.chatLinkCopied), duration: const Duration(seconds: 1)),
    );
  }

  /// Build inline spans for [text]. [indexBase] offsets spoiler keys so their
  /// reveal state stays unique across the blocks of one body. Returns the spans
  /// and the token count consumed (to advance [indexBase] for the next block).
  (List<InlineSpan>, int) _spansFor(
    String text,
    int indexBase,
    TextStyle base,
    TextStyle mono,
    ColorScheme scheme,
    String? highlight,
    Color hlColor,
  ) {
    final tokens = parseFormatted(text);
    final spans = <InlineSpan>[];
    void addText(String s, TextStyle style) =>
        spans.addAll(highlightSpans(s, style, highlight, hlColor));
    for (var idx = 0; idx < tokens.length; idx++) {
      final t = tokens[idx];
      final key = indexBase + idx;
      switch (t.kind) {
        case FmtKind.plain:
          addText(t.text, base);
        case FmtKind.bold:
          addText(t.text, base.copyWith(fontWeight: FontWeight.bold));
        case FmtKind.italic:
          addText(t.text, base.copyWith(fontStyle: FontStyle.italic));
        case FmtKind.underline:
          addText(t.text, base.copyWith(decoration: TextDecoration.underline));
        case FmtKind.strike:
          addText(t.text, base.copyWith(decoration: TextDecoration.lineThrough));
        case FmtKind.code:
        case FmtKind.codeBlock:
          addText(t.text, mono);
        case FmtKind.link:
          final recognizer = TapGestureRecognizer()
            ..onTap = () => _copyLink(t.text);
          _recognizers.add(recognizer);
          spans.add(
            TextSpan(
              text: t.text,
              style: base.copyWith(
                color: scheme.primary,
                decoration: TextDecoration.underline,
                decorationColor: scheme.primary,
              ),
              recognizer: recognizer,
            ),
          );
        case FmtKind.spoiler:
          final shown = _revealed.contains(key);
          spans.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: GestureDetector(
                onTap: shown ? null : () => setState(() => _revealed.add(key)),
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
    return (spans, tokens.length);
  }

  @override
  Widget build(BuildContext context) {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
    final base = widget.style ?? DefaultTextStyle.of(context).style;
    final scheme = Theme.of(context).colorScheme;
    final mono = base.copyWith(
      fontFamily: 'monospace',
      backgroundColor: scheme.surfaceContainerHighest,
    );
    final hlQuery = (widget.highlight?.isNotEmpty ?? false)
        ? widget.highlight
        : null;
    final hlColor = scheme.tertiary.withValues(alpha: 0.55);

    final blocks = parseBlocks(widget.body);
    // No quotes: one Text.rich over the whole body — preserves blank lines and
    // matches the pre-quote behaviour exactly.
    if (!blocks.any((b) => b.kind == MdBlockKind.quote)) {
      final (spans, _) = _spansFor(widget.body, 0, base, mono, scheme, hlQuery, hlColor);
      return Text.rich(TextSpan(children: spans));
    }

    var indexBase = 0;
    final children = <Widget>[];
    for (final b in blocks) {
      final blockBase = b.kind == MdBlockKind.quote
          ? base.copyWith(color: scheme.onSurfaceVariant)
          : base;
      final (spans, count) =
          _spansFor(b.text, indexBase, blockBase, mono, scheme, hlQuery, hlColor);
      indexBase += count;
      final rich = Text.rich(TextSpan(children: spans));
      children.add(
        b.kind == MdBlockKind.quote
            ? Container(
                margin: const EdgeInsets.symmetric(vertical: 2),
                padding: const EdgeInsets.only(left: 10),
                decoration: BoxDecoration(
                  border: Border(
                    left: BorderSide(color: scheme.primary, width: 3),
                  ),
                ),
                child: rich,
              )
            : rich,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }
}
