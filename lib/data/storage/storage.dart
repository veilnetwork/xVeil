import 'dart:typed_data';

import '../../core/ids.dart';
import '../../domain/chat.dart';
import '../../domain/identity.dart';
import '../../domain/roster.dart';

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

  /// Persist this space's **master roster** — the list of child identities it
  /// manages (label + each child's opaque `SpaceKeys`). Stored as a KV blob
  /// inside the space, so it inherits the space's deniability; writing one is
  /// what makes a space a *master*. The keys are sensitive — they live only
  /// here, never logged.
  Future<void> saveRoster(List<RosterEntry> entries);

  /// The roster stored in this space, or null if it is a plain identity space
  /// (no roster blob). Null-vs-list is the master-vs-identity discriminator the
  /// app uses after unlock — there is no on-disk flag (deniability).
  Future<List<RosterEntry>?> loadRoster();

  Future<void> upsertContact(Contact contact);

  /// The stored contact for [nodeId], or null if we have no record of them.
  Future<Contact?> getContact(NodeId nodeId);

  Future<List<Conversation>> loadConversations();

  Future<List<Message>> loadMessages(String conversationId);
  Future<void> appendMessage(Message message);

  /// Update a stored message's delivery [status] (e.g. `sent → delivered` on an
  /// ack). Folded over the append-log, so it never mutates history in place.
  Future<void> markMessageStatus(String messageId, MessageStatus status);

  /// Replace the body of message [messageId] with [newBody] (edit of a sent
  /// message). Re-writes the SAME log record via last-write-wins, so the old
  /// text no longer reads back; the orphaned ciphertext chunk is reclaimed by a
  /// later [scrubDeleted] pass. No-op if the id is unknown.
  Future<void> editMessage(String messageId, String newBody);

  /// Permanently remove message [messageId] (incl. a received one). Tombstones
  /// the SAME log record so the body no longer reads back, then the prior
  /// chunk is reclaimed by [scrubDeleted] for true (forensic) erasure. No-op if
  /// the id is unknown.
  Future<void> deleteMessage(String messageId);

  /// Reclaim/overwrite chunks orphaned by edits and deletes so the prior
  /// plaintext is no longer recoverable from the container even by a
  /// password-holder. Backed by hidden-volume's vacuum/compact; a no-op on the
  /// in-memory fake (which never persists). MUST be run after edit/delete to
  /// make erasure deniable rather than merely logical.
  Future<void> scrubDeleted();

  /// Persist a file deniably inside the container under [fileId].
  Future<void> storeFile(String fileId, Uint8List bytes, {String? name});

  /// Load a previously stored file, or null if unknown / incomplete.
  Future<Uint8List?> loadFile(String fileId);

  /// Lock the space and zeroize in-memory key material.
  Future<void> close();
}
