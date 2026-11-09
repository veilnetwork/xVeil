import '../../domain/chat.dart';
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
