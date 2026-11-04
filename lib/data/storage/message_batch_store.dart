import '../../domain/chat.dart';

/// Outcome of an insert-if-missing publication, not an authorization verdict.
enum PreparedMessageWrite { appended, existing, suppressed }

typedef PreparedMessageAppender =
    Future<PreparedMessageWrite> Function(Message message);

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
