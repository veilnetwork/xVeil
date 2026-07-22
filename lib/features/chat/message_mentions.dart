import 'package:flutter/material.dart';

import '../../core/ids.dart';

const int kMessageMentionMaxCount = 64;

final _canonicalMentionPattern = RegExp(
  r'@\[([0-9a-fA-F]{64})(?:\|([a-z0-9%]{3,32}))?\]',
);
final _canonicalDhtNamePattern = RegExp(r'^[a-z0-9_]{3,32}$');

class MessageMentionToken {
  const MessageMentionToken({
    required this.start,
    required this.end,
    required this.nodeId,
    this.dhtName,
  });

  final int start;
  final int end;
  final NodeId nodeId;

  /// Public lookup hint only. It is never an authority: renderers must verify
  /// that the current DHT owner is still [nodeId] before displaying it.
  final String? dhtName;
}

String encodeMessageMention(NodeId nodeId, {String? dhtName}) {
  final normalized = dhtName?.trim().toLowerCase();
  final safeName =
      normalized != null && _canonicalDhtNamePattern.hasMatch(normalized)
      ? normalized
      : null;
  // `%` is outside the DHT alphabet and has no Markdown formatting meaning,
  // so it is a compact, reversible escape for `_` inside the inline token.
  final encodedName = safeName?.replaceAll('_', '%');
  return '@[${nodeId.hex}${encodedName == null ? '' : '|$encodedName'}]';
}

List<MessageMentionToken> parseMessageMentions(String body) {
  final mentions = <MessageMentionToken>[];
  for (final match in _canonicalMentionPattern.allMatches(body)) {
    if (mentions.length >= kMessageMentionMaxCount) break;
    try {
      mentions.add(
        MessageMentionToken(
          start: match.start,
          end: match.end,
          nodeId: NodeId.fromHex(match.group(1)!.toLowerCase()),
          dhtName: match.group(2)?.replaceAll('%', '_'),
        ),
      );
    } catch (_) {
      // The strict regex already rejects malformed ids. Keep this defensive so
      // an independently-constructed body can never break message rendering.
    }
  }
  return List.unmodifiable(mentions);
}

bool messageMentionsNode(String body, NodeId nodeId) =>
    parseMessageMentions(body).any((mention) => mention.nodeId == nodeId);

/// Safe synchronous fallback for surfaces that cannot perform identity
/// lookups (search indices, logs and early notification projection). The full
/// canonical id remains in storage/wire; only its normal compact UI form is
/// shown here.
String messageMentionsFallbackText(String body) {
  final mentions = parseMessageMentions(body);
  if (mentions.isEmpty) return body;
  final out = StringBuffer();
  var cursor = 0;
  for (final mention in mentions) {
    out
      ..write(body.substring(cursor, mention.start))
      ..write('@${mention.nodeId.short}');
    cursor = mention.end;
  }
  out.write(body.substring(cursor));
  return out.toString();
}

class ActiveMentionQuery {
  const ActiveMentionQuery({
    required this.start,
    required this.end,
    required this.query,
  });

  final int start;
  final int end;
  final String query;
}

/// The unfinished `@query` immediately before the caret. E-mail-like text does
/// not trigger: `@` must begin the field or follow whitespace/open punctuation.
ActiveMentionQuery? activeMentionQuery(String text, TextSelection selection) {
  if (!selection.isValid || !selection.isCollapsed) return null;
  final caret = selection.extentOffset.clamp(0, text.length);
  if (caret == 0) return null;
  final start = text.lastIndexOf('@', caret - 1);
  if (start < 0) return null;
  if (start > 0 && !RegExp(r'[\s\(\[\{]').hasMatch(text[start - 1])) {
    return null;
  }
  final query = text.substring(start + 1, caret);
  if (query.length > 64 || query.contains(RegExp(r'[\s@\[\]\|]'))) {
    return null;
  }
  return ActiveMentionQuery(start: start, end: caret, query: query);
}
