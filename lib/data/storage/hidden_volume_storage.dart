import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../../core/ids.dart';
import '../../domain/chat.dart';
import '../../domain/event.dart';
import '../../domain/identity.dart';
import '../../domain/roster.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;

import 'async_kv_log_store.dart';
import 'file_store.dart';
import 'kv_log_store.dart';
import 'on_disk_blob_store.dart';
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
      if (contact.retentionDays != null) 'rd': contact.retentionDays,
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
      retentionDays: m['rd'] as int?,
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
    final sorted = all.where((m) => m.conversationId == conversationId).toList();
    // DETERMINISTIC, cross-device-stable display order (EVENT-LOG-SYNC-DESIGN.md
    // §15.1 R-ORDER): sort by (effective_ts, author, seq), id as the final
    // tiebreak. Now that (author, seq) travels on the wire and is identical on
    // both devices (3a/3c), it is the convergent key — NOT receive order.
    //
    // effective_ts is an AUTHOR-MONOTONE FLOOR over each author's own seq order:
    // a message's display time is its own ts raised to never fall below an
    // earlier (lower-seq) message from the SAME author. This is a pure function
    // of the converged event set (identical on both devices), so a peer stamping
    // a skewed/zero ts cannot float its message out of its causal place — yet
    // honest timestamps still interleave two authors naturally. Messages off the
    // seq stream (legacy / files) fall back to their raw ts and sort by id.
    final byAuthor = <String, List<Message>>{};
    for (final m in sorted) {
      if (m.author != null && m.seq != null) {
        (byAuthor[m.author!] ??= <Message>[]).add(m);
      }
    }
    final effTs = <String, int>{}; // message id -> effective ts (ms)
    for (final stream in byAuthor.values) {
      stream.sort((a, b) => a.seq!.compareTo(b.seq!));
      var runningMax = 0;
      for (final m in stream) {
        final raw = m.timestamp.millisecondsSinceEpoch;
        final eff = raw > runningMax ? raw : runningMax;
        effTs[m.id] = eff;
        runningMax = eff;
      }
    }
    int effOf(Message m) => effTs[m.id] ?? m.timestamp.millisecondsSinceEpoch;
    sorted.sort((a, b) {
      final t = effOf(a).compareTo(effOf(b));
      if (t != 0) return t;
      final au = (a.author ?? '').compareTo(b.author ?? '');
      if (au != 0) return au;
      final s = (a.seq ?? 0).compareTo(b.seq ?? 0);
      return s != 0 ? s : a.id.compareTo(b.id);
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
  Future<void> storeFile(String fileId, Uint8List bytes, {String? name}) =>
      // Serialize against other stores so the multi-commit read-base/bump-last
      // sequence can't interleave and collide chunk log-ids (see [_fileGate]).
      _fileSerialized(
          () => AsyncFileStore(_as).storeFile(fileId, bytes, name: name));

  // ── Large-file tier (Phase B) ────────────────────────────────────────────
  // A blob at/above [_kOnDiskTierMinBytes] can't fit the hidden-volume index
  // (its per-namespace B+ tree caps at a few thousand small records), so it is
  // stored ENCRYPTED on the normal filesystem ([OnDiskBlobStore]). The per-blob
  // random key + opaque name live HERE, in the volume (deniable) — only
  // ciphertext is on disk. Per cid, the routing is decided ONCE at first store
  // and recorded as `ondisk:<cid>` metadata; every later read consults it, so a
  // file's tier is stable regardless of the (size-less) read API.

  /// Files at/above this route to the on-disk encrypted tier; smaller ones stay
  /// in the volume (fast, fully deniable). Below the ~20–40 MB index ceiling.
  static const int _kOnDiskTierMinBytes = 16 * 1024 * 1024;

  OnDiskBlobStore? _blobs;
  int _onDiskMinBytes = _kOnDiskTierMinBytes;
  final Random _blobRand = Random.secure();

  /// Enable the on-disk LARGE-FILE tier, rooted at [dir] (one per identity).
  /// Until set, large files fall back to the in-volume store (and would hit its
  /// index ceiling). Production wiring points this at an app-private dir.
  /// [minBytes] overrides the routing threshold (tests use a tiny one).
  void useOnDiskTier(Directory dir, {int? minBytes}) {
    _blobs = OnDiskBlobStore(dir);
    if (minBytes != null) _onDiskMinBytes = minBytes;
  }

  Uint8List _randomBytes(int n) =>
      Uint8List.fromList(List.generate(n, (_) => _blobRand.nextInt(256)));

  Future<Map<String, dynamic>?> _odMeta(String cid) async {
    final raw = await _as.get(Ns.settings, _sk('ondisk:$cid'));
    if (raw == null) return null;
    try {
      return jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> _putOdMeta(String cid, Map<String, dynamic> m) =>
      _as.commit([PutOp(Ns.settings, _sk('ondisk:$cid'), _sk(jsonEncode(m)))]);

  @override
  Future<Uint8List?> loadFile(String fileId) async {
    final meta = await _odMeta(fileId);
    if (meta != null) {
      if (_blobs == null) return null;
      final size = meta['sz'] as int;
      // Whole-file read — large-file callers should STREAM via [readFileRange]
      // instead (this holds the whole blob in RAM). Used for small/medium blobs.
      return _blobs!.readRange(meta['fn'] as String,
          base64.decode(meta['k'] as String), 0, size, meta['ps'] as int, size);
    }
    return AsyncFileStore(_as).loadFile(fileId);
  }

  @override
  Future<bool> hasFile(String fileId) async {
    final meta = await _odMeta(fileId);
    if (meta != null) {
      return (meta['st'] as List).length >= (meta['pc'] as int);
    }
    return AsyncFileStore(_as).hasFile(fileId);
  }

  @override
  Future<void> storeFilePiece(String fileId, int pieceIndex, int pieceCount,
      int pieceSize, int totalSize, Uint8List bytes, {String? name}) {
    // Route by size — but a file already known on-disk stays on-disk even if a
    // (re)store passes a smaller-looking total, so reads remain consistent.
    if (_blobs != null && totalSize >= _onDiskMinBytes) {
      return _fileSerialized(() => _storeFilePieceOnDisk(
          fileId, pieceIndex, pieceCount, pieceSize, totalSize, bytes, name));
    }
    return _fileSerialized(() => AsyncFileStore(_as).storeFilePiece(
        fileId, pieceIndex, pieceCount, pieceSize, totalSize, bytes,
        name: name));
  }

  /// Store one piece of a large blob in the on-disk encrypted tier. Runs under
  /// [_fileSerialized] (no nested gate): the metadata read-modify-write — first
  /// piece mints a random opaque name + per-blob key — is serialized so
  /// concurrent pieces agree on ONE blob, and each piece records itself in `st`.
  Future<void> _storeFilePieceOnDisk(String cid, int pieceIndex, int pieceCount,
      int pieceSize, int totalSize, Uint8List bytes, String? name) async {
    final meta = await _odMeta(cid) ??
        <String, dynamic>{
          'fn': base64Url.encode(_randomBytes(12)), // opaque, FS-safe name
          'k': base64.encode(_randomBytes(32)), // per-blob AEAD key
          'sz': totalSize,
          'ps': pieceSize,
          'pc': pieceCount,
          'name': name,
          'st': <int>[],
        };
    await _blobs!.storePiece(
        meta['fn'] as String, base64.decode(meta['k'] as String), pieceIndex, bytes);
    final st = (meta['st'] as List).cast<int>().toSet()..add(pieceIndex);
    meta['st'] = st.toList()..sort();
    await _putOdMeta(cid, meta);
  }

  @override
  Future<Uint8List?> readFileRange(String fileId, int offset, int length) async {
    final meta = await _odMeta(fileId);
    if (meta != null) {
      if (_blobs == null) return null;
      return _blobs!.readRange(meta['fn'] as String,
          base64.decode(meta['k'] as String), offset, length,
          meta['ps'] as int, meta['sz'] as int);
    }
    return AsyncFileStore(_as).readFileRange(fileId, offset, length);
  }

  @override
  Future<Message> appendMessage(Message message) async {
    // Bind (author, seq): the author is the message originator (set by the
    // messaging layer from the authenticated sender — R1; defaults to the
    // conversation peer for a bare incoming row). The seq is the message's own
    // when it carries one (a wire-delivered event keeps the SENDER's seq, R4),
    // else we allocate the next gap-free per-(conv,author) value locally.
    //
    // FILE messages (filePost, §15) ARE on the seq stream: fileMeta carries the
    // sender's seq, so the receiver folds the file under the same (author, seq)
    // and gap-fill detects/heals a missing file like any other event. The
    // allocation rule is uniform (a wire seq is kept; a local one is allocated).
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
    await _commitAtNextLogId((logId) => [
      AppendLogOp(Ns.messageLog, logId, _sk(_encodeMessage(stored))),
      // Advance the per-(conv,author) seq cursor ONLY when we ALLOCATED it (a
      // wire event with its own seq must not bump our local counter — the two
      // streams are independent and reconciled by the fold/sync, not here).
      if (message.seq == null)
        PutOp(
          Ns.settings,
          _sk('conv_seq:${message.conversationId}:$author'),
          _sk('${seq + 1}'),
        ),
    ]);
    return stored;
  }

  /// Next gap-free per-(conversation, author) sequence number (§15.4, R4/R10).
  /// 1-based; advanced by [appendMessage] only when it ALLOCATES (locally
  /// originated or a bare incoming row), never for a wire event carrying its own.
  Future<int> _nextConvSeq(String convHex, String authorHex) async {
    final raw = await _as.get(Ns.settings, _sk('conv_seq:$convHex:$authorHex'));
    return raw == null ? 1 : (int.tryParse(utf8.decode(raw)) ?? 1);
  }

  @override
  Future<ConversationSync> conversationSync(String conversationId) =>
      _serialized(() => _conversationSyncCritical(conversationId));

  /// Build the per-author high-water + holes for one conversation from a raw log
  /// scan (event-log §15, RULE HW / RULE NH). For each author we collect the SET
  /// of seqs that author has consumed in this conversation — every post, edit,
  /// void, and (seq-bearing) delete tombstone counts, because they all draw from
  /// the one per-(conv, author) counter, so a gap-free prefix needs all of them.
  /// From the set we derive the contiguous high-water (the ack) and the interior
  /// holes below the highest seq (the named re-request ranges). Caller holds
  /// [_serialized]; this is an independent raw scan (it does NOT consult the
  /// composite-keyed fold), so a deleted-but-still-tombstoned seq still counts.
  Future<ConversationSync> _conversationSyncCritical(String conv) async {
    final seqsByAuthor = <String, Set<int>>{};
    final entries = await _as.iterLogRange(
      namespace: Ns.messageLog,
      limit: _logScanLimit,
    );
    for (final e in entries) {
      final m = jsonDecode(utf8.decode(e.payload)) as Map<String, dynamic>;
      if (m['c'] != conv) continue;
      // A status op carries no (author, seq) and consumes no seq — skip it. Every
      // other row (post / edit / void / seq-bearing del tombstone) carries au+sq.
      if (m['op'] == 'status') continue;
      final au = m['au'];
      final sq = m['sq'];
      // A legacy pre-event-log row (or a tombstone of one) has no au/sq → it
      // contributes no high-water for its author (R17 mixed-pair degrade).
      if (au is! String || sq is! int || sq <= 0) continue;
      (seqsByAuthor[au] ??= <int>{}).add(sq);
    }
    final highWater = <String, int>{};
    final holes = <String, List<(int, int)>>{};
    seqsByAuthor.forEach((author, seqs) {
      // Contiguous high-water: the longest gap-free prefix 1..hw.
      var hw = 0;
      while (seqs.contains(hw + 1)) {
        hw++;
      }
      highWater[author] = hw;
      // Interior holes: the missing seqs strictly between the high-water and the
      // highest observed seq, coalesced into ranges. (Nothing above max is a
      // "hole" — those unseen seqs are covered by the high-water "ship me newer"
      // query, not a named re-request.)
      final max = seqs.reduce((a, b) => a > b ? a : b);
      final ranges = <(int, int)>[];
      int? lo;
      for (var s = hw + 1; s <= max; s++) {
        if (!seqs.contains(s)) {
          lo ??= s;
        } else if (lo != null) {
          ranges.add((lo, s - 1));
          lo = null;
        }
      }
      if (ranges.isNotEmpty) holes[author] = ranges;
    });
    return (highWater: highWater, holes: holes);
  }

  @override
  Future<List<LogEvent>> loadEventsSince(
    String conversationId,
    String author,
    int fromSeq, {
    int limit = 200,
  }) =>
      _serialized(
        () => _loadEventsSinceCritical(conversationId, author, fromSeq, limit),
      );

  /// Raw-scan the conversation log for forward events authored by [author] with
  /// seq > [fromSeq] (the gap-fill re-ship batch, §15 3c). A live post/edit
  /// surfaces with its body; a deleted slot (op:'del' tombstone) or a superseded
  /// edit (k:void_) surfaces as an inert [EventKind.void_] with NO id/body
  /// (§12.1) — the peer advances its high-water past it without resurrecting the
  /// content. Oldest-first (so a post precedes its edits on re-ship), capped.
  Future<List<LogEvent>> _loadEventsSinceCritical(
    String conv,
    String author,
    int fromSeq,
    int limit,
  ) async {
    final entries = await _as.iterLogRange(
      namespace: Ns.messageLog,
      limit: _logScanLimit,
    );
    final events = <LogEvent>[];
    for (final e in entries) {
      final m = jsonDecode(utf8.decode(e.payload)) as Map<String, dynamic>;
      if (m['c'] != conv || m['op'] == 'status') continue;
      final au = m['au'];
      final sq = m['sq'];
      if (au != author || sq is! int || sq <= fromSeq) continue;
      final ts = m['t'] is int ? m['t'] as int : 0;
      if (m['op'] == 'del' ||
          m['k'] == EventKind.void_.index ||
          m['k'] == EventKind.clear.index) {
        // A deleted / superseded / clear slot → an inert void on the wire (no
        // id/body). A clear's EFFECT travels via its own WireEnvelope.clear frame
        // (carrying the watermark); the gap-fill re-ship only advances the peer's
        // high-water past the clear's seq so the per-author stream stays gap-free.
        events.add((
          kind: EventKind.void_,
          author: author,
          seq: sq,
          id: '',
          target: null,
          body: null,
          ts: ts,
        ));
      } else if (m['k'] == EventKind.edit.index) {
        events.add((
          kind: EventKind.edit,
          author: author,
          seq: sq,
          id: m['id'] as String? ?? '',
          target: m['tg'] as String?,
          body: m['b'] as String?,
          ts: ts,
        ));
      } else {
        final k = m['k'] as int?;
        events.add((
          kind: k == EventKind.filePost.index
              ? EventKind.filePost
              : EventKind.post,
          author: author,
          seq: sq,
          id: m['id'] as String? ?? '',
          target: null,
          body: m['b'] as String?,
          ts: ts,
        ));
      }
    }
    events.sort((a, b) => a.seq.compareTo(b.seq));
    return events.length > limit ? events.sublist(0, limit) : events;
  }

  @override
  Future<void> applyRemoteVoid(
    String conversationId,
    String author,
    int seq,
  ) async {
    // NOT wrapped in _serialized: the raw idempotency scan reads the store
    // directly (like loadMessageHistory / _voidEditRowsOps) and the only gated
    // step is the closing _patchCache — wrapping the whole method would nest
    // _serialized inside _serialized (via _patchCache) and DEADLOCK the gate.
    // This mirrors editMessage/deleteMessage: commit, then _patchCache.
    //
    // Idempotent: if any row already occupies this (author, seq) slot — a post,
    // edit, void, or tombstone — the high-water already accounts for it, so a
    // duplicate void would only bloat the log. Skip it.
    final entries = await _as.iterLogRange(
      namespace: Ns.messageLog,
      limit: _logScanLimit,
    );
    for (final e in entries) {
      final m = jsonDecode(utf8.decode(e.payload)) as Map<String, dynamic>;
      if (m['c'] == conversationId &&
          m['au'] == author &&
          m['sq'] == seq &&
          m['op'] != 'status') {
        return; // slot present — nothing to do
      }
    }
    await _commitAtNextLogId((logId) => [
      AppendLogOp(
        Ns.messageLog,
        logId,
        // An inert void slot: no id/tg/body (§12.1) — the fold renders nothing,
        // conversationSync counts (au, sq) so the per-author high-water advances.
        _sk(jsonEncode({
          'k': EventKind.void_.index,
          'c': conversationId,
          'au': author,
          'sq': seq,
        })),
      ),
    ]);
    await _patchCache(() {});
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
    // A file message is a filePost event (its body is the descriptor, the blob
    // travels out-of-band); a text message is a post. The fold treats both as a
    // post-class row, but loadEventsSince surfaces the right kind so the gap-fill
    // re-ship and any kind-aware consumer agree with the wire.
    // A file message is a filePost event whether DOWNLOADED (fileId) or merely
    // OFFERED (fileContentId, awaiting opt-in download) — both carry the
    // descriptor; only the blob differs. A text message is a post.
    'k': (m.isFile ? EventKind.filePost : EventKind.post).index,
    'd': m.direction.index,
    'b': m.body,
    't': m.timestamp.millisecondsSinceEpoch,
    's': m.status.index,
    if (m.edited) 'e': 1,
    if (m.fileId != null) 'fi': m.fileId,
    if (m.fileName != null) 'fn': m.fileName,
    if (m.fileSize != null) 'fs': m.fileSize,
    if (m.fileContentId != null) 'fc': m.fileContentId,
    if (m.fileExternal) 'fx': 1, // blob in the external store, not in-container
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
  Future<int?> editMessage(
    String conversationId,
    String messageId,
    String newBody, {
    int? seq,
  }) async {
    final hit = await _liveEntryFor(conversationId, messageId);
    if (hit == null) return null;
    // EVENT-LOG edit (§15, "keep history + clear button" mode): append a NEW
    // k:edit row at a fresh seq instead of rewriting the post in place. The
    // original post row + every prior edit row are RETAINED so the edit history
    // reads back (loadMessageHistory); the fold collapses them to the current
    // text. The author is the post's own (edits are authorised upstream to the
    // post author — R16). NOT scrubbed here — superseded bodies are reclaimed by
    // the explicit clear-history scrub / panic erase, not silently on edit.
    final author = hit.message.author ?? conversationId;
    // The edit's seq. A WIRE-DELIVERED edit carries the EDITOR's own seq (passed
    // in) — fold it under that, exactly as appendMessage keeps a wire post's seq,
    // so the (author, seq) is identical on both devices (R4/R5) and we do NOT
    // fabricate a local seq for an author whose stream is remote-allocated (which
    // would inject a phantom gap into conversationSync). A LOCAL edit (seq null)
    // allocates the next gap-free value for the editing author and bumps that
    // author's cursor.
    final editSeq = seq ?? await _nextConvSeq(conversationId, author);
    await _commitAtNextLogId((logId) => [
      AppendLogOp(
        Ns.messageLog,
        logId,
        _sk(jsonEncode({
          'k': EventKind.edit.index,
          'id': '$messageId~e$editSeq', // synthetic edit-event id (unique)
          'c': conversationId,
          'tg': messageId,
          'au': author,
          'sq': editSeq,
          'b': newBody,
          't': DateTime.now().millisecondsSinceEpoch,
        })),
      ),
      // Advance the per-(conv, author) cursor ONLY for a locally-allocated edit
      // (seq == null); a wire edit keeps the editor's seq, like appendMessage.
      if (seq == null)
        PutOp(
          Ns.settings,
          _sk('conv_seq:$conversationId:$author'),
          _sk('${editSeq + 1}'),
        ),
    ]);
    // The new row bumps next-id, so the next incremental fold reads + applies it
    // (the k:edit arm). Drop only the materialised result so loadMessages
    // re-folds; keep the rest of the warm fold.
    await _patchCache(() {});
    return editSeq;
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
      // Carry the deleted post's (author, seq) into the tombstone so the
      // per-(conv, author) seq stream stays GAP-FREE (event-log R4): this row
      // rewrites the post's own log_id, so without this its seq would vanish and
      // conversationSync would see a permanent hole at it — stalling high-water
      // forever. The tombstone keeps the seq SLOT (a local body-less void) while
      // the id stays LOCAL-only for born-delete suppression (§12.1, never on the
      // recovery wire). Author/seq are already-known/inherent (R11), so this
      // leaks nothing beyond the documented seq-count exposure.
      if (hit.message.author != null) 'au': hit.message.author,
      if (hit.message.seq != null) 'sq': hit.message.seq,
    });
    // An EDITED message has retained edit rows holding its old plaintext — void
    // them too so the delete is forensic, not just the current text. Skipped for
    // an unedited message (no edit rows) to avoid a needless full-log scan.
    final editVoids = hit.message.edited
        ? await _voidEditRowsOps(conversationId, targets: {messageId})
        : const <KvLogOp>[];
    await _as.commit([
      AppendLogOp(Ns.messageLog, hit.logId, _sk(tomb)),
      if (fileId != null) ...await AsyncFileStore(_as).deleteFileOps(fileId),
      ...editVoids,
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

  /// Void-rewrite (reclaim) the retained k:edit rows of [conv]: when [targets]
  /// is null, every edit row in the conversation; otherwise only edits of those
  /// message ids. Each rewrite replaces the edit row with a body-less void at the
  /// SAME log_id, orphaning the superseded-text chunk so a following scrub
  /// forensically erases it — without this, deleting/clearing an EDITED message
  /// would leave its old plaintext on disk (a deniability hole introduced by
  /// keeping edit history). Returns ops to fold into the caller's commit.
  Future<List<KvLogOp>> _voidEditRowsOps(String conv, {Set<String>? targets}) async {
    final entries = await _as.iterLogRange(
      namespace: Ns.messageLog,
      limit: _logScanLimit,
    );
    final ops = <KvLogOp>[];
    for (final e in entries) {
      final m = jsonDecode(utf8.decode(e.payload)) as Map<String, dynamic>;
      if (m['c'] != conv) continue;
      if (m['k'] != EventKind.edit.index) continue;
      if (targets != null && !targets.contains(m['tg'])) continue;
      ops.add(AppendLogOp(
        Ns.messageLog,
        e.logId,
        _sk(jsonEncode({
          'k': EventKind.void_.index,
          'c': conv,
          'tg': m['tg'],
          'id': m['id'],
          // The void IS the seq-preserving placeholder (R-VOID): carry the
          // voided edit's (author, seq) so its slot survives the reclaim and the
          // contiguous high-water (conversationSync) advances past it instead of
          // stalling on a phantom hole (R4). Body-less either way → the scrub
          // still erases the orphaned plaintext.
          if (m['au'] is String) 'au': m['au'],
          if (m['sq'] is int) 'sq': m['sq'],
        })),
      ));
    }
    return ops;
  }

  /// Tombstone every message of [peer]'s conversation (+ purge file blobs and
  /// void every retained edit row) as a list of ops for ONE commit. Shared by
  /// [removeConversation] and [clearMessages]; the only difference is whether the
  /// caller ALSO drops the contact record. Coalescing to a single commit is the
  /// high-leverage cut for storage bloat. Voiding the edit rows ensures no
  /// superseded edit plaintext survives a clear (forensic, with the scrub).
  Future<List<KvLogOp>> _tombstoneAllOps(NodeId peer,
      {Map<String, int>? upTo}) async {
    final ops = <KvLogOp>[];
    final cleared = <String>{};
    for (final m in await loadMessages(peer.hex)) {
      // Bounded clear (applyRemoteClear): a remote clear only erases up to the
      // high-water it captured — KEEP anything newer (seq > watermark) that the
      // receiver has since received. A null upTo clears everything (local clear).
      if (upTo != null) {
        final a = m.author, s = m.seq;
        if (a == null || s == null || s > (upTo[a] ?? -1)) continue;
      }
      final hit = await _liveEntryFor(peer.hex, m.id);
      if (hit == null) continue;
      cleared.add(m.id);
      ops.add(
        AppendLogOp(
          Ns.messageLog,
          hit.logId,
          // Preserve (author, seq) so the seq slot survives the tombstone (R4) —
          // same gap-free rule as deleteMessage.
          _sk(jsonEncode({
            'op': 'del',
            'id': m.id,
            'c': peer.hex,
            if (hit.message.author != null) 'au': hit.message.author,
            if (hit.message.seq != null) 'sq': hit.message.seq,
          })),
        ),
      );
      final fileId = hit.message.fileId;
      if (fileId != null) {
        ops.addAll(await AsyncFileStore(_as).deleteFileOps(fileId));
      }
    }
    // Scrub edit rows: ALL of them for a full local clear; only the cleared
    // messages' for a bounded (remote) clear, so a kept newer message keeps its
    // edit history.
    ops.addAll(await _voidEditRowsOps(peer.hex,
        targets: upTo == null ? null : cleared));
    return ops;
  }

  @override
  Future<void> removeConversation(NodeId peer) async {
    final ops = await _tombstoneAllOps(peer);
    final index = await _contactIndex();
    index.remove(peer.hex);
    ops.add(DeleteOp(Ns.contacts, peer.bytes));
    ops.add(PutOp(Ns.settings, _sk('contacts:index'), _sk(jsonEncode(index))));
    await _commitBatched(ops);
    // Whole conversation is gone — scrub the orphaned chunks for forensic erasure
    // and drop the warm fold (scrubDeleted invalidates it) so a later read can't
    // resurrect a tombstoned row; the tombstones are durable in the log, so
    // isMessageDeleted still answers true after the rebuild.
    await scrubDeleted();
  }

  @override
  Future<int> pruneConversation(NodeId peer, int retentionDays) async {
    if (retentionDays <= 0) return 0; // unlimited — never auto-delete
    final cutoff = DateTime.now().subtract(Duration(days: retentionDays));
    // Old messages by ORIGINAL post time (the fold keeps the post's original
    // timestamp; edits are separate rows and never refresh it).
    final old = <String>{
      for (final m in await loadMessages(peer.hex))
        if (m.timestamp.isBefore(cutoff)) m.id,
    };
    if (old.isEmpty) return 0;
    // ONE raw scan: tombstone each old post (+ purge its file), and void-rewrite
    // each retained edit row of an old post (orphaning its body chunk) so the
    // scrub reclaims ALL of its plaintext — not just the current version.
    final entries = await _as.iterLogRange(
      namespace: Ns.messageLog,
      limit: _logScanLimit,
    );
    final ops = <KvLogOp>[];
    for (final e in entries) {
      final m = jsonDecode(utf8.decode(e.payload)) as Map<String, dynamic>;
      if (m['c'] != peer.hex) continue;
      if (m['op'] == 'status' || m['op'] == 'del') continue;
      final k = m['k'] as int?;
      if (k == EventKind.edit.index && old.contains(m['tg'])) {
        ops.add(AppendLogOp(
          Ns.messageLog,
          e.logId,
          _sk(jsonEncode({
            'k': EventKind.void_.index,
            'c': peer.hex,
            'tg': m['tg'],
            'id': m['id'],
            // Keep the voided edit's seq slot (R4 / R-VOID) — see _voidEditRowsOps.
            if (m['au'] is String) 'au': m['au'],
            if (m['sq'] is int) 'sq': m['sq'],
          })),
        ));
      } else if (old.contains(m['id']) &&
          (k == null ||
              k == EventKind.post.index ||
              k == EventKind.filePost.index)) {
        ops.add(AppendLogOp(
          Ns.messageLog,
          e.logId,
          // Preserve (author, seq) so the seq slot survives the tombstone (R4).
          _sk(jsonEncode({
            'op': 'del',
            'id': m['id'],
            'c': peer.hex,
            if (m['au'] is String) 'au': m['au'],
            if (m['sq'] is int) 'sq': m['sq'],
          })),
        ));
        final fileId = m['fi'] as String?;
        if (fileId != null) {
          ops.addAll(await AsyncFileStore(_as).deleteFileOps(fileId));
        }
      }
    }
    if (ops.isEmpty) return 0;
    await _commitBatched(ops);
    await scrubDeleted();
    return old.length;
  }

  @override
  Future<void> clearMessages(NodeId peer) async {
    // Same per-message tombstone+scrub as removeConversation, but the contact
    // record and chat-list index entry stay — the conversation remains (empty).
    final ops = await _tombstoneAllOps(peer);
    if (ops.isEmpty) return; // nothing stored — keep the chat untouched
    await _commitBatched(ops);
    await scrubDeleted();
  }

  @override
  Future<({String author, int seq, Map<String, int> watermark})>
      emitClearConversation(NodeId peer, String selfHex) async {
    // Clear locally AND record a propagatable + replayable clear EVENT: a
    // per-author seq WATERMARK (= the current contiguous high-water) under
    // [selfHex]'s next seq. The per-message scrub + tombstone still runs (forensic
    // erasure + immediate local hide); the watermark is what brings ANOTHER device
    // (the peer, or — once multi-device lands — the author's own) to the same
    // emptied state on replay, and suppresses an in-flight message that belongs
    // before the clear. Returns the event so the caller ships it on the wire.
    final conv = peer.hex;
    final sync = await conversationSync(conv);
    final wm = Map<String, int>.from(sync.highWater);
    final tombstones = await _tombstoneAllOps(peer); // all current (== <= wm)
    final seq = await _nextConvSeq(conv, selfHex);
    await _commitAtNextLogId((logId) => [
      AppendLogOp(
        Ns.messageLog,
        logId,
        // ONLY the watermark travels/persists — never a cleared id or text.
        _sk(jsonEncode({
          'k': EventKind.clear.index,
          'c': conv,
          'au': selfHex,
          'sq': seq,
          't': DateTime.now().millisecondsSinceEpoch,
          'wm': wm,
        })),
      ),
      PutOp(Ns.settings, _sk('conv_seq:$conv:$selfHex'), _sk('${seq + 1}')),
    ]);
    if (tombstones.isNotEmpty) await _commitBatched(tombstones);
    await scrubDeleted();
    await _patchCache(() {}); // refold → watermark + tombstones land
    return (author: selfHex, seq: seq, watermark: wm);
  }

  @override
  Future<void> applyRemoteClear(
      NodeId peer, String author, int seq, Map<String, int> watermark) async {
    // Apply a clear received from [author]. Record the watermark, scrub +
    // tombstone every local message AT/BELOW it (keep anything newer), and occupy
    // the clear's own (author, seq) slot so the per-author stream stays gap-free.
    // Idempotent on (author, seq). The caller (messaging) decides WHETHER to apply
    // a peer's clear (policy); this is the apply mechanism.
    final conv = peer.hex;
    final entries =
        await _as.iterLogRange(namespace: Ns.messageLog, limit: _logScanLimit);
    for (final e in entries) {
      final m = jsonDecode(utf8.decode(e.payload)) as Map<String, dynamic>;
      if (m['c'] == conv &&
          m['au'] == author &&
          m['sq'] == seq &&
          m['op'] != 'status') {
        return; // slot present — already applied
      }
    }
    // Gather scrub+tombstone ops BEFORE the clear row sets the fold watermark, so
    // loadMessages still lists the to-be-cleared messages.
    final tombstones = await _tombstoneAllOps(peer, upTo: watermark);
    await _commitAtNextLogId((logId) => [
      AppendLogOp(
        Ns.messageLog,
        logId,
        _sk(jsonEncode({
          'k': EventKind.clear.index,
          'c': conv,
          'au': author,
          'sq': seq,
          't': DateTime.now().millisecondsSinceEpoch,
          'wm': watermark,
        })),
      ),
    ]);
    if (tombstones.isNotEmpty) await _commitBatched(tombstones);
    await scrubDeleted();
    await _patchCache(() {});
  }

  /// Commit [ops] in as few batches as fit. The at-rest store encodes ONE commit
  /// into a single DataBatch bounded by the chunk capacity (~4 KB zstd), with no
  /// auto-split at this layer — so a big atomic commit (clearing a chat with many
  /// files = a chunk-zeroing op PER chunk, thousands of records) overflowed with
  /// `HvException.PayloadTooLarge`, aborting the whole clear so the history
  /// survived. Try the whole list first (one commit when it fits), and on
  /// PayloadTooLarge split recursively in half until each batch fits. This is no
  /// longer a single atomic commit, but every caller [scrubDeleted]s afterwards,
  /// so a deleted blob still ends forensically erased even if a split lands
  /// mid-file. A genuinely oversized SINGLE record (length 1) still rethrows.
  Future<void> _commitBatched(List<KvLogOp> ops) async {
    if (ops.isEmpty) return;
    try {
      await _as.commit(ops);
    } on hv.HvException catch (e) {
      if (e.kind != 'PayloadTooLarge' || ops.length == 1) rethrow;
      final mid = ops.length >> 1;
      await _commitBatched(ops.sublist(0, mid));
      await _commitBatched(ops.sublist(mid));
    }
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
    final payload = jsonEncode({
      'op': 'status',
      'id': messageId,
      'c': conversationId,
      's': status.index,
    });
    await _commitAtNextLogId((logId) => [
      AppendLogOp(Ns.messageLog, logId, _sk(payload)),
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
  // conv -> author -> cleared-up-to seq watermark, built from folded
  // EventKind.clear rows. A message with (author, seq <= watermark) is
  // BORN-CLEARED: suppressed in the fold even if it arrives AFTER the clear (out
  // of order) — a per-message tombstone can't catch a not-yet-seen message, the
  // watermark can, which is what makes a propagated clear CONVERGE across devices.
  final Map<String, Map<String, int>> _clearedWatermark = {};
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

  // Single-flight gate serializing file-blob stores. storeFile reads the
  // file_next_log counter from the store, appends the chunks across SEVERAL
  // commits, then bumps the counter LAST — so two concurrent stores (e.g. the
  // user sending a file while an inbound one completes) could otherwise read the
  // same base and write colliding chunk log-ids, corrupting both blobs. Kept
  // SEPARATE from _scanGate so a multi-MiB store never blocks message scans.
  Future<void> _fileGate = Future<void>.value();
  Future<T> _fileSerialized<T>(Future<T> Function() body) {
    final result = _fileGate.then((_) => body());
    _fileGate = result.then((_) {}, onError: (_) {});
    return result;
  }

  // IN-MEMORY log-id allocator. The next log id lives in [_nextIdCache] and is
  // handed out by a SYNCHRONOUS atomic increment ([_allocLogId]) — there is no
  // await between reading and incrementing it, so two concurrent appenders can
  // never get the same id (the race a previous serializing gate fixed) WITHOUT
  // serializing the slow data commit behind one lock. That gate head-of-line
  // BLOCKED every append whenever a single commit stalled: an inline
  // notification-reply send issued while the app was backgrounded (storage worker
  // slow to respond) held the gate and froze ALL later sends until it finally
  // completed. With the counter, a slow commit delays only itself. (deleteMessage
  // rewrites an EXISTING log id and bumps nothing → no allocation.)
  int? _nextIdCache;
  Future<void>? _idInit;
  Future<int> _allocLogId() async {
    if (_nextIdCache == null) {
      _idInit ??= _nextLogId().then((v) {
        _nextIdCache ??= v;
      });
      await _idInit;
    }
    // Synchronous read-then-increment (no await between) → atomic across
    // concurrent callers: each gets a distinct id.
    final id = _nextIdCache!;
    _nextIdCache = id + 1;
    return id;
  }

  Future<int> _commitAtNextLogId(
    List<KvLogOp> Function(int logId) opsFor,
  ) async {
    final logId = await _allocLogId();
    await _as.commit([
      ...opsFor(logId),
      // Persist the current in-memory counter (monotonic, > every allocated id),
      // so a reopen never re-hands an id still in use. A crash mid-flight between
      // two concurrent commits can persist a slightly stale value; the only
      // consequence is a single re-used log id whose append the gap-fill heals —
      // far cheaper than the global stall the serializing gate caused.
      PutOp(Ns.settings, _sk('msg_next_id'), _sk('${_nextIdCache!}')),
    ]);
    return logId;
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
    _clearedWatermark.clear();
    _scanFoldedUpTo = 0;
    _scanResult = null;
    // Drop the log-id counter too: adopting a different space (open), or a
    // scrub/vacuum that may renumber the log, invalidates it — re-read lazily.
    _nextIdCache = null;
    _idInit = null;
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
      // Event-log VOID row (k:void_, §15 R-VOID): an inert placeholder occupying a
      // seq whose content was reclaimed (a retention/clear-history scrub rewrote a
      // superseded edit row to a body-less void). No effect on the fold state.
      if (m['k'] == EventKind.void_.index) continue;
      // Event-log CLEAR row (k:clear): the conversation was cleared up to a
      // per-author seq WATERMARK. Record it (max-merge across repeated clears),
      // then RETROACTIVELY purge already-folded messages at/below it. Messages
      // folded LATER (out-of-order arrival after the clear) are caught by the
      // born-clear guard in the post arm below — together they converge.
      if (m['k'] == EventKind.clear.index) {
        final c = m['c'] as String?;
        final wmRaw = m['wm'];
        if (c != null && wmRaw is Map) {
          final wm = _clearedWatermark.putIfAbsent(c, () => <String, int>{});
          wmRaw.forEach((au, hw) {
            if (au is String && hw is int && hw > (wm[au] ?? 0)) wm[au] = hw;
          });
          for (final key in _scanOrder.toList()) {
            final msg = _scanById[key];
            if (msg == null || msg.conversationId != c) continue;
            final a = msg.author, s = msg.seq;
            if (a != null && s != null && s <= (wm[a] ?? -1)) {
              _scanById.remove(key);
              _scanOrder.remove(key);
              _scanLogIds.remove(key);
            }
          }
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
      // Born-clear (R17-analogue): a post whose (author, seq) is at/below a
      // folded clear watermark for this conversation was cleared — drop it. This
      // catches a message that arrives AFTER the clear (out of order); the clear
      // arm above already purged the ones folded before it.
      final pAu = m['au'] as String?;
      final pSq = m['sq'] as int?;
      if (pAu != null && pSq != null && pSq <= (_clearedWatermark[c]?[pAu] ?? -1)) {
        final dk = _msgKey(c, id);
        _scanById.remove(dk);
        _scanOrder.remove(dk);
        _scanLogIds.remove(dk);
        continue;
      }
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
        fileSize: m['fs'] as int?,
        fileContentId: m['fc'] as String?,
        fileExternal: m['fx'] == 1,
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
