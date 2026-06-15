import 'dart:convert';
import 'dart:typed_data';

import '../../core/ids.dart';
import '../../domain/chat.dart';
import '../../domain/identity.dart';
import 'file_store.dart';
import 'kv_log_store.dart';
import 'storage.dart';

/// Reasonable upper bound for a single log scan. hidden-volume's log is the
/// source of truth for messages; conversations are derived by scanning it
/// (the FFI exposes no KV key enumeration).
const _logScanLimit = 100000;

Uint8List _sk(String key) => Uint8List.fromList(utf8.encode(key));

/// Domain [Storage] mapped onto a single hidden-volume space:
/// - SETTINGS (KV): identity blob, app settings, the message-log counter
/// - CONTACTS (KV): one entry per peer, keyed by node id bytes
/// - MESSAGE_LOG (append-log): every message, payload tagged with its
///   conversation id so a single log serves all conversations
///
/// Backed by a [KvLogStore] obtained from a [SpaceOpener], so the same mapping
/// runs over the in-memory fake (dev/tests) and the real `HvSpace` (native).
class HiddenVolumeStorage implements Storage {
  HiddenVolumeStorage(this._opener);

  final SpaceOpener _opener;
  KvLogStore? _store;

  KvLogStore get _s {
    final s = _store;
    if (s == null) {
      throw StateError('storage is locked — call open() first');
    }
    return s;
  }

  @override
  bool get isOpen => _store != null;

  @override
  Future<bool> open({
    required String password,
    bool createIfMissing = false,
  }) async {
    final store = _opener(
      password: Uint8List.fromList(utf8.encode(password)),
      create: createIfMissing,
    );
    if (store == null) return false;
    _store = store;
    return true;
  }

  // --- Identity ----------------------------------------------------------

  @override
  Future<void> saveIdentity(Identity identity) async {
    final json = jsonEncode({
      'n': identity.nodeId.hex,
      'dn': identity.displayName,
      'u': identity.username,
    });
    _s.commit([PutOp(Ns.settings, _sk('identity'), _sk(json))]);
  }

  @override
  Future<Identity?> loadIdentity() async {
    final raw = _s.get(Ns.settings, _sk('identity'));
    if (raw == null) return null;
    final m = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
    return Identity(
      nodeId: NodeId.fromHex(m['n'] as String),
      displayName: m['dn'] as String?,
      username: m['u'] as String?,
    );
  }

  // --- Settings ----------------------------------------------------------

  @override
  Future<void> putSetting(String key, String value) async {
    _s.commit([PutOp(Ns.settings, _sk('set:$key'), _sk(value))]);
  }

  @override
  Future<String?> getSetting(String key) async {
    final raw = _s.get(Ns.settings, _sk('set:$key'));
    return raw == null ? null : utf8.decode(raw);
  }

  // The node config (with the keypair) is just another SETTINGS-namespace KV
  // entry, so it inherits the space's deniability — no plaintext config file.
  @override
  Future<void> saveNodeConfig(String configToml) async {
    _s.commit([PutOp(Ns.settings, _sk('node:config'), _sk(configToml))]);
  }

  @override
  Future<String?> loadNodeConfig() async {
    final raw = _s.get(Ns.settings, _sk('node:config'));
    return raw == null ? null : utf8.decode(raw);
  }

  // --- Contacts ----------------------------------------------------------

  @override
  Future<void> upsertContact(Contact contact) async {
    final json = jsonEncode({
      'n': contact.nodeId.hex,
      'name': contact.name,
      's': contact.status.index,
    });
    // Maintain a contacts index (hidden-volume has no KV key enumeration) so
    // the chat list can show contacts that have no messages yet.
    final index = _contactIndex();
    if (!index.contains(contact.nodeId.hex)) index.add(contact.nodeId.hex);
    _s.commit([
      PutOp(Ns.contacts, contact.nodeId.bytes, _sk(json)),
      PutOp(Ns.settings, _sk('contacts:index'), _sk(jsonEncode(index))),
    ]);
  }

