/// A local user decision, atomically recorded with the message tombstone.
enum MessageDeletionIntent { devices, everyone }

/// Recovery metadata only: never the erased body, filename, reply or caption.
typedef PendingMessageDeletion = ({
  String conversationId,
  String messageId,
  bool mirrorPending,
  bool peerPending,
  String? contentId,
});

String pendingMessageDeletionKey(PendingMessageDeletion deletion) =>
    '${deletion.conversationId}\u001f${deletion.messageId}';
