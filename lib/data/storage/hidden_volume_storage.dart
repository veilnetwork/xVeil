import 'dart:convert';
import 'dart:typed_data';

import '../../core/ids.dart';
import '../../domain/chat.dart';
import '../../domain/identity.dart';
import '../../domain/roster.dart';
import 'file_store.dart';
import 'kv_log_store.dart';
import 'storage.dart';

/// Reasonable upper bound for a single log scan. hidden-volume's log is the
/// source of truth for messages; conversations are derived by scanning it
/// (the FFI exposes no KV key enumeration).
const _logScanLimit = 100000;

Uint8List _sk(String key) => Uint8List.fromList(utf8.encode(key));

/// Opener for [HiddenVolumeStorage.fromStore], where the store is already open
/// and [HiddenVolumeStorage.open] is never called.
KvLogStore? _noOpener({required Uint8List password, required bool create}) => null;

/// Domain [Storage] mapped onto a single hidden-volume space:
/// - SETTINGS (KV): identity blob, app settings, the message-log counter
/// - CONTACTS (KV): one entry per peer, keyed by node id bytes
/// - MESSAGE_LOG (append-log): every message, payload tagged with its
///   conversation id so a single log serves all conversations
///
/// Backed by a [KvLogStore] obtained from a [SpaceOpener], so the same mapping
/// runs over the in-memory fake (dev/tests) and the real `HvSpace` (native).
class HiddenVolumeStorage implements Storage {
  HiddenVolumeStorage(this._opener, {this.keysOpener});

  /// Wrap an ALREADY-OPEN [KvLogStore] (e.g. one [MultiSpaceKvLogStore] view of
  /// a shared multi-space backing). Used in "all identities online" mode where
  /// every identity's space is already hosted; [open]/[openWithKeys] are not
  /// used. [close] tears down the view (a no-op for a shared backing — the owner
  /// closes the backing once).
  HiddenVolumeStorage.fromStore(KvLogStore store)
      : _opener = _noOpener,
        keysOpener = null,
        _store = store;

  final SpaceOpener _opener;

