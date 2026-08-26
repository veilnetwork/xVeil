import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/ids.dart';
import '../../data/transport/bootstrap_invite.dart';
import '../../data/node/proxy_routing.dart';
import '../../data/transport/oproxy_invite.dart';
import '../../data/transport/peers_invite.dart';
import '../../l10n/app_localizations.dart';
import '../../domain/cloud.dart';
import '../../domain/inline_custom_emoji.dart';
import '../../state/app_controller.dart';
import '../../state/mention_identity.dart';
import '../../state/providers.dart';
import '../../state/proxy_routing_controller.dart';
import '../storage/cloud_attachment.dart';
import 'chat_link.dart';
import 'message_mentions.dart';

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

  /// A `veil-cloud:<itemId>` reference to a personal-cloud object. The token's
  /// text is the bare item id — the scheme is vocabulary, and everything
  /// downstream wants the id.
  cloudAttachment,
}

/// Links, terminated at whitespace. Trailing sentence punctuation is trimmed by
/// [_splitLinks] so "see https://x.org." doesn't swallow the dot.
///
/// http/https AND the app's own `veil:` schemes. Only http/https used to match,
/// so every link this app mints — a contact invite, a share of entry nodes, a
/// device link — reached a chat as flat text that could not be tapped at all.
/// The schemes come from [chatLinkSchemePattern], which is built from the same
/// constants the tap handler classifies with.
final _urlPattern = RegExp(
  '(?:https?://|$chatLinkSchemePattern)[^\\s]+',
  caseSensitive: false,
);

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
    // Ahead of the markers, not in the post-pass with links: an item id may
    // legitimately contain `_`, and a marker pass that ran first would read
    // `veil-cloud:a_b_c` as an italic run and lose the reference entirely.
    final attachment = _attachmentAt(body, i);
    if (attachment != null) {
      flushPlain();
      out.add(FmtToken(FmtKind.cloudAttachment, attachment));
      i += kCloudAttachmentScheme.length + attachment.length;
      continue;
    }
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
  // Split links out of plain runs into tappable link tokens — http(s) AND the
  // app's own `veil:` schemes. Done as a post-pass so a URL inside `code`
  // (already a non-plain run) stays literal.
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

