import '../core/ids.dart';

const int kMessageMentionMaxCount = 64;

final _canonicalMentionPattern = RegExp(
  r'@\[([0-9a-fA-F]{64})(?:\|([a-z0-9%]{3,32}))?\]',
);
final _canonicalDhtNamePattern = RegExp(r'^[a-z0-9_]{3,32}$');

/// A canonical mention keeps the complete [nodeId] on disk and on the wire.
///
/// [dhtName] is only a public lookup hint. It is never authority and must be
/// verified against the current DHT owner before being rendered.
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
      // independently constructed content cannot break projections.
    }
  }
  return List.unmodifiable(mentions);
}

bool messageMentionsNode(String body, NodeId nodeId) =>
    parseMessageMentions(body).any((mention) => mention.nodeId == nodeId);

/// Safe synchronous fallback for surfaces that cannot perform identity
/// lookups (search indices, logs and early notification projection).
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