  /// Opens a child space by its `SpaceKeys` (master mode). Null when this
  /// handle is not configured for keys-based open (single-identity build).
  final KeysSpaceOpener? keysOpener;
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
    // Close any previously-open space before adopting the new one. Without this
    // a re-open (e.g. switching identities) would leak the old handle and keep
    // its exclusive flock, so the NEXT open of that container fails with `Busy`.
    _store?.close();
    _store = store;
    _invalidateScanCache(); // adopting a different space — drop the old fold
    return true;
  }

  /// Open a child space directly from its [keys] (master mode) — no password.
  /// Returns false if the keys match no space, or if this handle has no
  /// keys-opener configured.
  @override
  Future<bool> openWithKeys(Uint8List keys) async {
    final store = keysOpener?.call(keys);
    if (store == null) return false;
    _store?.close();
    _store = store;
    _invalidateScanCache(); // adopting a different space — drop the old fold
    return true;
  }

  @override
  Uint8List exportSpaceKeys() => _s.exportKeys();

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

  // The master roster is a single SETTINGS-namespace KV blob, so it inherits
  // the space's deniability. Each child's SpaceKeys are base64'd inside it —
  // sensitive material that lives only in this (master) space.
  @override
  Future<void> saveRoster(List<RosterEntry> entries) async {
    final json = jsonEncode([
      for (final e in entries)
        {
          'l': e.label,
          'k': base64.encode(e.spaceKeys),
          if (e.anonymous) 'a': 1,
        },
    ]);
    _s.commit([PutOp(Ns.settings, _sk('master:roster'), _sk(json))]);
  }

  @override
  Future<List<RosterEntry>?> loadRoster() async {
    final raw = _s.get(Ns.settings, _sk('master:roster'));
    if (raw == null) return null; // plain identity space — not a master
    final list = jsonDecode(utf8.decode(raw)) as List;
    return [
      for (final e in list.cast<Map<String, dynamic>>())
        RosterEntry(
          label: e['l'] as String,
          spaceKeys: base64.decode(e['k'] as String),
          anonymous: e['a'] == 1,
        ),
    ];
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
  Future<void> markRead(String conversationId) async {
    var latest = 0;
    for (final m in _scanLog()) {
      if (m.conversationId == conversationId) {
        final ms = m.timestamp.millisecondsSinceEpoch;
        if (ms > latest) latest = ms;
      }
    }
    _s.commit([PutOp(Ns.settings, _sk('read:$conversationId'), _sk('$latest'))]);
  }

  /// Millis of the latest message marked read in [conversationId] (0 = never
  /// read → all incoming count as unread).
  int _readMarker(String conversationId) {
    final raw = _s.get(Ns.settings, _sk('read:$conversationId'));
    return raw == null ? 0 : (int.tryParse(utf8.decode(raw)) ?? 0);
  }

  @override
  Future<List<Conversation>> loadConversations() async {
    final byConv = <String, Message>{};
    final unread = <String, int>{};
    final readMarkers = <String, int>{}; // cache: one KV read per conversation
    for (final entry in _scanLog()) {
      final existing = byConv[entry.conversationId];
      if (existing == null || entry.timestamp.isAfter(existing.timestamp)) {
        byConv[entry.conversationId] = entry;
      }
      // Unread = incoming messages newer than the conversation's read marker.
      if (entry.direction == MessageDirection.incoming) {
        final marker = readMarkers[entry.conversationId] ??=
            _readMarker(entry.conversationId);
        if (entry.timestamp.millisecondsSinceEpoch > marker) {
          unread[entry.conversationId] = (unread[entry.conversationId] ?? 0) + 1;
        }
      }
    }
    // Union of known contacts and any conversation that has messages (a peer
    // we received from is auto-added, but include log-only ids defensively).
    final ids = <String>{..._contactIndex(), ...byConv.keys};
    final out = ids
        .map((hex) => Conversation(
              peer: _contactFor(NodeId.fromHex(hex)),
              lastMessage: byConv[hex],
              unread: unread[hex] ?? 0,
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
    // Edit rewrites an EXISTING log_id (last-write-wins) and does NOT bump the
    // next-id, so the next-id-keyed scan cache would otherwise show the stale
    // body — invalidate it explicitly.
    _invalidateScanCache();
  }

  @override
  Future<void> deleteMessage(String messageId) async {
    final logId = _logIdFor(messageId);
    if (logId == null) return;
    // If it is a file message, purge the stored blob too — otherwise the
    // attachment lingers in the container after the row is gone (a deniability
    // hole). Look it up before we tombstone the row.
    String? fileId;
    for (final m in _scanLog()) {
      if (m.id == messageId) {
        fileId = m.fileId;
        break;
      }
    }
    // One atomic commit: tombstone the SAME log_id (so the body no longer reads
    // back), drop the index entry, AND purge the file blob. Folding the blob
    // ops in here (rather than a separate FileStore.deleteFile commit) closes
    // the crash window where the chat row and the blob could disagree. The
    // orphaned chunks are reclaimed by scrubDeleted() for forensic erasure.
    final tomb = jsonEncode({'op': 'del', 'id': messageId});
    _s.commit([
      AppendLogOp(Ns.messageLog, logId, _sk(tomb)),
      DeleteOp(Ns.settings, _sk('msgidx:$messageId')),
      if (fileId != null) ...FileStore(_s).deleteFileOps(fileId),
    ]);
    // Tombstone rewrites an EXISTING log_id without bumping the next-id, so the
    // next-id-keyed scan cache must be invalidated or the deleted message would
    // keep surfacing (a deniability hole).
    _invalidateScanCache();
  }

  @override
  Future<bool> isMessageDeleted(String messageId) async {
    for (final e
        in _s.iterLogRange(namespace: Ns.messageLog, limit: _logScanLimit)) {
      final m = jsonDecode(utf8.decode(e.payload)) as Map<String, dynamic>;
      if (m['op'] == 'del' && m['id'] == messageId) return true;
    }
    return false;
  }

  @override
  Future<void> removeConversation(NodeId peer) async {
    // Tombstone every message in the conversation (forensic, like deleteMessage)
    // …
    for (final m in await loadMessages(peer.hex)) {
      await deleteMessage(m.id);
    }
    // …then drop the contact record + its chat-list index entry in one commit.
    final index = _contactIndex()..remove(peer.hex);
    _s.commit([
      DeleteOp(Ns.contacts, peer.bytes),
      PutOp(Ns.settings, _sk('contacts:index'), _sk(jsonEncode(index))),
    ]);
    // Reclaim the orphaned chunks so the retracted request is truly gone.
    await scrubDeleted();
  }

  @override
  Future<void> eraseSpace() async {
    // Erase EVERY namespace this app uses, then scrub orphaned chunks — the
    // identity's data (its keypair, contacts, message log, file blobs) is gone
    // forensically, not merely unlinked. Irreversible.
    for (final ns in const [
      Ns.settings,
      Ns.contacts,
      Ns.messageLog,
      Ns.media,
      Ns.fileChunks,
    ]) {
      _s.eraseNamespace(ns);
    }
    _s.scrub();
    // The message log is gone — drop the in-memory fold or a later loadMessages
    // would resurrect the erased conversation from cache.
    _invalidateScanCache();
  }

  @override
  Future<void> scrubDeleted() async {
    // Reclaim chunks orphaned by edit/delete so the prior plaintext is no
    // longer recoverable from the container. Backed by hidden-volume's
    // vacuum/compact when the store exposes it; a no-op on the in-memory fake.
    _s.scrub();
    // Defensive: if the vacuum ever compacts/renumbers the log, the fold's
    // log-id watermark would be stale — force a clean rebuild next read.
    _invalidateScanCache();
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
  // INCREMENTAL reduction of the append-only message log. The full scan DECRYPTS
  // every record, and `iterLogRange` is a SYNCHRONOUS FFI, so re-running it on
  // every `changes` tick blocked the UI isolate — a freeze on a large
  // conversation, worst during active delivery (every send / receive / status
  // flip churns the log). We keep the reduced state and fold only the records
  // appended SINCE the last scan (ids are sequential), so a reload during active
  // delivery reads 1-2 new records instead of hundreds.
  //
  // Correctness: append + status are NEW records (bump the next-id) so the
  // forward fold sees them. Edit/delete REWRITE an existing log_id (no new id,
  // no next-id bump) so they bypass the forward fold — they call
  // [_invalidateScanCache] for a full rebuild. The `del` arm below only fires
  // during such a full rebuild (start == null reads the tombstones). Wiped on
  // close().
  final List<String> _scanOrder = [];
  final Map<String, Message> _scanById = {};
  final Map<String, MessageStatus> _scanStatusOps = {};
  int _scanFoldedUpTo = 0; // next log_id not yet folded into the state above
  List<Message>? _scanResult; // materialised; valid while _scanFoldedUpTo == nextId

  void _invalidateScanCache() {
    _scanOrder.clear();
    _scanById.clear();
    _scanStatusOps.clear();
    _scanFoldedUpTo = 0;
    _scanResult = null;
  }

  Iterable<Message> _scanLog() {
    final nextId = _nextLogId();
    final cached = _scanResult;
    if (cached != null && _scanFoldedUpTo == nextId) return cached;
    // Fold only records appended since the last fold. Re-read ONE record of
    // overlap (start = foldedUpTo - 1) so we don't depend on the range's
    // inclusive/exclusive boundary — re-applying a record is idempotent.
    final start = _scanFoldedUpTo == 0 ? null : _scanFoldedUpTo - 1;
    for (final e
        in _s.iterLogRange(namespace: Ns.messageLog, start: start, limit: _logScanLimit)) {
      final m = jsonDecode(utf8.decode(e.payload)) as Map<String, dynamic>;
      if (m['op'] == 'status') {
        _scanStatusOps[m['id'] as String] = MessageStatus.values[m['s'] as int];
        continue;
      }
      if (m['op'] == 'del') {
        // Tombstone (deleted message) — the record at this log_id no longer
        // carries a body. Drop it so it never surfaces.
        final id = m['id'] as String;
        _scanById.remove(id);
        _scanOrder.remove(id);
        continue;
      }
      final id = m['id'] as String;
      if (!_scanById.containsKey(id)) _scanOrder.add(id);
      _scanById[id] = Message(
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
    _scanFoldedUpTo = nextId;
    final result = _scanOrder
        .map((id) {
          final msg = _scanById[id]!;
          final s = _scanStatusOps[id];
          return s != null ? msg.copyWith(status: s) : msg;
        })
        .toList(growable: false);
    _scanResult = result;
    return result;
  }

  @override
  Future<void> close() async {
    _store?.close();
    _store = null;
    _invalidateScanCache();
  }
}