/// The item id of a `veil-cloud:` reference beginning exactly at [at], or null.
String? _attachmentAt(String body, int at) {
  if (!_startsWith(body, at, kCloudAttachmentScheme)) return null;
  final match = cloudAttachmentPattern.matchAsPrefix(body, at);
  return match?.group(0)!.substring(kCloudAttachmentScheme.length);
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
enum MdBlockKind { normal, quote, code }

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

/// A line opens a fenced code block when its trimmed text starts with ``` and
/// carries no second ``` on the same line — so `\`\`\`dart` (a language tag)
/// opens a block, but a self-closed inline `\`\`\`x\`\`\`` does not.
bool _opensFence(String trimmedLine) =>
    trimmedLine.startsWith('```') && !trimmedLine.substring(3).contains('```');

/// Split [body] into block-level runs: normal text, block quotes (`>` line
/// prefix), and fenced ``` code blocks. A code block runs from an opening fence
/// line to the next line whose trimmed text starts with ``` — its inner lines
/// are literal (a `>` inside is code, not a quote). An unterminated fence stays
/// literal text. Quote markers (`>` + one optional space) are stripped. Pure —
/// unit-tested.
List<MdBlock> parseBlocks(String body) {
  final lines = body.split('\n');
  final blocks = <MdBlock>[];
  final buf = StringBuffer();
  var kind = MdBlockKind.normal;
  void flush() {
    if (buf.isEmpty) return;
    blocks.add(MdBlock(kind, buf.toString()));
    buf.clear();
  }

  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    final trimmed = line.trimLeft();
    if (_opensFence(trimmed)) {
      // Seek the closing fence; only form a code block if one exists.
      var j = i + 1;
      while (j < lines.length && !lines[j].trimLeft().startsWith('```')) {
        j++;
      }
      if (j < lines.length) {
        flush();
        blocks.add(
          MdBlock(MdBlockKind.code, lines.sublist(i + 1, j).join('\n')),
        );
        kind = MdBlockKind.normal;
        i = j + 1;
        continue;
      }
      // No close: fall through and treat this line as ordinary text.
    }
    final isQuote = trimmed.startsWith('>');
    final lineKind = isQuote ? MdBlockKind.quote : MdBlockKind.normal;
    if (buf.isNotEmpty && lineKind != kind) flush();
    if (buf.isNotEmpty) buf.write('\n');
    kind = lineKind;
    if (isQuote) {
      var content = trimmed.substring(1);
      if (content.startsWith(' ')) content = content.substring(1);
      buf.write(content);
    } else {
      buf.write(line);
    }
    i++;
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

/// Lightweight, language-agnostic syntax classes for fenced code blocks.
enum CodeTokenKind { plain, keyword, str, comment, number }

class CodeToken {
  const CodeToken(this.kind, this.text);
  final CodeTokenKind kind;
  final String text;

  @override
  bool operator ==(Object other) =>
      other is CodeToken && other.kind == kind && other.text == text;

  @override
  int get hashCode => Object.hash(kind, text);

  @override
  String toString() => 'CodeToken($kind, ${text.replaceAll("\n", "\\n")})';
}

/// Common keywords across C-like, Python, Rust, JS/TS, Dart, Go, etc. A shared
/// set (not per-language) keeps the highlighter dependency-free; false matches
/// inside a code block read as "looks like code", which is the whole point.
const _codeKeywords = <String>{
  'if',
  'else',
  'elif',
  'for',
  'while',
  'do',
  'switch',
  'case',
  'default',
  'break',
  'continue',
  'return',
  'goto',
  'yield',
  'await',
  'async',
  'function',
  'fn',
  'func',
  'def',
  'lambda',
  'class',
  'struct',
  'enum',
  'interface',
  'trait',
  'impl',
  'extends',
  'implements',
  'mixin',
  'const',
  'let',
  'var',
  'val',
  'final',
  'static',
  'mut',
  'public',
  'private',
  'protected',
  'abstract',
  'override',
  'virtual',
  'void',
  'int',
  'long',
  'short',
  'float',
  'double',
  'bool',
  'boolean',
  'char',
  'string',
  'str',
  'byte',
  'true',
  'false',
  'null',
  'nil',
  'none',
  'undefined',
  'import',
  'export',
  'from',
  'package',
  'module',
  'use',
  'using',
  'pub',
  'new',
  'delete',
  'this',
  'self',
  'super',
  'typeof',
  'instanceof',
  'sizeof',
  'try',
  'catch',
  'except',
  'finally',
  'throw',
  'throws',
  'raise',
  'match',
  'in',
  'is',
  'as',
  'and',
  'or',
  'not',
  'with',
};

bool _isIdentStart(String c) {
  final u = c.codeUnitAt(0);
  return (u >= 65 && u <= 90) || (u >= 97 && u <= 122) || c == '_' || c == r'$';
}

bool _isIdentPart(String c) {
  final u = c.codeUnitAt(0);
  return _isIdentStart(c) || (u >= 48 && u <= 57);
}

bool _isDigit(String c) {
  final u = c.codeUnitAt(0);
  return u >= 48 && u <= 57;
}

/// True if everything from the previous newline (or start) up to [i] is blank —
/// used so `#` opens a comment only when it leads the line (Python/shell), not
/// mid-expression.
bool _atLineStart(String s, int i) {
  var j = i - 1;
  while (j >= 0) {
    final c = s[j];
    if (c == '\n') return true;
    if (c != ' ' && c != '\t') return false;
    j--;
  }
  return true;
}

/// Split [code] into coarse syntax tokens: line/block comments, single- and
/// double-quoted strings, numbers, keywords, and plain runs. Deliberately
/// simple and language-agnostic — no grammar, no dependency. Pure — unit-tested.
List<CodeToken> highlightCode(String code) {
  final out = <CodeToken>[];
  final plain = StringBuffer();
  void flush() {
    if (plain.isNotEmpty) {
      out.add(CodeToken(CodeTokenKind.plain, plain.toString()));
      plain.clear();
    }
  }

  var i = 0;
  final n = code.length;
  while (i < n) {
    final c = code[i];
    final two = i + 1 < n ? code.substring(i, i + 2) : '';
    // Line comment: // or a leading #.
    if (two == '//' || (c == '#' && _atLineStart(code, i))) {
      var end = code.indexOf('\n', i);
      if (end < 0) end = n;
      flush();
      out.add(CodeToken(CodeTokenKind.comment, code.substring(i, end)));
      i = end;
    } else if (two == '/*') {
      var end = code.indexOf('*/', i + 2);
      end = end < 0 ? n : end + 2;
      flush();
      out.add(CodeToken(CodeTokenKind.comment, code.substring(i, end)));
      i = end;
    } else if (c == '"' || c == "'" || c == '`') {
      // String literal to the matching unescaped quote (or EOL/end).
      var j = i + 1;
      while (j < n && code[j] != c) {
        if (code[j] == r'\' && j + 1 < n) {
          j += 2;
        } else if (code[j] == '\n') {
          break;
        } else {
          j++;
        }
      }
      final end = (j < n && code[j] == c) ? j + 1 : j;
      flush();
      out.add(CodeToken(CodeTokenKind.str, code.substring(i, end)));
      i = end;
    } else if (_isIdentStart(c)) {
      var j = i + 1;
      while (j < n && _isIdentPart(code[j])) {
        j++;
      }
      final word = code.substring(i, j);
      if (_codeKeywords.contains(word)) {
        flush();
        out.add(CodeToken(CodeTokenKind.keyword, word));
      } else {
        plain.write(word);
      }
      i = j;
    } else if (_isDigit(c)) {
      var j = i + 1;
      while (j < n && (_isIdentPart(code[j]) || code[j] == '.')) {
        j++;
      }
      flush();
      out.add(CodeToken(CodeTokenKind.number, code.substring(i, j)));
      i = j;
    } else {
      plain.write(c);
      i++;
    }
  }
  flush();
  return out;
}

/// Renders a message body with the [parseFormatted] subset. Bold / italic /
/// underline / strikethrough / inline `code` / ``` code blocks / ||spoiler|| /
/// `>` block quotes. Spoilers are tap-to-reveal.
class FormattedText extends ConsumerStatefulWidget {
  const FormattedText(
    this.body, {
    super.key,
    this.style,
    this.highlight,
    this.customEmoji = const [],
    this.maxLines,
    this.overflow,
  });
  final String body;
  final TextStyle? style;
  final List<InlineCustomEmoji> customEmoji;
  final int? maxLines;
  final TextOverflow? overflow;

  /// When set (an active search query), case-insensitive occurrences of it get
  /// a highlight background. Applied to text runs only — not links (keeps the
  /// tap target) or spoilers (would reveal hidden text).
  final String? highlight;

  @override
  ConsumerState<FormattedText> createState() => _FormattedTextState();
}

class _FormattedTextState extends ConsumerState<FormattedText> {
  // Indices of spoiler tokens the user has revealed (by tap).
  final _revealed = <int>{};
  // Tap recognizers for link spans — rebuilt each build, disposed here.
  final _recognizers = <TapGestureRecognizer>[];

  /// Replace each authenticated fallback glyph with an otherwise-unused BMP
  /// private-use code unit. The replacement is one UTF-16 unit too, so block
  /// and markdown parsing cannot shift offsets. If the body somehow occupies
  /// the whole PUA range, the affected item simply stays a readable `☺`.
  ({String body, Map<int, ({int offset, Uint8List bytes})> images})
  _prepareCustomEmoji() {
    if (widget.customEmoji.isEmpty) {
      return (body: widget.body, images: const {});
    }
    final units = widget.body.codeUnits.toList(growable: false);
    final used = units.toSet();
    final images = <int, ({int offset, Uint8List bytes})>{};
    var candidate = 0xe000;
    for (final item in widget.customEmoji) {
      while (candidate <= 0xf8ff && used.contains(candidate)) {
        candidate++;
      }
      if (candidate > 0xf8ff) break;
      try {
        final bytes = Uint8List.fromList(base64Decode(item.dataB64));
        units[item.offset] = candidate;
        images[candidate] = (offset: item.offset, bytes: bytes);
        used.add(candidate);
        candidate++;
      } catch (_) {
        // Domain decoders already validate this. Keep the fallback glyph if a
        // locally-constructed value still manages to be malformed.
      }
    }
    return (body: String.fromCharCodes(units), images: images);
  }

  List<InlineSpan> _inlineSpans(
    String text,
    TextStyle style,
    Map<int, ({int offset, Uint8List bytes})> images,
    String? highlight,
    Color hlColor, {
    GestureRecognizer? recognizer,
    bool hideImages = false,
  }) {
    final mentions = recognizer == null
        ? parseMessageMentions(text)
        : const <MessageMentionToken>[];
    if (images.isEmpty && mentions.isEmpty) {
      if (recognizer != null) {
        return [TextSpan(text: text, style: style, recognizer: recognizer)];
      }
      return highlightSpans(text, style, highlight, hlColor);
    }
    final out = <InlineSpan>[];
    final mentionByOffset = {
      for (final mention in mentions) mention.start: mention,
    };
    final plain = StringBuffer();
    void flush() {
      if (plain.isEmpty) return;
      final value = plain.toString();
      plain.clear();
      if (recognizer != null) {
        out.add(TextSpan(text: value, style: style, recognizer: recognizer));
      } else {
        out.addAll(highlightSpans(value, style, highlight, hlColor));
      }
    }

    var offset = 0;
    while (offset < text.length) {
      final mention = mentionByOffset[offset];
      if (mention != null) {
        flush();
        final resolved = ref
            .watch(
              mentionIdentityProvider(
                MentionIdentityKey(
                  mention.nodeId.hex,
                  dhtHint: mention.dhtName,
                ),
              ),
            )
            .value;
        final label = resolved?.label ?? mention.nodeId.short;
        final mentionStyle = hideImages
            ? style
            : style.copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w600,
              );
        final mentionRecognizer = hideImages
            ? null
            : (TapGestureRecognizer()
                ..onTap = () => _onTapMention(mention.nodeId, label));
        if (mentionRecognizer != null) _recognizers.add(mentionRecognizer);
        out.add(
          TextSpan(
            text: '@$label',
            style: mentionStyle,
            recognizer: mentionRecognizer,
          ),
        );
        offset = mention.end;
        continue;
      }
      final code = text.codeUnitAt(offset);
      final image = images[code];
      if (image == null) {
        plain.writeCharCode(code);
        offset++;
        continue;
      }
      flush();
      out.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: hideImages
                ? const SizedBox(width: 24, height: 24)
                : Image.memory(
                    image.bytes,
                    key: ValueKey('inline-custom-emoji:${image.offset}'),
                    width: 24,
                    height: 24,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                    errorBuilder: (_, _, _) =>
                        Text(kInlineCustomEmojiFallback, style: style),
                  ),
          ),
        ),
      );
      offset++;
    }
    flush();
    return out;
  }

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
      SnackBar(
        content: Text(l.chatLinkCopied),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  /// Tapping a link never navigates on its own (privacy): it opens a dialog
  /// showing the full URL with Open / Copy / Cancel, so handing the URL to the
  /// system browser is always a conscious choice.
  ///
  /// The app's OWN links get the same confirmation and a different verb. They
  /// are not the browser's to open — nothing installed answers `veil:` — so
  /// sending them to `launchUrl` only ever produced "could not open link" for
  /// a link this very app had minted.
  Future<void> _onTapLink(String url) async {
    final l = AppL10n.of(context);
    final kind = chatLinkKind(url);
    final title = switch (kind) {
      ChatLinkKind.web => l.linkDialogTitle,
      ChatLinkKind.contactInvite => l.chatLinkInviteTitle,
      ChatLinkKind.entryNodes => l.chatLinkPeersTitle,
      ChatLinkKind.proxyShare => l.chatLinkProxyTitle,
      ChatLinkKind.deviceLink => l.chatLinkDeviceTitle,
    };
    final confirmLabel = switch (kind) {
      ChatLinkKind.web => l.linkOpen,
      ChatLinkKind.contactInvite => l.chatLinkInviteAction,
      ChatLinkKind.entryNodes => l.chatLinkPeersAction,
      ChatLinkKind.proxyShare => l.chatLinkProxyAction,
      ChatLinkKind.deviceLink => l.chatLinkDeviceAction,
    };
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // WHY it is not applied here, said before the button that leads
            // somewhere else — not after the person has pressed it.
            // A shared exit SEES where the traffic goes. Said before the
            // button, not after: adding one is a trust decision about whoever
            // runs that node, and the link itself looks like any other.
            if (kind == ChatLinkKind.proxyShare) ...[
              Text(l.chatLinkProxyBody),
              const SizedBox(height: 12),
            ],
            if (kind == ChatLinkKind.deviceLink) ...[
              Text(l.chatLinkDeviceBody),
              const SizedBox(height: 12),
            ],
            SelectableText(url),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l.actionCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'copy'),
            child: Text(l.linkCopy),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'confirm'),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (action == 'copy') {
      _copyLink(url);
    } else if (action == 'confirm') {
      switch (kind) {
        case ChatLinkKind.web:
          await _openLink(url);
        case ChatLinkKind.contactInvite:
          await _redeemContactInvite(url);
        case ChatLinkKind.entryNodes:
          await _redeemEntryNodes(url);
        case ChatLinkKind.proxyShare:
          await _redeemProxyShare(url);
        case ChatLinkKind.deviceLink:
          // Handed to the screen that owns it, still unapplied: the person
          // pastes it there deliberately. A device link in a message is
          // somebody else's, and a tap is not consent to join a device to
          // this identity.
          context.push('/settings/devices?link=1');
      }
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  Future<void> _redeemContactInvite(String url) async {
    final l = AppL10n.of(context);
    final BootstrapInvite invite;
    try {
      invite = BootstrapInvite.parse(url);
    } catch (_) {
      _toast(l.inviteInvalid);
      return;
    }
    // Own invite: adding it would make a chat with yourself. Say so rather
    // than pretending it worked (the same answer the add-contact sheet gives).
    final me = ref.read(appControllerProvider).identity?.nodeId;
    if (me != null && invite.nodeId == me) {
      _toast(l.inviteIsSelf);
      return;
    }
    // A redeem failure (already known, for one) must not block opening the
    // chat: the invite is still who they are.
    try {
      await ref.read(realStackProvider)?.addContact(invite);
    } catch (_) {}
    if (!mounted) return;
    context.push('/chat/${invite.nodeId.hex}');
  }

  Future<void> _redeemProxyShare(String url) async {
    final l = AppL10n.of(context);
    final OproxyInvite invite;
    try {
      invite = OproxyInvite.parse(url);
    } catch (_) {
      _toast(l.inviteInvalid);
      return;
    }
    // The deployment's own decision, called rather than copied: same
    // de-duplication against the effective catalog, same label fallback. A null
    // means the node is already there — worth saying, because the list is long
    // enough that "nothing happened" reads as a failure.
    final updated = routingWithDeployedExit(
      ref.read(proxyRoutingProvider),
      isExit: true,
      nodeId: invite.nodeId,
      label: invite.label,
    );
    if (updated == null) {
      _toast(l.chatLinkProxyKnown);
      return;
    }
    await ref.read(proxyRoutingProvider.notifier).set(updated);
    if (!mounted) return;
    final added = updated.effectiveOproxies
        .firstWhere((e) => e.nodeId == invite.nodeId);
    _toast(l.chatLinkProxyAdded(added.label));
  }

  Future<void> _redeemEntryNodes(String url) async {
    final l = AppL10n.of(context);
    final SharedPeers shared;
    try {
      shared = SharedPeers.parse(url);
    } catch (_) {
      _toast(l.inviteInvalid);
      return;
    }
    // Counted only where the call actually happened: with no running stack the
    // loop is skipped entirely and the honest "0 imported" is what is shown.
    final stack = ref.read(realStackProvider);
    var added = 0;
    if (stack != null) {
      for (final peer in shared.peers) {
        try {
          await stack.addContact(peer);
          added++;
        } catch (_) {}
      }
    }
    _toast(l.peersImported(added));
  }

  Future<void> _openLink(String url) async {
    final l = AppL10n.of(context);
    final uri = Uri.tryParse(url);
    var ok = false;
    if (uri != null) {
      try {
        ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {
        ok = false;
      }
    }
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l.linkOpenFailed),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _onTapMention(NodeId nodeId, String label) async {
    final l = AppL10n.of(context);
    final action = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text('@$label'),
        content: SelectableText(nodeId.hex),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(),
            child: Text(l.actionCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialog).pop('copy'),
            child: Text(l.linkCopy),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialog).pop('open'),
            child: Text(l.linkOpen),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (action == 'copy') {
      await Clipboard.setData(ClipboardData(text: nodeId.hex));
    } else if (action == 'open') {
      context.push('/chat/${nodeId.hex}');
    }
  }

  void _copyCode(String code) {
    Clipboard.setData(ClipboardData(text: code));
    final l = AppL10n.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l.chatCodeCopied),
        duration: const Duration(seconds: 1),
      ),
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
    Map<int, ({int offset, Uint8List bytes})> images,
  ) {
    final tokens = parseFormatted(text);
    final spans = <InlineSpan>[];
    void addText(String s, TextStyle style) =>
        spans.addAll(_inlineSpans(s, style, images, highlight, hlColor));
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
          addText(
            t.text,
            base.copyWith(decoration: TextDecoration.lineThrough),
          );
        case FmtKind.code:
        case FmtKind.codeBlock:
          addText(t.text, mono);
        case FmtKind.link:
          final recognizer = TapGestureRecognizer()
            ..onTap = () => _onTapLink(t.text);
          _recognizers.add(recognizer);
          spans.add(
            TextSpan(
              children: _inlineSpans(
                t.text,
                base.copyWith(
                  color: scheme.primary,
                  decoration: TextDecoration.underline,
                  decorationColor: scheme.primary,
                ),
                images,
                null,
                hlColor,
                recognizer: recognizer,
              ),
            ),
          );
        case FmtKind.cloudAttachment:
          // A widget, not a span: an attachment has a state (present, being
          // fetched, gone) that no run of text can carry.
          spans.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: CloudAttachmentChip(itemId: t.text),
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
                  child: Text.rich(
                    TextSpan(
                      children: _inlineSpans(
                        t.text,
                        base.copyWith(color: shown ? null : Colors.transparent),
                        images,
                        shown ? highlight : null,
                        hlColor,
                        hideImages: !shown,
                      ),
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

    final prepared = _prepareCustomEmoji();
    final blocks = parseBlocks(prepared.body);
    // All-normal: one Text.rich over the whole body — preserves blank lines and
    // matches the pre-block behaviour exactly.
    if (blocks.every((b) => b.kind == MdBlockKind.normal)) {
      final (spans, _) = _spansFor(
        prepared.body,
        0,
        base,
        mono,
        scheme,
        hlQuery,
        hlColor,
        prepared.images,
      );
      return Text.rich(
        TextSpan(children: spans),
        maxLines: widget.maxLines,
        overflow: widget.overflow ?? TextOverflow.clip,
      );
    }

    var indexBase = 0;
    final children = <Widget>[];
    for (final b in blocks) {
      if (b.kind == MdBlockKind.code) {
        children.add(
          _codeBox(b.text, mono, scheme, hlQuery, hlColor, prepared.images),
        );
        continue;
      }
      final blockBase = b.kind == MdBlockKind.quote
          ? base.copyWith(color: scheme.onSurfaceVariant)
          : base;
      final (spans, count) = _spansFor(
        b.text,
        indexBase,
        blockBase,
        mono,
        scheme,
        hlQuery,
        hlColor,
        prepared.images,
      );
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

  /// A fenced code block: a rounded box with the code (horizontally scrollable
  /// so long lines don't wrap) and a copy button. Search hits inside the code
  /// still get the highlight background via [highlightSpans].
  Widget _codeBox(
    String code,
    TextStyle mono,
    ColorScheme scheme,
    String? hlQuery,
    Color hlColor,
    Map<int, ({int offset, Uint8List bytes})> images,
  ) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Text.rich(
                TextSpan(
                  children: _codeSpans(
                    code,
                    mono,
                    scheme,
                    hlQuery,
                    hlColor,
                    images,
                  ),
                ),
              ),
            ),
          ),
          InkWell(
            onTap: () => _copyCode(code),
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Icon(
                Icons.content_copy,
                size: 16,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Syntax-colour the code (via [highlightCode]) and, within each token, still
  /// apply the search highlight background (via [highlightSpans]).
  List<InlineSpan> _codeSpans(
    String code,
    TextStyle mono,
    ColorScheme scheme,
    String? hlQuery,
    Color hlColor,
    Map<int, ({int offset, Uint8List bytes})> images,
  ) {
    final spans = <InlineSpan>[];
    for (final tok in highlightCode(code)) {
      spans.addAll(
        _inlineSpans(
          tok.text,
          _codeStyle(tok.kind, mono, scheme),
          images,
          hlQuery,
          hlColor,
        ),
      );
    }
    return spans;
  }

  TextStyle _codeStyle(CodeTokenKind kind, TextStyle mono, ColorScheme scheme) {
    return switch (kind) {
      CodeTokenKind.plain => mono,
      CodeTokenKind.keyword => mono.copyWith(
        color: scheme.primary,
        fontWeight: FontWeight.w600,
      ),
      CodeTokenKind.str => mono.copyWith(color: scheme.tertiary),
      CodeTokenKind.number => mono.copyWith(color: scheme.secondary),
      CodeTokenKind.comment => mono.copyWith(
        color: scheme.onSurfaceVariant,
        fontStyle: FontStyle.italic,
      ),
    };
  }
}
