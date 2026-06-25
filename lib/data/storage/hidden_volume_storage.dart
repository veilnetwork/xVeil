import 'dart:convert';
import 'dart:typed_data';

import '../../core/ids.dart';
import '../../domain/chat.dart';
import '../../domain/identity.dart';
import '../../domain/roster.dart';
import 'async_kv_log_store.dart';
import 'file_store.dart';
import 'kv_log_store.dart';
import 'storage.dart';
import 'package:xveil/core/log.dart';

/// Reasonable upper bound for a single log scan. hidden-volume's log is the
/// source of truth for messages; conversations are derived by scanning it
/// (the FFI exposes no KV key enumeration).
const _logScanLimit = 100000;

Uint8List _sk(String key) => Uint8List.fromList(utf8.encode(key));

/// Opener for [HiddenVolumeStorage.fromStore], where the store is already open
/// and [HiddenVolumeStorage.open] is never called.
Future<AsyncKvLogStore?> _noOpener(
        {required Uint8List password, required bool create}) async =>
    null;

/// Domain [Storage] mapped onto a single hidden-volume space:
/// - SETTINGS (KV): identity blob, app settings, the message-log counter
/// - CONTACTS (KV): one entry per peer, keyed by node id bytes
/// - MESSAGE_LOG (append-log): every message, payload tagged with its
///   conversation id so a single log serves all conversations
///
/// Backed by an [AsyncKvLogStore] obtained from an [AsyncSpaceOpener], so the
/// same mapping runs over the in-memory fake (dev/tests, sync-wrapped) and the
/// real `HvSpace` — the latter on a dedicated WORKER ISOLATE so every
/// `get`/`commit`/`iterLogRange` runs OFF the UI isolate (no freeze / Android
/// ANR). The public API is unchanged: it was already `Future`-returning and
/// callers already `await`.
class HiddenVolumeStorage implements Storage {
  /// Default (SYNC opener) — the in-memory fake, tests, and any path not yet
  /// given its own worker. The sync opener is lifted to async (run INLINE on
  /// the calling isolate) internally, so behaviour is unchanged; only the
  /// [HiddenVolumeStorage.async] path actually moves work off the UI isolate.
  HiddenVolumeStorage(SpaceOpener opener, {KeysSpaceOpener? keysOpener})
      : _opener = syncWrappedSpaceOpener(opener),
        keysOpener =
            keysOpener == null ? null : syncWrappedKeysOpener(keysOpener);

  /// OFF-ISOLATE: the opener — and every op it serves — runs on a dedicated
  /// WORKER isolate (UI thread never blocks on the hidden-volume FFI). The
  /// production single-identity path (main.dart wires `workerSpaceOpener`).
  HiddenVolumeStorage.async(this._opener, {this.keysOpener});

  /// Wrap an ALREADY-OPEN [KvLogStore] (e.g. one multi-space view of a shared
  /// backing). Used in "all identities online" mode where every identity's
  /// space is already hosted; [open]/[openWithKeys] are not used. The view is
  /// sync-wrapped (the shared multi-space backing isn't worker-backed yet —
  /// Phase 2). [close] tears down the view (a no-op for a shared backing — the
  /// owner closes the backing once).
  HiddenVolumeStorage.fromStore(KvLogStore store)
      : _opener = _noOpener,
        keysOpener = null,
        _store = SyncWrappedAsyncKvLogStore(store);

  /// Wrap an ALREADY-OPEN [AsyncKvLogStore] view — e.g. an
  /// [AsyncMultiSpaceKvLogStore] over a worker-backed multi-space backing, so
  /// the all-online path is off-isolate too (Phase 2). [open]/[openWithKeys]
  /// are not used; [close] is a no-op for a shared backing.
  HiddenVolumeStorage.fromAsyncStore(AsyncKvLogStore store)
      : _opener = _noOpener,
        keysOpener = null,
        _store = store;

  final AsyncSpaceOpener _opener;

  /// Opens a child space by its `SpaceKeys` (master mode). Null when this
  /// handle is not configured for keys-based open (single-identity build).
  final AsyncKeysSpaceOpener? keysOpener;
  AsyncKvLogStore? _store;

