import '../../domain/chat.dart';
import '../../domain/identity.dart';

/// Domain-oriented persistence port.
///
/// The production adapter is backed by `hidden-volume`: a [open] call unlocks
/// one space with the user's password; identity/settings map to KV
/// namespaces (SETTINGS, CONTACTS) and messages to a per-conversation
/// MESSAGE_LOG append-log. Keeping the port domain-shaped (not KV-shaped)
/// means the UI never sees namespace bytes or commit sequencing.
abstract interface class Storage {
  /// Unlock (or create on first run) the user's space with [password].
  /// Returns false if the password does not unlock any space.
  Future<bool> open({required String password, bool createIfMissing = false});

  bool get isOpen;

  Future<void> saveIdentity(Identity identity);
  Future<Identity?> loadIdentity();

  Future<void> putSetting(String key, String value);
  Future<String?> getSetting(String key);

  Future<void> upsertContact(Contact contact);
  Future<List<Conversation>> loadConversations();

  Future<List<Message>> loadMessages(String conversationId);
  Future<void> appendMessage(Message message);

  /// Lock the space and zeroize in-memory key material.
  Future<void> close();
}