  List<String> _contactIndex() {
    final raw = _s.get(Ns.settings, _sk('contacts:index'));
    if (raw == null) return [];
    return (jsonDecode(utf8.decode(raw)) as List).cast<String>();
  }

  @override
  Future<Contact?> getContact(NodeId nodeId) async {
    if (_s.get(Ns.contacts, nodeId.bytes) == null) return null;
    return _contactFor(nodeId);
  }

  Contact _contactFor(NodeId id) {
    final raw = _s.get(Ns.contacts, id.bytes);
    if (raw == null) return Contact(nodeId: id);
    final m = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
    final s = m['s'] as int?;
    return Contact(
      nodeId: id,
      name: m['name'] as String?,
      status: s != null && s >= 0 && s < ContactStatus.values.length
          ? ContactStatus.values[s]
          : ContactStatus.accepted,
    );
  }

  // --- Conversations & messages -----------------------------------------

  @override
  Future<List<Conversation>> loadConversations() async {
    final byConv = <String, Message>{};
    for (final entry in _scanLog()) {
      final existing = byConv[entry.conversationId];
      if (existing == null || entry.timestamp.isAfter(existing.timestamp)) {
        byConv[entry.conversationId] = entry;
      }
    }
    // Union of known contacts and any conversation that has messages (a peer
    // we received from is auto-added, but include log-only ids defensively).
    final ids = <String>{..._contactIndex(), ...byConv.keys};
    final out = ids
        .map((hex) => Conversation(
              peer: _contactFor(NodeId.fromHex(hex)),
              lastMessage: byConv[hex],
            ))
        .toList()
      ..sort((a, b) {
        final at = a.lastMessage?.timestamp;
        final bt = b.lastMessage?.timestamp;
        // Conversations with messages first (newest), message-less by name.
        if (at == null && bt == null) {
          return a.peer.label.compareTo(b.peer.label);
        }
        if (at == null) return 1;
        if (bt == null) return -1;
        return bt.compareTo(at);
      });
    return out;
  }

  @override
  Future<List<Message>> loadMessages(String conversationId) async {
    return _scanLog()
        .where((m) => m.conversationId == conversationId)
        .toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }

  @override
  Future<void> storeFile(String fileId, Uint8List bytes, {String? name}) async {
    FileStore(_s).storeFile(fileId, bytes, name: name);
  }

  @override
  Future<Uint8List?> loadFile(String fileId) async => FileStore(_s).loadFile(fileId);

  @override
  Future<void> appendMessage(Message message) async {
    final nextId = _nextLogId();
    _s.commit([
      AppendLogOp(Ns.messageLog, nextId, _sk(_encodeMessage(message))),
      // Map the domain message id -> its log_id so a later edit/delete can
      // rewrite the SAME record (last-write-wins), the core's edit primitive.
      PutOp(Ns.settings, _sk('msgidx:${message.id}'), _sk('$nextId')),
      PutOp(Ns.settings, _sk('msg_next_id'), _sk('${nextId + 1}')),
    ]);
  }

  String _encodeMessage(Message m) => jsonEncode({
        'id': m.id,
        'c': m.conversationId,
        'd': m.direction.index,
        'b': m.body,
        't': m.timestamp.millisecondsSinceEpoch,
        's': m.status.index,
        if (m.edited) 'e': 1,
        if (m.fileId != null) 'fi': m.fileId,
        if (m.fileName != null) 'fn': m.fileName,
      });

  int _nextLogId() {
    final raw = _s.get(Ns.settings, _sk('msg_next_id'));
    if (raw == null) return 1;
    return int.tryParse(utf8.decode(raw)) ?? 1;
  }

  /// The log_id a message was written under, or null if we have no index entry
  /// (older messages predate the index, or the id is unknown / already deleted).
  int? _logIdFor(String messageId) {
    final raw = _s.get(Ns.settings, _sk('msgidx:$messageId'));
    return raw == null ? null : int.tryParse(utf8.decode(raw));
  }