  AsyncKvLogStore get _as {
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
    final store = await _opener(
      password: Uint8List.fromList(utf8.encode(password)),
      create: createIfMissing,
    );
    if (store == null) return false;
    // Close any previously-open space before adopting the new one. Without this
    // a re-open (e.g. switching identities) would leak the old handle and keep
    // its exclusive flock, so the NEXT open of that container fails with `Busy`.
    await _store?.close();
    _store = store;
    await _invalidateScanCache(); // adopting a different space — drop the old fold
    return true;
  }

  /// Open a child space directly from its [keys] (master mode) — no password.
  /// Returns false if the keys match no space, or if this handle has no
  /// keys-opener configured.
  @override
  Future<bool> openWithKeys(Uint8List keys) async {
    final store = await keysOpener?.call(keys);
    if (store == null) return false;
    await _store?.close();
    _store = store;
    await _invalidateScanCache(); // adopting a different space — drop the old fold
    return true;
  }

  @override
  Future<Uint8List> exportSpaceKeys() => _as.exportKeys();

  // --- Identity ----------------------------------------------------------

  @override
  Future<void> saveIdentity(Identity identity) async {
    final json = jsonEncode({
      'n': identity.nodeId.hex,
      'dn': identity.displayName,
      'u': identity.username,
    });
    await _as.commit([PutOp(Ns.settings, _sk('identity'), _sk(json))]);
  }

  @override
  Future<Identity?> loadIdentity() async {
    final raw = await _as.get(Ns.settings, _sk('identity'));
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
    await _as.commit([PutOp(Ns.settings, _sk('set:$key'), _sk(value))]);
  }

  @override
  Future<String?> getSetting(String key) async {
    final raw = await _as.get(Ns.settings, _sk('set:$key'));
    return raw == null ? null : utf8.decode(raw);
  }

  // The node config (with the keypair) is just another SETTINGS-namespace KV
  // entry, so it inherits the space's deniability — no plaintext config file.
  @override
  Future<void> saveNodeConfig(String configToml) async {
    await _as.commit([PutOp(Ns.settings, _sk('node:config'), _sk(configToml))]);
  }

  @override
  Future<String?> loadNodeConfig() async {
    final raw = await _as.get(Ns.settings, _sk('node:config'));
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
    await _as.commit([PutOp(Ns.settings, _sk('master:roster'), _sk(json))]);
  }

  @override
  Future<List<RosterEntry>?> loadRoster() async {
    final raw = await _as.get(Ns.settings, _sk('master:roster'));
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
    final index = await _contactIndex();
    if (!index.contains(contact.nodeId.hex)) index.add(contact.nodeId.hex);
    await _as.commit([
      PutOp(Ns.contacts, contact.nodeId.bytes, _sk(json)),
      PutOp(Ns.settings, _sk('contacts:index'), _sk(jsonEncode(index))),
    ]);
  }

  Future<List<String>> _contactIndex() async {
    final raw = await _as.get(Ns.settings, _sk('contacts:index'));
    if (raw == null) return [];
    return (jsonDecode(utf8.decode(raw)) as List).cast<String>();
  }

  @override
  Future<Contact?> getContact(NodeId nodeId) async {
    if (await _as.get(Ns.contacts, nodeId.bytes) == null) return null;
    return _contactFor(nodeId);
  }

  Future<Contact> _contactFor(NodeId id) async {
    final raw = await _as.get(Ns.contacts, id.bytes);
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
    for (final m in await _scanLog()) {
      if (m.conversationId == conversationId) {
        final ms = m.timestamp.millisecondsSinceEpoch;
        if (ms > latest) latest = ms;
      }
    }
    await _as
        .commit([PutOp(Ns.settings, _sk('read:$conversationId'), _sk('$latest'))]);
  }

  /// Millis of the latest message marked read in [conversationId] (0 = never
  /// read → all incoming count as unread).
  Future<int> _readMarker(String conversationId) async {
    final raw = await _as.get(Ns.settings, _sk('read:$conversationId'));
    return raw == null ? 0 : (int.tryParse(utf8.decode(raw)) ?? 0);
  }

