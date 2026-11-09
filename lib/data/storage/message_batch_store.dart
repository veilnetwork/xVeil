import '../../domain/chat.dart';

/// One bounded prepared cohort may publish atomically. Each encoded storage row is
/// still limited to 1800 bytes by the adapter (at most 115200 payload bytes).
/// Ordinary live-message coalescing keeps its separate, smaller budget.
const preparedMessageBatchMaxRows = 64;

/// Outcome of an insert-if-missing publication, not an authorization verdict.
enum PreparedMessageWrite { appended, existing, suppressed }

typedef PreparedMessageAppender =
    Future<PreparedMessageWrite> Function(Message message);

/// Immutable compare-and-adopt request. The messaging layer has already
/// authenticated the source position; storage only checks the held raw pair.
class MessageOrderingAdoption {
  const MessageOrderingAdoption({
    required this.conversationId,
    required this.messageId,
    required this.provisionalAuthor,
    required this.provisionalSeq,
    required this.author,
    required this.seq,
  });
  final String conversationId, messageId, provisionalAuthor, author;
  final int provisionalSeq, seq;
}

typedef PreparedOrderingAdopter =
    Future<bool> Function(MessageOrderingAdoption request);

/// Insert/ordering boundaries used by the ordinary mirror merge. An absent
/// ordering callback leaves that operation on its ordinary storage path.
class PreparedMessageWrites {
  const PreparedMessageWrites({required this.append, this.adoptOrdering});
  final PreparedMessageAppender append;
  final PreparedOrderingAdopter? adoptOrdering;
}

abstract interface class PreparedOrderingBatchStore {
  /// Per-request compare-and-adopt results after durable publication. Null
  /// means unsupported and no write. Does not insert posts or change bodies,
  /// delivery status, raw authorship or exportable sequence slots.
  Future<List<bool>?> adoptMessageOrderingBatch(
    List<MessageOrderingAdoption> requests, {
    required Future<void> Function() beforeCommit,
  });
}

/// Optional storage capability for already-positioned, bounded mirror posts.
/// Null means the request is unsupported and **nothing was written**. A
/// non-null result corresponds to every input and follows durable publication.
/// Existing rows are not overwritten; tombstones/clear watermarks suppress
/// stale bodies. Unsupported stores keep the ordinary single-message path.
abstract interface class PreparedMessageBatchStore {
  Future<List<PreparedMessageWrite>?> appendMissingMessageBatch(
    List<Message> messages, {

    /// Fresh admission immediately before the native transaction is sent.
    /// May read settings/files/contacts, but must not enter message scan APIs:
    /// the adapter holds its scan gate across the compare-and-insert turn.
    required Future<void> Function() beforeCommit,
  });
}
