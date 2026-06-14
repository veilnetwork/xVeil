import '../core/ids.dart';

/// A remote party the user can message.
class Contact {
  const Contact({required this.nodeId, this.name});

  final NodeId nodeId;
  final String? name;

  String get label => name ?? nodeId.short;
}

/// Direction of a message relative to the local user.
enum MessageDirection { outgoing, incoming }

/// Delivery state of an outgoing message.
///
/// Maps onto the transport lifecycle: queued locally → handed to the node →
/// delivered to peer (or stored in their mailbox) → failed.
enum MessageStatus { sending, sent, delivered, failed }

class Message {
  const Message({
    required this.id,
    required this.conversationId,
    required this.direction,
    required this.body,
    required this.timestamp,
    this.status = MessageStatus.sent,
  });

  final String id;
  final String conversationId;
  final MessageDirection direction;
  final String body;
  final DateTime timestamp;
  final MessageStatus status;

  Message copyWith({MessageStatus? status}) => Message(
        id: id,
        conversationId: conversationId,
        direction: direction,
        body: body,
        timestamp: timestamp,
        status: status ?? this.status,
      );
}

/// A 1:1 conversation. (Group chats are a later milestone.)
///
/// Identified by the peer node id hex so it is stable across restarts and
/// directly maps to a hidden-volume MESSAGE_LOG namespace partition.
class Conversation {
  const Conversation({
    required this.peer,
    this.lastMessage,
    this.unread = 0,
  });

  final Contact peer;
  final Message? lastMessage;
  final int unread;

  String get id => peer.nodeId.hex;
}