  @override
  Future<void> editMessage(String messageId, String newBody) async {
    final logId = _logIdFor(messageId);
    if (logId == null) return;
    Message? current;
    for (final m in _scanLog()) {
      if (m.id == messageId) {
        current = m;
        break;
      }
    }
    if (current == null) return;
    // Rewrite the SAME log_id: last-write-wins replaces the body on read, so
    // the prior text no longer reads back (its chunk is orphaned for scrub).
    final edited = current.copyWith(body: newBody, edited: true);
    _s.commit([AppendLogOp(Ns.messageLog, logId, _sk(_encodeMessage(edited)))]);
  }

  @override
  Future<void> deleteMessage(String messageId) async {
    final logId = _logIdFor(messageId);
    if (logId == null) return;
    // Tombstone the SAME log_id so the body no longer reads back, and drop the
    // index entry. The original record's chunk is orphaned; scrubDeleted()
    // reclaims it for forensic erasure.
    final tomb = jsonEncode({'op': 'del', 'id': messageId});
    _s.commit([
      AppendLogOp(Ns.messageLog, logId, _sk(tomb)),
      DeleteOp(Ns.settings, _sk('msgidx:$messageId')),
    ]);
  }

  @override
  Future<void> scrubDeleted() async {
    // Reclaim chunks orphaned by edit/delete so the prior plaintext is no
    // longer recoverable from the container. Backed by hidden-volume's
    // vacuum/compact when the store exposes it; a no-op on the in-memory fake.
    _s.scrub();
  }

  @override
  Future<void> markMessageStatus(String messageId, MessageStatus status) async {
    // Append-only log can't mutate a row, so record a status OP that [_scanLog]
    // folds onto the message (latest wins). Drives the outbox: an ack flips a
    // message to `delivered` so it is no longer re-sent.
    final nextId = _nextLogId();
    final payload =
        jsonEncode({'op': 'status', 'id': messageId, 's': status.index});
    _s.commit([
      AppendLogOp(Ns.messageLog, nextId, _sk(payload)),
      PutOp(Ns.settings, _sk('msg_next_id'), _sk('${nextId + 1}')),
    ]);
  }

  /// Scan the log, building messages and folding status OPs onto them. Base
  /// rows carry the message; `{op:'status'}` rows update an existing id.
  Iterable<Message> _scanLog() {
    final order = <String>[];
    final byId = <String, Message>{};
    final statusOps = <String, MessageStatus>{};
    for (final e in _s.iterLogRange(namespace: Ns.messageLog, limit: _logScanLimit)) {
      final m = jsonDecode(utf8.decode(e.payload)) as Map<String, dynamic>;
      if (m['op'] == 'status') {
        statusOps[m['id'] as String] = MessageStatus.values[m['s'] as int];
        continue;
      }
      if (m['op'] == 'del') {
        // Tombstone (deleted message) — the record at this log_id no longer
        // carries a body. Drop it so it never surfaces.
        final id = m['id'] as String;
        byId.remove(id);
        order.remove(id);
        continue;
      }
      final id = m['id'] as String;
      if (!byId.containsKey(id)) order.add(id);
      byId[id] = Message(
        id: id,
        conversationId: m['c'] as String,
        direction: MessageDirection.values[m['d'] as int],
        body: m['b'] as String,
        timestamp: DateTime.fromMillisecondsSinceEpoch(m['t'] as int),
        status: MessageStatus.values[m['s'] as int],
        edited: m['e'] == 1,
        fileId: m['fi'] as String?,
        fileName: m['fn'] as String?,
      );
    }
    return order.map((id) {
      final msg = byId[id]!;
      final s = statusOps[id];
      return s != null ? msg.copyWith(status: s) : msg;
    });
  }

  @override
  Future<void> close() async {
    _store?.close();
    _store = null;
  }
}
