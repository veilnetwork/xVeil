import 'call_log.dart';
import 'chat.dart' show Message;

/// One row of a conversation: a message, or a call that happened in it.
///
/// Calls are NOT messages and are deliberately not stored as any. The journal
/// (`call_log.dart`) is already the record — encrypted, capped, and mirrored to
/// this identity's other devices — so writing a second copy into the message
/// log would put the same fact in two places, with two deletion rules and two
/// chances to disagree. This is a view over both.
sealed class ChatTimelineItem {
  const ChatTimelineItem();

  /// Sort key: ms since epoch.
  int get atMs;
}

class ChatMessageItem extends ChatTimelineItem {
  const ChatMessageItem(this.message);
  final Message message;
  @override
  int get atMs => message.timestamp.millisecondsSinceEpoch;
}

class ChatCallItem extends ChatTimelineItem {
  const ChatCallItem(this.call);
  final CallLogEntry call;
  @override
  int get atMs => call.atMs;
}

/// Merge [calls] into the loaded [messages] window, oldest first.
///
/// [messages] must already be in the order the conversation renders them
/// (oldest first), and is the WINDOW — the app pages history, so it is
/// normally the tail of a longer conversation.
///
/// Calls are clipped to that window's span for a reason. Dropping every call
/// into the list regardless would pile a year of them above the oldest loaded
/// message, where they have no conversation around them and push the messages
/// somebody opened the chat to read off the screen. Inside the span they sit
/// where they happened, which is the point.
///
/// The newest end is deliberately NOT clipped: a call that just ended is newer
/// than the last message, and that is exactly the one a person opens the chat
/// to see.
List<ChatTimelineItem> mergeCallsIntoTimeline({
  required List<Message> messages,
  required List<CallLogEntry> calls,
}) {
  if (calls.isEmpty) {
    return [for (final m in messages) ChatMessageItem(m)];
  }
  // With no messages there is no window to clip to, and the honest answer is
  // the calls themselves: a conversation whose only history is a missed call
  // should not look empty.
  final int? oldest = messages.isEmpty
      ? null
      : messages.first.timestamp.millisecondsSinceEpoch;
  final items = <ChatTimelineItem>[
    for (final m in messages) ChatMessageItem(m),
    for (final c in calls)
      if (oldest == null || c.atMs >= oldest) ChatCallItem(c),
  ];
  // Stable by design: two rows sharing a millisecond keep the order they were
  // added, so a message and the call it is about do not swap places between
  // builds and make the list appear to shuffle itself.
  items.sort((a, b) => a.atMs.compareTo(b.atMs));
  return items;
}
