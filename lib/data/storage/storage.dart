import 'dart:typed_data';

import '../../core/ids.dart';
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

  /// Persist this identity's veil node config (TOML from `veil_config_init`,
  /// carrying the node keypair) INSIDE the deniable space — so the private key
  /// never lives in a plaintext `config.toml` on disk. Loaded at unlock to boot
  /// the embedded node via deferred-init + apply-config.
  Future<void> saveNodeConfig(String configToml);

  /// The stored node config for this identity, or null if none is saved yet.
  Future<String?> loadNodeConfig();

  Future<void> upsertContact(Contact contact);

  /// The stored contact for [nodeId], or null if we have no record of them.
  Future<Contact?> getContact(NodeId nodeId);

  Future<List<Conversation>> loadConversations();

  Future<List<Message>> loadMessages(String conversationId);
  Future<void> appendMessage(Message message);

  /// Update a stored message's delivery [status] (e.g. `sent → delivered` on an
  /// ack). Folded over the append-log, so it never mutates history in place.
  Future<void> markMessageStatus(String messageId, MessageStatus status);

  /// Persist a file deniably inside the container under [fileId].
  Future<void> storeFile(String fileId, Uint8List bytes, {String? name});

  /// Load a previously stored file, or null if unknown / incomplete.
  Future<Uint8List?> loadFile(String fileId);

  /// Lock the space and zeroize in-memory key material.
  Future<void> close();
}
