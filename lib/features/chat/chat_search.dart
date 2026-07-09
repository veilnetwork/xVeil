import 'dart:convert';

import '../../data/transport/wire_envelope.dart' show isServiceEchoBody;
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
  if (isServiceEchoBody(m.body)) return false;
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

/// A locally-pinned message: its id plus a display snippet (so the pinned
/// banner renders even when the message is outside the loaded window).
typedef PinnedRef = ({String id, String text});

/// Serialize a pin for the settings KV: `{id, t}` with the snippet capped so a
/// huge message doesn't bloat the setting.
String encodePinned(String id, String body) {
  final snippet = body.length > 120 ? '${body.substring(0, 120)}…' : body;
  return jsonEncode({'id': id, 't': snippet});
}

/// Parse a pin from the settings KV, or null when absent/blank/corrupt.
PinnedRef? decodePinned(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  try {
    final j = jsonDecode(raw);
    if (j is Map && j['id'] is String) {
      return (id: j['id'] as String, text: (j['t'] as String?) ?? '');
    }
  } catch (_) {}
  return null;
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
