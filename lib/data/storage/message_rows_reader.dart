import '../../domain/chat.dart';
import '../../domain/message_history_order.dart';
import 'storage.dart';

/// Optional read of the current live rows without computing UI display order.
///
/// Rows retain normal status/signature overlays and conversation isolation.
/// Order is unspecified; the returned list is detached from storage. This does
/// not filter expiry/retention or establish authorization, and is not atomic
/// with a separately read edit frontier. Callers keep those fresh checks.
abstract interface class MessageRowsReader {
  Future<List<Message>> loadMessageRows(String conversationId);
}

/// Stores without this capability retain their ordinary read path. A failure
/// of an advertised capability propagates; it must not become an empty or
/// remembered successful snapshot.
Future<List<Message>> readMessageRows(Storage storage, String conversationId) =>
    storage is MessageRowsReader
    ? (storage as MessageRowsReader).loadMessageRows(conversationId)
    : storage.loadMessages(conversationId);

/// Optional bounded read in wire timestamp-milliseconds/message-ID order.
/// Rows retain current status/signature overlays and conversation isolation.
/// This is a storage projection, not an authorization or retention decision.
/// Callers must apply their current policy; filtered views may need all rows.
abstract interface class MessageHistoryWindowReader {
  Future<List<Message>> loadMessageHistoryWindow(
    String conversationId, {
    required int limit,
    int? afterTimestampMs,
    String? afterId,
  });
}

/// A failed advertised reader propagates. Ordinary stores obtain a fresh full
/// view and select the window without keeping rows between requests.
Future<List<Message>> readMessageHistoryWindow(
  Storage storage,
  String conversationId, {
  required int limit,
  int? afterTimestampMs,
  String? afterId,
}) async {
  if (limit < 0) throw ArgumentError.value(limit, 'limit');
  if ((afterTimestampMs == null) != (afterId == null)) {
    throw ArgumentError('history cursor requires both timestamp and id');
  }
  if (storage is MessageHistoryWindowReader) {
    return (storage as MessageHistoryWindowReader).loadMessageHistoryWindow(
      conversationId,
      limit: limit,
      afterTimestampMs: afterTimestampMs,
      afterId: afterId,
    );
  }
  return messageHistoryWindow(
    await readMessageRows(storage, conversationId),
    limit: limit,
    afterTimestampMs: afterTimestampMs,
    afterId: afterId,
  );
}
