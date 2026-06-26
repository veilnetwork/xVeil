import '../core/ids.dart';

/// Relationship state with a peer — gates messaging so strangers can't write
/// without consent.
/// - [pendingOutgoing]: we sent a connection request, awaiting their approval.
/// - [pendingIncoming]: they requested us; we can accept / decline / block.
/// - [accepted]: mutual — free messaging.
/// - [blocked]: their messages are dropped.
enum ContactStatus { pendingOutgoing, pendingIncoming, accepted, blocked }

/// A remote party the user can message.
class Contact {
  const Contact({
    required this.nodeId,
    this.name,
    this.status = ContactStatus.accepted,
    this.muted = false,
    this.pinned = false,
  });

  final NodeId nodeId;
  final String? name;
  final ContactStatus status;

  /// Local notification-mute for this conversation. Stored in the encrypted
  /// contact record (never on the wire) — a per-peer flag is low-sensitivity but
  /// still belongs in the deniable store, not plaintext prefs (a muted-peer list
  /// would otherwise leak the contact set on a seized device).
  final bool muted;

  /// Local pin — pinned conversations sort to the top of the list. Encrypted
  /// + local-only, same rationale as [muted].
  final bool pinned;

  String get label => name ?? nodeId.short;

  /// Free messaging is only allowed once the relationship is accepted.
  bool get canMessage => status == ContactStatus.accepted;

  Contact copyWith({
    String? name,
    ContactStatus? status,
    bool? muted,
    bool? pinned,
  }) =>
      Contact(
        nodeId: nodeId,
        name: name ?? this.name,
        status: status ?? this.status,
        muted: muted ?? this.muted,
        pinned: pinned ?? this.pinned,
      );
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
    this.fileId,
    this.fileName,
    this.edited = false,
  });

  final String id;
  final String conversationId;
  final MessageDirection direction;
  final String body;
  final DateTime timestamp;
  final MessageStatus status;

  /// True once the body has been replaced via an edit. Surfaced in the UI as
  /// an "edited" marker; never reveals the prior text (which is scrubbed).
  final bool edited;

  /// When set, this message carries a stored file (see Storage.loadFile);
  /// [body] holds a human label and [fileName] the original name.
  final String? fileId;
  final String? fileName;

  bool get isFile => fileId != null;

  Message copyWith({MessageStatus? status, String? body, bool? edited}) =>
      Message(
        id: id,
        conversationId: conversationId,
        direction: direction,
        body: body ?? this.body,
        timestamp: timestamp,
        status: status ?? this.status,
        fileId: fileId,
        fileName: fileName,
        edited: edited ?? this.edited,
      );
}

/// A 1:1 conversation. (Group chats are a later milestone.)
///
/// Identified by the peer node id hex so it is stable across restarts; it tags
/// entries in the SINGLE shared MESSAGE_LOG append-log (NOT a per-conversation
/// namespace partition — see doc/EVENT-LOG-SYNC-DESIGN.md §14.2).
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