  @override
  Future<List<Conversation>> loadConversations() async {
    final byConv = <String, Message>{};
    final unread = <String, int>{};
    final readMarkers = <String, int>{}; // cache: one KV read per conversation
    for (final entry in await _scanLog()) {
      final existing = byConv[entry.conversationId];
      if (existing == null || entry.timestamp.isAfter(existing.timestamp)) {
        byConv[entry.conversationId] = entry;
      }
      // Unread = incoming messages newer than the conversation's read marker.
      if (entry.direction == MessageDirection.incoming) {
        final marker = readMarkers[entry.conversationId] ??=
            await _readMarker(entry.conversationId);
        if (entry.timestamp.millisecondsSinceEpoch > marker) {
          unread[entry.conversationId] = (unread[entry.conversationId] ?? 0) + 1;
        }
      }
    }
    // Union of known contacts and any conversation that has messages (a peer
    // we received from is auto-added, but include log-only ids defensively).
    final ids = <String>{...await _contactIndex(), ...byConv.keys};
    final out = <Conversation>[];
    for (final hex in ids) {
      out.add(Conversation(
        peer: await _contactFor(NodeId.fromHex(hex)),
        lastMessage: byConv[hex],
        unread: unread[hex] ?? 0,
      ));
    }
    out.sort((a, b) {
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
    final all = await _scanLog();
    return all.where((m) => m.conversationId == conversationId).toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }

  @override
  Future<void> storeFile(String fileId, Uint8List bytes, {String? name}) async {
    await AsyncFileStore(_as).storeFile(fileId, bytes, name: name);
  }

  @override
  Future<Uint8List?> loadFile(String fileId) => AsyncFileStore(_as).loadFile(fileId);

  @override
  Future<void> appendMessage(Message message) async {
    final nextId = await _nextLogId();
    await _as.commit([
      AppendLogOp(Ns.messageLog, nextId, _sk(_encodeMessage(message))),
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

  Future<int> _nextLogId() async {
    final raw = await _as.get(Ns.settings, _sk('msg_next_id'));
    if (raw == null) return 1;
    return int.tryParse(utf8.decode(raw)) ?? 1;
  }

  /// Resolve the log_id (and decoded body) of a LIVE message in a SPECIFIC
  /// conversation by scanning the message log, scoped by BOTH `conversationId`
  /// and `messageId`. Returns null when no such live message exists (unknown
  /// id, already deleted, beyond the scan window) — OR when the id resolves to a
  /// message in a DIFFERENT conversation. That scoping is the security boundary:
  /// edit/delete are driven by a wire envelope whose claimed id is attacker-
  /// chosen, so resolving on the id alone (the old global `msgidx:<id>` index)
  /// let a peer rewrite/erase a message belonging to someone else's chat. The
  /// conversationId is server-authenticated (it is the sender's node id), so a
  /// peer can only ever name records inside its own conversation.
  Future<({int logId, Message message})?> _liveEntryFor(
      String conversationId, String messageId) async {
    ({int logId, Message message})? hit;
    final entries = await _as
        .iterLogRange(namespace: Ns.messageLog, limit: _logScanLimit);
    for (final e in entries) {
      final m = jsonDecode(utf8.decode(e.payload)) as Map<String, dynamic>;
      final op = m['op'];
      if (op == 'del' || op == 'status') continue;
      if (m['id'] != messageId || m['c'] != conversationId) continue;
      // Keep scanning to the LAST match: an edit reuses the same log_id, so the
      // newest record (latest body / edited flag) wins regardless of whether the
      // iterator yields one entry per log_id or every physical append.
      hit = (
        logId: e.logId,
        message: Message(
          id: messageId,
          conversationId: conversationId,
          direction: MessageDirection.values[m['d'] as int],
          body: m['b'] as String,
          timestamp: DateTime.fromMillisecondsSinceEpoch(m['t'] as int),
          status: MessageStatus.values[m['s'] as int],
          edited: m['e'] == 1,
          fileId: m['fi'] as String?,
          fileName: m['fn'] as String?,
        ),
      );
    }
    return hit;
  }

  @override
  Future<void> editMessage(
      String conversationId, String messageId, String newBody) async {
    final hit = await _liveEntryFor(conversationId, messageId);
    if (hit == null) return;
    // Rewrite the SAME log_id: last-write-wins replaces the body on read, so
    // the prior text no longer reads back (its chunk is orphaned for scrub).
    final edited = hit.message.copyWith(body: newBody, edited: true);
    await _as.commit(
        [AppendLogOp(Ns.messageLog, hit.logId, _sk(_encodeMessage(edited)))]);
    // Edit rewrites an EXISTING log_id (last-write-wins) and does NOT bump the
    // next-id, so the next-id-keyed scan cache would otherwise show the stale
    // body — invalidate it explicitly.
    await _invalidateScanCache();
  }

  @override
  Future<void> deleteMessage(String conversationId, String messageId) async {
    final hit = await _liveEntryFor(conversationId, messageId);
    if (hit == null) return;
    // If it is a file message, purge the stored blob too — otherwise the
    // attachment lingers in the container after the row is gone (a deniability
    // hole). The blob id rides along on the resolved record.
    final fileId = hit.message.fileId;
    // One atomic commit: tombstone the SAME log_id (so the body no longer reads
    // back) AND purge the file blob. Folding the blob ops in here (rather than a
    // separate FileStore.deleteFile commit) closes the crash window where the
    // chat row and the blob could disagree. The orphaned chunks are reclaimed by
    // scrubDeleted() for forensic erasure. The tombstone carries the
    // conversation id so isMessageDeleted stays conversation-scoped too.
    final tomb =
        jsonEncode({'op': 'del', 'id': messageId, 'c': conversationId});
    await _as.commit([
      AppendLogOp(Ns.messageLog, hit.logId, _sk(tomb)),
      if (fileId != null) ...await AsyncFileStore(_as).deleteFileOps(fileId),
    ]);
    // Tombstone rewrites an EXISTING log_id without bumping the next-id, so the
    // next-id-keyed scan cache must be invalidated or the deleted message would
    // keep surfacing (a deniability hole).
    await _invalidateScanCache();
  }

  @override
  Future<bool> isMessageDeleted(String conversationId, String messageId) async {
    for (final e
        in await _as.iterLogRange(namespace: Ns.messageLog, limit: _logScanLimit)) {
      final m = jsonDecode(utf8.decode(e.payload)) as Map<String, dynamic>;
      if (m['op'] != 'del' || m['id'] != messageId) continue;
      // New tombstones are conversation-scoped; a legacy tombstone (no 'c')
      // predates the fix and is matched on id alone so a pre-fix delete is
      // still honored and the message never resurrects.
      final c = m['c'];
      if (c == null || c == conversationId) return true;
    }
    return false;
  }

  @override
  Future<void> removeConversation(NodeId peer) async {
    // Tombstone every message in the conversation (forensic, like deleteMessage)
    // …
    for (final m in await loadMessages(peer.hex)) {
      await deleteMessage(peer.hex, m.id);
    }
    // …then drop the contact record + its chat-list index entry in one commit.
    final index = await _contactIndex();
    index.remove(peer.hex);
    await _as.commit([
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
      await _as.eraseNamespace(ns);
    }
    await _as.scrub();
    // The message log is gone — drop the in-memory fold or a later loadMessages
    // would resurrect the erased conversation from cache.
    await _invalidateScanCache();
  }

  @override
  Future<void> scrubDeleted() async {
    // Reclaim chunks orphaned by edit/delete so the prior plaintext is no
    // longer recoverable from the container. Backed by hidden-volume's
    // vacuum/compact when the store exposes it; a no-op on the in-memory fake.
    await _as.scrub();
    // Defensive: if the vacuum ever compacts/renumbers the log, the fold's
    // log-id watermark would be stale — force a clean rebuild next read.
    await _invalidateScanCache();
  }

  @override
  Future<void> markMessageStatus(
      String conversationId, String messageId, MessageStatus status) async {
    // Append-only log can't mutate a row, so record a status OP that [_scanLog]
    // folds onto the message (latest wins). Drives the outbox: an ack flips a
    // message to `delivered` so it is no longer re-sent. The op carries the
    // conversation id so the fold can refuse to apply a status meant for one
    // conversation onto a same-id message in another (a peer-reachable path).
    final nextId = await _nextLogId();
    final payload = jsonEncode(
        {'op': 'status', 'id': messageId, 'c': conversationId, 's': status.index});
    await _as.commit([
      AppendLogOp(Ns.messageLog, nextId, _sk(payload)),
      PutOp(Ns.settings, _sk('msg_next_id'), _sk('${nextId + 1}')),
    ]);
  }

  /// Scan the log, building messages and folding status OPs onto them. Base
  /// rows carry the message; `{op:'status'}` rows update an existing id.
  // INCREMENTAL reduction of the append-only message log. The full scan DECRYPTS
  // every record, and `iterLogRange` is FFI, so re-running it on every `changes`
  // tick used to block the UI isolate — now it runs on the worker isolate, but
  // we STILL keep the reduced state and fold only the records appended SINCE the
  // last scan (ids are sequential), so a reload during active delivery reads
  // 1-2 new records instead of hundreds.
  //
  // Correctness: append + status are NEW records (bump the next-id) so the
  // forward fold sees them. Edit/delete REWRITE an existing log_id (no new id,
  // no next-id bump) so they bypass the forward fold — they call
  // [_invalidateScanCache] for a full rebuild. The `del` arm below only fires
  // during such a full rebuild (start == null reads the tombstones). Wiped on
  // close().
  //
  // Concurrency: now that the fold awaits the worker, two scans (or a scan and
  // an invalidate) could interleave on the shared fold state. [_serialized]
  // runs scan + invalidate through ONE async gate so they never overlap.
  final List<String> _scanOrder = [];
  final Map<String, Message> _scanById = {};
  // id -> (latest status, the conversation the status op named). `conv` is null
  // only for legacy pre-scoping ops; the apply step requires it to match the
  // message's conversation so a status can't cross conversations.
  final Map<String, ({MessageStatus status, String? conv})> _scanStatusOps = {};
  int _scanFoldedUpTo = 0; // next log_id not yet folded into the state above
  List<Message>? _scanResult; // materialised; valid while _scanFoldedUpTo == nextId

  // Single-flight gate serializing all scan-cache access (scan + invalidate).
  Future<void> _scanGate = Future<void>.value();
  Future<T> _serialized<T>(Future<T> Function() body) {
    final result = _scanGate.then((_) => body());
    _scanGate = result.then((_) {}, onError: (_) {});
    return result;
  }

  void _clearScanState() {
    _scanOrder.clear();
    _scanById.clear();
    _scanStatusOps.clear();
    _scanFoldedUpTo = 0;
    _scanResult = null;
  }

  Future<void> _invalidateScanCache() => _serialized(() async => _clearScanState());

  Future<List<Message>> _scanLog() => _serialized(_scanLogCritical);

  Future<List<Message>> _scanLogCritical() async {
    final nextId = await _nextLogId();
    final cached = _scanResult;
    if (cached != null && _scanFoldedUpTo == nextId) return cached;
    // Fold only records appended since the last fold. Re-read ONE record of
    // overlap (start = foldedUpTo - 1) so we don't depend on the range's
    // inclusive/exclusive boundary — re-applying a record is idempotent.
    final start = _scanFoldedUpTo == 0 ? null : _scanFoldedUpTo - 1;
    final scanT0 = DateTime.now();
    var scanned = 0;
    final entries = await _as
        .iterLogRange(namespace: Ns.messageLog, start: start, limit: _logScanLimit);
    for (final e in entries) {
      scanned++;
      final m = jsonDecode(utf8.decode(e.payload)) as Map<String, dynamic>;
      if (m['op'] == 'status') {
        _scanStatusOps[m['id'] as String] = (
          status: MessageStatus.values[m['s'] as int],
          conv: m['c'] as String?,
        );
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
          final op = _scanStatusOps[id];
          // Apply the status only when the op named THIS message's conversation
          // (legacy ops have no conv → apply by id as before). A status op a peer
          // aimed at a guessed id in another conversation is ignored.
          final apply = op != null && (op.conv == null || op.conv == msg.conversationId);
          return apply ? msg.copyWith(status: op!.status) : msg;
        })
        .toList(growable: false);
    _scanResult = result;
    final ms = DateTime.now().difference(scanT0).inMilliseconds;
    if (ms > 50) {
      devLog(() => 'xVeil[scan]: ${start == null ? 'FULL' : 'incr'} fold scanned=$scanned '
          'total=${result.length} took=${ms}ms (worker isolate)');
    }
    return result;
  }

  @override
  Future<void> close() async {
    await _store?.close();
    _store = null;
    await _invalidateScanCache();
  }
}
