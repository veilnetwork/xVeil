import 'dart:convert';
import 'dart:typed_data';

import '../../core/ids.dart';
import '../../domain/chat.dart';
import '../../domain/event.dart';
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
Future<AsyncKvLogStore?> _noOpener({
  required Uint8List password,
  required bool create,
}) async => null;

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
      keysOpener = keysOpener == null
          ? null
          : syncWrappedKeysOpener(keysOpener);

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
    // A truncated / corrupt blob must not crash the open path (jsonDecode,
    // the cast, or NodeId.fromHex would throw) — treat it as "no identity"
    // and let the caller fall back to a placeholder.
    try {
      final m = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
      return Identity(
        nodeId: NodeId.fromHex(m['n'] as String),
        displayName: m['dn'] as String?,
        username: m['u'] as String?,
      );
    } catch (_) {
      return null;
    }
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
    // A corrupt / truncated roster blob must not crash a roster-edit or the
    // master open (jsonDecode, the cast, or base64.decode would throw). Treat
    // it as no-roster so the caller degrades gracefully rather than wedging.
    try {
      final list = jsonDecode(utf8.decode(raw)) as List;
      return [
        for (final e in list.cast<Map<String, dynamic>>())
          RosterEntry(
            label: e['l'] as String,
            spaceKeys: base64.decode(e['k'] as String),
            anonymous: e['a'] == 1,
          ),
      ];
    } catch (_) {
      return null;
    }
  }

  // --- Contacts ----------------------------------------------------------

  @override
  Future<void> upsertContact(Contact contact) async {
    final json = jsonEncode({
      'n': contact.nodeId.hex,
      'name': contact.name,
      's': contact.status.index,
      if (contact.muted) 'm': true,
      if (contact.pinned) 'p': true,
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
      muted: m['m'] as bool? ?? false,
      pinned: m['p'] as bool? ?? false,
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
    await _as.commit([
      PutOp(Ns.settings, _sk('read:$conversationId'), _sk('$latest')),
    ]);
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
        final marker = readMarkers[entry.conversationId] ??= await _readMarker(
          entry.conversationId,
        );
        if (entry.timestamp.millisecondsSinceEpoch > marker) {
          unread[entry.conversationId] =
              (unread[entry.conversationId] ?? 0) + 1;
        }
      }
    }
    // Union of known contacts and any conversation that has messages (a peer
    // we received from is auto-added, but include log-only ids defensively).
    final ids = <String>{...await _contactIndex(), ...byConv.keys};
    final out = <Conversation>[];
    for (final hex in ids) {
      out.add(
        Conversation(
          peer: await _contactFor(NodeId.fromHex(hex)),
          lastMessage: byConv[hex],
          unread: unread[hex] ?? 0,
        ),
      );
    }
    out.sort((a, b) {
      // Pinned conversations always sort above unpinned ones; within each group
      // the existing recency / name ordering applies.
      if (a.peer.pinned != b.peer.pinned) return a.peer.pinned ? -1 : 1;
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
  Future<List<Message>> loadMessages(
    String conversationId, {
    int? limit,
  }) async {
    final all = await _scanLog();
    final sorted = all.where((m) => m.conversationId == conversationId).toList()
      // DETERMINISTIC, cross-device-stable order (EVENT-LOG-SYNC-DESIGN.md §15.1
      // R-ORDER, display layer): primary by send time, tiebroken by the message
      // id. Dart's List.sort is NOT stable, so without a tiebreak two messages
      // sharing a millisecond timestamp ordered arbitrarily — and differently on
      // two devices. The id travels on the wire (same on both ends), so
      // (timestamp, id) is identical everywhere. NOTE: the records now carry the
      // durable (author, seq); the tiebreak SWITCHES to (author, seq) once the
      // seq is wire-carried (sync step) and thus cross-device-identical — until
      // then an incoming seq is locally allocated, so id remains the stable key.
      ..sort((a, b) {
        final t = a.timestamp.compareTo(b.timestamp);
        return t != 0 ? t : a.id.compareTo(b.id);
      });
    // Pagination tail: return only the most-recent [limit]. NOTE: the underlying
    // _scanLog() is still O(whole log) — the per-conversation prefix range scan
    // that makes this O(window) is the deferred storage-foundation step
    // (EVENT-LOG-SYNC-DESIGN.md §15.4). For now this bounds the UI render +
    // the decrypt-to-Message work to the window, which is the visible win.
    if (limit != null && limit > 0 && sorted.length > limit) {
      return sorted.sublist(sorted.length - limit);
    }
    return sorted;
  }

  @override
  Future<void> storeFile(String fileId, Uint8List bytes, {String? name}) async {
    await AsyncFileStore(_as).storeFile(fileId, bytes, name: name);
  }

  @override
  Future<Uint8List?> loadFile(String fileId) =>
      AsyncFileStore(_as).loadFile(fileId);

  @override
  Future<void> appendMessage(Message message) async {
    // Bind (author, seq): the author is the message originator (set by the
    // messaging layer from the authenticated sender — R1; defaults to the
    // conversation peer for a bare incoming row). The seq is the message's own
    // when it carries one (a wire-delivered event keeps the SENDER's seq, R4),
    // else we allocate the next gap-free per-(conv,author) value locally.
    final author = message.author ?? message.conversationId;
    final seq =
        message.seq ?? await _nextConvSeq(message.conversationId, author);
    final stored = (message.author == author && message.seq == seq)
        ? message
        : Message(
            id: message.id,
            conversationId: message.conversationId,
            direction: message.direction,
            body: message.body,
            timestamp: message.timestamp,
            status: message.status,
            edited: message.edited,
            fileId: message.fileId,
            fileName: message.fileName,
            author: author,
            seq: seq,
          );
    final nextId = await _nextLogId();
    await _as.commit([
      AppendLogOp(Ns.messageLog, nextId, _sk(_encodeMessage(stored))),
      PutOp(Ns.settings, _sk('msg_next_id'), _sk('${nextId + 1}')),
      // Advance the per-(conv,author) seq cursor ONLY when we allocated it (a
      // wire event with its own seq must not bump our local counter — the two
      // streams are independent and reconciled by the fold/sync, not here).
      if (message.seq == null)
        PutOp(
          Ns.settings,
          _sk('conv_seq:${message.conversationId}:$author'),
          _sk('${seq + 1}'),
        ),
    ]);
  }

  /// Next gap-free per-(conversation, author) sequence number (§15.4, R4/R10).
  /// 1-based; advanced by [appendMessage] only when it ALLOCATES (locally
  /// originated or a bare incoming row), never for a wire event carrying its own.
  Future<int> _nextConvSeq(String convHex, String authorHex) async {
    final raw = await _as.get(Ns.settings, _sk('conv_seq:$convHex:$authorHex'));
    return raw == null ? 1 : (int.tryParse(utf8.decode(raw)) ?? 1);
  }

  String _encodeMessage(Message m) => jsonEncode({
    'id': m.id,
    'c': m.conversationId,
    // Event-log fields (§15): author + per-(conv,author) seq + event kind. The
    // main message row is a `post`; edits/deletes still ride the op:'status'/'del'
    // side-channel for now (edit/delete-as-events is a later step). Written only
    // when present so legacy rows + the in-memory fake stay readable.
    if (m.author != null) 'au': m.author,
    if (m.seq != null) 'sq': m.seq,
    'k': EventKind.post.index,
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
    String conversationId,
    String messageId,
  ) => _serialized(() async {
    await _foldCritical(); // warm, incremental — not a fresh full-log scan
    final k = _msgKey(conversationId, messageId);
    final msg = _scanById[k];
    final logId = _scanLogIds[k];
    if (msg == null || logId == null) return null;
    return (logId: logId, message: msg);
  });

  @override
  Future<void> editMessage(
    String conversationId,
    String messageId,
    String newBody,
  ) async {
    final hit = await _liveEntryFor(conversationId, messageId);
    if (hit == null) return;
    // EVENT-LOG edit (§15, "keep history + clear button" mode): append a NEW
    // k:edit row at a fresh seq instead of rewriting the post in place. The
    // original post row + every prior edit row are RETAINED so the edit history
    // reads back (loadMessageHistory); the fold collapses them to the current
    // text. The author is the post's own (edits are authorised upstream to the
    // post author — R16), and the seq is the next gap-free value for that author
    // in this conversation. NOT scrubbed here — superseded bodies are reclaimed
    // by the explicit clear-history scrub / panic erase, not silently on edit.
    final author = hit.message.author ?? conversationId;
    final seq = await _nextConvSeq(conversationId, author);
    final logId = await _nextLogId();
    await _as.commit([
      AppendLogOp(
        Ns.messageLog,
        logId,
        _sk(jsonEncode({
          'k': EventKind.edit.index,
          'id': '$messageId~e$seq', // synthetic edit-event id (unique)
          'c': conversationId,
          'tg': messageId,
          'au': author,
          'sq': seq,
          'b': newBody,
          't': DateTime.now().millisecondsSinceEpoch,
        })),
      ),
      PutOp(Ns.settings, _sk('msg_next_id'), _sk('${logId + 1}')),
      PutOp(
        Ns.settings,
        _sk('conv_seq:$conversationId:$author'),
        _sk('${seq + 1}'),
      ),
    ]);
    // The new row bumps next-id, so the next incremental fold reads + applies it
    // (the k:edit arm). Drop only the materialised result so loadMessages
    // re-folds; keep the rest of the warm fold.
    await _patchCache(() {});
  }

  @override
  Future<List<MessageVersion>> loadMessageHistory(
    String conversationId,
    String messageId,
  ) async {
    // Deleted = gone: no history to surface.
    if (await isMessageDeleted(conversationId, messageId)) return const [];
    // Raw scan (NOT the collapsing fold): collect the original post row plus
    // every retained k:edit row targeting this message, oldest-first. O(log) for
    // one message's on-demand history — acceptable; the prefix range scan would
    // bound it once the §15.4 layout lands.
    final entries = await _as.iterLogRange(
      namespace: Ns.messageLog,
      limit: _logScanLimit,
    );
    final versions = <MessageVersion>[];
    for (final e in entries) {
      final m = jsonDecode(utf8.decode(e.payload)) as Map<String, dynamic>;
      if (m['c'] != conversationId) continue;
      if (m['op'] == 'status' || m['op'] == 'del') continue; // side-channel rows
      final k = m['k'] as int?;
      MessageVersion? v;
      if (k == EventKind.edit.index && m['tg'] == messageId) {
        v = MessageVersion(
          body: m['b'] as String? ?? '',
          timestamp: DateTime.fromMillisecondsSinceEpoch(m['t'] as int? ?? 0),
          isOriginal: false,
          author: m['au'] as String?,
          seq: m['sq'] as int?,
        );
      } else if (m['id'] == messageId &&
          (k == null ||
              k == EventKind.post.index ||
              k == EventKind.filePost.index)) {
        v = MessageVersion(
          body: m['b'] as String? ?? '',
          timestamp: DateTime.fromMillisecondsSinceEpoch(m['t'] as int? ?? 0),
          isOriginal: true,
          author: m['au'] as String?,
          seq: m['sq'] as int?,
        );
      }
      if (v != null) versions.add(v);
    }
    versions.sort((a, b) {
      final t = a.timestamp.compareTo(b.timestamp);
      return t != 0 ? t : (a.seq ?? 0).compareTo(b.seq ?? 0);
    });
    return versions;
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
    final tomb = jsonEncode({
      'op': 'del',
      'id': messageId,
      'c': conversationId,
    });
    await _as.commit([
      AppendLogOp(Ns.messageLog, hit.logId, _sk(tomb)),
      if (fileId != null) ...await AsyncFileStore(_as).deleteFileOps(fileId),
    ]);
    // The tombstone reuses an EXISTING log_id without bumping the next-id, so the
    // incremental fold won't re-read it. Patch the warm fold: drop the message
    // and record it as deleted (so it never resurfaces — a deniability hole — and
    // isMessageDeleted answers true) without dropping the whole cache.
    await _patchCache(() {
      final k = _msgKey(conversationId, messageId);
      _scanById.remove(k);
      _scanOrder.remove(k);
      _scanLogIds.remove(k);
      _scanDeletedKeys.add(k);
    });
  }

  @override
  Future<bool> isMessageDeleted(String conversationId, String messageId) =>
      _serialized(() async {
        await _foldCritical(); // warm fold — O(1) lookup, not a fresh full scan
        // New tombstones are conversation-scoped; a legacy tombstone (no 'c')
        // matched on id alone so a pre-fix delete is still honored and the
        // message never resurrects.
        return _scanDeletedKeys.contains(_msgKey(conversationId, messageId)) ||
            _scanDeletedLegacyIds.contains(messageId);
      });

  /// Tombstone every message of [peer]'s conversation (+ purge file blobs) as a
  /// list of ops for ONE commit. Shared by [removeConversation] and
  /// [clearMessages]; the only difference is whether the caller ALSO drops the
  /// contact record. Coalescing to a single commit is the high-leverage cut for
  /// storage bloat (one 1 MiB-padded commit, not one per message). The
  /// per-message tombstone bytes are byte-identical to [deleteMessage], so
  /// deniable-delete / isMessageDeleted semantics are unchanged.
  Future<List<KvLogOp>> _tombstoneAllOps(NodeId peer) async {
    final ops = <KvLogOp>[];
    for (final m in await loadMessages(peer.hex)) {
      final hit = await _liveEntryFor(peer.hex, m.id);
      if (hit == null) continue;
      ops.add(
        AppendLogOp(
          Ns.messageLog,
          hit.logId,
          _sk(jsonEncode({'op': 'del', 'id': m.id, 'c': peer.hex})),
        ),
      );
      final fileId = hit.message.fileId;
      if (fileId != null) {
        ops.addAll(await AsyncFileStore(_as).deleteFileOps(fileId));
      }
    }
    return ops;
  }

  @override
  Future<void> removeConversation(NodeId peer) async {
    final ops = await _tombstoneAllOps(peer);
    final index = await _contactIndex();
    index.remove(peer.hex);
    ops.add(DeleteOp(Ns.contacts, peer.bytes));
    ops.add(PutOp(Ns.settings, _sk('contacts:index'), _sk(jsonEncode(index))));
    await _as.commit(ops);
    // Whole conversation is gone — scrub the orphaned chunks for forensic erasure
    // and drop the warm fold (scrubDeleted invalidates it) so a later read can't
    // resurrect a tombstoned row; the tombstones are durable in the log, so
    // isMessageDeleted still answers true after the rebuild.
    await scrubDeleted();
  }

  @override
  Future<void> clearMessages(NodeId peer) async {
    // Same per-message tombstone+scrub as removeConversation, but the contact
    // record and chat-list index entry stay — the conversation remains (empty).
    final ops = await _tombstoneAllOps(peer);
    if (ops.isEmpty) return; // nothing stored — keep the chat untouched
    await _as.commit(ops);
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
    String conversationId,
    String messageId,
    MessageStatus status,
  ) async {
    // Append-only log can't mutate a row, so record a status OP that [_scanLog]
    // folds onto the message (latest wins). Drives the outbox: an ack flips a
    // message to `delivered` so it is no longer re-sent. The op carries the
    // conversation id so the fold can refuse to apply a status meant for one
    // conversation onto a same-id message in another (a peer-reachable path).
    final nextId = await _nextLogId();
    final payload = jsonEncode({
      'op': 'status',
      'id': messageId,
      'c': conversationId,
      's': status.index,
    });
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
  // Keyed by a COMPOSITE (conversationId, message-id) — two conversations may
  // legitimately, or from a hostile peer DELIBERATELY, carry the same message id
  // (incoming ids are sender-chosen: a request id, a file transfer id). Keying
  // by the bare id would let the later one overwrite the earlier in the fold, so
  // one conversation's message could erase/replace another's. The composite key
  // keeps them distinct.
  final List<String> _scanOrder = []; // composite keys, in arrival order
  final Map<String, Message> _scanById = {}; // composite key -> message
  // Composite key -> the log_id the live message was written under, so edit/
  // delete can rewrite the SAME record without an independent full scan.
  final Map<String, int> _scanLogIds = {};
  // Composite keys (and legacy bare ids) that have been tombstoned — lets
  // isMessageDeleted answer in O(1) off the warm fold instead of re-scanning.
  final Set<String> _scanDeletedKeys = {};
  final Set<String> _scanDeletedLegacyIds = {};
  // Composite key -> latest delivery status (status ops carry their conversation).
  final Map<String, MessageStatus> _scanStatusOps = {};
  // Legacy (pre-scoping) status ops had no conversation; applied by bare id.
  final Map<String, MessageStatus> _scanStatusLegacy = {};
  // Composite key -> the winning (highest) edit seq applied to that post, so the
  // fold honours a strictly-newer edit only (R5): deterministic last-writer-wins
  // with NO old body kept in state (superseded bodies live only in the log rows,
  // surfaced by loadMessageHistory until a clear-history scrub reclaims them).
  final Map<String, int> _scanEditWinSeq = {};
  int _scanFoldedUpTo = 0; // next log_id not yet folded into the state above
  List<Message>?
  _scanResult; // materialised; valid while _scanFoldedUpTo == nextId

  // Single-flight gate serializing all scan-cache access (scan + invalidate).
  Future<void> _scanGate = Future<void>.value();
  Future<T> _serialized<T>(Future<T> Function() body) {
    final result = _scanGate.then((_) => body());
    _scanGate = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Composite key for the scan maps: a conversation + a message id, joined by
  /// the Unit Separator (U+001F). `conv` is a server-authenticated 64-hex node id
  /// containing no separator, so even a hostile peer-chosen `id` (which sits
  /// AFTER the separator) cannot forge a key in another conversation.
  static String _msgKey(String conv, String id) => '$conv\u001f$id';

  void _clearScanState() {
    _scanOrder.clear();
    _scanById.clear();
    _scanLogIds.clear();
    _scanDeletedKeys.clear();
    _scanDeletedLegacyIds.clear();
    _scanStatusOps.clear();
    _scanStatusLegacy.clear();
    _scanEditWinSeq.clear();
    _scanFoldedUpTo = 0;
    _scanResult = null;
  }

  Future<void> _invalidateScanCache() =>
      _serialized(() async => _clearScanState());

  /// Surgically mutate the warm fold state (under the serial gate) for ONE
  /// message, then drop only the materialised list so the next read re-projects
  /// from the patched fold — instead of [_invalidateScanCache]'s full reset,
  /// which forces a whole-log re-decrypt. For edit/delete, which rewrite an
  /// existing log_id WITHOUT bumping the next-id (so the incremental fold can't
  /// pick the change up on its own). If the fold is cold the mutate is a no-op
  /// and the next scan folds from disk — still correct.
  Future<void> _patchCache(void Function() mutate) => _serialized(() async {
    mutate();
    _scanResult = null;
  });

  Future<List<Message>> _scanLog() => _serialized(_scanLogCritical);

  Future<List<Message>> _scanLogCritical() async {
    final nextId = await _nextLogId();
    final cached = _scanResult;
    if (cached != null && _scanFoldedUpTo == nextId) return cached;
    await _foldCritical();
    // Materialise from the (now-current) fold state, applying delivery status.
    final result = _scanOrder
        .map((k) {
          final msg = _scanById[k]!;
          // Status by composite (conversation-scoped) key; fall back to a legacy
          // by-id op for messages whose status predates conversation scoping.
          final s = _scanStatusOps[k] ?? _scanStatusLegacy[msg.id];
          return s != null ? msg.copyWith(status: s) : msg;
        })
        .toList(growable: false);
    _scanResult = result;
    return result;
  }

  /// Bring the fold state (_scanById / _scanOrder / _scanLogIds / deleted sets /
  /// status maps) up to date with the on-disk log, folding ONLY records appended
  /// since the last fold; a no-op when already current. So a message append,
  /// every dedup [isMessageDeleted], and every edit/delete [_liveEntryFor] reuse
  /// ONE warm fold instead of each re-decrypting the whole log — without this an
  /// accepted peer flooding edit/del frames re-ran a full-log decrypt per frame
  /// and could stall delivery for every conversation. Caller MUST hold
  /// [_serialized].
  Future<void> _foldCritical() async {
    final nextId = await _nextLogId();
    if (_scanFoldedUpTo == nextId) return; // fold state already current
    // The fold state is about to change, so the materialised list is now stale.
    // Drop it here (not only in _scanLogCritical) because a NON-materialising
    // caller (isMessageDeleted / _liveEntryFor) advances the fold too — without
    // this, a later loadMessages would see _scanFoldedUpTo == nextId next to a
    // stale _scanResult and return the OLD list.
    _scanResult = null;
    // Re-read ONE record of overlap (start = foldedUpTo - 1) so we don't depend
    // on the range's inclusive/exclusive boundary — re-applying a record is
    // idempotent under the composite-key maps.
    final start = _scanFoldedUpTo == 0 ? null : _scanFoldedUpTo - 1;
    final scanT0 = DateTime.now();
    var scanned = 0;
    final entries = await _as.iterLogRange(
      namespace: Ns.messageLog,
      start: start,
      limit: _logScanLimit,
    );
    for (final e in entries) {
      scanned++;
      final m = jsonDecode(utf8.decode(e.payload)) as Map<String, dynamic>;
      if (m['op'] == 'status') {
        final id = m['id'] as String;
        final c = m['c'] as String?;
        final s = MessageStatus.values[m['s'] as int];
        if (c != null) {
          _scanStatusOps[_msgKey(c, id)] = s;
        } else {
          _scanStatusLegacy[id] = s; // pre-scoping op — applied by bare id
        }
        continue;
      }
      if (m['op'] == 'del') {
        // Tombstone (deleted message) — the record at this log_id no longer
        // carries a body. Drop it so it never surfaces; remember it as deleted.
        final id = m['id'] as String;
        final c = m['c'] as String?;
        if (c != null) {
          final k = _msgKey(c, id);
          _scanById.remove(k);
          _scanOrder.remove(k);
          _scanLogIds.remove(k);
          _scanDeletedKeys.add(k);
        } else {
          // Legacy tombstone (no conversation) — drop every message with this id
          // (the old delete-by-id behavior), so a pre-fix delete still applies.
          _scanOrder.removeWhere((k) {
            final hit = _scanById[k]?.id == id;
            if (hit) {
              _scanById.remove(k);
              _scanLogIds.remove(k);
            }
            return hit;
          });
          _scanDeletedLegacyIds.add(id);
        }
        continue;
      }
      // Event-log EDIT row (k:edit, §15): replace the body of an existing post
      // by the SAME author (R16), keeping a strictly-newer edit only (R5). The
      // original/ superseded bodies stay in their own log rows for the edit
      // history; the FOLD STATE holds only the current text. A delete tombstone
      // already removed the post -> the edit finds no target and is dropped.
      if (m['k'] == EventKind.edit.index && m['tg'] != null) {
        final c = m['c'] as String;
        final target = m['tg'] as String;
        final tk = _msgKey(c, target);
        final post = _scanById[tk];
        if (post != null) {
          final editAuthor = m['au'] as String?;
          final editSeq = m['sq'] as int?;
          final authorOk = post.author == null ||
              editAuthor == null ||
              post.author == editAuthor;
          final win = _scanEditWinSeq[tk];
          final newer = editSeq == null || win == null || editSeq > win;
          if (authorOk && newer) {
            _scanById[tk] =
                post.copyWith(body: m['b'] as String? ?? post.body, edited: true);
            if (editSeq != null) _scanEditWinSeq[tk] = editSeq;
          }
        }
        // Target not folded yet (out-of-order in the log) — drop; the messaging
        // layer's pending-ops buffer handles edit-before-message on delivery.
        continue;
      }
      final id = m['id'] as String;
      final c = m['c'] as String;
      final k = _msgKey(c, id);
      if (!_scanById.containsKey(k)) _scanOrder.add(k);
      _scanById[k] = Message(
        id: id,
        conversationId: c,
        direction: MessageDirection.values[m['d'] as int],
        body: m['b'] as String,
        timestamp: DateTime.fromMillisecondsSinceEpoch(m['t'] as int),
        status: MessageStatus.values[m['s'] as int],
        edited: m['e'] == 1,
        fileId: m['fi'] as String?,
        fileName: m['fn'] as String?,
        author: m['au'] as String?,
        seq: m['sq'] as int?,
      );
      _scanLogIds[k] = e.logId;
      _scanDeletedKeys.remove(
        k,
      ); // a live record supersedes an earlier tombstone
    }
    _scanFoldedUpTo = nextId;
    final ms = DateTime.now().difference(scanT0).inMilliseconds;
    if (ms > 50) {
      devLog(
        () =>
            'xVeil[scan]: ${start == null ? 'FULL' : 'incr'} fold scanned=$scanned '
            'total=${_scanById.length} took=${ms}ms (worker isolate)',
      );
    }
  }

  @override
  Future<void> close() async {
    await _store?.close();
    _store = null;
    await _invalidateScanCache();
  }
}
