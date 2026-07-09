import '../../domain/chat.dart';

/// Pure matchers/formatters behind the chats-screen search — kept
/// widget-free so the behavior is unit-testable.
///
/// All queries are matched case-insensitively; callers pass the query
/// pre-lowercased so a scan over thousands of messages lowercases each
/// needle exactly once.

/// True when [m] should show up for [lowerQuery]: body or attached file
/// name contains it. Service echo frames (sync/callSignal debug echoes)
/// never match.
bool messageMatchesQuery(Message m, String lowerQuery) {
  if (lowerQuery.isEmpty) return false;
  if (m.body.trimLeft().startsWith('↩︎ echo:')) return false;
  if (m.body.toLowerCase().contains(lowerQuery)) return true;
  final fn = m.fileName;
  return fn != null && fn.toLowerCase().contains(lowerQuery);
}

/// A short window of [body] centered on the first match of [lowerQuery],
/// with ellipses marking trimmed sides. Falls back to the head of the body
/// when the match is only in the file name.
String searchSnippet(String body, String lowerQuery, {int radius = 40}) {
  final at = body.toLowerCase().indexOf(lowerQuery);
  if (at < 0) {
    return body.length <= 2 * radius
        ? body
        : '${body.substring(0, 2 * radius)}…';
  }
  final start = (at - radius).clamp(0, body.length);
  final end = (at + lowerQuery.length + radius).clamp(0, body.length);
  final prefix = start > 0 ? '…' : '';
  final suffix = end < body.length ? '…' : '';
  return '$prefix${body.substring(start, end)}$suffix';
}

/// Conversations whose contact matches [lowerQuery] by local alias (label)
/// or stored name.
List<Conversation> filterConversationsByName(
  List<Conversation> conversations,
  String lowerQuery,
) {
  if (lowerQuery.isEmpty) return conversations;
  return conversations
      .where(
        (c) =>
            c.peer.label.toLowerCase().contains(lowerQuery) ||
            (c.peer.name?.toLowerCase().contains(lowerQuery) ?? false),
      )
      .toList(growable: false);
}
