import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import '../../core/ids.dart';
import '../../domain/call_log.dart';
import '../../domain/chat.dart';
import '../../domain/contact_preferences.dart';
import '../../domain/clear_policy.dart';
import '../../domain/event.dart';
import '../../domain/identity.dart';
import '../../domain/inline_custom_emoji.dart';
import '../../domain/message_edit.dart';
import '../../domain/p2p_policy.dart';
import '../../domain/peer_authorization.dart';
import '../../domain/roster.dart';
import '../transport/wire_envelope.dart' show isServiceEchoBody;
import 'package:hidden_volume/hidden_volume.dart' as hv;

import 'async_kv_log_store.dart';
import 'file_store.dart';
import 'materialized_view.dart';
import 'message_batch_store.dart';
import 'kv_log_store.dart';
import 'rollback_anchor.dart';
import 'on_disk_blob_store.dart';
import 'storage.dart';
import 'package:xveil/core/log.dart';

/// Reasonable upper bound for a single log scan. hidden-volume's log is the
/// source of truth for messages; conversations are derived by scanning it
/// (the FFI exposes no KV key enumeration).
const _logScanLimit = 100000;

/// Legacy outbox journals can contain years of enqueue/ack rows. Migrate them
/// in bounded transfers so the native FFI never materialises one enormous
/// RustBuffer on the storage worker.
const _outboxScanPageSize = 256;

Uint8List _sk(String key) => Uint8List.fromList(utf8.encode(key));

typedef _FileReadSession = ({
  AsyncKvLogStore store,
  OnDiskBlobStore? blobs,
  int epoch,
});

class _ContactReadFlight {
  _ContactReadFlight(this.store, this.peer, this.frontier);
  final AsyncKvLogStore store;
  final NodeId peer;
  final int frontier;
  late final Future<Uint8List?> result;
}

final RegExp _sharedContentIdPattern = RegExp(r'^[0-9a-f]{64}$');

bool _bytesEqual(List<int>? a, List<int> b) {
  if (a == null || a.length != b.length) return false;
  for (var i = 0; i < b.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// One message-log record together with the namespace that owns its log id.
///
/// The namespace matters for in-place tombstone/void rewrites: legacy rows
/// stay in namespace 3, while post-upgrade rows live in deterministic shards.
class _MessageLogEntry {
  const _MessageLogEntry({
    required this.namespace,
    required this.logId,
    required this.payload,
  });

  final int namespace;
  final int logId;
  final Uint8List payload;
}

class _PendingOutboxAcks {
  _PendingOutboxAcks(this.peer);
  final String peer;
  final ids = <String>{};
  late final Future<void> result;
}

class _PositionedMessageAppends {
  final payloads = <Uint8List>[];
  late final Future<void> result;
}

class _PendingOrderingAdoptions {
  final requests = <MessageOrderingAdoption>[];
  int bytes = 0;
  late final Future<List<bool>> result;
}

typedef _QueuedOutboxFrame = ({OutboxFrame frame, Uint8List payload});

class _PendingOutboxEnqueues {
  _PendingOutboxEnqueues(this.peer);
  final String peer;
  final records = <_QueuedOutboxFrame>[];
  int bytes = 0;
  late final Future<void> result;
}

/// Opener for [HiddenVolumeStorage.fromStore], where the store is already open
/// and [HiddenVolumeStorage.open] is never called.
Future<AsyncKvLogStore?> _noOpener({
  required Uint8List password,
  required bool create,
}) async => null;

/// Domain [Storage] mapped onto a single hidden-volume space:
/// - SETTINGS (KV): identity blob, app settings, the message-log counter
/// - CONTACTS (KV): one entry per peer, keyed by node id bytes
/// - MESSAGE_LOG (append-log family): deterministic capacity shards; every
///   payload carries its conversation id and all shards merge back into one
///   globally ordered event stream
///
/// Backed by an [AsyncKvLogStore] obtained from an [AsyncSpaceOpener], so the
/// same mapping runs over the in-memory fake (dev/tests, sync-wrapped) and the
/// real `HvSpace` — the latter on a dedicated WORKER ISOLATE so every
/// `get`/`commit`/`iterLogRange` runs OFF the UI isolate (no freeze / Android
/// ANR). The public API is unchanged: it was already `Future`-returning and
/// callers already `await`.
class HiddenVolumeStorage
    implements
        Storage,
        RollbackAnchorReader,
        PreMaintenanceAnchorSource,
        AtomicRatchetSnapshotReservations,
        StoredFileBatchReader,
        StoredFilePresenceReader,
        StoredFilePairWriter,
        PreparedMessageBatchStore,
        PreparedOrderingBatchStore,
        GuardedOutboxRetirement {
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

  // One encrypted flag, committed WITH a message tombstone. A tombstone makes
  // the body logically absent; it does not prove its orphaned chunks were
  // reclaimed. Keep that obligation across crashes without replaying a vacuum
  // for every historical deletion. No message/device identifiers live here.
  static const _pendingDeleteScrubKey = 'storage.message_delete_scrub.v1';
  static const _legacyDeleteScrubKey = 'storage.message_delete_scrub.legacy.v1';
  bool? _deleteScrubPending;
  bool? _legacyDeleteScrubReady;
  bool _deleteScrubRecoveryNeeded = false;
  Future<void> _deleteScrubGate = Future<void>.value();
  AnchorReading? _anchorBeforeDeletionRecovery;

  @override
  AnchorReading? get anchorBeforeMaintenance => _anchorBeforeDeletionRecovery;

  @override
  void acceptMaintenanceAnchorAudit() => _anchorBeforeDeletionRecovery = null;

  Future<T> _serializeDeleteScrub<T>(Future<T> Function() action) {
    final result = _deleteScrubGate.then((_) => action());
    _deleteScrubGate = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<void> _commitMessageDeletion(List<KvLogOp> ops) =>
      _serializeDeleteScrub(() async {
        try {
          await _as.commit([
            for (final unit in await _messageRewriteUnits(ops)) ...unit,
            PutOp(
              Ns.settings,
              _sk(_pendingDeleteScrubKey),
              Uint8List.fromList([1]),
            ),
          ]);
          _deleteScrubPending = true;
        } catch (_) {
          _deleteScrubPending = null;
          _deleteScrubRecoveryNeeded = true;
          rethrow;
        }
      });

  // Legacy point deletes retained their tombstone, but not a pending-scrub
  // flag. Probe bounded namespace metadata, including retired namespaces;
  // never infer "no history" from a possibly stale next-id counter alone.
  Future<bool> _hasLegacyMessageRows() async {
    if (await _as.count(Ns.messageLog) > 0) return true;
    for (
      var ns = Ns.messageLogShardFirst;
      ns <= Ns.messageLogShardRetiredLast;
      ns++
    ) {
      if (await _as.count(ns) > 0) return true;
    }
    return false;
  }

  // Called under the scrub gate, only after a successful space-wide vacuum.
  Future<void> _finishMessageDeletionScrub() async {
    _deleteScrubPending ??=
        await _as.get(Ns.settings, _sk(_pendingDeleteScrubKey)) != null;
    _legacyDeleteScrubReady ??=
        await _as.get(Ns.settings, _sk(_legacyDeleteScrubKey)) != null;
    final ops = <KvLogOp>[
      if (_deleteScrubPending!)
        DeleteOp(Ns.settings, _sk(_pendingDeleteScrubKey)),
      if (!_legacyDeleteScrubReady!)
        PutOp(Ns.settings, _sk(_legacyDeleteScrubKey), Uint8List.fromList([1])),
    ];
    if (ops.isNotEmpty) await _as.commit(ops);
    _deleteScrubPending = false;
    _legacyDeleteScrubReady = true;
    _deleteScrubRecoveryNeeded = false;
  }

  // Called either before exposing an opened space or under the scan gate for
  // an already-open multi-space view. Never acquire the scan gate from inside
  // the scrub gate: a concurrent history read may already be waiting for us.
  Future<bool> _recoverMessageDeletion({
    bool opening = false,
  }) => _serializeDeleteScrub(() async {
    _deleteScrubRecoveryNeeded = true;
    _deleteScrubPending ??=
        await _as.get(Ns.settings, _sk(_pendingDeleteScrubKey)) != null;
    _legacyDeleteScrubReady ??=
        await _as.get(Ns.settings, _sk(_legacyDeleteScrubKey)) != null;
    if (!_deleteScrubPending! && !_legacyDeleteScrubReady!) {
      if (await _hasLegacyMessageRows()) {
        // Missing completion marker is the durable obligation across a crash
        // during migration. Treat all old message-bearing spaces conservatively.
        _deleteScrubPending = true;
      } else {
        await _as.commit([
          PutOp(
            Ns.settings,
            _sk(_legacyDeleteScrubKey),
            Uint8List.fromList([1]),
          ),
        ]);
        _legacyDeleteScrubReady = true;
      }
    }
    if (!_deleteScrubPending!) {
      _deleteScrubRecoveryNeeded = false;
      return false;
    }
    if (opening) {
      _anchorBeforeDeletionRecovery ??= await readCommitAnchor();
    }
    await _as.scrub();
    await _finishMessageDeletionScrub();
    return true;
  });

  Future<void> _prepareOpenedStore() async {
    _anchorBeforeDeletionRecovery = null;
    _deleteScrubPending = null;
    _legacyDeleteScrubReady = null;
    _deleteScrubRecoveryNeeded = false;
    try {
      await _recoverMessageDeletion(opening: true);
      await _withRatchetIo(() => _recoverRatchetCleanup(opening: true));
    } catch (_) {
      // A failed recovery must not leak the exclusive handle and wedge retry.
      await close();
      rethrow;
    }
  }

  AsyncKvLogStore get _as {
    final s = _store;
    if (s == null) {
      throw StateError('storage is locked — call open() first');
    }
    return s;
  }

  @override
  bool get isOpen => _store != null;

  /// Every legitimate flow closes the previous space before opening the next
  /// (switchIdentity, roster edits, compaction all call [close] explicitly), so
  /// a still-set [_store] here means a handle LEAKED past a failed path. It
  /// must be closed BEFORE the new open, not after: the old handle holds the
  /// container's exclusive flock, so opening the same container over it fails
  /// `Busy` — and since a failed open used to leave the stale handle in place,
  /// every retry failed the same way until an app restart ("correct password
  /// but won't unlock"). Closing first makes the retry self-healing.
  ///
  /// Callers guard with `if (_store != null)` instead of awaiting
  /// unconditionally: in the common no-stale case open() must reach its opener
  /// WITHOUT yielding to the event loop, so a Busy container still fails the
  /// caller synchronously-first (semantics some callers/tests rely on).
  Future<void> _closeStaleStoreBeforeOpen(String who) async {
    if (_store == null) return;
    devLog(
      () =>
          'xVeil[storage]: $who called while a space is still open — '
          'closing the stale handle first (leaked by an earlier failure?)',
    );
    await close();
  }

  @override
  Future<bool> open({
    required String password,
    bool createIfMissing = false,
  }) async {
    final closing = _closePending;
    if (closing != null) await closing;
    if (_store != null) await _closeStaleStoreBeforeOpen('open()');
    final store = await _opener(
      password: Uint8List.fromList(utf8.encode(password)),
      create: createIfMissing,
    );
    if (store == null) return false;
    _store = store;
    _resetLogAllocator();
    await _invalidateScanCache(); // adopting a different space — drop the old fold
    await _invalidateOutboxCache();
    await _prepareOpenedStore();
    return true;
  }

  /// Open a child space directly from its [keys] (master mode) — no password.
  /// Returns false if the keys match no space, or if this handle has no
  /// keys-opener configured.
  @override
  Future<bool> openWithKeys(Uint8List keys) async {
    if (keysOpener == null) return false;
    final closing = _closePending;
    if (closing != null) await closing;
    if (_store != null) await _closeStaleStoreBeforeOpen('openWithKeys()');
    final store = await keysOpener?.call(keys);
    if (store == null) return false;
    _store = store;
    _resetLogAllocator();
    await _invalidateScanCache(); // adopting a different space — drop the old fold
    await _invalidateOutboxCache();
    await _prepareOpenedStore();
    return true;
  }

  /// Where this container's anchor is kept, once somebody has attached one.
  ///
  /// Null for every space that is not anchored, which is every decoy: an
  /// anchor for a hidden space announces that the space exists. Attaching is
  /// how the acknowledged space opts in, and nothing else can.
  RollbackAnchorStore? _rollbackAnchor;

  /// Anchor this container from here on. See [RollbackAnchorStore].
  void attachRollbackAnchor(RollbackAnchorStore anchor) {
    _rollbackAnchor = anchor;
  }

  /// The settings key holding this container's generation.
  ///
  /// Inside the container on purpose: it must travel with the data it names,
  /// so a copy of the container carries the same generation and a different
  /// container carries a different one.
  static const String _generationKey = 'hv.anchor.generation';

  /// This container's commit counter, the window of commits it still
  /// recognises, and its generation — or null when the store behind this
  /// handle has no container to ask (the in-memory fake, and every
  /// multi-space view — see [CommitAnchorSource] for why that omission IS the
  /// decoy policy).
  @override
  Future<AnchorReading?> readCommitAnchor() async {
    final store = _store;
    if (store is! CommitAnchorSource) return null;
    final anchored = store as CommitAnchorSource;
    final generation = await _containerGeneration();
    if (generation == null) return null;
    final seq = await anchored.commitSeq();
    // Negative is the worker's "there is no container behind me". An anchor
    // built on it would call every honest open a rollback.
    if (seq < 0) return null;
    return AnchorReading(
      seq: seq,
      history: await anchored.commitHistory(),
      roots: await anchored.commitRoots(),
      generation: generation,
    );
  }

  /// This container's generation, minted and stored on first use.
  ///
  /// Minting is a write, so it moves the commit counter — which is why it
  /// happens BEFORE the counter is read above, and never after.
  Future<String?> _containerGeneration() async {
    final held = await getSetting(_generationKey);
    if (held != null && held.isNotEmpty) return held;
    final fresh = _randomHex(16);
    await putSetting(_generationKey, fresh);
    // Read back rather than trust the write: a container that refused it
    // would otherwise be anchored under a generation it does not hold, and
    // every later open would look like a different container.
    final stored = await getSetting(_generationKey);
    return stored == fresh ? fresh : null;
  }

  static String _randomHex(int bytes) {
    final rng = Random.secure();
    final out = StringBuffer();
    for (var i = 0; i < bytes; i++) {
      out.write(rng.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return out.toString();
  }

  /// Record where this container now stands. See [RollbackAnchorReader].
  @override
  Future<bool> advanceRollbackAnchor() async {
    final anchor = _rollbackAnchor;
    if (anchor == null) return false;
    final reading = await readCommitAnchor();
    if (reading == null) return false;
    return anchor.write(
      AnchorRecord(generation: reading.generation, seq: reading.seq),
    );
  }

  @override
  Future<Uint8List> exportSpaceKeys() => _as.exportKeys();

  // --- Identity ----------------------------------------------------------

  @override
  Future<void> saveProfile(UserProfile profile) {
    // No node id (audit XV-06). It is derivable from the node config in this
    // same space and nowhere else; a copy here was a cache that went stale on
    // the very first launch and stayed stale.
    final json = jsonEncode({'dn': profile.displayName, 'u': profile.username});
    final bytes = _sk(json);
    return _metadataWrite('identity', (store) async {
      final existing = await store.get(Ns.settings, _sk('identity'));
      if (_bytesEqual(existing, bytes)) return;
      await store.commit([PutOp(Ns.settings, _sk('identity'), bytes)]);
    });
  }

  @override
  Future<UserProfile?> loadProfile() async {
    final raw = await _as.get(Ns.settings, _sk('identity'));
    if (raw == null) return null; // genuinely absent — a fresh or erased space
    // A truncated / corrupt blob (jsonDecode or the casts throwing) is reported
    // AS ITSELF. It used to return null — the same answer as "no record" —
    // which sent the app down the fresh-space path: a random placeholder
    // identity on screen, and every "is this space empty?" guard answering yes
    // over a record that is still there (audit XV-13).
    try {
      final m = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
      return UserProfile(
        displayName: m['dn'] as String?,
        username: m['u'] as String?,
      );
    } catch (e) {
      throw CorruptIdentityRecord(raw.length, e);
    }
  }

  // --- Settings ----------------------------------------------------------

  // Active writes only. Keep read/compare/commit ordered for one key, without
  // putting unrelated settings behind its IO or caching a completed value.
  final _metadataTails = <String, Future<void>>{};

  Future<void> _metadataWrite(
    String key,
    Future<void> Function(AsyncKvLogStore) write,
  ) => _trackLogWrite((store) {
    final previous = _metadataTails[key] ?? Future<void>.value();
    final result = previous.then((_) => write(store));
    late final Future<void> tail;
    tail = result.then<void>((_) {}, onError: (_) {}).whenComplete(() {
      if (identical(_metadataTails[key], tail)) _metadataTails.remove(key);
    });
    _metadataTails[key] = tail;
    return result;
  });

  @override
  Future<void> putSetting(String key, String value) => _metadataWrite(
    'set:$key',
    (store) async {
      // Idempotent-write chokepoint: every commit is padded to a full bucket
      // (256 KiB) that the append-only container NEVER reclaims until a manual
      // compaction. Concurrent identical callers must compare AFTER the earlier
      // write, or every caller pays for another permanent bucket.
      // Pin this accepted operation to its space across both awaits; close and
      // erase drain it before replacing or clearing that space.
      final existing = await store.get(Ns.settings, _sk('set:$key'));
      if (existing != null &&
          utf8.decode(existing, allowMalformed: true) == value) {
        return;
      }
      await store.commit([PutOp(Ns.settings, _sk('set:$key'), _sk(value))]);
    },
  );

  @override
  Future<String?> getSetting(String key) async {
    final raw = await _as.get(Ns.settings, _sk('set:$key'));
    return raw == null ? null : utf8.decode(raw);
  }

  // The node config (with the keypair) is just another SETTINGS-namespace KV
  // entry, so it inherits the space's deniability — no plaintext config file.
  @override
  Future<void> saveNodeConfig(String configToml) => _metadataWrite(
    'node:config',
    (store) async {
      // Same no-op-write shield as putSetting: the config is re-saved on every
      // node (re)start, almost always byte-identical.
      final existing = await store.get(Ns.settings, _sk('node:config'));
      if (existing != null &&
          utf8.decode(existing, allowMalformed: true) == configToml) {
        return;
      }
      await store.commit([
        PutOp(Ns.settings, _sk('node:config'), _sk(configToml)),
      ]);
    },
  );

  @override
  Future<String?> loadNodeConfig() async {
    final raw = await _as.get(Ns.settings, _sk('node:config'));
    return raw == null ? null : utf8.decode(raw);
  }

  // File writers already serialize publication and close/erase. Readers
  // recheck this revision instead of holding writers or another session's
  // readers behind a suspended storage reply.
  int _rosterRevision = 0;
  Future<void>? _rosterPublication;

  Future<T> _publishingRoster<T>(Future<T> Function() body) async {
    final done = Completer<void>();
    final publication = done.future;
    _rosterPublication = publication;
    _rosterRevision++;
    try {
      return await body();
    } finally {
      _rosterRevision++;
      if (identical(_rosterPublication, publication)) _rosterPublication = null;
      done.complete();
    }
  }

  @override
  Future<void> saveRoster(List<RosterEntry> entries) {
    // Freeze labels and opaque SpaceKeys before any queued operation yields.
    final bytes = _sk(
      jsonEncode([
        for (final e in entries)
          {
            'l': e.label,
            'k': base64.encode(e.spaceKeys),
            if (e.anonymous) 'a': 1,
          },
      ]),
    );
    return _fileSerialized(() {
      final store = _as;
      return _publishingRoster(() async {
        final snapshot = await _rosterSnapshot(store);
        final existing = snapshot.active;
        if (existing != null && _decodeRoster(existing) == null) {
          throw StateError('refusing to overwrite an unreadable master roster');
        }
        final files = AsyncFileStore(store);
        if (bytes.length <= _maxSettingValueBytes) {
          if (!snapshot.filePresent && _bytesEqual(snapshot.legacy, bytes)) {
            return;
          }
          // The old file remains authoritative until this atomic publication.
          // Failure cannot leave a new setting shadowed by an old file while
          // reporting that the new roster has been saved.
          final retire = await files.deleteFileOps(_rosterFile);
          await store.commit([
            PutOp(Ns.settings, _sk('master:roster'), bytes),
            ...retire,
          ]);
        } else {
          // FileStore retains the previous version until publication. A crash
          // before the following cleanup still leaves the new file preferred.
          if (!_bytesEqual(existing, bytes)) {
            await files.storeFile(_rosterFile, bytes, name: 'master-roster');
          }
          // The file is already durable and preferred. Keep legacy cleanup
          // best-effort, but retry it even when the requested bytes match.
          if (snapshot.cleanupLegacy) {
            try {
              await store.commit([DeleteOp(Ns.settings, _sk('master:roster'))]);
            } catch (_) {
              // A later save retries this; a declared file never falls back
              // to this stale shadow if its payload becomes unreadable.
            }
          }
        }
      });
    });
  }

  /// Internal in-volume file used when a roster outgrows one settings record.
  static const String _rosterFile = 'master:roster.v2';
  static const int _maxSettingValueBytes = 1900;

  Future<
    ({
      Uint8List? active,
      Uint8List? legacy,
      bool filePresent,
      bool cleanupLegacy,
    })
  >
  _rosterSnapshot(AsyncKvLogStore store, {bool readOnly = false}) async {
    // This private file is created only by saveRoster, in the volume. Refuse
    // an unexpected external-tier descriptor rather than overwrite keys we
    // cannot account for. No plaintext roster is written outside the volume.
    if (await store.get(Ns.settings, _sk('ondisk:$_rosterFile')) != null) {
      if (readOnly) {
        return (
          active: null,
          legacy: null,
          filePresent: true,
          cleanupLegacy: false,
        );
      }
      throw StateError('unsupported master roster file tier');
    }
    final metadata = await store.get(Ns.settings, _sk('file:$_rosterFile'));
    Uint8List? active;
    if (metadata != null) {
      try {
        active = await AsyncFileStore(
          store,
        ).loadFile(_rosterFile, maxBytes: kMaxStoredFileBytes);
        if (active == null) {
          // A declared file with missing chunks is not an absent roster.
          throw StateError('unreadable master roster file');
        }
      } catch (_) {
        if (!readOnly) rethrow;
        return (
          active: null,
          legacy: null,
          filePresent: true,
          cleanupLegacy: false,
        );
      }
      if (active.isEmpty) active = null; // legacy retired-file marker
      if (readOnly && active != null) {
        return (
          active: active,
          legacy: null,
          filePresent: true,
          cleanupLegacy: false,
        );
      }
    }
    Uint8List? legacy;
    try {
      legacy = await store.get(Ns.settings, _sk('master:roster'));
    } catch (_) {
      if (active == null) rethrow; // the setting is the only primary copy
      // A valid file does not depend on an optional stale setting. Attempt
      // cleanup best-effort rather than refusing the authoritative update.
      return (
        active: active,
        legacy: null,
        filePresent: true,
        cleanupLegacy: true,
      );
    }
    active ??= legacy == null || legacy.isEmpty ? null : legacy;
    return (
      active: active,
      legacy: legacy,
      filePresent: metadata != null,
      cleanupLegacy: legacy != null,
    );
  }

  @override
  Future<List<RosterEntry>?> loadRoster() => _readFileSession((session) async {
    while (true) {
      _checkFileReadSession(session);
      final publication = _rosterPublication;
      if (publication != null) {
        await publication;
        continue;
      }
      final revision = _rosterRevision;
      Uint8List? raw;
      try {
        raw = (await _rosterSnapshot(session.store, readOnly: true)).active;
      } catch (_) {
        _checkFileReadSession(session);
        if (revision != _rosterRevision) continue;
        // An IO failure of the primary setting is not an absent identity.
        rethrow;
      }
      _checkFileReadSession(session);
      if (revision != _rosterRevision) continue;
      return raw == null ? null : _decodeRoster(raw);
    }
  });

  /// The roster in [raw], or null if it does not parse.
  static List<RosterEntry>? _decodeRoster(Uint8List raw) {
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

  Future<void> _contactGate = Future<void>.value();

  Future<T> _contactSerialized<T>(Future<T> Function() body) {
    final result = _contactGate.then((_) => body());
    _contactGate = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  static const _contactPendingPrefix = 'contact.status.pending.v1:';
  static const _contactFloorPrefix = 'contact.status.floor.v1:';

  static bool _isContactDecision(ContactStatus status) =>
      status == ContactStatus.accepted || status == ContactStatus.blocked;

  static PendingContactDecision _decodeContactDecision(Uint8List raw) {
    try {
      final value = jsonDecode(utf8.decode(raw));
      final status = ContactStatus.values.byName(value['status'] as String);
      final atMs = value['ts'];
      final peer = value['peer'];
      if (_isContactDecision(status) &&
          atMs is int &&
          atMs >= 0 &&
          peer is String &&
          RegExp(r'^[0-9a-f]{64}$').hasMatch(peer)) {
        return PendingContactDecision(
          peer: NodeId.fromHex(peer),
          status: status,
          atMs: atMs,
          token: crypto.sha256.convert(raw).toString(),
        );
      }
    } catch (_) {
      // Keep corrupt obligations for diagnosis, without their private bytes.
    }
    throw StateError('Unreadable pending contact decision');
  }

  static Uint8List _contactDecisionBytes(
    NodeId peer,
    ContactStatus status,
    int atMs,
  ) => _sk(jsonEncode({'peer': peer.hex, 'status': status.name, 'ts': atMs}));

  Future<Uint8List> _newContactDecision(
    AsyncKvLogStore store,
    NodeId peer,
    ContactStatus status,
  ) async {
    final old = await store.get(
      Ns.settings,
      _sk('$_contactFloorPrefix${peer.hex}'),
    );
    final previous = old == null ? null : _decodeContactDecision(old);
    if (previous != null && previous.peer != peer) {
      throw StateError('Contact decision floor does not match its key');
    }
    final stamp = max(
      DateTime.now().millisecondsSinceEpoch,
      (previous?.atMs ?? -1) + 1,
    );
    return _contactDecisionBytes(peer, status, stamp);
  }

  List<PutOp> _contactDecisionOps(NodeId peer, Uint8List value) => [
    PutOp(Ns.settings, _sk('$_contactFloorPrefix${peer.hex}'), value),
    PutOp(Ns.settings, _sk('$_contactPendingPrefix${peer.hex}'), value),
  ];

  @override
  Future<void> setContactStatus(NodeId peer, ContactStatus status) =>
      _trackLogWrite(
        (store) => _contactSerialized(() async {
          final existing = await getContact(peer);
          final contact = (existing ?? Contact(nodeId: peer)).copyWith(
            status: status,
          );
          final (index, shards) = await _contactIndexShards();
          final indexed = index.contains(peer.hex);
          if (!indexed) index.add(peer.hex);
          await store.commit([
            PutOp(Ns.contacts, peer.bytes, _encodeContact(contact)),
            if (!indexed) ..._contactIndexOps(index, shards),
            if (_isContactDecision(status))
              ..._contactDecisionOps(
                peer,
                await _newContactDecision(store, peer, status),
              ),
          ]);
        }),
      );

  @override
  Future<bool> applyContactDecision(
    NodeId peer,
    ContactStatus status,
    int atMs,
  ) {
    if (!_isContactDecision(status) || atMs < 0) {
      return Future.error(ArgumentError('Invalid contact decision'));
    }
    return _trackLogWrite(
      (store) => _contactSerialized(() async {
        final key = _sk('$_contactFloorPrefix${peer.hex}');
        final raw = await store.get(Ns.settings, key);
        final old = raw == null ? null : _decodeContactDecision(raw);
        if (old != null && old.peer != peer) {
          throw StateError('Contact decision floor does not match its key');
        }
        if (old != null &&
            (atMs < old.atMs ||
                (atMs == old.atMs &&
                    status.name.compareTo(old.status.name) <= 0))) {
          return false;
        }
        final existing = await getContact(peer);
        final contact = (existing ?? Contact(nodeId: peer)).copyWith(
          status: status,
        );
        final (index, shards) = await _contactIndexShards();
        final indexed = index.contains(peer.hex);
        if (!indexed) index.add(peer.hex);
        await store.commit([
          PutOp(Ns.contacts, peer.bytes, _encodeContact(contact)),
          if (!indexed) ..._contactIndexOps(index, shards),
          PutOp(Ns.settings, key, _contactDecisionBytes(peer, status, atMs)),
        ]);
        return existing?.status != status;
      }),
    );
  }

  @override
  Future<PendingContactDecision?> contactDecisionFloor(NodeId peer) =>
      _trackLogWrite((store) async {
        final raw = await store.get(
          Ns.settings,
          _sk('$_contactFloorPrefix${peer.hex}'),
        );
        if (raw == null) return null;
        final record = _decodeContactDecision(raw);
        if (record.peer != peer) {
          throw StateError('Contact decision floor does not match its key');
        }
        return record;
      });

  @override
  Future<List<PendingContactDecision>> pendingContactDecisions({
    int limit = 64,
    String? afterPeerHex,
  }) {
    if (limit <= 0) throw ArgumentError.value(limit, 'limit');
    return _trackLogWrite((store) async {
      final names = [
        for (final key in await store.kvKeys(Ns.settings))
          if (utf8.decode(key, allowMalformed: true) case final name)
            if (name.startsWith(_contactPendingPrefix) &&
                (afterPeerHex == null ||
                    name.compareTo('$_contactPendingPrefix$afterPeerHex') > 0))
              name,
      ]..sort();
      final records = <PendingContactDecision>[];
      for (final name in names) {
        final raw = await store.get(Ns.settings, _sk(name));
        if (raw == null) continue;
        final record = _decodeContactDecision(raw);
        if (name != '$_contactPendingPrefix${record.peer.hex}') {
          throw StateError('Contact decision does not match its key');
        }
        records.add(record);
        if (records.length >= limit) break;
      }
      return records;
    });
  }

  @override
  Future<bool> acknowledgeContactDecision(PendingContactDecision record) =>
      _trackLogWrite(
        (store) => _contactSerialized(() async {
          final key = _sk('$_contactPendingPrefix${record.peer.hex}');
          final raw = await store.get(Ns.settings, key);
          if (raw == null ||
              crypto.sha256.convert(raw).toString() != record.token) {
            return false;
          }
          await store.commit([DeleteOp(Ns.settings, key)]);
          return true;
        }),
      );

  static const _prefsPending = 'contact.prefs.pending.v1:';
  static const _prefsFloor = 'contact.prefs.floor.v1:';
  static const _prefsData = 'contact.prefs.data.v1:';
  static const _prefsPartBytes = 1024, _prefsMaxParts = 8;

  static Map<String, dynamic> _prefsManifest(Uint8List raw) {
    try {
      final value = jsonDecode(utf8.decode(raw));
      if (value is Map<String, dynamic> &&
          value['v'] == 1 &&
          value['nonce'] is String &&
          RegExp(r'^[0-9a-f]{32}$').hasMatch(value['nonce']) &&
          value['peer'] is String &&
          RegExp(r'^[0-9a-f]{64}$').hasMatch(value['peer']) &&
          value['ts'] is int &&
          value['ts'] >= 0 &&
          value['parts'] is int &&
          value['parts'] > 0 &&
          value['parts'] <= _prefsMaxParts &&
          value['n'] is int &&
          value['n'] > 0 &&
          value['n'] <= _prefsMaxParts * _prefsPartBytes &&
          value['parts'] ==
              (value['n'] + _prefsPartBytes - 1) ~/ _prefsPartBytes &&
          value['sha'] is String &&
          RegExp(r'^[0-9a-f]{64}$').hasMatch(value['sha'])) {
        return value;
      }
    } catch (_) {}
    throw StateError('Unreadable contact preference manifest');
  }

  Future<List<KvLogOp>> _preferenceObligationOps(
    AsyncKvLogStore store,
    Contact contact,
  ) async {
    final peer = contact.nodeId.hex;
    final previous = await store.get(Ns.settings, _sk('$_prefsFloor$peer'));
    final oldPending = await store.get(Ns.settings, _sk('$_prefsPending$peer'));
    if ((previous != null && _prefsManifest(previous)['peer'] != peer) ||
        (oldPending != null && _prefsManifest(oldPending)['peer'] != peer)) {
      throw StateError('Contact preference manifest does not match its key');
    }
    final oldParts = oldPending == null
        ? 0
        : _prefsManifest(oldPending)['parts'] as int;
    final ts = max(
      DateTime.now().millisecondsSinceEpoch,
      previous == null ? 0 : (_prefsManifest(previous)['ts'] as int) + 1,
    );
    final bytes = _sk(jsonEncode(contactPrefsPayload(contact)));
    final count = (bytes.length + _prefsPartBytes - 1) ~/ _prefsPartBytes;
    if (count <= 0 || count > _prefsMaxParts) {
      throw StateError('Contact preference snapshot exceeds storage bound');
    }
    final manifest = _sk(
      jsonEncode({
        'v': 1,
        'peer': peer,
        'nonce': _randomHex(16),
        'ts': ts,
        'parts': count,
        'n': bytes.length,
        'sha': crypto.sha256.convert(bytes).toString(),
      }),
    );
    return [
      PutOp(Ns.settings, _sk('$_prefsFloor$peer'), manifest),
      PutOp(Ns.settings, _sk('$_prefsPending$peer'), manifest),
      for (var i = 0; i < count; i++)
        PutOp(
          Ns.settings,
          _sk('$_prefsData$peer:$i'),
          Uint8List.sublistView(
            bytes,
            i * _prefsPartBytes,
            min((i + 1) * _prefsPartBytes, bytes.length),
          ),
        ),
      for (var i = count; i < oldParts; i++)
        DeleteOp(Ns.settings, _sk('$_prefsData$peer:$i')),
    ];
  }

  @override
  Future<List<PendingContactPreferences>> pendingContactPreferences({
    int limit = 64,
    String? afterPeerHex,
  }) {
    if (limit <= 0) throw ArgumentError.value(limit, 'limit');
    return _trackLogWrite(
      (store) => _contactSerialized(() async {
        final names = [
          for (final key in await store.kvKeys(Ns.settings))
            if (utf8.decode(key, allowMalformed: true) case final name)
              if (name.startsWith(_prefsPending) &&
                  (afterPeerHex == null ||
                      name.compareTo('$_prefsPending$afterPeerHex') > 0))
                name,
        ]..sort();
        final records = <PendingContactPreferences>[];
        for (final name in names) {
          final peerHex = name.substring(_prefsPending.length);
          if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(peerHex)) {
            throw StateError('Unreadable contact preference key');
          }
          final raw = await store.get(Ns.settings, _sk(name));
          if (raw == null) continue;
          final manifest = _prefsManifest(raw);
          if (manifest['peer'] != peerHex) {
            throw StateError(
              'Contact preference manifest does not match its key',
            );
          }
          final bytes = BytesBuilder(copy: false);
          for (var i = 0; i < manifest['parts']; i++) {
            final part = await store.get(
              Ns.settings,
              _sk('$_prefsData$peerHex:$i'),
            );
            final expected = min(
              _prefsPartBytes,
              manifest['n'] - i * _prefsPartBytes,
            );
            if (part == null || part.length != expected) {
              throw StateError('Incomplete contact preference snapshot');
            }
            bytes.add(part);
          }
          final encoded = bytes.takeBytes();
          if (crypto.sha256.convert(encoded).toString() != manifest['sha']) {
            throw StateError('Invalid contact preference snapshot digest');
          }
          final Map<String, Object?> payload;
          try {
            payload = Map<String, Object?>.from(
              jsonDecode(utf8.decode(encoded)) as Map,
            );
          } catch (_) {
            throw StateError('Unreadable contact preference snapshot');
          }
          records.add(
            PendingContactPreferences(
              peer: NodeId.fromHex(peerHex),
              atMs: manifest['ts'] as int,
              payload: Map.unmodifiable(payload),
              token: crypto.sha256.convert(raw).toString(),
            ),
          );
          if (records.length >= limit) break;
        }
        return records;
      }),
    );
  }

  @override
  Future<bool> acknowledgeContactPreferences(
    PendingContactPreferences record,
  ) => _trackLogWrite(
    (store) => _contactSerialized(() async {
      final key = _sk('$_prefsPending${record.peer.hex}');
      final raw = await store.get(Ns.settings, key);
      if (raw == null ||
          crypto.sha256.convert(raw).toString() != record.token) {
        return false;
      }
      final manifest = _prefsManifest(raw);
      await store.commit([
        DeleteOp(Ns.settings, key),
        for (var i = 0; i < manifest['parts']; i++)
          DeleteOp(Ns.settings, _sk('$_prefsData${record.peer.hex}:$i')),
      ]);
      return true;
    }),
  );

  static Uint8List _encodeContact(Contact contact) {
    final json = jsonEncode({
      'n': contact.nodeId.hex,
      'name': contact.name,
      's': contact.status.index,
      // 'mu' (ms epoch deadline) supersedes the legacy boolean 'm'; a legacy
      // record's 'm':true reads back as muted-forever (see _contactFor).
      if (contact.mutedUntil != null)
        'mu': contact.mutedUntil!.millisecondsSinceEpoch,
      if (contact.mutedUntil != null &&
          contact.notificationMuteMode != NotificationMuteMode.none)
        'mm': contact.notificationMuteMode.name,
      if (contact.pinned) 'p': true,
      if (contact.archived) 'a': true,
      if (contact.retentionDays != null) 'rd': contact.retentionDays,
      // The disappearing window and WHO set it WHEN. The stamp is written
      // even for "off", because turning the window off is itself a decision
      // that has to beat an older one on the peer's device.
      if (contact.disappearingTtlSeconds != null)
        'dts': contact.disappearingTtlSeconds,
      if (contact.disappearingSetAtMs > 0) 'dsa': contact.disappearingSetAtMs,
      if (contact.disappearingSetBy.isNotEmpty)
        'dsb': contact.disappearingSetBy,
      // The read-clock half. Absent means off, and off needs no stamp of its
      // own: it shares `dsa`/`dsb` with the post-time window because the two
      // are one announcement.
      if (contact.hideAfterReadSeconds != null)
        'hrs': contact.hideAfterReadSeconds,
      // Written only when DISALLOWED — absence reads back as the default (allow).
      if (!contact.allowPeerDelete) 'apd': false,
      // BY NAME, not by index: this one can still grow, and a record written
      // today must not change meaning when a value is inserted in the middle.
      // Absent reads back through the legacy bit — see the decode side.
      if (contact.clearPolicy != kDefaultClearRequestPolicy)
        'clp': contact.clearPolicy.name,
      if (contact.p2pOverride != kDefaultContactP2POverride)
        'p2p': contact.p2pOverride.index,
    });
    return _sk(json);
  }

  @override
  Future<void> upsertContact(Contact contact) => _trackLogWrite(
    (store) => _contactSerialized(() => _upsertContact(store, contact)),
  );

  @override
  Future<Contact?> updateContactPrefs(
    NodeId peer,
    Contact? Function(Contact current) update, {
    bool queueForSync = false,
    String? onlyIfLocalPrefsToken,
  }) => _trackLogWrite(
    (store) => _contactSerialized(() async {
      if (onlyIfLocalPrefsToken != null) {
        final raw = await store.get(
          Ns.settings,
          _sk('$_prefsFloor${peer.hex}'),
        );
        if (raw == null ||
            crypto.sha256.convert(raw).toString() != onlyIfLocalPrefsToken) {
          return null;
        }
      }
      final current = await getContact(peer);
      if (current == null) return null;
      final next = update(current);
      if (next == null) return null;
      if (next.nodeId != peer || next.status != current.status) {
        throw ArgumentError('Preference update cannot change the relationship');
      }
      await _upsertContact(
        store,
        next,
        extraOps: queueForSync
            ? await _preferenceObligationOps(store, next)
            : const [],
      );
      return next;
    }),
  );

  Future<void> _upsertContact(
    AsyncKvLogStore store,
    Contact contact, {
    List<KvLogOp> extraOps = const [],
  }) async {
    final contactBytes = _encodeContact(contact);
    final existingContact = await store.get(Ns.contacts, contact.nodeId.bytes);
    // Maintain a contacts index (hidden-volume has no KV key enumeration) so
    // the chat list can show contacts that have no messages yet.
    final (index, hadShards) = await _contactIndexShards();
    final oldIndexJson = jsonEncode(index);
    if (!index.contains(contact.nodeId.hex)) index.add(contact.nodeId.hex);
    final indexJson = jsonEncode(index);
    if (extraOps.isEmpty &&
        _bytesEqual(existingContact, contactBytes) &&
        oldIndexJson == indexJson) {
      return;
    }
    await store.commit([
      PutOp(Ns.contacts, contact.nodeId.bytes, contactBytes),
      ..._contactIndexOps(index, hadShards),
      ...extraOps,
    ]);
  }

  /// The key of index shard `k`. Shard 0 keeps the original name, so a
  /// container written before this existed reads back as a one-shard index.
  static String _contactIndexKey(int shard) =>
      shard == 0 ? 'contacts:index' : 'contacts:index/$shard';

  /// How many contact ids go in one shard.
  ///
  /// A container settings value is capped at 2048 bytes, and an id costs 67 of
  /// them inside a JSON list — 64 hex characters, two quotes, a comma. The
  /// whole index was ONE value, so the thirty-first contact encoded to 2078
  /// bytes and the commit that carried it was refused: the contact and the
  /// index travel in one transaction, so the refusal took the contact with it
  /// and a container simply stopped accepting new contacts at thirty
  /// (report27 X25).
  ///
  /// Sharded rather than moved to the file store — which is what the master
  /// roster does a few methods up — precisely BECAUSE of that transaction. A
  /// file write is not part of the commit, so above the threshold the contact
  /// would land and its index entry might not. Twenty-five ids is 1676 bytes,
  /// well inside the cap with room for the record around it.
  static const int _contactIdsPerIndexShard = 25;

  /// Every id in the index, in order, across however many shards it takes.
  ///
  /// Stops at the first shard that is absent or empty: a write clears the
  /// shard after the last one it used, so an empty shard IS the end.
  Future<List<String>> _contactIndex() async =>
      (await _contactIndexShards()).$1;

  /// The ids, and how many shards were actually read — the second is what a
  /// write needs in order to clear the ones it no longer fills.
  Future<(List<String>, int)> _contactIndexShards() async {
    final ids = <String>[];
    var shard = 0;
    while (true) {
      final raw = await _as.get(Ns.settings, _sk(_contactIndexKey(shard)));
      if (raw == null) break;
      final decoded = (jsonDecode(utf8.decode(raw)) as List).cast<String>();
      if (decoded.isEmpty) break;
      ids.addAll(decoded);
      shard += 1;
    }
    return (ids, shard);
  }

  /// The writes that put `ids` back, and clear whatever shards they no longer
  /// fill. `hadShards` is what [`_contactIndexShards`] reported when the list
  /// was read.
  List<PutOp> _contactIndexOps(List<String> ids, int hadShards) {
    final ops = <PutOp>[];
    var shard = 0;
    for (var at = 0; at < ids.length; at += _contactIdsPerIndexShard) {
      final slice = ids.sublist(
        at,
        (at + _contactIdsPerIndexShard).clamp(0, ids.length),
      );
      ops.add(
        PutOp(
          Ns.settings,
          _sk(_contactIndexKey(shard)),
          _sk(jsonEncode(slice)),
        ),
      );
      shard += 1;
    }
    // The terminator, and the cleanup: an empty shard stops the reader, and
    // every shard the old index used past this point has to stop looking
    // authoritative.
    for (var stale = shard; stale <= hadShards; stale += 1) {
      ops.add(PutOp(Ns.settings, _sk(_contactIndexKey(stale)), _sk('[]')));
    }
    return ops;
  }

  _ContactReadFlight? _contactReadFlight;

  Future<Uint8List?> _readContactBytes(NodeId peer) {
    final store = _as;
    final queue = store is AsyncKvRequestFrontier
        ? store as AsyncKvRequestFrontier
        : null;
    final frontier = queue?.requestFrontier;
    final pending = _contactReadFlight;
    if (frontier != null &&
        pending != null &&
        identical(pending.store, store) &&
        pending.frontier == frontier &&
        pending.peer == peer) {
      return pending.result;
    }
    _contactReadFlight = null;
    final raw = store.get(Ns.contacts, peer.bytes);
    final dispatched = queue?.requestFrontier;
    // Share only a single get actually queued by this call. A wrapper which
    // queues another operation must not attach the earlier read to its witness.
    if (frontier == null || dispatched != frontier + 1) return raw;
    final flight = _ContactReadFlight(store, peer, dispatched!);
    flight.result = raw.whenComplete(() {
      // Clear BEFORE any caller receives a value or failure. No completed
      // contact, consent decision or error is cached; a new command is a barrier.
      if (identical(_contactReadFlight, flight)) _contactReadFlight = null;
    });
    _contactReadFlight = flight;
    return flight.result;
  }

  @override
  Future<Contact?> getContact(NodeId nodeId) async {
    final peer = NodeId(nodeId.bytes);
    final raw = await _readContactBytes(peer);
    // The presence check already fetched the row from the storage worker.
    // Decode that observation, without a second RPC or a stale contact cache.
    return raw == null ? null : _decodeContact(peer, raw);
  }

  Future<Contact> _contactFor(NodeId id) async {
    final raw = await _as.get(Ns.contacts, id.bytes);
    // A CONTACT ROW THAT WAS NEVER WRITTEN IS NOT CONSENT. `Contact`'s own
    // default status is `accepted` — right for a record built after the
    // relationship exists, and a fabrication here, where the only thing known
    // is that nobody ever decided anything about this id.
    //
    // [loadConversations] unions the contact index with every id that has
    // messages, so a conversation with no row got this default and came back
    // as an ACCEPTED contact with `canMessage: true`. Measured live on a
    // two-device stand: the sibling device mirrors the outgoing greeting of a
    // contact REQUEST but deliberately does not mirror a pending status (see
    // `applyMirroredContactStatus`), so it held two chats with no rows — and
    // showed both as accepted contacts. One of them was a peer whose request
    // had never been deposited at all: it had never seen a request, let alone
    // answered one, and the second device offered to message it.
    //
    // The consequences are not cosmetic: `canMessage`, the realtime-control
    // gate, content publish and group recommendations all key on
    // `status == accepted`, and `capPreConsentIntros` returns early for an
    // accepted peer, so the pre-consent intro cap stopped applying too.
    //
    // `pendingOutgoing` because that is what the case actually is — our own
    // device asked and nobody has answered — and because every gate above is
    // closed for it.
    if (raw == null) {
      return Contact(nodeId: id, status: ContactStatus.pendingOutgoing);
    }
    return _decodeContact(id, raw);
  }

  Contact _decodeContact(NodeId id, Uint8List raw) {
    final m = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
    final s = m['s'] as int?;
    return Contact(
      nodeId: id,
      name: m['name'] as String?,
      status: s != null && s >= 0 && s < ContactStatus.values.length
          ? ContactStatus.values[s]
          : ContactStatus.accepted,
      mutedUntil: m['mu'] != null
          ? DateTime.fromMillisecondsSinceEpoch(m['mu'] as int)
          : (m['m'] == true ? kMuteForever : null),
      notificationMuteMode: NotificationMuteMode.values.firstWhere(
        (mode) => mode.name == m['mm'],
        orElse: () => NotificationMuteMode.none,
      ),
      pinned: m['p'] as bool? ?? false,
      archived: m['a'] as bool? ?? false,
      retentionDays: m['rd'] as int?,
      disappearingTtlSeconds: m['dts'] as int?,
      disappearingSetAtMs: m['dsa'] as int? ?? 0,
      disappearingSetBy: m['dsb'] as String? ?? '',
      hideAfterReadSeconds: m['hrs'] as int?,
      allowPeerDelete: m['apd'] as bool? ?? true,
      // A record from before the setting existed carries only the legacy bit,
      // and it has to answer for both: OFF was an explicit act and is kept as
      // "never", ON is what every untouched record holds and becomes the new
      // default. See [clearRequestPolicyFromLegacy] for what that costs whom.
      clearPolicy:
          ClearRequestPolicy.fromName(m['clp'] as String?) ??
          clearRequestPolicyFromLegacy(
            allowPeerDelete: m['apd'] as bool? ?? true,
          ),
      p2pOverride: _contactP2POverride(m['p2p']),
    );
  }

  ContactP2POverride _contactP2POverride(Object? raw) {
    final i = raw is int ? raw : null;
    if (i == null || i < 0 || i >= ContactP2POverride.values.length) {
      return kDefaultContactP2POverride;
    }
    return ContactP2POverride.values[i];
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
    final existing = await _readMarker(conversationId);
    if (existing >= latest) return;
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
  Future<int> readMarker(String conversationId) => _readMarker(conversationId);

  @override
  Future<void> setReadMarker(String conversationId, int tsMs) async {
    if (await _readMarker(conversationId) >= tsMs) return;
    await _as.commit([
      PutOp(Ns.settings, _sk('read:$conversationId'), _sk('$tsMs')),
    ]);
  }

  @override
  Future<List<Conversation>> loadConversations() async {
    final byConv = <String, Message>{};
    final unread = <String, int>{};
    final readMarkers = <String, int>{}; // cache: one KV read per conversation
    for (final entry in await _scanLog()) {
      // Loopback echoes of control frames (accept/sync/ack/…) are service
      // noise — they must not become a conversation's preview or unread count
      // (the in-chat window filters them the same way via isServiceEchoBody).
      if (isServiceEchoBody(entry.body)) continue;
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
    final sorted = all
        .where((m) => m.conversationId == conversationId)
        .toList();
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
      if (m.orderAuthor != null && m.orderSeq != null) {
        (byAuthor[m.orderAuthor!] ??= <Message>[]).add(m);
      }
    }
    final effTs = <String, int>{}; // message id -> effective ts (ms)
    for (final stream in byAuthor.values) {
      // ONE AUTHOR, MORE THAN ONE STREAM: the floor assumes an author's seqs
      // are one causal sequence, and for a sovereign identity with several
      // devices they are not — each device numbers its own messages from 1,
      // and this side files them all under the identity. Ordered by seq, a
      // device's fresh seq 5 then lifted another device's day-old 6..140 to
      // "now": measured on the stand, 143 of 305 rows of such a chat shown
      // below a newer one, the last line on screen from four hours earlier.
      // Two distinct messages at one seq are the mark of it (one device never
      // writes two), so such a stream keeps its honest timestamps.
      final seen = <int>{};
      if (stream.any((m) => !seen.add(m.orderSeq!))) continue;
      stream.sort((a, b) => a.orderSeq!.compareTo(b.orderSeq!));
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
      final au = (a.orderAuthor ?? '').compareTo(b.orderAuthor ?? '');
      if (au != 0) return au;
      final s = (a.orderSeq ?? 0).compareTo(b.orderSeq ?? 0);
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
  Future<Message?> loadMessageById(
    String conversationId,
    String messageId,
  ) => _serialized(() async {
    // The same warm, incremental fold [_liveEntryFor] uses — a map lookup on
    // the composite key once the fold is current, instead of [loadMessages]'s
    // project-filter-sort over every message in the log.
    await _foldCritical();
    final k = _msgKey(conversationId, messageId);
    final msg = _scanById[k];
    if (msg == null) return null;
    // The same overlay [_scanLogCritical] applies on the way out, so a row read
    // by id is the row `loadMessages` would have handed back and not a
    // pre-status copy of it.
    final s = _scanStatusOps[k] ?? _scanStatusLegacy[msg.id];
    final sig = _scanSigOps[k];
    var out = s != null && msg.status != MessageStatus.delivered
        ? msg.copyWith(status: s)
        : msg;
    if (sig != null) out = out.copyWith(signature: sig);
    return out;
  });

  @override
  Future<Set<String>> deletedMessageIds(String conversationId) =>
      _serialized(() async {
        await _foldCritical();
        final prefix = '$conversationId\u001f';
        return {
          for (final k in _scanDeletedKeys)
            if (k.startsWith(prefix)) k.substring(prefix.length),
        };
      });

  @override
  Future<bool> recordExpiredMessage(
    String conversationId,
    String messageId, {
    String? author,
    int? seq,
  }) => _withConvSequence(
    conversationId,
    author ?? conversationId,
    () => _serialized(() async {
      await _foldCritical();
      final key = _msgKey(conversationId, messageId);
      if (_scanById.containsKey(key) ||
          _scanDeletedKeys.contains(key) ||
          _scanDeletedLegacyIds.contains(messageId)) {
        return false;
      }
      await _commitAtNextMessageLogId(
        (namespace, logId) => [
          AppendLogOp(
            namespace,
            logId,
            _sk(
              jsonEncode({
                'op': 'del',
                'c': conversationId,
                'id': messageId,
                if (author != null && seq != null) ...{'au': author, 'sq': seq},
              }),
            ),
          ),
        ],
      );
      await _foldCritical();
      return true;
    }),
  );

  @override
  Future<void> recordBlockedMessage(
    String conversationId,
    String author,
    String messageId,
    int? seq,
  ) async {
    if (await isBlockedMessage(conversationId, messageId)) return;
    // If the 200-message cap has room, the body is kept separately until
    // Show/Delete. This local, body-less marker stops a retry after unblock
    // from bypassing that choice even when the cap was already full.
    // It is a void on the recovery wire, so siblings never mistake a local
    // block for an instruction to erase their own copy.
    await _commitAtNextMessageLogId(
      (namespace, logId) => [
        AppendLogOp(
          namespace,
          logId,
          _sk(
            jsonEncode({
              'k': EventKind.void_.index,
              'c': conversationId,
              'au': author,
              'sq': ?seq,
              'bi': messageId,
            }),
          ),
        ),
      ],
    );
    await _patchCache(
      () => _scanBlockedKeys.add(_msgKey(conversationId, messageId)),
    );
  }

  @override
  Future<bool> isBlockedMessage(String conversationId, String messageId) =>
      _serialized(() async {
        await _foldCritical();
        return _scanBlockedKeys.contains(_msgKey(conversationId, messageId));
      });

  @override
  Future<Map<String, int>> editSeqs(String conversationId) => _serialized(
    () async {
      await _foldCritical();
      final prefix = '$conversationId\u001f';
      return {
        for (final e in _scanEditWinSeq.entries)
          if (e.key.startsWith(prefix)) e.key.substring(prefix.length): e.value,
      };
    },
  );

  @override
  Future<void> storeFile(
    String fileId,
    Uint8List bytes, {
    String? name,
    List<String> retireHints = const [],
  }) {
    if (retireHints.contains(fileId)) {
      throw ArgumentError('a file cannot retire itself');
    }
    final hints = retireHints.take(64).toSet();
    // Serialize against other stores so the multi-commit read-base/bump-last
    // sequence can't interleave and collide chunk log-ids (see [_fileGate]).
    return _fileSerialized(() async {
      final inVolume = <String>[];
      for (final id in hints) {
        try {
          // Presence, not successful decoding: an on-disk key must go through
          // deleteStoredFile's key scrub and ciphertext cleanup even if its
          // metadata is malformed. Never retire only half of a tiered file.
          if (await _as.get(Ns.settings, _sk('ondisk:$id')) == null) {
            inVolume.add(id);
          }
        } catch (_) {
          // This hint is optional. The caller still retries explicit cleanup.
        }
      }
      await AsyncFileStore(
        _as,
      ).storeFile(fileId, bytes, name: name, retireHints: inVolume);
    });
  }

  @override
  Future<bool> tryStoreFilePair(
    StoredFileWrite prerequisite,
    StoredFileWrite publication, {
    List<String> retireHints = const [],
  }) {
    if (prerequisite.id == publication.id ||
        retireHints.contains(prerequisite.id) ||
        retireHints.contains(publication.id)) {
      throw ArgumentError('paired files cannot replace or retire each other');
    }
    if (prerequisite.bytes.isEmpty ||
        publication.bytes.isEmpty ||
        prerequisite.bytes.length > StoredFilePairWriter.maxBytes ||
        publication.bytes.length >
            StoredFilePairWriter.maxBytes - prerequisite.bytes.length) {
      return Future.value(false);
    }
    StoredFileWrite snapshot(StoredFileWrite file) => StoredFileWrite(
      file.id,
      Uint8List.fromList(file.bytes),
      name: file.name,
    );
    final first = snapshot(prerequisite), second = snapshot(publication);
    final hints = retireHints.take(64).toSet();
    return _fileSerialized(() async {
      // A tiered file must use ordinary key scrub/ciphertext cleanup, even
      // when its metadata cannot be decoded. Never erase only half a tier.
      for (final id in [first.id, second.id]) {
        if (await _as.get(Ns.settings, _sk('ondisk:$id')) != null) return false;
      }
      final inVolume = <String>[];
      for (final id in hints) {
        try {
          if (await _as.get(Ns.settings, _sk('ondisk:$id')) == null) {
            inVolume.add(id);
          }
        } catch (_) {
          // Optional retirement; the group caller still performs cleanup.
        }
      }
      return AsyncFileStore(
        _as,
      ).tryStoreFilePair(first, second, retireHints: inVolume);
    });
  }

  // ── Large-file tier (Phase B) ────────────────────────────────────────────
  // A blob at/above [_kOnDiskTierMinBytes] can't fit the hidden-volume index
  // (its per-namespace B+ tree caps at a few thousand small records), so it is
  // stored ENCRYPTED on the normal filesystem ([OnDiskBlobStore]). The per-blob
  // random key + opaque name live HERE, in the volume (deniable) — only
  // ciphertext is on disk. Per cid, the routing is decided ONCE at first store
  // and recorded as `ondisk:<cid>` metadata; every later read consults it, so a
  // file's tier is stable regardless of the (size-less) read API.

  /// Files ABOVE the proven in-volume whole-file cap route to the on-disk
  /// encrypted tier; at/below it they stay in the volume (fully deniable). This
  /// aligns with the sender's serve-from-source threshold and keeps the
  /// hidden-volume index well clear of its ceiling.
  static const int _kOnDiskTierMinBytes = kMaxStoredFileBytes;

  OnDiskBlobStore? _blobs;
  int _onDiskMinBytes = _kOnDiskTierMinBytes;
  final Random _blobRand = Random.secure();

  /// Enable the on-disk LARGE-FILE tier, rooted at [dir].
  ///
  /// ONE directory per CONTAINER, shared by every space in it — not one per
  /// identity, as this used to say. A directory per space would publish how
  /// many hidden spaces the container holds, right beside it, which is the
  /// fingerprint class hidden-volume removed from its cleartext header in v3.
  /// Ownership is resolved inside each space instead: `eraseSpace` deletes only
  /// the blob names its own volume names (audit XV-01).
  ///
  /// Until set, large files fall back to the in-volume store (and would hit its
  /// index ceiling) — which is what all-online mode did for every identity
  /// until XV-02. Production wiring points this at an app-private dir.
  /// [minBytes] overrides the routing threshold (tests use a tiny one).
  void useOnDiskTier(Directory dir, {int? minBytes}) {
    _blobs = OnDiskBlobStore(dir);
    if (minBytes != null) _onDiskMinBytes = minBytes;
  }

  Uint8List _randomBytes(int n) =>
      Uint8List.fromList(List.generate(n, (_) => _blobRand.nextInt(256)));

  Future<Map<String, dynamic>?> _odMeta(
    String cid, {
    AsyncKvLogStore? store,
  }) async {
    final raw = await (store ?? _as).get(Ns.settings, _sk('ondisk:$cid'));
    return _decodeOdMeta(raw);
  }

  Map<String, dynamic>? _decodeOdMeta(Uint8List? raw) {
    if (raw == null) return null;
    try {
      return jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> _putOdMeta(String cid, Map<String, dynamic> m) =>
      _as.commit([PutOp(Ns.settings, _sk('ondisk:$cid'), _sk(jsonEncode(m)))]);

  /// Forward-secrecy scrub ops for the ON-DISK tier of [fileId]. The per-blob
  /// key lives ONLY in the `ondisk:` row — deleting that row in the SAME commit
  /// as the message tombstone makes the on-disk ciphertext permanently
  /// unreadable, exactly like the in-container chunk zeroing. The opaque blob
  /// name is collected into [blobNamesOut] so the caller removes the ciphertext
  /// files AFTER the commit (an FS delete can't join the volume commit
  /// atomically, and never needs to: it only reclaims space — confidentiality
  /// rests on the key scrub). Empty for a file that never hit the on-disk tier.
  Future<List<KvLogOp>> _onDiskScrubOps(
    String fileId,
    List<String> blobNamesOut,
  ) async {
    final meta = await _odMeta(fileId);
    if (meta == null) return const [];
    final fn = meta['fn'];
    if (fn is String) blobNamesOut.add(fn);
    return [DeleteOp(Ns.settings, _sk('ondisk:$fileId'))];
  }

  /// Every blob name THIS space owns, read from its `ondisk:` settings rows.
  ///
  /// The blob directory is shared by every space of the container — the names
  /// are opaque and the keys live in each space's own volume — so "which of
  /// these are mine" is answerable only from inside an open space, and only
  /// before its metadata is erased.
  ///
  /// A read failure yields the empty list: leaving unreadable ciphertext behind
  /// is a space leak, while guessing would delete another identity's files,
  /// and only one of those is recoverable.
  Future<List<String>> _ownBlobNames() async {
    if (_blobs == null) return const [];
    try {
      final names = <String>[];
      for (final key in await settingsKeys()) {
        if (!key.startsWith('ondisk:')) continue;
        final meta = await _odMeta(key.substring('ondisk:'.length));
        final fn = meta?['fn'];
        if (fn is String && fn.isNotEmpty) names.add(fn);
      }
      return names;
    } catch (_) {
      return const [];
    }
  }

  /// Best-effort ciphertext removal AFTER the key scrub committed. Failures are
  /// swallowed: without its key the blob is unreadable garbage either way; a
  /// later [eraseSpace] (or the OS) reclaims what a transient FS error leaves.
  Future<void> _deleteBlobFiles(List<String> names) async {
    final blobs = _blobs;
    if (blobs == null || names.isEmpty) return;
    for (final n in names) {
      try {
        await blobs.delete(n);
      } catch (_) {}
    }
  }

  @override
  Future<Uint8List?> loadFile(
    String fileId, {
    int? maxBytes,
  }) => _readFileSession((session) async {
    final meta = await _odMeta(fileId, store: session.store);
    _checkFileReadSession(session);
    if (meta != null) {
      final blobs = session.blobs;
      if (blobs == null) return null;
      final size = meta['sz'] as int;
      // Whole-file read — large-file callers should STREAM via [readFileRange]
      // instead (this holds the whole blob in RAM). Used for small/medium blobs.
      //
      // The ceiling is checked against the STORED size, which is the one number
      // here that describes the bytes about to be allocated. A caller checking
      // a size it was handed by a sender cannot do this: the sender chooses
      // whether to include one (audit report8).
      if (maxBytes != null && size > maxBytes) return null;
      return blobs.readRange(
        meta['fn'] as String,
        base64.decode(meta['k'] as String),
        0,
        size,
        meta['ps'] as int,
        size,
      );
    }
    return AsyncFileStore(session.store).loadFile(fileId, maxBytes: maxBytes);
  });

  @override
  Future<List<Uint8List>?> loadFiles(
    List<String> fileIds, {
    required int maxBytesPerFile,
  }) async {
    if (fileIds.length > StoredFileBatchReader.maxFiles ||
        maxBytesPerFile < 0) {
      throw ArgumentError('invalid bounded file read');
    }
    final requested = List<String>.of(fileIds);
    return _readFileSession((session) async {
      if (requested.isEmpty) return const <Uint8List>[];
      Future<List<Uint8List>?> individually() async {
        final result = <Uint8List>[];
        for (final id in requested) {
          _checkFileReadSession(session);
          final bytes = await loadFile(id, maxBytes: maxBytesPerFile);
          if (bytes == null) return null;
          result.add(bytes);
        }
        return result;
      }

      final reader = session.store;
      if (reader is! AsyncKvBatchReader) return individually();
      final metadata = await (reader as AsyncKvBatchReader).getBatch(
        Ns.settings,
        [for (final id in requested) _sk('ondisk:$id')],
      );
      _checkFileReadSession(session);
      if (metadata.length != requested.length) {
        throw StateError('file tier metadata batch length mismatch');
      }
      // Mixed/on-disk batches keep the existing tier precedence and bounded
      // whole-file reader. Journal segments normally all live in the volume.
      if (metadata.any((raw) => _decodeOdMeta(raw) != null)) {
        return individually();
      }
      return AsyncFileStore(
        reader,
      ).loadFiles(requested, maxBytesPerFile: maxBytesPerFile);
    });
  }

  @override
  Future<void> deleteStoredFile(String fileId) => _fileSerialized(() async {
    final blobNames = <String>[];
    final ops = <KvLogOp>[
      ...await AsyncFileStore(_as).deleteFileOps(fileId),
      ...await _onDiskScrubOps(fileId, blobNames),
    ];
    if (ops.isNotEmpty) await _as.commit(ops);
    await _deleteBlobFiles(blobNames);
  });

  @override
  Future<bool> hasFile(String fileId) => _readFileSession((session) async {
    final meta = await _odMeta(fileId, store: session.store);
    _checkFileReadSession(session);
    if (meta != null) {
      return _hasOnDiskFile(session, meta);
    }
    return AsyncFileStore(session.store).hasFile(fileId);
  });

  @override
  Future<List<bool>> hasFiles(List<String> fileIds) async {
    if (fileIds.length > StoredFilePresenceReader.maxFiles) {
      throw ArgumentError('file presence batch exceeds limit');
    }
    final requested = List<String>.of(fileIds);
    return _readFileSession((session) async {
      if (requested.isEmpty) return const <bool>[];
      final reader = session.store;
      if (reader is! AsyncKvBatchReader) {
        final result = <bool>[];
        for (final id in requested) {
          // Preserve the ordinary tier precedence on stores without batching.
          // A replacement space cannot be queried by the previous request.
          _checkFileReadSession(session);
          result.add(await hasFile(id));
        }
        return result;
      }
      final metadata = await (reader as AsyncKvBatchReader).getBatch(
        Ns.settings,
        [for (final id in requested) _sk('ondisk:$id')],
      );
      _checkFileReadSession(session);
      if (metadata.length != requested.length) {
        throw StateError('file presence tier batch length mismatch');
      }
      final disk = [for (final raw in metadata) _decodeOdMeta(raw)];
      final volume = [
        for (var i = 0; i < requested.length; i++)
          if (disk[i] == null) requested[i],
      ];
      final inVolume = await AsyncFileStore(reader).hasFiles(volume);
      _checkFileReadSession(session);
      var next = 0;
      return [
        for (final meta in disk)
          if (meta == null)
            inVolume[next++]
          else
            await _hasOnDiskFile(session, meta),
      ];
    });
  }

  Future<bool> _hasOnDiskFile(
    _FileReadSession session,
    Map<String, dynamic> meta,
  ) async {
    // Presence comes from atomic piece files, not the obsolete `st` metadata
    // list. Extra out-of-range files cannot make up for a missing piece.
    final blobs = session.blobs;
    if (blobs == null) return false;
    final expected = meta['pc'] as int;
    return await blobs.piecesPresent(meta['fn'] as String, expected) >=
        expected;
  }

  @override
  Future<void> storeFilePiece(
    String fileId,
    int pieceIndex,
    int pieceCount,
    int pieceSize,
    int totalSize,
    Uint8List bytes, {
    String? name,
  }) {
    // Tier is decided ONCE, by the first piece, and is then a property of the
    // file rather than of whatever the current call happens to say.
    //
    // Re-deciding it per call on `totalSize` is what the comment here used to
    // promise against and the code did anyway: a second store passing a
    // smaller-looking total routed the same content id into the in-volume
    // store while its earlier pieces sat on disk. One id, two tiers, each half
    // answering `hasFile` about its own half.
    return _fileSerialized(() async {
      final blobs = _blobs;
      final known = blobs == null ? null : await _odMeta(fileId);
      final onDisk =
          blobs != null && (known != null || totalSize > _onDiskMinBytes);
      if (onDisk) {
        return _storeFilePieceOnDisk(
          fileId,
          pieceIndex,
          pieceCount,
          pieceSize,
          totalSize,
          bytes,
          name,
        );
      }
      return AsyncFileStore(_as).storeFilePiece(
        fileId,
        pieceIndex,
        pieceCount,
        pieceSize,
        totalSize,
        bytes,
        name: name,
      );
    });
  }

  /// Store one piece of a large blob in the on-disk encrypted tier. Runs under
  /// [_fileSerialized] (no nested gate): the metadata read-modify-write — first
  /// piece mints a random opaque name + per-blob key — is serialized so
  /// concurrent pieces agree on ONE blob, and each piece records itself in `st`.
  Future<void> _storeFilePieceOnDisk(
    String cid,
    int pieceIndex,
    int pieceCount,
    int pieceSize,
    int totalSize,
    Uint8List bytes,
    String? name,
  ) async {
    var meta = await _odMeta(cid);
    if (meta == null) {
      // First piece mints the blob identity — ONE constant-size meta row per
      // file. Piece presence is read from the FS ([OnDiskBlobStore
      // .piecesPresent]), NOT re-written here: the old per-piece meta rewrite
      // cost a padded commit PER PIECE (pure container bloat) and its growing
      // index list hit the ~4 KB chunk-payload cap at ~700 pieces — the hard
      // ceiling that kept the tier from TB-scale files.
      meta = <String, dynamic>{
        'fn': base64Url.encode(_randomBytes(12)), // opaque, FS-safe name
        'k': base64.encode(_randomBytes(32)), // per-blob AEAD key
        'sz': totalSize,
        'ps': pieceSize,
        'pc': pieceCount,
        'name': name,
      };
      await _putOdMeta(cid, meta);
    }

    // The minted layout is authoritative. A later piece that disagrees with it
    // is not a piece of this file, and storing it anyway puts bytes at an index
    // the read path will interpret under the RECORDED pieceSize — which returns
    // the wrong plaintext rather than failing, and passes its MAC while doing
    // it, because each piece is sealed independently.
    final pc = meta['pc'] as int;
    final ps = meta['ps'] as int;
    final sz = meta['sz'] as int;
    if (pieceCount != pc || pieceSize != ps || totalSize != sz) {
      throw StateError(
        'piece layout disagrees with the stored blob for $cid: '
        'got pc=$pieceCount ps=$pieceSize sz=$totalSize, have pc=$pc ps=$ps sz=$sz',
      );
    }
    if (pieceIndex < 0 || pieceIndex >= pc) {
      throw RangeError('piece index $pieceIndex outside [0, $pc) for $cid');
    }
    // Every piece but the last is full; the last carries the remainder. A short
    // middle piece would leave a hole that reads as zeroes at some later offset.
    final expected = pieceIndex == pc - 1 ? sz - pieceIndex * ps : ps;
    if (bytes.length != expected) {
      throw StateError(
        'piece $pieceIndex of $cid is ${bytes.length} bytes, layout says $expected',
      );
    }

    await _blobs!.storePiece(
      meta['fn'] as String,
      base64.decode(meta['k'] as String),
      pieceIndex,
      bytes,
    );
  }

  @override
  Future<int?> fileSize(String fileId) => _readFileSession((session) async {
    final meta = await _odMeta(fileId, store: session.store);
    _checkFileReadSession(session);
    if (meta != null) {
      final size = meta['sz'];
      return size is int ? size : null;
    }
    return AsyncFileStore(session.store).fileSize(fileId);
  });

  @override
  Future<Uint8List?> readFileRange(String fileId, int offset, int length) =>
      _readFileSession((session) async {
        final meta = await _odMeta(fileId, store: session.store);
        _checkFileReadSession(session);
        if (meta != null) {
          final blobs = session.blobs;
          if (blobs == null) return null;
          return blobs.readRange(
            meta['fn'] as String,
            base64.decode(meta['k'] as String),
            offset,
            length,
            meta['ps'] as int,
            meta['sz'] as int,
          );
        }
        return AsyncFileStore(
          session.store,
        ).readFileRange(fileId, offset, length);
      });

  // --- Ratchet sessions ----------------------------------------------------
  //
  // One conversation is one chunk RUN in [Ns.ratchet], keyed
  // `conversation key (64) ‖ chunk index (u16 BE)`. Chunked because a
  // hidden-volume KV value stops at 2 KiB and an exported session does not: an
  // established one is ~1.4 kB, but the skipped-message-key cache rides along
  // at 68 bytes per key banked for a frame that has not arrived, and veil caps
  // that at 256 KiB. A single-value scheme would have worked for months and
  // then started refusing to save exactly the conversations under load — the
  // ones with the most banked keys to lose.
  //
  // Chunk zero opens with the total length, so a run that is short by a record
  // reads back as ABSENT rather than as a truncated session. veil would refuse
  // the blob anyway ("rejects a blob it does not fully understand"), but the
  // failure belongs here, where it names the conversation.

  /// Bytes of blob per record. Half the 2 KiB KV ceiling on purpose: values
  /// live inline in the namespace's index leaves, and a 4 KiB leaf that fits
  /// one maximal value spends a whole tree level per conversation.
  static const int _kRatchetChunkBytes = 1024;

  /// Records per commit, bounded like the settings sweep. A conversation is
  /// never split across commits — see [saveRatchetStates].
  static const int _kRatchetOpsPerCommit = 128;

  /// Conversations written between vacuum passes.
  ///
  /// Replacing a KV value does not scrub the chunk that held the old one; it
  /// ORPHANS it, readable to anyone with the password until a vacuum reclaims
  /// it. For ordinary settings that is untidy. For this namespace it undoes the
  /// point: every superseded blob is a chain key the ratchet has already turned
  /// past, and forward secrecy that a password recovers is not forward secrecy.
  ///
  /// Amortized rather than per-save because the pass walks the container, and
  /// this runs on the path a send is waiting on. The window it leaves is
  /// bounded by a count, not by time — an idle profile does not sit on old keys
  /// because an idle profile is not producing any.
  static const int _kRatchetSavesPerScrub = 128;

  // A disjoint key shape in the existing protected namespace avoids consuming
  // another native namespace root (the on-disk format has a fixed root cap).
  // Ratchet keys are 66 bytes; authorization keys are 35 bytes, or one byte for
  // the layout marker. File/cache purges do not touch this namespace.
  static const _peerAuthorizationTag = 0x50;
  static const _peerAuthorizationChunkBytes = 1024;
  // Include the layout marker in this budget. Whole documents (including
  // obsolete tails) must stay in one transaction, never a flat split of ops.
  static const _peerAuthorizationOpsPerCommit = 64;
  static final _peerAuthorizationHeader = Uint8List.fromList([
    _peerAuthorizationTag,
  ]);
  static final _peerAuthorizationLayout = _sk('peer-authorization/1');
  static final _peerAuthorizationGates = Expando<Future<void>>(
    'peer authorization storage',
  );

  Future<T> _peerAuthorizationExclusive<T>(Future<T> Function() operation) {
    final previous = _peerAuthorizationGates[_as] ?? Future<void>.value();
    final result = previous.then((_) => operation());
    _peerAuthorizationGates[_as] = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  static Uint8List _peerAuthorizationKey(String peer, int chunk) {
    final key = Uint8List(35);
    key[0] = _peerAuthorizationTag;
    key.setRange(1, 33, NodeId.fromHex(peer).bytes);
    key[33] = chunk >> 8;
    key[34] = chunk & 255;
    return key;
  }

  static int _peerAuthorizationChunks(int bytes) =>
      (bytes + 4 + _peerAuthorizationChunkBytes - 1) ~/
      _peerAuthorizationChunkBytes;

  @override
  Future<List<PeerAuthorizationEntry>> loadPeerAuthorization() =>
      _peerAuthorizationExclusive(_loadPeerAuthorization);

  Future<List<PeerAuthorizationEntry>> _loadPeerAuthorization() async {
    final layout = await _as.get(Ns.ratchet, _peerAuthorizationHeader);
    if (layout != null && !_bytesEqual(layout, _peerAuthorizationLayout)) {
      throw const CorruptPeerAuthorizationState();
    }
    final chunksByPeer = <String, Set<int>>{};
    for (final key in await _as.kvKeys(Ns.ratchet)) {
      if (key.length == kRatchetKeyLen + 2 ||
          key.isEmpty ||
          key[0] != _peerAuthorizationTag ||
          key.length == 1) {
        continue;
      }
      if (key.length != 35 || layout == null) {
        throw const CorruptPeerAuthorizationState();
      }
      final peer = NodeId(Uint8List.sublistView(key, 1, 33)).hex;
      (chunksByPeer[peer] ??= <int>{}).add((key[33] << 8) | key[34]);
      if (chunksByPeer.length > PeerAuthorizationEntry.maxEntries) {
        throw const CorruptPeerAuthorizationState();
      }
    }
    final entries = <PeerAuthorizationEntry>[];
    for (final peer in chunksByPeer.keys) {
      final head = await _as.get(Ns.ratchet, _peerAuthorizationKey(peer, 0));
      if (head == null || head.length < 4) {
        throw const CorruptPeerAuthorizationState();
      }
      final length = ByteData.sublistView(head).getUint32(0);
      if (length == 0 || length > PeerAuthorizationEntry.maxDocumentBytes) {
        throw const CorruptPeerAuthorizationState();
      }
      final count = _peerAuthorizationChunks(length);
      if (chunksByPeer[peer]!.length != count ||
          !chunksByPeer[peer]!.containsAll(List.generate(count, (i) => i))) {
        throw const CorruptPeerAuthorizationState();
      }
      final bytes = Uint8List(length);
      var offset = 0;
      for (var index = 0; index < count; index++) {
        final chunk = index == 0
            ? head
            : await _as.get(Ns.ratchet, _peerAuthorizationKey(peer, index));
        final skip = index == 0 ? 4 : 0;
        final remaining = length - offset;
        final take = min(remaining, _peerAuthorizationChunkBytes - skip);
        if (chunk == null || chunk.length != skip + take) {
          throw const CorruptPeerAuthorizationState();
        }
        bytes.setRange(offset, offset + take, chunk, skip);
        offset += take;
      }
      entries.add(PeerAuthorizationEntry(peer, bytes));
    }
    return entries;
  }

  @override
  Future<void> replacePeerAuthorization(List<PeerAuthorizationEntry> entries) {
    if (entries.length > PeerAuthorizationEntry.maxEntries ||
        entries.map((e) => e.peer).toSet().length != entries.length) {
      throw const CorruptPeerAuthorizationState();
    }
    // Freeze and validate the complete input before any await or deletion.
    // A caller may reuse/mutate its buffers while the container worker runs.
    final snapshot = [
      for (final e in entries) PeerAuthorizationEntry(e.peer, e.document),
    ];
    return _peerAuthorizationExclusive(() async {
      final previous = {
        for (final e in await _loadPeerAuthorization()) e.peer: e,
      };
      var pending = <KvLogOp>[];
      Future<void> flush() async {
        if (pending.isEmpty) return;
        final ops = pending;
        pending = <KvLogOp>[];
        await _as.commit([
          PutOp(Ns.ratchet, _peerAuthorizationHeader, _peerAuthorizationLayout),
          ...ops,
        ]);
      }

      Future<void> queueWholeDocument(List<KvLogOp> ops) async {
        if (ops.length + 1 > _peerAuthorizationOpsPerCommit) {
          throw const CorruptPeerAuthorizationState();
        }
        if (pending.length + ops.length + 1 > _peerAuthorizationOpsPerCommit) {
          await flush();
        }
        pending.addAll(ops);
      }

      final wanted = snapshot.map((e) => e.peer).toSet();
      // These absences come from the authoritative native snapshot after host
      // restore. Its bounded policy only evicts entries without revocations.
      // Remove whole ordinary rows before adding replacements, so interruption
      // cannot leave more peers than the restore budget permits.
      for (final prior in previous.values) {
        if (wanted.contains(prior.peer)) continue;
        await queueWholeDocument([
          for (
            var i = 0;
            i < _peerAuthorizationChunks(prior.document.length);
            i++
          )
            DeleteOp(Ns.ratchet, _peerAuthorizationKey(prior.peer, i)),
        ]);
      }
      // Finish evictions before adding replacements: every committed prefix
      // remains within the restore budget, even after a failed later batch.
      await flush();
      for (final entry in snapshot) {
        final prior = previous[entry.peer];
        if (_bytesEqual(prior?.document, entry.document)) continue;
        // Entries can be created by code as well as the decoder. Revalidate
        // before publishing even if a caller mutated its byte array meanwhile.
        if (entry.document.isEmpty ||
            entry.document.length > PeerAuthorizationEntry.maxDocumentBytes) {
          throw const CorruptPeerAuthorizationState();
        }
        final stream = Uint8List(4 + entry.document.length);
        ByteData.sublistView(stream).setUint32(0, entry.document.length);
        stream.setRange(4, stream.length, entry.document);
        final count = _peerAuthorizationChunks(entry.document.length);
        await queueWholeDocument([
          for (var i = 0; i < count; i++)
            PutOp(
              Ns.ratchet,
              _peerAuthorizationKey(entry.peer, i),
              Uint8List.sublistView(
                stream,
                i * _peerAuthorizationChunkBytes,
                min(stream.length, (i + 1) * _peerAuthorizationChunkBytes),
              ),
            ),
          if (prior != null)
            for (
              var i = count;
              i < _peerAuthorizationChunks(prior.document.length);
              i++
            )
              DeleteOp(Ns.ratchet, _peerAuthorizationKey(entry.peer, i)),
        ]);
      }
      // The caller may ACK only after ALL batches have committed. A failure
      // leaves complete old/new documents and the native revision pending.
      await flush();
    });
  }

  // One protected byte, committed WITH the replacement states. A RAM-only
  // count can be reset indefinitely by restarts, or carried into another
  // identity when a Storage handle switches spaces. Unlike settings, this
  // namespace is not cleared by cache/file maintenance. 0x53 is disjoint
  // from both the 66-byte session keys and the authorization layout (0x50).
  static final _ratchetCleanupKey = Uint8List.fromList([0x53]);
  int? _ratchetSavesSinceScrub;
  Future<void> _ratchetIoGate = Future<void>.value();
  int _ratchetIoFences = 0;

  // This view is the space's sole ratchet writer; all writes join the gate
  // below. Remember only confirmed committed run lengths, never session blobs.
  // A send otherwise pays another worker round trip just to read the head
  // it wrote itself. Bound the cache and discard it on uncertain outcomes or
  // lifecycle changes. Authorization rows have a disjoint key shape.
  static const _ratchetChunkCacheLimit = 128;
  final _ratchetCommittedChunks = <String, int>{};

  void _rememberRatchetChunks(String key, int chunks) {
    _ratchetCommittedChunks.remove(key);
    _ratchetCommittedChunks[key] = chunks;
    if (_ratchetCommittedChunks.length > _ratchetChunkCacheLimit) {
      _ratchetCommittedChunks.remove(_ratchetCommittedChunks.keys.first);
    }
  }

  Future<T> _withRatchetIo<T>(Future<T> Function() operation) {
    if (_closePending != null || _ratchetIoFences > 0) {
      return Future<T>.error(StateError('ratchet storage is closing'));
    }
    final session = _store;
    if (session == null) {
      return Future<T>.error(StateError('ratchet storage is locked'));
    }
    final result = _ratchetIoGate.then((_) async {
      if (!identical(session, _store)) {
        throw StateError('storage session changed before ratchet operation');
      }
      try {
        return await operation();
      } catch (_) {
        // A commit may have reached disk even if its reply was lost. Never
        // use an old run length to prune that possibly newer durable state.
        _ratchetCommittedChunks.clear();
        _ratchetSavesSinceScrub = null;
        rethrow;
      }
    });
    _ratchetIoGate = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Future<T> _drainRatchetIo<T>(Future<T> Function() operation) async {
    _ratchetIoFences++;
    try {
      // Queue maintenance as well as waiting for earlier accepted operations.
      // No new ratchet work can join until this maintenance has finished.
      final result = _ratchetIoGate.then((_) => operation());
      _ratchetIoGate = result.then<void>((_) {}, onError: (_) {});
      return await result;
    } finally {
      _ratchetIoFences--;
    }
  }

  PutOp _ratchetBudgetOp(int count) =>
      PutOp(Ns.ratchet, _ratchetCleanupKey, Uint8List.fromList([count]));

  // Called only under the ratchet IO gate. Already-open multi-space views
  // need this lazily too, before exposing persisted keys to the native node.
  Future<void> _recoverRatchetCleanup({bool opening = false}) async {
    if (_ratchetSavesSinceScrub == null) {
      final raw = await _as.get(Ns.ratchet, _ratchetCleanupKey);
      if (raw == null) {
        final keys = await _as.kvKeys(Ns.ratchet);
        // Old stores have no count. A live run (including a headless damaged
        // run) can have superseded chunks: reclaim once before restoring it.
        _ratchetSavesSinceScrub =
            keys.any((k) => k.length == kRatchetKeyLen + 2)
            ? _kRatchetSavesPerScrub
            : 0;
      } else {
        // Damaged metadata must not silently waive the cleanup obligation.
        _ratchetSavesSinceScrub = raw.length == 1
            ? min(raw[0], _kRatchetSavesPerScrub)
            : _kRatchetSavesPerScrub;
      }
    }
    if (_ratchetSavesSinceScrub! < _kRatchetSavesPerScrub) return;
    if (opening) {
      _anchorBeforeDeletionRecovery ??= await readCommitAnchor();
    }
    await _as.scrub();
    // Keep the durable obligation until BOTH erasure and its completion
    // commit succeed. A crash here merely repeats a safe vacuum on reopen.
    await _as.commit([_ratchetBudgetOp(0)]);
    _ratchetSavesSinceScrub = 0;
    // Vacuum preserves live log IDs/values, so retain the warm message fold.
  }

  /// `conversation key ‖ chunk index`, the record key.
  static Uint8List _ratchetRecordKey(Uint8List conversationKey, int chunk) {
    final out = Uint8List(kRatchetKeyLen + 2);
    out.setRange(0, kRatchetKeyLen, conversationKey);
    out[kRatchetKeyLen] = (chunk >> 8) & 0xff;
    out[kRatchetKeyLen + 1] = chunk & 0xff;
    return out;
  }

  /// How many records a blob of [blobLen] bytes occupies (length prefix
  /// included). Never zero: an empty run and an absent conversation must not
  /// look the same.
  static int _ratchetChunkCount(int blobLen) =>
      ((4 + blobLen) + _kRatchetChunkBytes - 1) ~/ _kRatchetChunkBytes;

  @override
  Future<List<Uint8List>> ratchetConversationKeys() => _withRatchetIo(() async {
    await _recoverRatchetCleanup();
    final keys = await _as.kvKeys(Ns.ratchet);
    final out = <Uint8List>[];
    for (final k in keys) {
      // Only the head record names a conversation. Counting every record would
      // return one "conversation" per chunk of a big one.
      if (k.length != kRatchetKeyLen + 2) continue;
      if (k[kRatchetKeyLen] != 0 || k[kRatchetKeyLen + 1] != 0) continue;
      out.add(Uint8List.fromList(k.sublist(0, kRatchetKeyLen)));
    }
    return out;
  });

  @override
  Future<Uint8List?> loadRatchetState(Uint8List conversationKey) =>
      _withRatchetIo(() async {
        await _recoverRatchetCleanup();
        if (conversationKey.length != kRatchetKeyLen) return null;
        final head = await _as.get(
          Ns.ratchet,
          _ratchetRecordKey(conversationKey, 0),
        );
        if (head == null || head.length < 4) return null;
        final total =
            (head[0] << 24) | (head[1] << 16) | (head[2] << 8) | head[3];
        if (total <= 0 || total > kRatchetMaxStateLen) return null;
        final out = Uint8List(total);
        var filled = 0;
        void take(Uint8List record, int from) {
          final n = record.length - from;
          if (n <= 0) return;
          final room = total - filled;
          final take = n < room ? n : room;
          out.setRange(filled, filled + take, record, from);
          filled += take;
        }

        take(head, 4);
        final chunks = _ratchetChunkCount(total);
        for (var i = 1; i < chunks; i++) {
          final part = await _as.get(
            Ns.ratchet,
            _ratchetRecordKey(conversationKey, i),
          );
          // A missing record means the run is incomplete. Half a session is a
          // session with the WRONG keys, so answer "nothing held" and let the
          // conversation re-key rather than importing a lie.
          if (part == null) return null;
          take(part, 0);
        }
        return filled == total ? out : null;
      });

  @override
  Future<void> saveRatchetStates(List<RatchetStateEntry> entries) async {
    final paired = entries.any((entry) => entry.sendReservation != null);
    final snapshots = <RatchetStateEntry>[];
    // Paired state and marks describe one immutable publication. Freeze them
    // before the worker/gate can yield; ordinary legacy saves retain their
    // existing buffer ownership contract.
    for (final entry in entries) {
      if (entry.conversationKey.length != kRatchetKeyLen) {
        throw ArgumentError.value(
          entry.conversationKey.length,
          'conversationKey',
          'a conversation key is exactly 64 bytes',
        );
      }
      if (entry.blob.isEmpty || entry.blob.length > kRatchetMaxStateLen) {
        throw ArgumentError.value(
          entry.blob.length,
          'blob',
          'implausible ratchet state length',
        );
      }
      final reservation = entry.sendReservation;
      if (reservation != null) {
        if (utf8.encode(reservation).length > 2048) {
          throw const RatchetSnapshotReservationTooLarge();
        }
        if (_ratchetChunkCount(entry.blob.length) + 2 > _kRatchetOpsPerCommit) {
          throw const RatchetSnapshotReservationTooLarge();
        }
      }
      snapshots.add(
        paired
            ? RatchetStateEntry(
                Uint8List.fromList(entry.conversationKey),
                Uint8List.fromList(entry.blob),
                sendReservation: reservation,
              )
            : entry,
      );
    }
    await _withRatchetIo(() async {
      if (snapshots.isEmpty) return;
      await _recoverRatchetCleanup();
      var pending = <KvLogOp>[];
      var pendingChunks = <String, int>{};
      var pendingSaves = 0;
      Future<void> flush() async {
        if (pending.isEmpty) return;
        final ops = pending;
        pending = <KvLogOp>[];
        final committedChunks = pendingChunks;
        pendingChunks = <String, int>{};
        final count = min(
          _ratchetSavesSinceScrub! + pendingSaves,
          _kRatchetSavesPerScrub,
        );
        await _as.commit([...ops, _ratchetBudgetOp(count)]);
        for (final entry in committedChunks.entries) {
          _rememberRatchetChunks(entry.key, entry.value);
        }
        _ratchetSavesSinceScrub = count;
        pendingSaves = 0;
        await _recoverRatchetCleanup();
      }

      for (final entry in snapshots) {
        final stream = Uint8List(4 + entry.blob.length);
        stream[0] = (entry.blob.length >> 24) & 0xff;
        stream[1] = (entry.blob.length >> 16) & 0xff;
        stream[2] = (entry.blob.length >> 8) & 0xff;
        stream[3] = entry.blob.length & 0xff;
        stream.setRange(4, stream.length, entry.blob);

        final chunks = _ratchetChunkCount(entry.blob.length);
        final ops = <KvLogOp>[];
        for (var i = 0; i < chunks; i++) {
          final start = i * _kRatchetChunkBytes;
          final end = start + _kRatchetChunkBytes < stream.length
              ? start + _kRatchetChunkBytes
              : stream.length;
          ops.add(
            PutOp(
              Ns.ratchet,
              _ratchetRecordKey(entry.conversationKey, i),
              Uint8List.sublistView(stream, start, end),
            ),
          );
        }
        // A shrinking session (skipped keys got claimed) leaves records past the
        // new tail. Left behind, the NEXT read would stop at the length prefix
        // and never notice them — but a later, longer save would then reuse them
        // as if they were its own, splicing bytes from two points in the chain.
        final cacheKey = base64Encode(entry.conversationKey);
        final priorChunks =
            pendingChunks[cacheKey] ??
            await _ratchetStoredChunkCount(
              entry.conversationKey,
              useCache: true,
            );
        for (var i = chunks; i < priorChunks; i++) {
          ops.add(
            DeleteOp(Ns.ratchet, _ratchetRecordKey(entry.conversationKey, i)),
          );
        }
        final reservation = entry.sendReservation;
        if (reservation != null) {
          ops.add(
            PutOp(
              Ns.settings,
              _sk('set:${ratchetReservationSettingKey(entry.conversationKey)}'),
              _sk(reservation),
            ),
          );
          // Old tails count too. Signal a bounded optimization fallback rather
          // than silently omitting the reservation or splitting the entry.
          if (ops.length + 1 > _kRatchetOpsPerCommit) {
            throw const RatchetSnapshotReservationTooLarge();
          }
        }
        // Conversations are whole or absent: never let one straddle two commits,
        // however large it is, or a crash between them restores a session whose
        // halves came from different points in the chain.
        if (pending.isNotEmpty &&
            pending.length + ops.length + 1 > _kRatchetOpsPerCommit) {
          await flush();
        }
        pending.addAll(ops);
        pendingChunks[cacheKey] = chunks;
        pendingSaves++;
        if (pending.length + 1 >= _kRatchetOpsPerCommit ||
            _ratchetSavesSinceScrub! + pendingSaves >= _kRatchetSavesPerScrub) {
          await flush();
        }
      }
      await flush();
    });
  }

  @override
  Future<int> forgetRatchetStates(
    Iterable<Uint8List> conversationKeys,
  ) => _withRatchetIo(() async {
    await _recoverRatchetCleanup();
    var pending = <KvLogOp>[];
    var pendingKeys = <String>[];
    var forgotten = 0;
    var wrote = false;
    Future<void> flush() async {
      if (pending.isEmpty) return;
      final ops = pending;
      pending = <KvLogOp>[];
      // Deletion requires immediate cleanup. Persist that requirement even
      // when a crash removes the last live head before the vacuum can run.
      await _as.commit([...ops, _ratchetBudgetOp(_kRatchetSavesPerScrub)]);
      for (final key in pendingKeys) {
        _ratchetCommittedChunks.remove(key);
      }
      pendingKeys = <String>[];
      _ratchetSavesSinceScrub = _kRatchetSavesPerScrub;
      wrote = true;
    }

    for (final key in conversationKeys) {
      if (key.length != kRatchetKeyLen) continue;
      final chunks = await _ratchetStoredChunkCount(key);
      if (chunks == 0) continue;
      forgotten++;
      final ops = <KvLogOp>[
        for (var i = 0; i < chunks; i++)
          DeleteOp(Ns.ratchet, _ratchetRecordKey(key, i)),
      ];
      // The same rule [saveRatchetStates] keeps, for the same reason facing
      // the other way. This used to cut a flat list of every conversation's
      // deletes every 128 ops, so a conversation straddled a commit boundary
      // whenever the total crossed one — which any multi-conversation
      // `forgetPeer` does. A crash between the two halves took the head
      // record, so the read path answered "nothing held" and nothing ever
      // looked for the rest: the tail chunks stayed on disk, holding chain
      // keys, unreachable and never scrubbed. Forward secrecy a password
      // still opens is the thing this namespace exists to prevent.
      if (pending.isNotEmpty &&
          pending.length + ops.length + 1 > _kRatchetOpsPerCommit) {
        await flush();
      }
      pending.addAll(ops);
      pendingKeys.add(base64Encode(key));
      if (pending.length + 1 >= _kRatchetOpsPerCommit) await flush();
    }
    await flush();
    // The bytes are key material, so the records they occupied are reclaimed
    // rather than orphaned — a tombstone that leaves the old chunk readable to
    // a key-holder is not forgetting.
    if (wrote) await _recoverRatchetCleanup();
    return forgotten;
  });

  /// Records currently stored for [conversationKey], read from its head
  /// record's length prefix (0 when nothing is held).
  Future<int> _ratchetStoredChunkCount(
    Uint8List conversationKey, {
    bool useCache = false,
  }) async {
    if (useCache) {
      final cached = _ratchetCommittedChunks[base64Encode(conversationKey)];
      if (cached != null) return cached;
    }
    final head = await _as.get(
      Ns.ratchet,
      _ratchetRecordKey(conversationKey, 0),
    );
    if (head == null || head.length < 4) return 0;
    final total = (head[0] << 24) | (head[1] << 16) | (head[2] << 8) | head[3];
    if (total <= 0 || total > kRatchetMaxStateLen) return 0;
    return _ratchetChunkCount(total);
  }

  @override
  Future<Message> appendMessage(Message message) async {
    if (_store == null || _convSequenceFences > 0) {
      throw StateError('storage is closing or locked');
    }
    // History/wire rows already own their sequence. Coalesce only bounded,
    // inline payloads; local allocation and fragmented records keep their
    // existing per-author transaction path and are barriers to this batch.
    if (message.author != null &&
        message.seq != null &&
        message.body.length <= _messageInlineBytes &&
        (message.thumb?.length ?? 0) <= _messageInlineBytes) {
      final frozen = message.copyWith(
        customEmoji: List.unmodifiable(message.customEmoji),
      );
      final payload = _sk(_encodeMessage(frozen));
      if (payload.length <= _messageInlineBytes) {
        final key = (message.conversationId, message.author!);
        final pending = _positionedMessageAppends[key];
        if (pending != null && pending.payloads.length < 16) {
          pending.payloads.add(payload);
          await pending.result;
          return frozen;
        }
        final batch = _PositionedMessageAppends()..payloads.add(payload);
        batch.result =
            _withConvSequence(key.$1, key.$2, () async {
              // Seal before any I/O. Later arrivals need the next sequence turn.
              if (identical(_positionedMessageAppends[key], batch)) {
                _positionedMessageAppends.remove(key);
              }
              await _commitPositionedMessageBatch(batch.payloads);
            }).whenComplete(() {
              if (identical(_positionedMessageAppends[key], batch)) {
                _positionedMessageAppends.remove(key);
              }
            });
        _positionedMessageAppends[key] = batch;
        await batch.result;
        return frozen;
      }
    }
    return _withConvSequence(
      message.conversationId,
      message.author ?? message.conversationId,
      () => _appendMessage(message),
    );
  }

  @override
  Future<List<PreparedMessageWrite>?> appendMissingMessageBatch(
    List<Message> messages, {
    required Future<void> Function() beforeCommit,
  }) {
    if (messages.length > preparedMessageBatchMaxRows) {
      return Future.value(null);
    }
    final frozen = <Message>[];
    final payloads = <Uint8List>[];
    final ids = <(String, String)>{};
    for (final message in messages) {
      if (!ids.add((message.conversationId, message.id))) {
        return Future.error(ArgumentError('duplicate prepared message'));
      }
      if (message.author == null ||
          message.seq == null ||
          message.body.length > _messageInlineBytes ||
          (message.thumb?.length ?? 0) > _messageInlineBytes) {
        return Future.value(null);
      }
      final copy = message.copyWith(
        customEmoji: List.unmodifiable(message.customEmoji),
      );
      final payload = _sk(_encodeMessage(copy));
      if (payload.length > _messageInlineBytes) return Future.value(null);
      frozen.add(copy);
      payloads.add(payload);
    }
    if (frozen.isEmpty) return Future.value(const []);
    final keys =
        {for (final row in frozen) (row.conversationId, row.author!)}.toList()
          ..sort((a, b) {
            final c = a.$1.compareTo(b.$1);
            return c != 0 ? c : a.$2.compareTo(b.$2);
          });
    Future<List<PreparedMessageWrite>?> acquire(int index) =>
        index == keys.length
        ? _serialized(() async {
            final checkErasure = _preparedErasureCheck();
            await _foldCritical();
            final selected = <Uint8List>[];
            final results = <PreparedMessageWrite>[];
            for (var i = 0; i < frozen.length; i++) {
              final row = frozen[i],
                  key = _msgKey(frozen[i].conversationId, frozen[i].id);
              final clear = _clearedWatermark[row.conversationId]?[row.author];
              if (_scanDeletedKeys.contains(key) ||
                  _scanDeletedLegacyIds.contains(row.id) ||
                  row.timestamp.millisecondsSinceEpoch <=
                      (_clearedAt[row.conversationId] ?? -1) ||
                  (clear != null &&
                      row.seq! <= clear.seq &&
                      row.timestamp.millisecondsSinceEpoch <= clear.at)) {
                results.add(PreparedMessageWrite.suppressed);
              } else if (_scanById.containsKey(key)) {
                results.add(PreparedMessageWrite.existing);
              } else {
                selected.add(payloads[i]);
                results.add(PreparedMessageWrite.appended);
              }
            }
            if (selected.isNotEmpty) {
              await _commitPositionedMessageBatch(
                selected,
                beforeCommit: beforeCommit,
                checkBeforePublish: checkErasure,
              );
            }
            return List.unmodifiable(results);
          })
        : _withConvSequence(
            keys[index].$1,
            keys[index].$2,
            () => acquire(index + 1),
            acceptedBeforeFence: index > 0,
          );
    return acquire(0);
  }

  Future<Message> _appendMessage(Message message) async {
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
            reflectedEdit: message.reflectedEdit,
            fileId: message.fileId,
            fileName: message.fileName,
            fileSize: message.fileSize,
            fileContentId: message.fileContentId,
            fileExternal: message.fileExternal,
            thumb: message.thumb,
            customEmoji: message.customEmoji,
            replyToId: message.replyToId,
            forwardedFrom: message.forwardedFrom,
            author: author,
            seq: seq,
            positionVerified: message.positionVerified,
          );
    await _commitAtNextMessageLogId(
      (namespace, logId) => [
        AppendLogOp(namespace, logId, _sk(_encodeMessage(stored))),
        // Advance the per-(conv,author) seq cursor ONLY when we ALLOCATED it (a
        // wire event with its own seq must not bump our local counter — the two
        // streams are independent and reconciled by the fold/sync, not here).
        if (message.seq == null)
          PutOp(
            Ns.settings,
            _sk('conv_seq:${message.conversationId}:$author'),
            _sk('${seq + 1}'),
          ),
      ],
    );
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
  Future<List<bool>?> adoptMessageOrderingBatch(
    List<MessageOrderingAdoption> requests, {
    required Future<void> Function() beforeCommit,
  }) {
    if (requests.length > preparedMessageBatchMaxRows) {
      return Future.value(null);
    }
    final frozen = List<MessageOrderingAdoption>.of(requests);
    if (frozen.isEmpty) return Future.value(const []);
    final ids = <(String, String)>{};
    for (final request in frozen) {
      if (!ids.add((request.conversationId, request.messageId))) {
        return Future.error(ArgumentError('duplicate prepared ordering'));
      }
      if (_orderingPayload(request).length > _messageInlineBytes) {
        return Future.value(null);
      }
    }
    final keys =
        {
          for (final r in frozen) (r.conversationId, r.provisionalAuthor),
        }.toList()..sort((a, b) {
          final c = a.$1.compareTo(b.$1);
          return c != 0 ? c : a.$2.compareTo(b.$2);
        });
    Future<List<bool>?> acquire(int index) => index == keys.length
        ? _serialized(
            () => _adoptOrderingCritical(frozen, beforeCommit: beforeCommit),
          )
        : _withConvSequence(
            keys[index].$1,
            keys[index].$2,
            () => acquire(index + 1),
            acceptedBeforeFence: index > 0,
          );
    return acquire(0);
  }

  Future<List<bool>> _adoptOrderingCritical(
    List<MessageOrderingAdoption> requests, {
    Future<void> Function()? beforeCommit,
  }) async {
    // Prepared history publication owns an explicit admission checkpoint and
    // must not cross erasure. Ordinary body-less corrections instead retain
    // the oversized path's behavior: a concurrent tombstone wins in the fold.
    final checkErasure = beforeCommit == null ? null : _preparedErasureCheck();
    await _foldCritical();
    final outcomes = <bool>[];
    final payloads = <Uint8List>[];
    for (final request in requests) {
      final matches = _canAdoptOrdering(request);
      outcomes.add(matches);
      if (matches) payloads.add(_orderingPayload(request));
    }
    if (payloads.isNotEmpty) {
      await _commitPositionedMessageBatch(
        payloads,
        beforeCommit: beforeCommit,
        checkBeforePublish: checkErasure,
      );
      await _foldCritical();
    }
    return List.unmodifiable(outcomes);
  }

  bool _canAdoptOrdering(MessageOrderingAdoption request) {
    final held = _scanById[_msgKey(request.conversationId, request.messageId)];
    return held != null &&
        held.direction == MessageDirection.outgoing &&
        held.author == request.provisionalAuthor &&
        held.seq == request.provisionalSeq &&
        held.ordering == null;
  }

  Uint8List _orderingPayload(MessageOrderingAdoption request) => _sk(
    jsonEncode({
      'op': 'ordering',
      'k': EventKind.void_.index,
      'c': request.conversationId,
      'id': request.messageId,
      'fromAu': request.provisionalAuthor,
      'fromSq': request.provisionalSeq,
      'orderAu': request.author,
      'orderSq': request.seq,
    }),
  );

  @override
  Future<bool> adoptMessageOrdering(
    String conversationId,
    String messageId, {
    required String provisionalAuthor,
    required int provisionalSeq,
    required String author,
    required int seq,
  }) {
    final request = MessageOrderingAdoption(
      conversationId: conversationId,
      messageId: messageId,
      provisionalAuthor: provisionalAuthor,
      provisionalSeq: provisionalSeq,
      author: author,
      seq: seq,
    );
    final size = _orderingPayload(request).length;
    if (size > _messageInlineBytes) {
      // Keep the existing fragmented path for a single oversized record.
      // It is still a sequence turn and a barrier to either kind of cohort.
      return _withConvSequence(
        conversationId,
        provisionalAuthor,
        () => _serialized(() => _adoptLargeOrderingCritical(request)),
      );
    }
    return _queueOrderingAdoption(request, size);
  }

  Future<bool> _queueOrderingAdoption(
    MessageOrderingAdoption request,
    int size,
  ) {
    if (_store == null || _convSequenceFences > 0) {
      return Future.error(StateError('storage is closing or locked'));
    }
    final key = (request.conversationId, request.provisionalAuthor);
    final pending = _pendingOrderingAdoptions[key];
    if (pending != null &&
        pending.requests.length < 16 &&
        pending.bytes + size <= _messageInlineBytes &&
        !pending.requests.any((r) => r.messageId == request.messageId)) {
      final index = pending.requests.length;
      pending.requests.add(request);
      pending.bytes += size;
      return pending.result.then((outcomes) => outcomes[index]);
    }
    final batch = _PendingOrderingAdoptions()
      ..requests.add(request)
      ..bytes = size;
    batch.result =
        _withConvSequence(key.$1, key.$2, () {
          // Seal at the start of this turn, before any read or native commit.
          if (identical(_pendingOrderingAdoptions[key], batch)) {
            _pendingOrderingAdoptions.remove(key);
          }
          return _serialized(() => _adoptOrderingCritical(batch.requests));
        }).whenComplete(() {
          if (identical(_pendingOrderingAdoptions[key], batch)) {
            _pendingOrderingAdoptions.remove(key);
          }
        });
    _pendingOrderingAdoptions[key] = batch;
    return batch.result.then((outcomes) => outcomes.first);
  }

  Future<bool> _adoptLargeOrderingCritical(
    MessageOrderingAdoption request,
  ) async {
    await _foldCritical();
    if (!_canAdoptOrdering(request)) return false;
    // A body-less local metadata record. Older folds see an inert void with no
    // sequence slot; exporters see no au/sq. In particular this cannot re-ship
    // the contact's unverified echo as a new send from our physical device.
    // Appending, rather than rewriting the post, also makes a concurrent local
    // delete/clear authoritative: the correction cannot resurrect its body.
    await _commitAtNextMessageLogId(
      (namespace, logId) => [
        AppendLogOp(namespace, logId, _orderingPayload(request)),
      ],
    );
    await _foldCritical();
    return true;
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
    final entries = await _messageLogEntries();
    final rows = <Map<String, dynamic>>[];
    // Whether this conversation holds OUR outgoing rows under our own author —
    // what the app writes for every message it sends (see the skip below).
    var ownAuthoredOutgoing = false;
    for (final e in entries) {
      final m = jsonDecode(utf8.decode(e.payload)) as Map<String, dynamic>;
      if (m['c'] != conv) continue;
      rows.add(m);
      if (m['d'] == MessageDirection.outgoing.index &&
          m['au'] is String &&
          m['au'] != conv) {
        ownAuthoredOutgoing = true;
      }
    }
    for (final m in rows) {
      // A status op carries no (author, seq) and consumes no seq — skip it. Every
      // other row (post / edit / void / seq-bearing del tombstone) carries au+sq.
      if (m['op'] == 'status' || m['op'] == 'sig' || m['er'] == true) continue;
      final au = m['au'];
      final sq = m['sq'];
      // A legacy pre-event-log row (or a tombstone of one) has no au/sq → it
      // contributes no high-water for its author (R17 mixed-pair degrade).
      if (au is! String || sq is! int || sq <= 0) continue;
      // An OUTGOING row credited to the peer is not the peer's: a mirror from
      // my other device used to land our own sent messages under the
      // conversation's default author with a locally allocated seq. Counted,
      // they ran the peer's high-water past what we hold of it, and the peer
      // re-shipped nothing to a device that had missed its messages.
      // Only where the app's own sent rows prove what "ours" looks like; a
      // log written without authors credits every row to the peer by default.
      if (ownAuthoredOutgoing &&
          au == conv &&
          m['d'] == MessageDirection.outgoing.index) {
        continue;
      }
      (seqsByAuthor[au] ??= <int>{}).add(sq);
    }
    final highWater = <String, int>{};
    final holes = <String, List<(int, int)>>{};
    // Authors to consider: everyone with rows, plus the conversation peer (in a
    // 1:1 chat the conv id IS the peer's author hex) — a peer whose rows were
    // all cleared can still carry a declared floor that must surface as its
    // high-water, or its next live message re-opens the phantom-hole loop.
    final authors = <String>{...seqsByAuthor.keys, conv};
    for (final author in authors) {
      final seqs = seqsByAuthor[author] ?? const <int>{};
      // The author's declared gap-fill floor: seqs ≤ floor no longer exist at
      // the source (history cleared/erased there) — they are consumed by
      // definition, NOT holes. See [applyAuthorSyncFloor].
      final floor = await _syncFloor(conv, author);
      if (seqs.isEmpty && floor <= 0) continue;
      // Contiguous high-water: the longest gap-free prefix above the floor.
      var hw = floor;
      while (seqs.contains(hw + 1)) {
        hw++;
      }
      highWater[author] = hw;
      if (seqs.isEmpty) continue;
      // Interior holes: the missing seqs strictly between the high-water and the
      // highest observed seq, coalesced into ranges. (Nothing above max is a
      // "hole" — those unseen seqs are covered by the high-water "ship me newer"
      // query, not a named re-request.)
      //
      // Derived by WALKING THE SEQS WE HOLD, in order — never by counting up
      // through the numeric range. A hole is the span between two consecutive
      // stored seqs, so the work is O(rows·log rows), bounded by what is
      // actually in the log. Counting from hw+1 to max instead made the cost
      // track the seq VALUE, which an accepted peer chooses: one ~60-byte frame
      // naming a large seq (a void slot stores one, and renders nothing at all)
      // bought minutes of a blocked isolate; at the 64-bit maximum `s++`
      // overflowed to the minimum negative and `s <= max` was true again, so the
      // loop never ended — permanently, since the fold re-runs on every start.
      final above = seqs.where((s) => s > hw).toList()..sort();
      final ranges = <(int, int)>[];
      var previous = hw;
      for (final s in above) {
        if (s > previous + 1) ranges.add((previous + 1, s - 1));
        previous = s;
      }
      if (ranges.isNotEmpty) holes[author] = ranges;
    }
    return (highWater: highWater, holes: holes);
  }

  String _syncFloorKey(String conv, String author) =>
      'sync_floor:$conv:$author';

  Future<int> _syncFloor(String conv, String author) async {
    final raw = await _as.get(
      Ns.settings,
      _sk('set:${_syncFloorKey(conv, author)}'),
    );
    if (raw == null) return 0;
    return int.tryParse(utf8.decode(raw, allowMalformed: true)) ?? 0;
  }

  @override
  Future<void> applyAuthorSyncFloor(
    String conversationId,
    String author,
    int floor,
  ) async {
    if (floor <= 0) return;
    // Monotonic max-merge; putSetting's no-change shield makes re-applies free.
    if (await _syncFloor(conversationId, author) >= floor) return;
    await putSetting(_syncFloorKey(conversationId, author), '$floor');
  }

  @override
  Future<int> ownSyncFloor(String conversationId, String author) =>
      _serialized(() async {
        // Lowest own event still stored → floor is one below it; nothing stored
        // at all → everything ever emitted (next-seq counter − 1) is gone.
        int? minSeq;
        final entries = await _messageLogEntries();
        for (final e in entries) {
          final m = jsonDecode(utf8.decode(e.payload)) as Map<String, dynamic>;
          if (m['c'] != conversationId ||
              m['op'] == 'status' ||
              m['op'] == 'sig' ||
              m['er'] == true) {
            continue;
          }
          if (m['au'] != author) continue;
          final sq = m['sq'];
          if (sq is! int || sq <= 0) continue;
          if (minSeq == null || sq < minSeq) minSeq = sq;
        }
        if (minSeq != null) return minSeq - 1;
        return await _nextConvSeq(conversationId, author) - 1;
      });

  @override
  Future<List<LogEvent>> loadEventsSince(
    String conversationId,
    String author,
    int fromSeq, {
    int limit = 200,
  }) => _serialized(
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
    final entries = await _messageLogEntries();
    final events = <LogEvent>[];
    for (final e in entries) {
      final m = jsonDecode(utf8.decode(e.payload)) as Map<String, dynamic>;
      if (m['c'] != conv ||
          m['op'] == 'status' ||
          m['op'] == 'sig' ||
          m['er'] == true) {
        continue;
      }
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
          replyTo: null,
          forwardedFrom: null,
          customEmoji: const [],
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
          replyTo: null,
          forwardedFrom: null,
          customEmoji: parseInlineCustomEmoji(m['b'] as String? ?? '', m['ce']),
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
          replyTo: m['rt'] as String?,
          forwardedFrom: m['fw'] as String?,
          customEmoji: parseInlineCustomEmoji(m['b'] as String? ?? '', m['ce']),
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
    final entries = await _messageLogEntries();
    for (final e in entries) {
      final m = jsonDecode(utf8.decode(e.payload)) as Map<String, dynamic>;
      if (m['c'] == conversationId &&
          m['au'] == author &&
          m['sq'] == seq &&
          m['op'] != 'status' &&
          m['op'] != 'sig') {
        return; // slot present — nothing to do
      }
    }
    await _commitAtNextMessageLogId(
      (namespace, logId) => [
        AppendLogOp(
          namespace,
          logId,
          // An inert void slot: no id/tg/body (§12.1) — the fold renders nothing,
          // conversationSync counts (au, sq) so the per-author high-water advances.
          _sk(
            jsonEncode({
              'k': EventKind.void_.index,
              'c': conversationId,
              'au': author,
              'sq': seq,
            }),
          ),
        ),
      ],
    );
    await _patchCache(() {});
  }

  /// Decode a persisted attestation-state index safely (absent / out-of-range →
  /// [MessageSignature.none], so legacy rows and forward-compat both hold).
  static MessageSignature _sigFromIndex(Object? raw) {
    if (raw is int && raw >= 0 && raw < MessageSignature.values.length) {
      return MessageSignature.values[raw];
    }
    return MessageSignature.none;
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
    if (m.positionVerified != null) 'pv': m.positionVerified,
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
    if (m.reflectedEdit) 'er': true,
    if (m.fileId != null) 'fi': m.fileId,
    if (m.fileName != null) 'fn': m.fileName,
    if (m.fileSize != null) 'fs': m.fileSize,
    if (m.fileContentId != null) 'fc': m.fileContentId,
    if (m.fileExternal) 'fx': 1, // blob in the external store, not in-container
    // Embedded micro-thumb (b64 PNG) — additive; old builds ignore the key.
    if (m.thumb != null) 'tb': m.thumb,
    if (m.customEmoji.isNotEmpty) 'ce': encodeInlineCustomEmoji(m.customEmoji),
    if (m.replyToId != null) 'rt': m.replyToId,
    if (m.forwardedFrom != null) 'fw': m.forwardedFrom,
    // Opt-in attestation state (omitted when `none` so legacy rows stay clean).
    if (m.signature != MessageSignature.none) 'sig': m.signature.index,
  });

  Future<int> _nextLogId() async {
    final store = _as;
    if (identical(store, _allocatorStore) && _visibleNextLogId != null) {
      return _visibleNextLogId!;
    }
    final raw = await store.get(Ns.settings, _sk('msg_next_id'));
    if (raw == null) return 1;
    return int.tryParse(utf8.decode(raw)) ?? 1;
  }

  static const _messageLogNamespaceMarkerPrefix = 'msglog_ns:v1:';

  /// Discover every namespace that may contain message rows.
  ///
  /// One tiny, monotonic marker is committed BEFORE the first record in each
  /// shard. Reading only marked shards avoids probing hundreds of empty
  /// namespaces when the shared global log-id counter grew mostly through the
  /// outbox/call journal. Markers contain only a namespace byte — no
  /// conversation or message metadata.
  Future<void> _ensureMessageLogNamespacesLoaded() async {
    final existing = _messageLogNamespacesInit;
    if (existing != null) return existing;
    final load = () async {
      final keys = await _as.kvKeys(Ns.settings);
      for (final raw in keys) {
        final key = utf8.decode(raw, allowMalformed: true);
        if (!key.startsWith(_messageLogNamespaceMarkerPrefix)) continue;
        final ns = int.tryParse(
          key.substring(_messageLogNamespaceMarkerPrefix.length),
        );
        if (ns == null ||
            ns < Ns.messageLogShardFirst ||
            ns > Ns.messageLogShardLast) {
          continue;
        }
        _messageLogNamespaces.add(ns);
        _messageLogNamespaceMarkers.add(ns);
      }
    }();
    _messageLogNamespacesInit = load;
    try {
      await load;
    } catch (_) {
      if (identical(_messageLogNamespacesInit, load)) {
        _messageLogNamespacesInit = null;
      }
      rethrow;
    }
  }

  /// Read every sharded message log as one globally ordered stream.
  Future<List<_MessageLogEntry>> _messageLogEntries({int? start}) async {
    await _ensureMessageLogNamespacesLoaded();

    final namespaces = _messageLogNamespaces.toList()..sort();
    final entries = <_MessageLogEntry>[];
    for (final namespace in namespaces) {
      // A deterministic shard wholly below an incremental scan's lower bound
      // cannot contribute.
      if (start != null) {
        final segment =
            (namespace - Ns.messageLogShardFirst) * Ns.messageLogShardSize;
        final shardLastId = segment + Ns.messageLogShardSize;
        if (shardLastId < start) continue;
      }
      final part = await _as.iterLogRange(
        namespace: namespace,
        start: start,
        limit: _logScanLimit,
      );
      for (final entry in part) {
        entries.add(
          _MessageLogEntry(
            namespace: namespace,
            logId: entry.logId,
            payload: entry.payload,
          ),
        );
      }
    }
    entries.sort((a, b) {
      final byId = a.logId.compareTo(b.logId);
      return byId != 0 ? byId : a.namespace.compareTo(b.namespace);
    });
    final byId = {for (final entry in entries) entry.logId: entry};
    final logical = <_MessageLogEntry>[];
    for (final entry in entries) {
      final wrapper = _messageWrapper(entry.payload);
      if (wrapper == null) {
        logical.add(entry);
      } else if (wrapper['messagePart'] == 1) {
        continue; // storage fragments are never conversation events
      } else {
        logical.add(
          _MessageLogEntry(
            namespace: entry.namespace,
            logId: entry.logId,
            payload: await _readMessageParts(entry, wrapper, available: byId),
          ),
        );
      }
    }
    return logical;
  }

  // Each encoded part remains below the incompressible native record bound.
  // Wrappers are body-less voids to older readers, so a downgrade can still
  // read surrounding ordinary records instead of failing its entire fold.
  static const _messagePartBytes = 1200;
  static const _messageInlineBytes = 1800;
  static const _messagePayloadMaxBytes = 512 * 1024;
  static final _messageWrapperPrefix = _sk('{"messagePart');

  static Map<String, dynamic>? _messageWrapper(Uint8List raw) {
    if (raw.length < _messageWrapperPrefix.length) return null;
    for (var i = 0; i < _messageWrapperPrefix.length; i++) {
      if (raw[i] != _messageWrapperPrefix[i]) return null;
    }
    final decoded = jsonDecode(utf8.decode(raw));
    if (decoded is! Map<String, dynamic> ||
        decoded['k'] != EventKind.void_.index ||
        (decoded['messagePart'] != 1 && decoded['messageParts'] != 1)) {
      throw const FormatException('invalid message storage wrapper');
    }
    return decoded;
  }

  static ({int first, int count, int length, String digest})
  _messagePartsDescriptor(Map<String, dynamic> wrapper, int head) {
    final first = wrapper['first'];
    final count = wrapper['count'];
    final length = wrapper['length'];
    final digest = wrapper['sha256'];
    if (wrapper['messageParts'] != 1 ||
        first is! int ||
        first <= head ||
        count is! int ||
        count < 1 ||
        length is! int ||
        length <= _messagePartBytes ||
        length > _messagePayloadMaxBytes ||
        count != (length + _messagePartBytes - 1) ~/ _messagePartBytes ||
        first + count - 1 > Ns.messageLogShardCapacity ||
        digest is! String ||
        !_sharedContentIdPattern.hasMatch(digest)) {
      throw const FormatException('invalid message storage descriptor');
    }
    return (first: first, count: count, length: length, digest: digest);
  }

  Future<Uint8List> _readMessageParts(
    _MessageLogEntry head,
    Map<String, dynamic> wrapper, {
    Map<int, _MessageLogEntry> available = const {},
  }) async {
    final descriptor = _messagePartsDescriptor(wrapper, head.logId);
    final bytes = BytesBuilder(copy: false);
    for (var i = 0; i < descriptor.count; i++) {
      final id = descriptor.first + i;
      final ns = Ns.messageLogNamespaceFor(id);
      final cached = available[id];
      final raw = cached != null && cached.namespace == ns
          ? cached.payload
          : await _as.readLog(ns, id);
      final part = raw == null ? null : _messageWrapper(raw);
      if (part == null ||
          part['messagePart'] != 1 ||
          part['owner'] != head.logId ||
          part['i'] != i ||
          part['d'] is! String) {
        throw const FormatException('missing or misbound message storage part');
      }
      final data = base64Decode(part['d'] as String);
      final expected = min(_messagePartBytes, descriptor.length - bytes.length);
      if (data.length != expected) {
        throw const FormatException('invalid message storage part length');
      }
      bytes.add(data);
    }
    final payload = bytes.takeBytes();
    if (crypto.sha256.convert(payload).toString() != descriptor.digest) {
      throw const FormatException('invalid message storage payload digest');
    }
    return payload;
  }

  // A head rewrite and the erasure of every fragment are one commit unit.
  // Splitting a bulk clear between them would orphan readable deleted text.
  Future<List<List<KvLogOp>>> _messageRewriteUnits(List<KvLogOp> ops) async {
    final units = <List<KvLogOp>>[];
    for (final op in ops) {
      final unit = <KvLogOp>[];
      if (op is AppendLogOp &&
          op.namespace >= Ns.messageLogShardFirst &&
          op.namespace <= Ns.messageLogShardRetiredLast) {
        final raw = await _as.readLog(op.namespace, op.logId);
        final wrapper = raw == null ? null : _messageWrapper(raw);
        if (wrapper?['messageParts'] == 1) {
          final descriptor = _messagePartsDescriptor(wrapper!, op.logId);
          // Verify ownership before rewriting any other log id.
          await _readMessageParts(
            _MessageLogEntry(
              namespace: op.namespace,
              logId: op.logId,
              payload: raw!,
            ),
            wrapper,
          );
          for (var i = 0; i < descriptor.count; i++) {
            final id = descriptor.first + i;
            unit.add(
              AppendLogOp(
                Ns.messageLogNamespaceFor(id),
                id,
                _sk(jsonEncode({'messagePart': 1, 'k': EventKind.void_.index})),
              ),
            );
          }
        }
      }
      units.add([...unit, op]);
    }
    return units;
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
  Future<({int namespace, int logId, Message message})?> _liveEntryFor(
    String conversationId,
    String messageId,
  ) => _serialized(() async {
    await _foldCritical(); // warm, incremental — not a fresh full-log scan
    final k = _msgKey(conversationId, messageId);
    final msg = _scanById[k];
    final location = _scanLogIds[k];
    if (msg == null || location == null) return null;
    return (namespace: location.namespace, logId: location.logId, message: msg);
  });

  @override
  Future<int?> editMessage(
    String conversationId,
    String messageId,
    String newBody, {
    int? seq,
    List<InlineCustomEmoji> customEmoji = const [],
    bool reflected = false,
  }) {
    if (reflected && seq == null) {
      return Future.error(
        ArgumentError('A reflected edit requires its source revision'),
      );
    }
    final session = _store;
    if (session == null || _convSequenceFences > 0) {
      return Future.error(StateError('storage is closing or locked'));
    }
    Future<int?> apply() => _editMessageCritical(
      conversationId,
      messageId,
      newBody,
      seq: seq,
      customEmoji: customEmoji,
      reflected: reflected,
    );
    final write = _editGate.then((_) async {
      if (!identical(session, _store)) {
        throw StateError('storage session changed before edit');
      }
      final hit = await _liveEntryFor(conversationId, messageId);
      if (hit == null) return null;
      return _withConvSequence(
        conversationId,
        hit.message.author ?? conversationId,
        apply,
        acceptedBeforeFence: true,
      );
    });
    _editGate = write.then<void>((_) {}, onError: (_) {});
    return write;
  }

  Future<void> _editGate = Future<void>.value();

  Future<int?> _editMessageCritical(
    String conversationId,
    String messageId,
    String newBody, {
    int? seq,
    List<InlineCustomEmoji> customEmoji = const [],
    bool reflected = false,
  }) async {
    if (reflected && seq == null) {
      throw ArgumentError('A reflected edit requires its source revision');
    }
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
    // A LOCAL edit also numbers past every edit of this message already held:
    // another device of this identity may have edited it from its own stream,
    // and the counterpart keeps the edit with the higher seq. Numbered from
    // the local cursor alone, a second device's later edit lost to the first
    // device's earlier one.
    var editSeq = seq ?? await _nextConvSeq(conversationId, author);
    if (seq == null) {
      for (final e in await _messageLogEntries()) {
        final m = jsonDecode(utf8.decode(e.payload)) as Map<String, dynamic>;
        final held = m['sq'];
        if (m['c'] == conversationId &&
            m['tg'] == messageId &&
            m['k'] == EventKind.edit.index &&
            held is int &&
            held >= editSeq) {
          editSeq = held + 1;
        }
      }
    }
    // A WIRE edit is idempotent on its (author, seq) slot, like applyRemoteVoid /
    // applyRemoteClear: the durable pipeline re-drives frames across restarts, and
    // without this each re-drive would append a duplicate k:edit row — log bloat
    // plus a duplicated version in loadMessageHistory. Concurrent devices can
    // occupy this same revision with DIFFERENT text: retain a larger value,
    // rather than treating another writer's edit as this frame's replay.
    // (A LOCAL edit allocates a fresh seq above, so it can never collide.)
    //
    // THIS edit in the slot, not merely something. Every device of an identity
    // numbers its own stream, and the counterpart files them all under the one
    // author it knows — so a slot can hold another device's MESSAGE at the
    // same number. Read as "applied", that dropped every edit a second device
    // made: measured on the stand, B's edits of its own messages were acked by
    // the counterpart and never shown, 0 of 3.
    if (seq != null) {
      final entries = await _messageLogEntries();
      final thisEdit = '$messageId~e$seq';
      for (final e in entries) {
        final m = jsonDecode(utf8.decode(e.payload)) as Map<String, dynamic>;
        if (m['c'] == conversationId &&
            m['id'] == thisEdit &&
            m['k'] == EventKind.edit.index &&
            m['tg'] == messageId &&
            (reflected || (m['au'] == author && m['er'] != true))) {
          final heldBody = m['b'] as String? ?? '';
          if (messageEditContentHash(
                heldBody,
                parseInlineCustomEmoji(heldBody, m['ce']),
              ).compareTo(messageEditContentHash(newBody, customEmoji)) >=
              0) {
            return editSeq;
          }
        }
      }
    }
    await _commitAtNextMessageLogId(
      (namespace, logId) => [
        AppendLogOp(
          namespace,
          logId,
          _sk(
            jsonEncode({
              'k': EventKind.edit.index,
              'id': '$messageId~e$editSeq', // synthetic edit-event id (unique)
              'c': conversationId,
              'tg': messageId,
              if (!reflected) 'au': author,
              if (reflected) 'er': true,
              'sq': editSeq,
              'b': newBody,
              if (customEmoji.isNotEmpty)
                'ce': encodeInlineCustomEmoji(customEmoji),
              't': DateTime.now().millisecondsSinceEpoch,
            }),
          ),
        ),
        // Advance the per-(conv, author) cursor ONLY for a locally-allocated edit
        // (seq == null); a wire edit keeps the editor's seq, like appendMessage.
        if (seq == null)
          PutOp(
            Ns.settings,
            _sk('conv_seq:$conversationId:$author'),
            _sk('${editSeq + 1}'),
          ),
      ],
    );
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
    final entries = await _messageLogEntries();
    final versions = <MessageVersion>[];
    for (final e in entries) {
      final m = jsonDecode(utf8.decode(e.payload)) as Map<String, dynamic>;
      if (m['c'] != conversationId) continue;
      if (m['op'] == 'status' || m['op'] == 'del' || m['op'] == 'sig') {
        continue; // side-channel rows
      }
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
  Future<void> deleteMessage(
    String conversationId,
    String messageId, {
    MessageDeletionIntent? intent,
  }) => _withMessageErasure(
    () => _deleteMessage(conversationId, messageId, intent: intent),
  );

  Future<void> _deleteMessage(
    String conversationId,
    String messageId, {
    MessageDeletionIntent? intent,
  }) async {
    final hit = await _liveEntryFor(conversationId, messageId);
    if (hit == null) return;
    if (intent == MessageDeletionIntent.everyone &&
        hit.message.direction != MessageDirection.outgoing) {
      throw StateError('Cannot unsend a message authored by the peer');
    }
    // Legacy attachment ids can be purged only when this is their LAST live
    // chat/cloud reference. Hash-CIDs are also shared by groups and Spaces, so
    // [_unreferencedBlobIds] always defers them to the global collector.
    final deletingKey = _msgKey(conversationId, messageId);
    final blobIds = _messageBlobIds(hit.message);
    final purgeBlobIds = await _unreferencedBlobIds(
      blobIds,
      deletingMessageKeys: {deletingKey},
    );
    // One atomic commit: tombstone the SAME log_id (so the body no longer reads
    // back) and purge any eligible legacy-exclusive blob. Shared hash-CIDs stay
    // quarantined until the global scan. Folding legacy blob ops in here closes
    // the crash window where the chat row and blob could disagree. Orphaned
    // chunks are reclaimed by scrubDeleted(). The tombstone carries the
    // conversation id so isMessageDeleted stays conversation-scoped too.
    final tomb = jsonEncode({
      'op': 'del',
      'id': messageId,
      'c': conversationId,
      if (intent != null) 'dm': true,
      if (intent == MessageDeletionIntent.everyone) 'dp': true,
      if (intent != null &&
          (hit.message.fileContentId ?? hit.message.fileId) != null)
        'dc': hit.message.fileContentId ?? hit.message.fileId,
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
    // Large-file tier: scrub the per-blob key in the SAME commit (forward
    // secrecy — see _onDiskScrubOps); the ciphertext files go after the commit.
    final blobNames = <String>[];
    final blobOps = <KvLogOp>[];
    for (final blobId in purgeBlobIds) {
      blobOps.addAll(await _deleteContentBlobOps(blobId, blobNames));
    }
    // Derived text, in the SAME commit as the tombstone. A transcript and a
    // translation are this message's content in another form, so leaving them
    // for the periodic sweep means the body is scrubbed while a readable copy
    // of it stays — and a person who tapped delete expects deleted, not
    // eventually. In one commit because a crash between two would leave
    // exactly that gap.
    //
    // purgeBlobIds is already "no live reference remains", computed above for
    // the blobs themselves, so a transcript of content another message still
    // shows is not touched.
    final derivedOps = await _derivedTextOps(
      deadMessageIds: {messageId},
      deadContentIds: purgeBlobIds,
    );
    await _commitMessageDeletion([
      AppendLogOp(hit.namespace, hit.logId, _sk(tomb)),
      ...blobOps,
      ...editVoids,
      ...derivedOps,
    ]);
    if (blobNames.isNotEmpty) {
      await _deleteBlobFiles(blobNames);
      // Vacuum promptly so the orphaned chunk holding the (now-deleted) key row
      // is truly erased, not just unlinked — the key IS the file's secrecy.
      await scrubDeleted();
    }
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
      _foldPendingDeletion(
        jsonDecode(tomb) as Map<String, dynamic>,
        hit.namespace,
        hit.logId,
      );
    });
  }

  void _foldPendingDeletion(
    Map<String, dynamic> tomb,
    int namespace,
    int logId,
  ) {
    final conversation = tomb['c'], id = tomb['id'];
    if (conversation is! String || id is! String) return;
    final key = _msgKey(conversation, id);
    final content = tomb['dc'] is String ? tomb['dc'] as String : null;
    if (tomb['dm'] != true && tomb['dp'] != true && content == null) {
      _scanPendingDeletions.remove(key);
      return;
    }
    _scanPendingDeletions[key] = (
      pending: (
        conversationId: conversation,
        messageId: id,
        mirrorPending: tomb['dm'] == true,
        peerPending: tomb['dp'] == true,
        contentId: content,
      ),
      namespace: namespace,
      logId: logId,
      tomb: tomb,
    );
  }

  @override
  Future<List<PendingMessageDeletion>> pendingMessageDeletions({
    String? messageId,
    String? afterKey,
    int limit = 64,
    bool includeMirrorOnly = true,
  }) => _serialized(() async {
    if (await _recoverMessageDeletion()) _clearScanState();
    await _foldCritical();
    final result = <PendingMessageDeletion>[];
    var pastCursor =
        afterKey == null || !_scanPendingDeletions.containsKey(afterKey);
    if (limit <= 0) return result;
    for (final entry in _scanPendingDeletions.entries) {
      if (!pastCursor) {
        if (entry.key == afterKey) pastCursor = true;
        continue;
      }
      final pending = entry.value.pending;
      if (messageId != null && pending.messageId != messageId) continue;
      if (!includeMirrorOnly &&
          !pending.peerPending &&
          pending.contentId == null) {
        continue;
      }
      result.add(pending);
      if (result.length >= limit.clamp(1, 256)) break;
    }
    return result;
  });

  @override
  Future<void> completeMessageDeletion(
    String conversationId,
    String messageId, {
    bool mirror = false,
    bool peer = false,
    bool serving = false,
  }) => _serialized(() async {
    await _foldCritical();
    final hit = _scanPendingDeletions[_msgKey(conversationId, messageId)];
    if (hit == null) return;
    final tomb = Map<String, dynamic>.from(hit.tomb);
    var changed = false;
    for (final field in [if (mirror) 'dm', if (peer) 'dp', if (serving) 'dc']) {
      if (tomb.containsKey(field)) {
        tomb.remove(field);
        changed = true;
      }
    }
    if (!changed) return;
    final ops = [AppendLogOp(hit.namespace, hit.logId, _sk(jsonEncode(tomb)))];
    if (serving && hit.pending.contentId != null) {
      // This last metadata copy identifies the erased attachment too.
      await _commitMessageDeletion(ops);
    } else {
      await _as.commit(ops);
    }
    _foldPendingDeletion(tomb, hit.namespace, hit.logId);
  });

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

  /// Delete ops for text DERIVED from a message: its translations, and the
  /// transcripts of content that dies with it.
  ///
  /// Keyed by suffix rather than by prefix, because both families carry the
  /// language BETWEEN the family name and the id
  /// (`set:msg.translation.v1:<lang>:<id>`), so a prefix match cannot name one
  /// without enumerating every language anyone might have chosen.
  ///
  /// Best effort: if the key listing fails, the periodic sweep still catches
  /// these. Losing the eager removal is a delay; failing the delete over it
  /// would be worse.
  Future<List<KvLogOp>> _derivedTextOps({
    required Iterable<String> deadMessageIds,
    required Iterable<String> deadContentIds,
  }) async {
    final deadMessages = deadMessageIds.toSet();
    if (deadMessages.isEmpty && deadContentIds.isEmpty) return const [];
    final List<String> keys;
    try {
      keys = await settingsKeys();
    } on Object {
      return const [];
    }
    final dead = deadContentIds.toSet();
    final ops = <KvLogOp>[];
    for (final key in keys) {
      if (!key.startsWith('set:')) continue;
      final rest = key.substring('set:'.length);
      String? id;
      if (rest.startsWith('msg.translation.v1:')) {
        final tail = rest.substring('msg.translation.v1:'.length);
        final cut = tail.indexOf(':');
        if (cut > 0 && deadMessages.contains(tail.substring(cut + 1))) {
          ops.add(DeleteOp(Ns.settings, _sk(key)));
        }
        continue;
      }
      if (rest.startsWith('voice.transcript.v3:')) {
        final tail = rest.substring('voice.transcript.v3:'.length);
        final cut = tail.indexOf(':');
        if (cut > 0) id = tail.substring(cut + 1);
      } else if (rest.startsWith('voice.transcript.v2:')) {
        id = rest.substring('voice.transcript.v2:'.length);
      }
      if (id != null && id.isNotEmpty && dead.contains(id)) {
        ops.add(DeleteOp(Ns.settings, _sk(key)));
      }
    }
    return ops;
  }

  /// Void-rewrite (reclaim) the retained k:edit rows of [conv]: when [targets]
  /// is null, every edit row in the conversation; otherwise only edits of those
  /// message ids. Each rewrite replaces the edit row with a body-less void at the
  /// SAME log_id, orphaning the superseded-text chunk so a following scrub
  /// forensically erases it — without this, deleting/clearing an EDITED message
  /// would leave its old plaintext on disk (a deniability hole introduced by
  /// keeping edit history). Returns ops to fold into the caller's commit.
  Future<List<KvLogOp>> _voidEditRowsOps(
    String conv, {
    Set<String>? targets,
  }) async {
    final entries = await _messageLogEntries();
    final ops = <KvLogOp>[];
    for (final e in entries) {
      final m = jsonDecode(utf8.decode(e.payload)) as Map<String, dynamic>;
      if (m['c'] != conv) continue;
      if (m['k'] != EventKind.edit.index) continue;
      if (targets != null && !targets.contains(m['tg'])) continue;
      ops.add(
        AppendLogOp(
          e.namespace,
          e.logId,
          _sk(
            jsonEncode({
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
            }),
          ),
        ),
      );
    }
    return ops;
  }

  /// Tombstone every message of [peer]'s conversation (+ purge file blobs and
  /// void every retained edit row) as a list of ops for ONE commit. Shared by
  /// [removeConversation] and [clearMessages]; the only difference is whether the
  /// caller ALSO drops the contact record. Coalescing to a single commit is the
  /// high-leverage cut for storage bloat. Voiding the edit rows ensures no
  /// superseded edit plaintext survives a clear (forensic, with the scrub).
  Future<List<KvLogOp>> _tombstoneAllOps(
    NodeId peer, {
    Map<String, int>? upTo,
    int? upToMs,
    required List<String> blobNamesOut,
  }) async {
    final ops = <KvLogOp>[];
    final cleared = <String>{};
    final deletingKeys = <String>{};
    final candidateBlobIds = <String>{};
    for (final m in await loadMessages(peer.hex)) {
      // Bounded clear (applyRemoteClear): a remote clear only erases up to the
      // high-water it captured — KEEP anything newer (seq > watermark) that the
      // receiver has since received. A null upTo clears everything (local clear).
      if (upTo != null) {
        final a = m.author, s = m.seq;
        final bySeq = a != null && s != null && s <= (upTo[a] ?? -1);
        // OUR OWN clear also reaches by TIME. The ceiling cannot carry a
        // clear between a person's own devices: the bounding in
        // [applyRemoteClear] drops every watermark key that is neither the
        // author nor ourselves, and when WE are the author the dropped key is
        // the PEER — half the conversation. Without this the fold would hide
        // those rows while the container kept their plaintext, which is the one
        // outcome a clear may not produce.
        final byTime =
            upToMs != null && m.timestamp.millisecondsSinceEpoch <= upToMs;
        if (!bySeq && !byTime) continue;
      }
      final hit = await _liveEntryFor(peer.hex, m.id);
      if (hit == null) continue;
      cleared.add(m.id);
      deletingKeys.add(_msgKey(peer.hex, m.id));
      candidateBlobIds.addAll(_messageBlobIds(hit.message));
      ops.add(
        AppendLogOp(
          hit.namespace,
          hit.logId,
          // Preserve (author, seq) so the seq slot survives the tombstone (R4) —
          // same gap-free rule as deleteMessage.
          _sk(
            jsonEncode({
              'op': 'del',
              'id': m.id,
              'c': peer.hex,
              if (hit.message.author != null) 'au': hit.message.author,
              if (hit.message.seq != null) 'sq': hit.message.seq,
            }),
          ),
        ),
      );
    }
    final purgeBlobIds = await _unreferencedBlobIds(
      candidateBlobIds,
      deletingMessageKeys: deletingKeys,
    );
    // Derived text for everything this clear tombstones, in the same ops the
    // callers commit. Every clear path — local, emitted, and a peer's applied
    // remotely — builds its work here, so one insertion covers all of them,
    // and a bounded clear only names the messages it actually erased.
    ops.addAll(
      await _derivedTextOps(
        deadMessageIds: cleared,
        deadContentIds: purgeBlobIds,
      ),
    );
    for (final blobId in purgeBlobIds) {
      ops.addAll(await _deleteContentBlobOps(blobId, blobNamesOut));
      // Large-file tier: fold the key scrub into the same batch; the caller
      // removes the ciphertext files after committing (see _onDiskScrubOps).
    }
    // Scrub edit rows: ALL of them for a full local clear; only the cleared
    // messages' for a bounded (remote) clear, so a kept newer message keeps its
    // edit history.
    ops.addAll(
      await _voidEditRowsOps(peer.hex, targets: upTo == null ? null : cleared),
    );
    return ops;
  }

  @override
  Future<void> removeConversation(NodeId peer) => _trackLogWrite(
    (_) => _withMessageErasure(() => _removeConversation(peer)),
  );

  Future<void> _removeConversation(NodeId peer) async {
    final blobNames = <String>[];
    final ops = await _tombstoneAllOps(peer, blobNamesOut: blobNames);
    await _contactSerialized(() async {
      final (index, hadShards) = await _contactIndexShards();
      index.remove(peer.hex);
      // Forgetting a contact must work even if a pending manifest is corrupt.
      // The writer has a fixed maximum; erase every possible owned part.
      for (var i = 0; i < _prefsMaxParts; i++) {
        ops.add(DeleteOp(Ns.settings, _sk('$_prefsData${peer.hex}:$i')));
      }
      ops.add(DeleteOp(Ns.settings, _sk('$_prefsPending${peer.hex}')));
      ops.add(DeleteOp(Ns.settings, _sk('$_prefsFloor${peer.hex}')));
      ops.add(DeleteOp(Ns.contacts, peer.bytes));
      ops.add(DeleteOp(Ns.settings, _sk('$_contactPendingPrefix${peer.hex}')));
      ops.add(DeleteOp(Ns.settings, _sk('$_contactFloorPrefix${peer.hex}')));
      ops.addAll(_contactIndexOps(index, hadShards));
      await _commitBatched(ops);
    });
    // Whole conversation is gone — scrub the orphaned chunks for forensic erasure
    // and drop the warm fold (scrubDeleted invalidates it) so a later read can't
    // resurrect a tombstoned row; the tombstones are durable in the log, so
    // isMessageDeleted still answers true after the rebuild.
    await scrubDeleted();
    await _deleteBlobFiles(blobNames);
  }

  @override
  Future<int> pruneConversation(NodeId peer, int retentionDays) {
    if (retentionDays <= 0) return Future.value(0); // unlimited
    return pruneConversationBefore(
      peer,
      DateTime.now().subtract(Duration(days: retentionDays)),
    );
  }

  @override
  Future<int> pruneConversationBefore(NodeId peer, DateTime cutoff) =>
      _withMessageErasure(() => _pruneConversationBefore(peer, cutoff));

  Future<int> _pruneConversationBefore(NodeId peer, DateTime cutoff) async {
    // Old messages by ORIGINAL post time (the fold keeps the post's original
    // timestamp; edits are separate rows and never refresh it).
    final oldMessages = [
      for (final m in await loadMessages(peer.hex))
        if (m.timestamp.isBefore(cutoff)) m,
    ];
    final old = {for (final m in oldMessages) m.id};
    if (old.isEmpty) return 0;
    final deletingKeys = {for (final m in oldMessages) _msgKey(peer.hex, m.id)};
    final candidateBlobIds = {
      for (final m in oldMessages) ..._messageBlobIds(m),
    };
    // ONE raw scan: tombstone each old post (+ purge its file), and void-rewrite
    // each retained edit row of an old post (orphaning its body chunk) so the
    // scrub reclaims ALL of its plaintext — not just the current version.
    final entries = await _messageLogEntries();
    final ops = <KvLogOp>[];
    final blobNames = <String>[];
    for (final e in entries) {
      final m = jsonDecode(utf8.decode(e.payload)) as Map<String, dynamic>;
      if (m['c'] != peer.hex) continue;
      if (m['op'] == 'status' || m['op'] == 'del' || m['op'] == 'sig') continue;
      final k = m['k'] as int?;
      if (k == EventKind.edit.index && old.contains(m['tg'])) {
        ops.add(
          AppendLogOp(
            e.namespace,
            e.logId,
            _sk(
              jsonEncode({
                'k': EventKind.void_.index,
                'c': peer.hex,
                'tg': m['tg'],
                'id': m['id'],
                // Keep the voided edit's seq slot (R4 / R-VOID) — see _voidEditRowsOps.
                if (m['au'] is String) 'au': m['au'],
                if (m['sq'] is int) 'sq': m['sq'],
              }),
            ),
          ),
        );
      } else if (old.contains(m['id']) &&
          (k == null ||
              k == EventKind.post.index ||
              k == EventKind.filePost.index)) {
        ops.add(
          AppendLogOp(
            e.namespace,
            e.logId,
            // Preserve (author, seq) so the seq slot survives the tombstone (R4).
            _sk(
              jsonEncode({
                'op': 'del',
                'id': m['id'],
                'c': peer.hex,
                if (m['au'] is String) 'au': m['au'],
                if (m['sq'] is int) 'sq': m['sq'],
              }),
            ),
          ),
        );
      }
    }
    final purgeBlobIds = await _unreferencedBlobIds(
      candidateBlobIds,
      deletingMessageKeys: deletingKeys,
    );
    for (final blobId in purgeBlobIds) {
      ops.addAll(await _deleteContentBlobOps(blobId, blobNames));
    }
    if (ops.isEmpty) return 0;
    await _commitBatched(ops);
    await scrubDeleted();
    await _deleteBlobFiles(blobNames);
    return old.length;
  }

  @override
  Future<void> clearMessages(NodeId peer) =>
      _withMessageErasure(() => _clearMessages(peer));

  Future<void> _clearMessages(NodeId peer) async {
    // Same per-message tombstone+scrub as removeConversation, but the contact
    // record and chat-list index entry stay — the conversation remains (empty).
    final blobNames = <String>[];
    final ops = await _tombstoneAllOps(peer, blobNamesOut: blobNames);
    if (ops.isEmpty) return; // nothing stored — keep the chat untouched
    await _commitBatched(ops);
    await scrubDeleted();
    await _deleteBlobFiles(blobNames);
  }

  @override
  Future<({String author, int seq, Map<String, int> watermark, int atMs})>
  emitClearConversation(NodeId peer, String selfHex) => _withConvSequence(
    peer.hex,
    selfHex,
    () => _withMessageErasure(() => _emitClearConversation(peer, selfHex)),
  );

  Future<({String author, int seq, Map<String, int> watermark, int atMs})>
  _emitClearConversation(NodeId peer, String selfHex) async {
    // Clear locally AND record a propagatable + replayable clear EVENT: a
    // per-author seq WATERMARK (= the current contiguous high-water) under
    // [selfHex]'s next seq. The per-message scrub + tombstone still runs (forensic
    // erasure + immediate local hide); the watermark is what brings ANOTHER device
    // (the peer, or — once multi-device lands — the author's own) to the same
    // emptied state on replay, and suppresses an in-flight message that belongs
    // before the clear. Returns the event so the caller ships it on the wire.
    final conv = peer.hex;
    // The moment of THIS clear, which travels with it to the other devices —
    // they apply minutes later and must bound by when it happened, not by when
    // they got round to it.
    final at = DateTime.now().millisecondsSinceEpoch;
    final sync = await conversationSync(conv);
    final wm = Map<String, int>.from(sync.highWater);
    final blobNames = <String>[];
    final tombstones = // all current (== <= wm)
    await _tombstoneAllOps(
      peer,
      blobNamesOut: blobNames,
    );
    final seq = await _nextConvSeq(conv, selfHex);
    await _commitAtNextMessageLogId(
      (namespace, logId) => [
        AppendLogOp(
          namespace,
          logId,
          // ONLY the watermark travels/persists — never a cleared id or text.
          _sk(
            jsonEncode({
              'k': EventKind.clear.index,
              'c': conv,
              'au': selfHex,
              'sq': seq,
              't': at,
              // Ours by construction, and it matters even on the device that
              // pressed the button: a sibling's mirror of a message from before
              // this clear is still in flight and would otherwise land here
              // afterwards.
              'ownAt': at,
              'wm': wm,
            }),
          ),
        ),
        PutOp(Ns.settings, _sk('conv_seq:$conv:$selfHex'), _sk('${seq + 1}')),
      ],
    );
    if (tombstones.isNotEmpty) await _commitBatched(tombstones);
    await scrubDeleted();
    await _deleteBlobFiles(blobNames);
    await _patchCache(() {}); // refold → watermark + tombstones land
    return (author: selfHex, seq: seq, watermark: wm, atMs: at);
  }

  @override
  Future<void> applyRemoteClear(
    NodeId peer,
    String author,
    int seq,
    Map<String, int> watermark, {
    required String selfHex,
    int? ownClearAtMs,
    bool fromOwnDevice = false,
  }) => _withMessageErasure(
    () => _applyRemoteClear(
      peer,
      author,
      seq,
      watermark,
      selfHex: selfHex,
      ownClearAtMs: ownClearAtMs,
      fromOwnDevice: fromOwnDevice,
    ),
  );

  Future<void> _applyRemoteClear(
    NodeId peer,
    String author,
    int seq,
    Map<String, int> watermark, {
    required String selfHex,
    int? ownClearAtMs,
    bool fromOwnDevice = false,
  }) async {
    // Apply a clear received from [author]. Record the watermark, scrub +
    // tombstone every local message AT/BELOW it (keep anything newer), and occupy
    // the clear's own (author, seq) slot so the per-author stream stays gap-free.
    // Idempotent on (author, seq). The caller (messaging) decides WHETHER to apply
    // a peer's clear (policy); this is the apply mechanism.
    final conv = peer.hex;
    // One pass for two things: whether this slot is already taken, and the
    // highest sequence OUR OWN stream has reached in this conversation.
    var ownCeiling = 0;
    final entries = await _messageLogEntries();
    for (final e in entries) {
      final m = jsonDecode(utf8.decode(e.payload)) as Map<String, dynamic>;
      if (m['c'] != conv || m['op'] == 'status' || m['op'] == 'sig') continue;
      // THIS clear in the slot, not whatever else holds the number: another
      // device of the same identity numbers its own stream, so a slot can
      // carry that device's message — read as "applied", a clear made on a
      // second device was acked and never happened (see [editMessage]).
      if (m['au'] == author &&
          m['sq'] == seq &&
          m['k'] == EventKind.clear.index) {
        return; // this very clear — already applied
      }
      final sq = m['sq'];
      if (m['au'] == selfHex && sq is int && sq > ownCeiling) ownCeiling = sq;
    }
    // Also every slot we have ALLOCATED, whether or not a row survives at it —
    // a message we sent and then deleted still happened, and the sender is
    // entitled to clear it.
    final allocated = await _nextConvSeq(conv, selfHex) - 1;
    if (allocated > ownCeiling) ownCeiling = allocated;

    // Bound the watermark before anything acts on it.
    //
    // Naming both sides is the FEATURE — an honest sender takes the watermark
    // from the conversation's high-water, which in a 1:1 chat covers both
    // authors, because "clear for everyone" that erased only the sender's half
    // would leave the conversation half-standing. What was never bounded is how
    // FAR it may reach into OUR stream. An honest sender cannot know a sequence
    // of ours beyond what we actually emitted; anything above that is no longer
    // "erase what exists" but an instruction to suppress what has not happened
    // yet. Left unbounded it left the victim with an erased history AND a chat
    // that stayed mute for good: they write, the peer receives it, and their own
    // screen shows nothing — no notice, no trace, surviving both a restart and
    // deleting the contact and adding it back, because the clear row is not a
    // message and nothing sweeps it away.
    //
    // So: keys that are neither the authenticated sender nor ourselves are
    // dropped (nobody may speak for a third author here); our own entry is
    // held to what we hold locally; and the sender's OWN entry is left exactly
    // as sent — a peer is entitled to clear its own stream above what ever
    // reached us, which is precisely what a born-clear is for.
    final bounded = <String, int>{};
    for (final entry in watermark.entries) {
      if (entry.key == author) {
        bounded[entry.key] = entry.value;
      } else if (entry.key == selfHex) {
        bounded[entry.key] = entry.value > ownCeiling
            ? ownCeiling
            : entry.value;
      }
    }
    // The clear's own moment, taken ONCE and used for both halves. It is
    // generated HERE, never read off the wire, so it cannot be widened by a
    // sender — which is what makes it safe to erase author-less rows by it.
    final at = DateTime.now().millisecondsSinceEpoch;
    // A clear of OUR OWN making — from one of this identity's other devices —
    // is bounded by TIME as well as by the ceiling, because the bounding above
    // drops the PEER's key when the author is ourselves, and the peer is half
    // the conversation. A peer's clear keeps exactly the semantics it had.
    //
    // WHOSE CLOCK. Not this device's: a device group runs minutes behind, so
    // "now, here" would sweep away every message that arrived while the clear
    // was in flight — messages sent AFTER the clear, which it has no business
    // touching. The moment that counts is when the clear HAPPENED, and it
    // travels with it. Held down to our own clock as well, so a sibling running
    // fast cannot reach into our future.
    // OURS when it came from this device OR from another device of this
    // identity. Each device authors under its own id, so a sibling's clear
    // names the sibling — and judged by the author alone it was taken for a
    // PEER's: no time bound, and every key but the sibling's own stream
    // dropped. Measured on the stand: a clear made on one device left 7 of
    // 12 messages on the other, every one of them the counterpart's.
    final own = author == selfHex || fromOwnDevice;
    final ownAt = own
        ? ((ownClearAtMs ?? at) < at ? (ownClearAtMs ?? at) : at)
        : null;
    // Gather scrub+tombstone ops BEFORE the clear row sets the fold watermark, so
    // loadMessages still lists the to-be-cleared messages.
    final blobNames = <String>[];
    final tombstones = await _tombstoneAllOps(
      peer,
      upTo: bounded,
      upToMs: ownAt,
      blobNamesOut: blobNames,
    );
    await _commitAtNextMessageLogId(
      (namespace, logId) => [
        AppendLogOp(
          namespace,
          logId,
          _sk(
            jsonEncode({
              'k': EventKind.clear.index,
              'c': conv,
              'au': author,
              'sq': seq,
              't': at,
              'ownAt': ?ownAt,
              // The BOUNDED map is what persists, so every later fold — on this
              // start and every one after it — reads the same bounded value.
              'wm': bounded,
            }),
          ),
        ),
      ],
    );
    if (tombstones.isNotEmpty) await _commitBatched(tombstones);
    await scrubDeleted();
    await _deleteBlobFiles(blobNames);
    await _patchCache(() {});
  }

  /// Pack a bulk mutation without splitting one message's head/part rewrite.
  /// The native store packs bounded records into multiple data batches; this
  /// fallback also supports backings that bound a whole operation batch.
  Future<void> _commitBatched(List<KvLogOp> ops) async {
    final messageDeletion = ops.whereType<AppendLogOp>().any(
      (op) =>
          op.namespace >= Ns.messageLogShardFirst &&
          op.namespace <= Ns.messageLogShardRetiredLast,
    );
    Future<void> commit() async {
      try {
        await _commitBatchedUnits(
          await _messageRewriteUnits(ops),
          messageDeletion: messageDeletion,
        );
      } catch (_) {
        if (messageDeletion) {
          _deleteScrubPending = null;
          _deleteScrubRecoveryNeeded = true;
        }
        rethrow;
      }
    }

    if (messageDeletion) {
      await _serializeDeleteScrub(commit);
    } else {
      await commit();
    }
  }

  Future<void> _commitBatchedUnits(
    List<List<KvLogOp>> units, {
    required bool messageDeletion,
  }) async {
    if (units.isEmpty) return;
    try {
      await _as.commit([
        for (final unit in units) ...unit,
        if (messageDeletion)
          PutOp(
            Ns.settings,
            _sk(_pendingDeleteScrubKey),
            Uint8List.fromList([1]),
          ),
      ]);
      if (messageDeletion) _deleteScrubPending = true;
    } on hv.HvException catch (e) {
      if (e.kind != 'PayloadTooLarge' || units.length == 1) rethrow;
      final mid = units.length >> 1;
      await _commitBatchedUnits(
        units.sublist(0, mid),
        messageDeletion: messageDeletion,
      );
      await _commitBatchedUnits(
        units.sublist(mid),
        messageDeletion: messageDeletion,
      );
    }
  }

  @override
  Future<void> eraseSpace() => _drainConvSequenceWrites(
    () => _drainRatchetIo(() => _drainFileIo(_eraseSpace)),
  );

  Future<void> _eraseSpace() async {
    _ratchetCommittedChunks.clear();
    // FIRST, while the volume can still be read: which blobs are OURS.
    //
    // Every space of a container shares one blob directory, and this used to
    // finish with `deleteAll()` — so erasing identity A destroyed the
    // large-file ciphertext of identities B and C, whose own metadata still
    // pointed at files that no longer existed (audit XV-01). Irreversible, and
    // silent until someone opened an old attachment.
    //
    // The names live in this space's `ondisk:` settings rows, which the erase
    // below is about to destroy, so they have to be collected up front.
    final ownBlobs = await _ownBlobNames();

    // Erase EVERY namespace this app uses, then scrub orphaned chunks — the
    // identity's data (its keypair, contacts, message log, file blobs) is gone
    // forensically, not merely unlinked. Irreversible.
    // Namespace 3 is retired and this build never writes it, but a
    // destroy-everything path must still cover it: forensic deletion is about
    // what the container holds, not about what this build would have put there.
    await _as.eraseNamespace(Ns.messageLog);
    // Erase the full reserved range, not merely namespaces discoverable from
    // settings: forensic identity deletion must remain complete even if a
    // marker/counter was damaged. Through the RETIRED bound, not the
    // allocator's — narrowing what this build may write must not narrow what a
    // destroy-everything pass reaches.
    for (
      var ns = Ns.messageLogShardFirst;
      ns <= Ns.messageLogShardRetiredLast;
      ns++
    ) {
      await _as.eraseNamespace(ns);
    }
    for (final ns in const [
      Ns.settings,
      Ns.contacts,
      Ns.media,
      Ns.fileChunks,
      Ns.outbox,
      Ns.callLog,
      Ns.outboxIndex,
      // Ratchet sessions. Leaving them would leave the ONE thing here that is
      // pure key material behind an erase that removed everything else.
      Ns.ratchet,
    ]) {
      await _as.eraseNamespace(ns);
    }
    await _as.scrub();
    _ratchetSavesSinceScrub = null;
    // The on-disk LARGE-FILE tier: every per-blob key just went with the
    // settings namespace (the ciphertext is already unreadable), so remove the
    // ciphertext files too — an erased identity must not leave a directory of
    // its blob sizes behind. ONLY OURS: the directory is shared with every
    // other space of this container. Best-effort: an FS error can't un-erase
    // the keys, and a blob left behind is unreadable garbage.
    await _deleteBlobFiles(ownBlobs);
    // The message log is gone — drop the in-memory fold or a later loadMessages
    // would resurrect the erased conversation from cache.
    _resetLogAllocator();
    await _invalidateScanCache();
    await _invalidateOutboxCache();
  }

  @override
  Future<void> scrubDeleted() async {
    // Reclaim chunks orphaned by edit/delete so the prior plaintext is no
    // longer recoverable from the container. Backed by hidden-volume's
    // vacuum/compact when the store exposes it; a no-op on the in-memory fake.
    await _serializeDeleteScrub(() async {
      try {
        await _as.scrub();
        await _finishMessageDeletionScrub();
      } catch (_) {
        _deleteScrubRecoveryNeeded = true;
        rethrow;
      }
    });
    // Defensive: if the vacuum ever compacts/renumbers the log, the fold's
    // log-id watermark would be stale — force a clean rebuild next read.
    await _invalidateScanCache();
  }

  @override
  Future<int> purgeFileStore() async {
    // Wholesale namespace erase — the only operation that actually frees
    // log-index slots (per-record scrubs overwrite in place; see the interface
    // doc). Scrub afterwards so the erased chunk payloads are reclaimed too.
    final erased = await _as.eraseNamespace(Ns.fileChunks);
    // The durable chunk accounting now describes records that are gone; leaving
    // it would keep the collector's high-water trigger armed against a count of
    // nothing. Dropping it re-seeds from the (now empty) namespace on the next
    // write.
    await AsyncFileStore(_as).forgetChunkAccounting();
    await _as.scrub();
    return erased;
  }

  @override
  Future<List<String>> settingsKeys() async {
    final keys = await _as.kvKeys(Ns.settings);
    return [for (final k in keys) utf8.decode(k, allowMalformed: true)];
  }

  @override
  Future<SharedContentReferenceSnapshot>
  sharedContentReferenceSnapshot() async {
    final stored = <String>{};
    final referenced = <String>{};
    try {
      for (final key in await settingsKeys()) {
        String? fileId;
        if (key.startsWith('file:')) {
          fileId = key.substring('file:'.length);
        } else if (key.startsWith('ondisk:')) {
          fileId = key.substring('ondisk:'.length);
        }
        if (fileId == null) continue;
        final contentId = fileId.startsWith('mf:')
            ? fileId.substring('mf:'.length)
            : fileId;
        if (_sharedContentIdPattern.hasMatch(contentId)) {
          stored.add(contentId);
        }
      }

      for (final message in await _scanLog()) {
        for (final contentId in _messageBlobIds(message)) {
          if (_sharedContentIdPattern.hasMatch(contentId)) {
            referenced.add(contentId);
          }
        }
      }
      final cloud = await _cloudIndexContentIds();
      referenced.addAll(cloud.contentIds);
      return SharedContentReferenceSnapshot(
        storedContentIds: Set.unmodifiable(stored),
        referencedContentIds: Set.unmodifiable(referenced),
        complete: cloud.complete,
      );
    } catch (_) {
      return SharedContentReferenceSnapshot(
        storedContentIds: Set.unmodifiable(stored),
        referencedContentIds: Set.unmodifiable(referenced),
        complete: false,
      );
    }
  }

  static void _logUnreadableCloudIndexRow(Object? event) => devLog(
    () =>
        'xVeil[content-gc]: cloud index row not understood — '
        'k=${event is Map ? event['k'] : event.runtimeType}',
  );

  /// Key families in the settings namespace that describe content which can
  /// disappear out from under them; everything else (identity, config,
  /// cursors, app settings) is never swept.
  static Set<String> _messageBlobIds(Message message) => {
    ?message.fileId,
    ?message.fileContentId,
  };

  /// Erase both the payload and its restart/reoffer manifest. They share one
  /// reachability lifetime even though they are separate file-store blobs.
  Future<List<KvLogOp>> _deleteContentBlobOps(
    String contentId,
    List<String> blobNamesOut,
  ) async {
    final ops = <KvLogOp>[];
    for (final id in [contentId, 'mf:$contentId']) {
      ops.addAll(await AsyncFileStore(_as).deleteFileOps(id));
      ops.addAll(await _onDiskScrubOps(id, blobNamesOut));
    }
    return ops;
  }

  /// Return candidate content ids with no live owner after the named messages
  /// are tombstoned. Cloud rows and chat messages share the same content-
  /// addressed blob namespace, so every destructive message path must consult
  /// both domains before folding physical erasure into its atomic commit.
  Future<Set<String>> _unreferencedBlobIds(
    Set<String> candidates, {
    required Set<String> deletingMessageKeys,
  }) async {
    if (candidates.isEmpty) return const {};
    // A 64-hex content id is shared by personal chat, cloud, groups and Spaces.
    // Storage can validate the first two domains but cannot decrypt/fold the
    // latter two, so destructive chat operations defer hash-CIDs to the global
    // GroupService mark/sweep. Legacy non-addressed file ids remain eligible
    // for the old atomic message+blob erasure path.
    final immediate = {
      for (final candidate in candidates)
        if (!_sharedContentIdPattern.hasMatch(candidate)) candidate,
    };
    if (immediate.isEmpty) return const {};
    final cloud = await _cloudIndexContentIds();
    if (!cloud.complete) return const {};
    final live = cloud.contentIds;
    for (final message in await _scanLog()) {
      if (deletingMessageKeys.contains(
        _msgKey(message.conversationId, message.id),
      )) {
        continue;
      }
      live.addAll(_messageBlobIds(message));
    }
    return immediate.difference(live);
  }

  /// Content referenced by the personal-cloud materialized index is just as
  /// live as a chat attachment. Parse the storage codec locally to keep the
  /// storage layer independent of the cloud domain, and accept only the exact
  /// bounded v1 shape + a 64-hex cid. Malformed rows retain nothing.
  Future<({Set<String> contentIds, bool complete})>
  _cloudIndexContentIds() async {
    final live = <String>{};
    try {
      // CLOUD-3 materialized views moved out of the ~4 KiB settings record
      // into the chunked file-store. Prefer it, but retain the legacy setting
      // fallback so a pre-migration store remains GC-safe on first unlock.
      final fileStore = AsyncFileStore(_as);
      // Settings are read through the same `set:` prefix the writer uses, so
      // the shared layout helper sees exactly what CloudService wrote.
      Future<String?> settingString(String name) async {
        final raw = await _as.get(Ns.settings, _sk('set:$name'));
        return raw == null ? null : utf8.decode(raw, allowMalformed: true);
      }

      final activeRaw = await _as.get(
        Ns.settings,
        _sk('set:cloud.index.v1.active'),
      );
      final cidPattern = RegExp(r'^[0-9a-f]{64}$');
      final active = activeRaw == null
          ? null
          : utf8.decode(activeRaw, allowMalformed: true);
      bool collect(Uint8List raw) {
        try {
          final rows = jsonDecode(utf8.decode(raw, allowMalformed: true));
          if (rows is! List || rows.length > 100000) return false;
          for (final body in rows) {
            if (body is! String || body.length > 4096) return false;
            final event = jsonDecode(body);
            if (event is! Map || event['v'] != 1) {
              _logUnreadableCloudIndexRow(event);
              return false;
            }
            // Folders describe structure, never content: their payload is
            // name/created/rev/parent (or a del tombstone). Skipping them is
            // safe, and NOT skipping them disabled shared-content GC outright
            // — measured on the stand as `stored=124 referenced=53 purged=0`
            // with `k=cloudFolder` stopping this reader on every pass.
            if (event['k'] == 'cloudFolder') continue;
            if (event['k'] != 'cloudEntry') {
              // Still fail-closed for a kind this reader has never seen: it
              // may carry a content id we cannot find, and collecting then
              // would delete live content.
              _logUnreadableCloudIndexRow(event);
              return false;
            }
            final payload = event['p'];
            if (payload is! Map) return false;
            if (payload['del'] == true) continue;
            final cid = payload['cid'];
            if (cid is! String || !cidPattern.hasMatch(cid)) return false;
            live.add(cid);
          }
          return true;
        } catch (_) {
          return false;
        }
      }

      // Reads through the SHARED layout helper, not by file name. The index is
      // paged, and a reader that does not know that sees an empty index and
      // concludes nothing is referenced — with a garbage collector on the other
      // end of that conclusion.
      Future<Uint8List?> slotBytes(String slot) async {
        final decoded = await readMaterializedSlot(
          key: 'cloud.index.v1',
          slot: slot,
          getSetting: settingString,
          loadFile: fileStore.loadFile,
        );
        return decoded == null
            ? null
            : Uint8List.fromList(utf8.encode(decoded));
      }

      if (active == 'a' || active == 'b') {
        final current = await slotBytes(active!);
        if (current != null && collect(current)) {
          return (contentIds: live, complete: true);
        }
        final fallback = await slotBytes(active == 'a' ? 'b' : 'a');
        if (fallback != null && collect(fallback)) {
          // The fallback is enough to recover the UI, but not proof that the
          // missing authoritative generation named no additional content. Let
          // CloudService republish/repair before physical deletion resumes.
          return (contentIds: live, complete: false);
        }
        return (contentIds: live, complete: false);
      } else {
        if (active != null && active.isNotEmpty) {
          return (contentIds: live, complete: false);
        }
        // With no trustworthy pointer, retain the union conservatively. The
        // service will publish a fresh generation and repair the pointer.
        var recovered = false;
        for (final slot in const ['a', 'b']) {
          final bytes = await slotBytes(slot);
          if (bytes != null) {
            if (!collect(bytes)) {
              return (contentIds: live, complete: false);
            }
            recovered = true;
          }
        }
        if (recovered) return (contentIds: live, complete: true);
      }
    } catch (_) {
      return (contentIds: live, complete: false);
    }
    return (contentIds: live, complete: true);
  }

  @override
  Future<int> sweepSettingsGarbage({bool wholesale = false}) async {
    final keys = await settingsKeys();
    final doomed = <String>[];
    final blobNames = <String>[];
    final sharedStillStored = <String, bool>{};
    Future<bool> retainForGlobalCollector(String contentId) async {
      if (wholesale || !_sharedContentIdPattern.hasMatch(contentId)) {
        return false;
      }
      final cached = sharedStillStored[contentId];
      if (cached != null) return cached;
      final stored = await hasFile(contentId) || await hasFile('mf:$contentId');
      sharedStillStored[contentId] = stored;
      return stored;
    }

    // Live MESSAGE ids, for the families keyed by one. Collected separately
    // from liveContent because the two answer different questions: an
    // incomplete cloud index makes CONTENT retention unknowable, and says
    // nothing about whether the message log folded.
    //
    // Null means unknown, and unknown retains — deleting a live person's
    // translation is worse than keeping a dead one's.
    Set<String>? liveMessages;
    if (!wholesale) {
      try {
        liveMessages = {for (final m in await _scanLog()) m.id};
      } on Object {
        liveMessages = null;
      }
    }

    Set<String>? liveContent;
    if (!wholesale) {
      // Per-content bookkeeping is only reachable through a message that
      // still names its content id; collect the live ids once per sweep.
      final cloud = await _cloudIndexContentIds();
      // Unknown cloud roots must retain every per-content row. Deleting stale
      // bookkeeping is optional; deleting the only restart/reoffer manifest is
      // not.
      if (!cloud.complete) {
        liveContent = null;
      } else {
        final live = cloud.contentIds;
        for (final m in await _scanLog()) {
          final cid = m.fileContentId;
          if (cid != null) live.add(cid);
          final fid = m.fileId;
          if (fid != null) live.add(fid);
        }
        liveContent = live;
      }
    }
    // Per-content families keyed `<prefix><cid>`: dead once no live message
    // references the cid. On aged senders `set:served:`/`file:mf:` dominate
    // (one per file ever offered); on aged receivers it is `set:saved:`.
    // Dropping a served/manifest record for content whose message is gone
    // also WITHDRAWS the offer on this side — deliberate: a deleted message
    // must not keep serving its bytes from a deniable store.
    const perContent = ['set:saved:', 'set:served:', 'set:gone:', 'file:mf:'];
    for (final key in keys) {
      final prefix = perContent.firstWhere(key.startsWith, orElse: () => '');
      if (prefix.isNotEmpty) {
        final cid = key.substring(prefix.length);
        final unreferenced =
            wholesale || (liveContent != null && !liveContent.contains(cid));
        if (unreferenced && !await retainForGlobalCollector(cid)) {
          doomed.add(key);
        }
        continue;
      }
      if (key.startsWith('filepiece:')) {
        // `filepiece:<cid>:<n>` — piece→log-id mapping; dead with its cid.
        final rest = key.substring('filepiece:'.length);
        final cut = rest.lastIndexOf(':');
        final cid = cut > 0 ? rest.substring(0, cut) : rest;
        final unreferenced =
            wholesale || (liveContent != null && !liveContent.contains(cid));
        if (unreferenced && !await retainForGlobalCollector(cid)) {
          doomed.add(key);
        }
        continue;
      }
      if (key.startsWith('ondisk:')) {
        // On-disk encrypted blobs are keyed by the content id. Once no live
        // message references that id, remove BOTH the in-volume key row and the
        // ciphertext directory so app-private storage does not grow forever.
        final cid = key.substring('ondisk:'.length);
        final unreferenced =
            wholesale || (liveContent != null && !liveContent.contains(cid));
        if (unreferenced && !await retainForGlobalCollector(cid)) {
          final meta = await _odMeta(cid);
          final fn = meta?['fn'];
          if (fn is String) blobNames.add(fn);
          doomed.add(key);
        }
        continue;
      }
      // Derived text: a transcript or a translation is the message's own
      // content in another form. The app scrubs a deleted event's body on
      // purpose (EventKind.delete is body-less, and clearing history scrubs to
      // a watermark) — and these survived it, so the text a person deleted
      // stayed readable in the store for as long as the volume existed. They
      // also grew without bound: one row per message ever transcribed or
      // translated, and nothing ever removed one.
      //
      // A transcript is keyed by the CONTENT id, so it lives and dies with it
      // exactly as `ondisk:` does. v3 carries the language between the prefix
      // and the id; the v2 legacy key does not.
      // `set:` because that is the prefix putSetting writes under, and
      // settingsKeys() reports the stored key. Matching the bare family name
      // here made every branch below unreachable — a fix that looked done and
      // swept nothing.
      const transcriptV3 = 'set:voice.transcript.v3:';
      const transcriptV2 = 'set:voice.transcript.v2:';
      final isV3 = key.startsWith(transcriptV3);
      if (isV3 || key.startsWith(transcriptV2)) {
        final rest = key.substring(
          isV3 ? transcriptV3.length : transcriptV2.length,
        );
        String? cid;
        if (isV3) {
          final cut = rest.indexOf(':');
          // A key shaped unlike its own family is left alone rather than
          // guessed at: this loop's job is to delete, and a wrong guess here
          // deletes something live.
          if (cut > 0) cid = rest.substring(cut + 1);
        } else {
          cid = rest;
        }
        if (cid != null && cid.isNotEmpty) {
          final unreferenced =
              wholesale || (liveContent != null && !liveContent.contains(cid));
          if (unreferenced && !await retainForGlobalCollector(cid)) {
            doomed.add(key);
          }
        }
        continue;
      }
      // `msg.translation.v1:<lang>:<messageId>` — keyed by the MESSAGE.
      const translation = 'set:msg.translation.v1:';
      if (key.startsWith(translation)) {
        final rest = key.substring(translation.length);
        final cut = rest.indexOf(':');
        if (cut > 0) {
          final messageId = rest.substring(cut + 1);
          final unreferenced =
              wholesale ||
              (liveMessages != null && !liveMessages.contains(messageId));
          if (unreferenced) doomed.add(key);
        }
        continue;
      }
      if (wholesale && key.startsWith('file:')) {
        // After a wholesale purge (file chunks + message log erased) the
        // remaining file-store records describe data that no longer exists.
        doomed.add(key);
      }
    }
    // Batched deletes: each commit costs one padded bucket, so don't emit one
    // per key — but keep batches bounded so a huge sweep stays well under any
    // single-commit budget.
    const batch = 128;
    for (var i = 0; i < doomed.length; i += batch) {
      final ops = <KvLogOp>[
        for (final key in doomed.skip(i).take(batch))
          DeleteOp(Ns.settings, _sk(key)),
      ];
      await _as.commit(ops);
    }
    await _deleteBlobFiles(blobNames);
    return doomed.length;
  }

  @override
  Future<SlotUtilization?> containerUtilization() async {
    // A LOCKED store has no space to ask, and this is a readout: answering
    // "unknown" is right where `_as` would throw and take the settings screen
    // down with it.
    final store = _store;
    if (store == null) return null;
    return store.slotUtilization();
  }

  /// Settings key the kept warning lives under.
  static const _kHardeningWarningSetting = 'container_hardening_warning';

  @override
  Future<void> acknowledgeHardeningWarning() async {
    // CONTAINER FIRST, and its failure is the whole operation's failure.
    //
    // The other order wrote the app's copy off and then tried the container
    // best-effort. When the container's half failed, its record stayed —
    // correctly, nobody acknowledged it — while the app side had already
    // marked the thing dismissed, so the warning was invisible from then on
    // (report14 X14-M6). An acknowledgement that only half happened must read
    // as not having happened.
    final store = _store;
    if (store == null) {
      // Nothing to acknowledge to. Leaving the kept copy standing is the safe
      // half of the pair: the warning is only ever shown from an open store.
      return;
    }
    await store.acknowledgeHardeningWarning();
    await putSetting(_kHardeningWarningSetting, '');
  }

  @override
  Future<String?> retainHardeningWarning() async {
    final store = _store;
    if (store == null) return null;
    final stored = await getSetting(_kHardeningWarningSetting);
    // An EMPTY value means NOTHING IS KEPT — it does not mean "never ask
    // again". Treating it as a permanent tombstone hid every hardening failure
    // that ever followed the first dismissal, on a store whose whole purpose
    // is to report when a commit stopped being as deniable as the policy asked
    // for (report14 X14-M6).
    //
    // Nothing needs a tombstone, because the acknowledgement clears the
    // CONTAINER's record too and does so before this key is written. A read
    // after a successful acknowledgement therefore finds nothing on either
    // side; a read after a failed one finds the container's record still
    // standing, which is exactly what should be shown again.
    final kept = (stored == null || stored.isEmpty) ? null : stored;
    final String? fresh;
    try {
      fresh = await store.hardeningWarning();
    } catch (_) {
      // A store that cannot answer leaves whatever was kept standing: an
      // unreadable stat is not evidence that the warning went away.
      return kept;
    }
    if (fresh == null) return kept;
    // FIRST one kept, not the latest. The container keeps the first for the
    // same reason: between two reads a replaced record is the earlier warning
    // gone, and the earlier one is the one nobody has seen yet.
    if (kept != null) return kept;
    await putSetting(_kHardeningWarningSetting, fresh);
    devLog(
      () =>
          'xVeil[storage]: container hardening step FAILED ($fresh). Kept on '
          'disk — the container forgets it at close, and what it means is that '
          'this commit is not as deniable as the policy asked for.',
    );
    return fresh;
  }

  @override
  Future<Map<String, int>> namespaceCounts() async {
    await _ensureMessageLogNamespacesLoaded();
    var shardedMessageCount = 0;
    for (final namespace in _messageLogNamespaces) {
      shardedMessageCount += await _as.count(namespace);
    }
    return {
      'settings': await _as.count(Ns.settings),
      'contacts': await _as.count(Ns.contacts),
      'messageLog': shardedMessageCount,
      'messageLogSharded': shardedMessageCount,
      'messageLogShardNamespaces': _messageLogNamespaces.length,
      'media': await _as.count(Ns.media),
      'fileChunks': await _as.count(Ns.fileChunks),
      'outbox': await _as.count(Ns.outbox),
      'callLog': await _as.count(Ns.callLog),
    };
  }

  @override
  Future<int> purgeMessageLog() async {
    // Bench-only relief, wholesale like [purgeFileStore]: a soak series
    // appends thousands of filePost/status/tombstone rows and the per-record
    // tombstones never free index slots. Per-author `conv_seq` cursors live in
    // the settings KV and keep advancing across the erase, so the peer never
    // sees a seq reuse or a gap (our next event is simply high-water + 1).
    var erased = await _as.eraseNamespace(Ns.messageLog);
    for (
      var ns = Ns.messageLogShardFirst;
      ns <= Ns.messageLogShardRetiredLast;
      ns++
    ) {
      erased += await _as.eraseNamespace(ns);
    }
    await _as.scrub();
    await _invalidateScanCache();
    return erased;
  }

  @override
  Future<bool> markMessageStatus(
    String conversationId,
    String messageId,
    MessageStatus status,
  ) async {
    // Idempotent vs the STORED fold: peers re-ack once per launch for as long
    // as their relay blob lives, and the caller's once-per-id guard is in-RAM
    // only — without this check every launch appended a duplicate status row
    // (a padded commit + a log record, forever). Same-status = true no-op.
    Message? target;
    try {
      // The incremental fold already has a conversation-scoped ID index and
      // the same status overlay. An ACK needs one row, not a whole-log search.
      target = await loadMessageById(conversationId, messageId);
    } catch (_) {
      // Fail closed: without a readable target row we must not manufacture an
      // orphan status op for an arbitrary ACK id.
      return false;
    }
    // A late retry failure or an old own-device journal row cannot undo an
    // authenticated delivery ACK, including one recovered from history.
    if (target == null ||
        target.status == status ||
        target.status == MessageStatus.delivered) {
      return false;
    }
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
    await _commitAtNextMessageLogId(
      (namespace, logId) => [AppendLogOp(namespace, logId, _sk(payload))],
    );
    return true;
  }

  @override
  Future<void> markMessageSignature(
    String conversationId,
    String messageId,
    MessageSignature signature,
  ) async {
    // Idempotent vs the stored fold (mirror of markMessageStatus): a re-arriving
    // response would otherwise append a duplicate sig row every time.
    Message? target;
    try {
      for (final message in await _scanLog()) {
        if (message.id == messageId &&
            message.conversationId == conversationId) {
          target = message;
          break;
        }
      }
    } catch (_) {
      // Same invariant as status: append only for a message proven to exist in
      // this exact conversation.
      return;
    }
    if (target == null || target.signature == signature) return;
    final payload = jsonEncode({
      'op': 'sig',
      'id': messageId,
      'c': conversationId,
      'sig': signature.index,
    });
    await _commitAtNextMessageLogId(
      (namespace, logId) => [AppendLogOp(namespace, logId, _sk(payload))],
    );
  }

  // ── Call journal (Ns.callLog append-log) ────────────────────────────────────
  // One immutable record per call revision, folded on read like the outbox.
  // The journal's previous home — ONE settings KV value rewritten per call —
  // hit the at-rest store's ~4KB DataBatch bound through the hot key's
  // accumulated versions: putSetting threw PayloadTooLarge after ~11 rows and
  // the unawaited recorder dropped calls silently. Append-log records take a
  // fresh id each, so nothing here ever rewrites a hot key, and the namespace
  // stays tiny (≤ the caller's cap, rows of ~150 B).

  // Use the existing encrypted settings namespace: the container already
  // reserves all 95 namespace roots. This prefix is not a shared preference.
  static const _callSyncPrefix = 'call.sync.pending.v1:';
  Future<void> _callJournalGate = Future<void>.value();

  Future<T> _serializeCallJournal<T>(Future<T> Function() body) {
    final result = _callJournalGate.then((_) => body());
    _callJournalGate = result.then((_) {}, onError: (_) {});
    return result;
  }

  static String _callSyncKey(String id) =>
      '$_callSyncPrefix${crypto.sha256.convert(utf8.encode(id))}';

  PendingCallLogSync _decodeCallSync(String key, Uint8List raw) {
    try {
      final json = jsonDecode(utf8.decode(raw));
      final entry = json is Map<String, dynamic>
          ? CallLogEntry.fromJson(json)
          : null;
      if (entry != null && _callSyncKey(entry.id) == key) {
        return PendingCallLogSync(
          entry: entry,
          token: crypto.sha256.convert(raw).toString(),
        );
      }
    } catch (_) {
      // Neither the key nor the payload belongs in diagnostics.
    }
    throw StateError('Unreadable pending call history');
  }

  Future<PutOp?> _callSyncPut(CallLogEntry entry) async {
    final key = _callSyncKey(entry.id);
    final raw = await _as.get(Ns.settings, _sk(key));
    if (raw != null &&
        compareCallLogEntries(entry, _decodeCallSync(key, raw).entry) <= 0) {
      return null;
    }
    return PutOp(Ns.settings, _sk(key), _sk(jsonEncode(entry.toJson())));
  }

  @override
  Future<void> queueCallLogSync(CallLogEntry entry) =>
      _serializeCallJournal(() async {
        final op = await _callSyncPut(entry);
        if (op != null) await _as.commit([op]);
      });

  @override
  Future<List<PendingCallLogSync>> pendingCallLogSync({
    int limit = 64,
    String? afterCallId,
  }) async {
    if (limit <= 0) throw ArgumentError.value(limit, 'limit');
    final cursor = afterCallId == null ? null : _callSyncKey(afterCallId);
    final keys = [
      for (final key in await _as.kvKeys(Ns.settings))
        if (utf8.decode(key, allowMalformed: true) case final name)
          if (name.startsWith(_callSyncPrefix) &&
              (cursor == null || name.compareTo(cursor) > 0))
            name,
    ]..sort();
    final records = <PendingCallLogSync>[];
    for (final key in keys) {
      final raw = await _as.get(Ns.settings, _sk(key));
      if (raw != null) records.add(_decodeCallSync(key, raw));
      if (records.length >= limit) break;
    }
    return records;
  }

  @override
  Future<bool> acknowledgeCallLogSync(PendingCallLogSync record) =>
      _serializeCallJournal(() async {
        final key = _sk(_callSyncKey(record.entry.id));
        final raw = await _as.get(Ns.settings, key);
        if (raw == null ||
            crypto.sha256.convert(raw).toString() != record.token) {
          return false;
        }
        await _as.commit([DeleteOp(Ns.settings, key)]);
        return true;
      });

  @override
  Future<bool> appendCallLogEntry(
    CallLogEntry entry, {
    required int cap,
    bool queueForSync = false,
  }) => _serializeCallJournal(
    () => _appendCallLogEntry(entry, cap: cap, queueForSync: queueForSync),
  );

  Future<bool> _appendCallLogEntry(
    CallLogEntry entry, {
    required int cap,
    required bool queueForSync,
  }) async {
    final raw = await _readCallLogNamespace();
    final cur = _foldCallLogRecords(raw);
    final previous = cur.where((row) => row.entry.id == entry.id).firstOrNull;
    final changed =
        previous == null || compareCallLogEntries(entry, previous.entry) > 0;
    // One winner per call. Replacing a provisional/shorter row uses a fresh
    // log id, so corrections never rewrite the hot KV value that used to hit
    // DataBatch limits. Selection and cap ties are independent of arrival order.
    final all =
        <({int? logId, CallLogEntry entry})>[
          if (changed) (logId: null, entry: entry),
          for (final row in cur)
            if (!changed || row.entry.id != entry.id)
              (logId: row.logId, entry: row.entry),
        ]..sort((a, b) {
          final time = b.entry.atMs.compareTo(a.entry.atMs);
          return time != 0 ? time : b.entry.id.compareTo(a.entry.id);
        });
    final kept = all.take(cap).toList(growable: false);
    final keptIds = {
      for (final row in kept)
        if (row.logId != null) row.logId!,
    };
    final doomed = [
      for (final row in raw)
        if (!keptIds.contains(row.logId)) DeleteLogOp(Ns.callLog, row.logId),
    ];
    final keepNew = kept.any((row) => row.logId == null);
    final pending = changed && queueForSync ? await _callSyncPut(entry) : null;
    // TWO commits, appends first. hidden-volume refuses a transaction that both
    // appends to and deletes from ONE Log namespace (`Tx::delete_log` ->
    // WrongNamespaceKind "delete_log cannot be mixed with append_log in one
    // Tx"), and the reverse order is refused just as firmly by
    // `Tx::check_namespace_kind`. One batch therefore threw for every call once
    // the journal reached its cap, and the recorder's catchError turned that
    // into a log line — the journal simply stopped growing, on a device, while
    // the in-memory fake accepted the same batch and kept the suite green.
    //
    // Appends first, never the other way round: a crash between the two commits
    // then leaves cap+1 rows, which the next append re-evicts, instead of a
    // hole where the evicted rows used to be.
    if (keepNew) {
      await _commitAtNextLogId(
        (logId) => [
          AppendLogOp(Ns.callLog, logId, _sk(jsonEncode(entry.toJson()))),
          ?pending,
        ],
      );
    } else if (pending != null) {
      // A final ring time can put the result outside the visible window. Its
      // siblings still need the correction; persist it BEFORE any eviction.
      await _as.commit([pending]);
    }
    if (doomed.isNotEmpty) {
      try {
        await _as.commit(doomed);
      } catch (e) {
        // The row IS journaled; eviction is recomputed from stored state on
        // every append, so a failed one heals itself on the next call. Failing
        // here would tell the recorder a call went unrecorded when it did not.
        devLog(() => 'xVeil[call-log]: eviction deferred: $e');
      }
    }
    return changed;
  }

  @override
  Future<List<CallLogEntry>> callLogEntries() async {
    final cur = await _callLogRecords();
    cur.sort((a, b) {
      final c = b.entry.atMs.compareTo(a.entry.atMs);
      return c != 0 ? c : b.entry.id.compareTo(a.entry.id);
    });
    return [for (final r in cur) r.entry];
  }

  Future<List<({int logId, CallLogEntry entry})>> _callLogRecords() async =>
      _foldCallLogRecords(await _readCallLogNamespace());

  List<({int logId, CallLogEntry entry})> _foldCallLogRecords(
    List<({int logId, CallLogEntry entry})> raw,
  ) {
    final winners = <String, ({int logId, CallLogEntry entry})>{};
    for (final row in raw) {
      final old = winners[row.entry.id];
      final rank = old == null
          ? 1
          : compareCallLogEntries(row.entry, old.entry);
      if (old == null || rank > 0 || (rank == 0 && row.logId > old.logId)) {
        winners[row.entry.id] = row;
      }
    }
    // An interrupted append-then-delete can leave several physical versions.
    // They are one logical call even before a later append retries cleanup.
    return winners.values.toList();
  }

  Future<List<({int logId, CallLogEntry entry})>>
  _readCallLogNamespace() async {
    final out = <({int logId, CallLogEntry entry})>[];
    // Namespace I/O failure is not an empty journal: the publisher would
    // permanently finish its legacy seed without saving any obligations, and
    // finished-call restore would report success with no replay evidence.
    // Propagate it so each caller can retry or report its own bounded failure.
    final rows = await _as.iterLogRange(
      namespace: Ns.callLog,
      start: null,
      limit: _logScanLimit,
    );
    for (final r in rows) {
      try {
        final m = jsonDecode(utf8.decode(r.payload));
        if (m is! Map) continue;
        final e = CallLogEntry.fromJson(Map<String, dynamic>.from(m));
        if (e != null) out.add((logId: r.logId, entry: e));
      } catch (_) {
        // A malformed row does not hide the remaining readable records.
      }
    }
    return out;
  }

  // ── Durable frame outbox (payload log + pending index) ─────────────────────
  // Payloads stay in Ns.outbox because a control frame can exceed the KV value
  // limit. Ns.outboxIndex maps sha256(frameId) -> logId, so reads are O(pending)
  // and enqueue/ack update payload + index atomically. A one-time paged fold
  // migrates the legacy enqueue/ack journal without ever returning its former
  // 100,000-row RustBuffer across FFI in one allocation.

  final Map<String, ({OutboxFrame frame, int logId, List<int> logIds})>
  _outboxById = {};
  bool _outboxLoaded = false;
  Future<void> _outboxGate = Future<void>.value();
  _PendingOutboxAcks? _pendingOutboxAcks;
  _PendingOutboxEnqueues? _pendingOutboxEnqueues;

  Future<T> _outboxSerialized<T>(Future<T> Function() body) {
    // An intervening enqueue/read/maintenance call is an ordering barrier.
    // In particular an ACK before re-enqueue must not absorb an ACK after it.
    _pendingOutboxAcks = null;
    _pendingOutboxEnqueues = null;
    final result = _outboxGate.then((_) => body());
    _outboxGate = result.then((_) {}, onError: (_) {});
    return result;
  }

  static Uint8List _outboxIndexKey(String frameId) =>
      Uint8List.fromList(crypto.sha256.convert(utf8.encode(frameId)).bytes);

  // Incompressible control envelopes can exceed the ~4 KiB encrypted
  // DataBatch capacity. Split the serialized row, not its network envelope.
  // All parts, descriptor and index share one commit, after reserving their ids.
  static const _outboxPartBytes = 1800;
  // A valid 512-KiB stored text edit also needs its original retry frame;
  // the outbox's JSON/base64 wrapper expands it beyond the event's size.
  static const _outboxMaxPayloadBytes = 1024 * 1024;

  int _outboxPartCount(Uint8List payload) {
    if (payload.length > _outboxMaxPayloadBytes) {
      throw ArgumentError('outbox payload exceeds the storage bound');
    }
    return payload.length <= _outboxPartBytes
        ? 0
        : (payload.length + _outboxPartBytes - 1) ~/ _outboxPartBytes;
  }

  // Shared encoding for a new batch and legacy timestamp rewrites. Index and
  // every payload part remain in the same atomic transaction and wire format.
  List<int> _appendOutboxPayloadOps(
    String frameId,
    Uint8List payload,
    int logId,
    List<KvLogOp> ops, {
    bool publishIndex = true,
  }) {
    final partCount = _outboxPartCount(payload);
    final logIds = <int>[logId];
    if (partCount == 0) {
      ops.add(AppendLogOp(Ns.outbox, logId, payload));
    } else {
      final first = logId + 1;
      for (var i = 0; i < partCount; i++) {
        final end = min((i + 1) * _outboxPartBytes, payload.length);
        ops.add(
          AppendLogOp(
            Ns.outbox,
            first + i,
            Uint8List.sublistView(payload, i * _outboxPartBytes, end),
          ),
        );
        logIds.add(first + i);
      }
      ops.add(
        AppendLogOp(
          Ns.outbox,
          logId,
          _sk(
            jsonEncode({
              'outboxParts': 1,
              'first': first,
              'count': partCount,
              'length': payload.length,
              'sha256': crypto.sha256.convert(payload).toString(),
            }),
          ),
        ),
      );
    }
    if (publishIndex) {
      ops.add(PutOp(Ns.outboxIndex, _outboxIndexKey(frameId), _sk('$logId')));
    }
    return logIds;
  }

  // Legacy stamp maintenance retains its existing single-record tracking.
  Future<({int logId, List<int> logIds})> _persistOutboxPayload(
    String frameId,
    Uint8List payload,
  ) => _trackLogWrite((store) async {
    final count = _outboxPartCount(payload) + 1;
    final logId = await _allocLogIds(store, count: count);
    final ops = <KvLogOp>[];
    final logIds = _appendOutboxPayloadOps(frameId, payload, logId, ops);
    await store.commit(ops);
    _noteLogCommit(store, logId + count - 1);
    return (logId: logId, logIds: logIds);
  });

  // Caller owns the outbox lane and tracks the entire admitted operation,
  // including its queue wait. Each payload/index keeps its existing format.
  Future<List<({OutboxFrame frame, int logId, List<int> logIds})>>
  _persistOutboxPayloadsCritical(
    AsyncKvLogStore store,
    List<_QueuedOutboxFrame> records, {
    List<KvLogOp> companionOps = const [],
  }) async {
    final counts = [for (final r in records) _outboxPartCount(r.payload) + 1];
    final total = counts.fold<int>(0, (a, b) => a + b);
    final first = await _allocLogIds(store, count: total);
    var cursor = first;
    final ops = <KvLogOp>[...companionOps];
    final persisted = <({OutboxFrame frame, int logId, List<int> logIds})>[];
    for (var n = 0; n < records.length; n++) {
      final record = records[n];
      final logIds = _appendOutboxPayloadOps(
        record.frame.frameId,
        record.payload,
        cursor,
        ops,
      );
      persisted.add((frame: record.frame, logId: cursor, logIds: logIds));
      cursor += counts[n];
    }
    try {
      await store.commit(ops);
    } catch (_) {
      // A lost reply can follow a successful all-or-none commit. Do not keep a
      // warm cache that hides durable frames (or re-enqueue duplicate payloads).
      _outboxLoaded = false;
      _outboxById.clear();
      _noteLogCommit(store, cursor - 1);
      rethrow;
    }
    _noteLogCommit(store, cursor - 1);
    return persisted;
  }

  // HVS admits at most 1024 log appends per transaction. Larger transfers
  // stage payload-only cohorts, then atomically publish ALL logical indexes.
  // The durable cleanup marker covers a crash/lost reply at any staging step.
  Future<List<({OutboxFrame frame, int logId, List<int> logIds})>>
  _persistCompleteOutboxTransferCritical(
    AsyncKvLogStore store,
    List<_QueuedOutboxFrame> records,
  ) async {
    final counts = [for (final r in records) _outboxPartCount(r.payload) + 1];
    final total = counts.fold<int>(0, (a, b) => a + b);
    if (total <= 1024) return _persistOutboxPayloadsCritical(store, records);
    final first = await _allocLogIds(store, count: total);
    var cursor = first;
    final staged = <({OutboxFrame frame, int logId, List<int> logIds})>[];
    final ops = <KvLogOp>[];
    var batchFrames = 0, batchBytes = 0;
    Future<void> flush() async {
      if (ops.isEmpty) return;
      await store.commit([
        ...ops,
        PutOp(Ns.settings, _sk(_outboxCleanupKey), Uint8List.fromList([1])),
      ]);
      _noteLogCommit(store, cursor - 1);
      ops.clear();
      batchFrames = 0;
      batchBytes = 0;
    }

    try {
      for (var n = 0; n < records.length; n++) {
        final r = records[n];
        if (batchFrames >= 8 ||
            ops.length + counts[n] > 1024 ||
            batchBytes + r.payload.length > 32 * 1024) {
          await flush();
        }
        final logId = cursor;
        final logIds = _appendOutboxPayloadOps(
          r.frame.frameId,
          r.payload,
          logId,
          ops,
          publishIndex: false,
        );
        staged.add((frame: r.frame, logId: logId, logIds: logIds));
        cursor += counts[n];
        batchFrames++;
        batchBytes += r.payload.length;
      }
      await flush();
      await store.commit([
        for (final item in staged)
          PutOp(
            Ns.outboxIndex,
            _outboxIndexKey(item.frame.frameId),
            _sk('${item.logId}'),
          ),
      ]);
      return staged;
    } catch (_) {
      _outboxLoaded = false;
      _outboxById.clear();
      _noteLogCommit(store, cursor - 1);
      rethrow;
    }
  }

  Future<({Uint8List payload, List<int> logIds})?> _readOutboxPayload(
    int logId,
  ) async {
    final raw = await _as.readLog(Ns.outbox, logId);
    if (raw == null) return null;
    final decoded = jsonDecode(utf8.decode(raw));
    if (decoded is! Map || !decoded.containsKey('outboxParts')) {
      return (payload: raw, logIds: [logId]); // old single-row format
    }
    final first = decoded['first'];
    final count = decoded['count'];
    final length = decoded['length'];
    if (decoded['outboxParts'] != 1 ||
        first is! int ||
        first < 1 ||
        count is! int ||
        count < 1 ||
        length is! int ||
        length < 1 ||
        length > _outboxMaxPayloadBytes ||
        count != (length + _outboxPartBytes - 1) ~/ _outboxPartBytes ||
        (logId >= first && logId < first + count)) {
      return null;
    }
    final bytes = BytesBuilder(copy: false);
    final logIds = <int>[logId];
    for (var i = 0; i < count; i++) {
      final part = await _as.readLog(Ns.outbox, first + i);
      final expected = i == count - 1
          ? length - i * _outboxPartBytes
          : _outboxPartBytes;
      if (part == null || part.length != expected) return null;
      bytes.add(part);
      logIds.add(first + i);
    }
    final payload = bytes.takeBytes();
    if (crypto.sha256.convert(payload).toString() != decoded['sha256']) {
      return null;
    }
    return (payload: payload, logIds: logIds);
  }

  /// Whether a stored outbox record already carries its queue time.
  static bool _payloadCarriesStamp(Uint8List payload) {
    try {
      final decoded = jsonDecode(utf8.decode(payload));
      return decoded is Map && decoded['t'] is int;
    } catch (_) {
      return true; // undecodable: leave it alone rather than rewrite blind
    }
  }

  /// Give rows written before stamping a queue time, once.
  ///
  /// Runs after the load rather than inside it: the load is on the critical
  /// path and this is bookkeeping. Each rewrite is the same commit an enqueue
  /// performs — a fresh log entry plus an index update — so a crash midway
  /// leaves every frame either as it was or stamped, never missing.
  Future<void> _stampLegacyOutboxFrames(List<OutboxFrame> frames) async {
    for (final frame in frames) {
      try {
        final payload = jsonEncode({
          'id': frame.frameId,
          'p': frame.peerHex,
          'w': base64.encode(frame.wire),
          't': frame.enqueuedAtMs ?? DateTime.now().millisecondsSinceEpoch,
        });
        final record = await _persistOutboxPayload(frame.frameId, _sk(payload));
        _outboxById[frame.frameId] = (
          frame: frame,
          logId: record.logId,
          logIds: record.logIds,
        );
      } catch (_) {
        // Best-effort: an unstamped frame is still bounded by the age its
        // decode gave it for this run, and the next start tries again.
      }
    }
  }

  static OutboxFrame? _decodePendingOutboxPayload(Uint8List payload) {
    try {
      final decoded = jsonDecode(utf8.decode(payload));
      if (decoded is! Map || decoded['op'] == 'ack') return null;
      final id = decoded['id'];
      final peer = decoded['p'];
      final wire = decoded['w'];
      if (id is! String || peer is! String || wire is! String) return null;
      final stamped = decoded['t'];
      return OutboxFrame(
        frameId: id,
        peerHex: peer,
        wire: base64.decode(wire),
        // A row written before stamping has no time of its own. Reading it as
        // "queued now" starts its clock at this load instead of leaving it
        // immortal — nothing is dropped early, and a backlog inherited from an
        // older build stops being permanent. Ages from load rather than from
        // the original queueing, which errs on the side of keeping.
        enqueuedAtMs: stamped is int
            ? stamped
            : DateTime.now().millisecondsSinceEpoch,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _loadIndexedOutboxCritical() async {
    final keys = await _as.kvKeys(Ns.outboxIndex);
    final badKeys = <Uint8List>[];
    final unstamped = <OutboxFrame>[];
    final loaded =
        <String, ({OutboxFrame frame, int logId, List<int> logIds})>{};
    for (final key in keys) {
      try {
        final rawLogId = await _as.get(Ns.outboxIndex, key);
        final logId = rawLogId == null
            ? null
            : int.tryParse(utf8.decode(rawLogId));
        final record = logId == null ? null : await _readOutboxPayload(logId);
        final payload = record?.payload;
        final frame = payload == null
            ? null
            : _decodePendingOutboxPayload(payload);
        if (frame == null ||
            !_bytesEqual(key, _outboxIndexKey(frame.frameId))) {
          badKeys.add(key);
          continue;
        }
        loaded[frame.frameId] = (
          frame: frame,
          logId: logId!,
          logIds: record!.logIds,
        );
        // A row from before stamping carries no time of its own. Decoding gave
        // it "now", which bounds it — but only until the next start, and a
        // backlog that resets its own clock on every launch is immortal again.
        // Write the stamp back so the clock starts once and stays started.
        if (!_payloadCarriesStamp(payload!)) {
          unstamped.add(frame);
        }
      } catch (_) {
        badKeys.add(key);
      }
    }
    _outboxById
      ..clear()
      ..addAll(loaded);
    _outboxLoaded = true;
    if (unstamped.isNotEmpty) {
      // Detached on purpose: bookkeeping must not delay the unlock path.
      _stampLegacyOutboxFrames(unstamped).ignore();
    }
    if (badKeys.isNotEmpty) {
      try {
        await _commitBatched([
          for (final key in badKeys) DeleteOp(Ns.outboxIndex, key),
        ]);
      } catch (_) {
        // A damaged index row is already excluded from the live set. Cleanup
        // is best-effort and can be retried after the next reopen.
      }
    }
    try {
      await _cleanupIndexedOutboxCritical();
    } catch (e) {
      // The index is already authoritative and usable. Historical payload rows
      // only waste space; a failed cleanup can safely retry on the next open.
      devLog(() => 'xVeil[outbox]: orphan payload cleanup deferred: $e');
    }
  }

  Future<void> _deleteOutboxLogIdsCritical(List<int> logIds) async {
    const batchSize = 128;
    for (var i = 0; i < logIds.length; i += batchSize) {
      await _as.commit([
        for (final logId in logIds.skip(i).take(batchSize))
          DeleteLogOp(Ns.outbox, logId),
      ]);
    }
  }

  Future<void> _cleanupIndexedOutboxCritical() async {
    final live = {for (final item in _outboxById.values) ...item.logIds};
    final count = await _as.count(Ns.outbox);
    if (count <= live.length) return;
    final obsolete = <int>[];
    int? start;
    while (true) {
      final page = await _as.iterLogRange(
        namespace: Ns.outbox,
        start: start,
        limit: _outboxScanPageSize,
      );
      if (page.isEmpty) break;
      for (final entry in page) {
        if (!live.contains(entry.logId)) obsolete.add(entry.logId);
      }
      if (page.length < _outboxScanPageSize) break;
      start = page.last.logId + 1;
    }
    if (obsolete.isEmpty) return;
    await _deleteOutboxLogIdsCritical(obsolete);
    devLog(
      () => 'xVeil[outbox]: removed ${obsolete.length} unindexed payload rows',
    );
  }

  Future<bool> _ensureOutboxLoadedCritical() async {
    if (_outboxLoaded) return true;
    try {
      await _loadIndexedOutboxCritical();
      return true;
    } catch (e) {
      devLog(() => 'xVeil[outbox]: index load failed: $e');
      return false;
    }
  }

  @override
  Future<bool> containsOutboxFrame(OutboxFrame expected) {
    final session = _store;
    if (session == null) return Future.value(false);
    final id = expected.frameId, peer = expected.peerHex;
    final wire = Uint8List.fromList(expected.wire);
    return _outboxSerialized(() async {
      if (!identical(session, _store) ||
          !await _ensureOutboxLoadedCritical() ||
          !identical(session, _store)) {
        return false;
      }
      final held = _outboxById[id]?.frame;
      return held != null &&
          held.peerHex == peer &&
          _bytesEqual(held.wire, wire);
    });
  }

  @override
  Future<void> enqueueOutboxTransfer(List<OutboxFrame> frames) {
    if (_store == null || _convSequenceFences > 0) {
      throw StateError('storage is closing or locked');
    }
    if (frames.isEmpty || frames.length > 4096) {
      throw ArgumentError('invalid outbox transfer size');
    }
    final peer = frames.first.peerHex;
    final ids = <String>{};
    var bytes = 0;
    for (final frame in frames) {
      bytes += frame.wire.length;
      if (frame.peerHex != peer ||
          !ids.add(frame.frameId) ||
          bytes > 16 * 1024 * 1024) {
        throw ArgumentError('inconsistent or oversized outbox transfer');
      }
    }
    final stamp = DateTime.now().millisecondsSinceEpoch;
    // Freeze before waiting for the storage lane, including caller-owned IDs,
    // bytes and age. The native commit publishes payloads and indexes together.
    final records = <_QueuedOutboxFrame>[];
    for (final input in frames) {
      final frame = OutboxFrame(
        frameId: input.frameId,
        peerHex: peer,
        wire: Uint8List.fromList(input.wire),
        enqueuedAtMs: input.enqueuedAtMs ?? stamp,
      );
      final payload = _sk(
        jsonEncode({
          'id': frame.frameId,
          'p': peer,
          'w': base64Encode(frame.wire),
          't': frame.enqueuedAtMs,
        }),
      );
      if (payload.length > _outboxMaxPayloadBytes) {
        throw ArgumentError('outbox transfer payload exceeds storage bound');
      }
      records.add((frame: frame, payload: payload));
    }
    return _trackLogWrite(
      (store) => _outboxSerialized(() async {
        if (!identical(store, _store)) {
          throw StateError('storage session changed before transfer admission');
        }
        if (!await _ensureOutboxLoadedCritical()) {
          throw StateError('durable outbox could not be loaded');
        }
        final missing = <_QueuedOutboxFrame>[];
        for (final record in records) {
          final held = _outboxById[record.frame.frameId]?.frame;
          if (held == null) {
            missing.add(record);
          } else if (held.peerHex != peer ||
              !_bytesEqual(held.wire, record.frame.wire)) {
            throw StateError('outbox transfer conflicts with a queued frame');
          }
        }
        if (missing.isEmpty) return;
        final persisted = await _persistCompleteOutboxTransferCritical(
          store,
          missing,
        );
        for (final item in persisted) {
          _outboxById[item.frame.frameId] = item;
        }
      }),
    );
  }

  _QueuedOutboxFrame _ownedOutboxRecord(
    String frameId,
    String peerHex,
    Uint8List wire,
  ) {
    final ownedWire = Uint8List.fromList(wire);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final record = (
      frame: OutboxFrame(
        frameId: frameId,
        peerHex: peerHex,
        wire: ownedWire,
        enqueuedAtMs: stamp,
      ),
      payload: _sk(
        jsonEncode({
          'id': frameId,
          'p': peerHex,
          'w': base64Encode(ownedWire),
          't': stamp,
        }),
      ),
    );
    if (record.payload.length > _outboxMaxPayloadBytes) {
      throw ArgumentError('outbox payload exceeds the storage bound');
    }
    return record;
  }

  @override
  Future<void> acceptContactAndEnqueue(
    NodeId peer,
    String frameId,
    Uint8List wire,
  ) {
    final record = _ownedOutboxRecord(frameId, peer.hex, wire);
    return _trackLogWrite(
      (store) => _outboxSerialized(
        () => _contactSerialized(() async {
          if (!identical(store, _store)) {
            throw StateError('acceptance storage session changed');
          }
          if (!await _ensureOutboxLoadedCritical()) {
            throw StateError('durable outbox could not be loaded');
          }
          final held = _outboxById[frameId];
          if (held != null &&
              (held.frame.peerHex != peer.hex ||
                  !_bytesEqual(held.frame.wire, record.frame.wire))) {
            throw StateError('conflicting durable acceptance frame');
          }
          final existing = await getContact(peer);
          final contact = (existing ?? Contact(nodeId: peer)).copyWith(
            status: ContactStatus.accepted,
          );
          final bytes = _encodeContact(contact);
          final (index, hadShards) = await _contactIndexShards();
          final indexed = index.contains(peer.hex);
          if (!indexed) index.add(peer.hex);
          final ops = <KvLogOp>[
            if (existing?.status != ContactStatus.accepted)
              PutOp(Ns.contacts, peer.bytes, bytes),
            if (!indexed) ..._contactIndexOps(index, hadShards),
          ];
          final decision = await _newContactDecision(
            store,
            peer,
            ContactStatus.accepted,
          );
          ops.addAll(_contactDecisionOps(peer, decision));
          try {
            if (held != null) {
              if (ops.isNotEmpty) await store.commit(ops);
              return;
            }
            final persisted = await _persistOutboxPayloadsCritical(store, [
              record,
            ], companionOps: ops);
            for (final item in persisted) {
              _outboxById[item.frame.frameId] = item;
            }
          } catch (error, stack) {
            // A lost reply may follow the full commit. Verify every promised
            // effect while still holding both lanes before publishing consent.
            // An unavailable read or partial proof remains a failure.
            try {
              if (identical(store, _store) &&
                  await _ensureOutboxLoadedCritical()) {
                final saved = _outboxById[frameId]?.frame;
                if (saved != null &&
                    saved.peerHex == peer.hex &&
                    _bytesEqual(saved.wire, record.frame.wire) &&
                    (await getContact(peer))?.status ==
                        ContactStatus.accepted &&
                    _bytesEqual(
                      await store.get(
                        Ns.settings,
                        _sk('$_contactPendingPrefix${peer.hex}'),
                      ),
                      decision,
                    ) &&
                    _bytesEqual(
                      await store.get(
                        Ns.settings,
                        _sk('$_contactFloorPrefix${peer.hex}'),
                      ),
                      decision,
                    ) &&
                    (await _contactIndex()).contains(peer.hex)) {
                  return;
                }
              }
            } catch (_) {
              // Preserve the original storage failure, not a recovery error.
            }
            Error.throwWithStackTrace(error, stack);
          }
        }),
      ),
    );
  }

  @override
  Future<void> enqueueOutboxFrame(
    String frameId,
    String peerHex,
    Uint8List wire,
  ) async {
    if (_store == null || _convSequenceFences > 0) {
      throw StateError('storage is closing or locked');
    }
    final record = _ownedOutboxRecord(frameId, peerHex, wire);
    final pending = _pendingOutboxEnqueues;
    if (pending != null &&
        pending.peer == peerHex &&
        pending.records.length < 8 &&
        pending.bytes + record.payload.length <= 32 * 1024) {
      pending.records.add(record);
      pending.bytes += record.payload.length;
      await pending.result;
      return;
    }
    final batch = _PendingOutboxEnqueues(peerHex)
      ..records.add(record)
      ..bytes = record.payload.length;
    // Track admission, not just the eventual commit. Maintenance must drain an
    // enqueue already waiting behind another outbox operation on this space.
    batch.result =
        _trackLogWrite(
          (store) => _outboxSerialized(() async {
            if (identical(_pendingOutboxEnqueues, batch)) {
              _pendingOutboxEnqueues = null;
            }
            if (!identical(store, _store)) {
              throw StateError('storage session changed before outbox enqueue');
            }
            if (!await _ensureOutboxLoadedCritical()) {
              throw StateError('durable outbox could not be loaded');
            }
            final seen = <String>{};
            final missing = [
              for (final r in batch.records)
                if (!_outboxById.containsKey(r.frame.frameId) &&
                    seen.add(r.frame.frameId))
                  r,
            ];
            if (missing.isEmpty) return;
            final persisted = await _persistOutboxPayloadsCritical(
              store,
              missing,
            );
            for (final item in persisted) {
              _outboxById[item.frame.frameId] = item;
            }
          }),
        ).whenComplete(() {
          if (identical(_pendingOutboxEnqueues, batch)) {
            _pendingOutboxEnqueues = null;
          }
        });
    _pendingOutboxEnqueues = batch;
    await batch.result;
  }

  @override
  /// Retire a durable frame the peer at [fromPeerHex] confirmed.
  ///
  /// The frame is stored with the destination it was addressed to, and the ACK
  /// must come from THAT peer. Retiring on frameId alone let an accepted
  /// contact who knew the id — `reconnect:`/`accept:` ids are derived from the
  /// peer, and `gcr:` ids are shared across holders — ACK a frame addressed to
  /// someone else and stop its delivery (audit XV-02).
  Future<void> ackOutboxFrame(String frameId, {required String fromPeerHex}) {
    final pending = _pendingOutboxAcks;
    if (pending != null &&
        pending.peer == fromPeerHex &&
        pending.ids.length < 64) {
      pending.ids.add(frameId);
      return pending.result;
    }
    final batch = _PendingOutboxAcks(fromPeerHex)..ids.add(frameId);
    batch.result = _outboxSerialized(() async {
      // Seal before the first await: arrivals during commit need another turn.
      if (identical(_pendingOutboxAcks, batch)) _pendingOutboxAcks = null;
      await _ackOutboxFramesCritical(batch.ids, fromPeerHex: batch.peer);
    });
    _pendingOutboxAcks = batch;
    return batch.result;
  }

  @override
  Future<List<String>> ackOutboxFrames(
    Iterable<String> frameIds, {
    required String fromPeerHex,
  }) => _outboxSerialized(
    () => _ackOutboxFramesCritical(frameIds, fromPeerHex: fromPeerHex),
  );

  Future<List<String>> _ackOutboxFramesCritical(
    Iterable<String> frameIds, {
    required String fromPeerHex,
  }) async {
    if (!await _ensureOutboxLoadedCritical()) {
      throw StateError('durable outbox could not be loaded');
    }
    final ids = frameIds
        .toSet()
        .where((id) => _outboxById[id]?.frame.peerHex == fromPeerHex)
        .toList();
    if (ids.isEmpty) return const <String>[];
    final payloadIds = <int>{for (final id in ids) ..._outboxById[id]!.logIds};
    // Log tombstones have a per-transaction cap. Small transfers can reclaim
    // their payload in this same commit; larger ones retire the index first.
    final inlineCleanup = payloadIds.length <= 1024;
    try {
      // The index is authoritative. Retire all logical rows together; payload
      // garbage may be cleaned in bounded batches after this atomic boundary.
      await _as.commit([
        for (final id in ids) DeleteOp(Ns.outboxIndex, _outboxIndexKey(id)),
        if (inlineCleanup)
          for (final logId in payloadIds) DeleteLogOp(Ns.outbox, logId),
      ]);
    } catch (_) {
      // A refused/uncertain commit must reload its all-or-none durable result.
      _outboxLoaded = false;
      _outboxById.clear();
      rethrow;
    }
    for (final id in ids) {
      _outboxById.remove(id);
    }
    try {
      if (_outboxById.isEmpty) {
        await _as.eraseNamespace(Ns.outbox);
        await _as.eraseNamespace(Ns.outboxIndex);
      } else if (!inlineCleanup) {
        await _cleanupIndexedOutboxCritical();
      }
    } catch (_) {}
    return ids;
  }

  @override
  Future<List<OutboxFrame>> pendingOutboxFrames() =>
      _outboxSerialized(() async {
        if (!await _ensureOutboxLoadedCritical()) return const [];
        return [
          for (final item in _outboxById.values)
            OutboxFrame(
              frameId: item.frame.frameId,
              peerHex: item.frame.peerHex,
              wire: Uint8List.fromList(item.frame.wire),
              // Carried through the copy: dropping it here would hand every
              // reader "unknown age" and quietly disable age-based retention.
              enqueuedAtMs: item.frame.enqueuedAtMs,
            ),
        ];
      });

  @override
  Future<bool> retireOutboxFramesIfCurrent({
    required List<OutboxFrame> obsolete,
    required OutboxFrame retained,
  }) {
    if (obsolete.isEmpty ||
        obsolete.length > 64 ||
        obsolete.map((f) => f.frameId).toSet().length != obsolete.length ||
        obsolete.any(
          (f) => f.peerHex != retained.peerHex || f.frameId == retained.frameId,
        ) ||
        [...obsolete, retained].fold<int>(0, (n, f) => n + f.wire.length) >
            32 * 1024 * 1024) {
      throw ArgumentError('invalid guarded outbox retirement');
    }
    OutboxFrame freeze(OutboxFrame frame) => OutboxFrame(
      frameId: frame.frameId,
      peerHex: frame.peerHex,
      wire: Uint8List.fromList(frame.wire),
    );
    final old = obsolete.map(freeze).toList();
    final keep = freeze(retained);
    return _trackLogWrite(
      (store) => _outboxSerialized(() async {
        if (!identical(store, _store)) {
          throw StateError('guarded retirement storage session changed');
        }
        if (!await _ensureOutboxLoadedCritical()) {
          throw StateError('durable outbox could not be loaded');
        }
        for (final expected in [...old, keep]) {
          final held = _outboxById[expected.frameId]?.frame;
          if (held == null ||
              held.peerHex != expected.peerHex ||
              !_bytesEqual(held.wire, expected.wire)) {
            return false;
          }
        }
        await _ackOutboxFramesCritical(
          old.map((f) => f.frameId),
          fromPeerHex: keep.peerHex,
        );
        return true;
      }),
    );
  }

  static const _outboxCleanupKey = 'outbox.replacement_scrub_pending';

  @override
  Future<bool> replaceOutboxFrames(
    List<OutboxFrame> expected,
    List<OutboxFrame> replacement,
  ) {
    if (expected.isEmpty ||
        expected.length > 4096 ||
        replacement.length > 4096) {
      throw ArgumentError('invalid outbox replacement size');
    }
    final peer = expected.first.peerHex;
    final oldIds = {for (final f in expected) f.frameId};
    final newIds = {for (final f in replacement) f.frameId};
    if (oldIds.length != expected.length ||
        newIds.length != replacement.length ||
        oldIds.any(newIds.contains) ||
        [...expected, ...replacement].any((f) => f.peerHex != peer) ||
        [
              ...expected,
              ...replacement,
            ].fold<int>(0, (n, f) => n + f.wire.length) >
            32 * 1024 * 1024) {
      throw ArgumentError('inconsistent outbox replacement');
    }
    OutboxFrame freeze(OutboxFrame f) => OutboxFrame(
      frameId: f.frameId,
      peerHex: f.peerHex,
      wire: Uint8List.fromList(f.wire),
      enqueuedAtMs: f.enqueuedAtMs,
    );
    final old = expected.map(freeze).toList();
    final fresh = replacement.map(freeze).toList();
    return _trackLogWrite((store) async {
      bool matches(OutboxFrame a, OutboxFrame b) =>
          a.peerHex == b.peerHex && _bytesEqual(a.wire, b.wire);
      Future<bool> check() async {
        if (!identical(store, _store)) {
          throw StateError('outbox replacement session changed');
        }
        if (!await _ensureOutboxLoadedCritical()) {
          throw StateError('durable outbox could not be loaded');
        }
        for (final frame in old) {
          final held = _outboxById[frame.frameId]?.frame;
          if (held == null || !matches(frame, held)) return false;
        }
        for (final frame in fresh) {
          final held = _outboxById[frame.frameId]?.frame;
          if (held != null && !matches(frame, held)) return false;
        }
        return true;
      }

      if (!await _outboxSerialized(check)) return false;
      // Stage bounded cohorts, releasing the outbox lane between commits so
      // unrelated ACK/enqueue operations are not parked behind a large copy.
      // The admitted outer write pins the same space through every cohort.
      for (var i = 0; i < fresh.length; i += 8) {
        final admitted = await _outboxSerialized(() async {
          if (!await check()) return false;
          final missing = <_QueuedOutboxFrame>[];
          for (final frame in fresh.skip(i).take(8)) {
            if (_outboxById.containsKey(frame.frameId)) continue;
            final stamped = OutboxFrame(
              frameId: frame.frameId,
              peerHex: peer,
              wire: frame.wire,
              enqueuedAtMs:
                  frame.enqueuedAtMs ?? DateTime.now().millisecondsSinceEpoch,
            );
            final payload = _sk(
              jsonEncode({
                'id': stamped.frameId,
                'p': peer,
                'w': base64Encode(stamped.wire),
                't': stamped.enqueuedAtMs,
              }),
            );
            if (payload.length > _outboxMaxPayloadBytes) {
              throw ArgumentError('outbox replacement payload exceeds bound');
            }
            missing.add((frame: stamped, payload: payload));
          }
          if (missing.isNotEmpty) {
            final stored = await _persistOutboxPayloadsCritical(store, missing);
            for (final item in stored) {
              _outboxById[item.frame.frameId] = item;
            }
          }
          return true;
        });
        if (!admitted) return false;
      }
      return _outboxSerialized(() async {
        if (!await check()) return false;
        // A replacement ACK can race staging. Absence is not proof that its
        // full payload is now durable; leave the original intact and retry.
        for (final frame in fresh) {
          final held = _outboxById[frame.frameId]?.frame;
          if (held == null || !matches(frame, held)) return false;
        }
        final payloadIds = {
          for (final id in oldIds) ..._outboxById[id]!.logIds,
        };
        try {
          await store.commit([
            for (final id in oldIds)
              DeleteOp(Ns.outboxIndex, _outboxIndexKey(id)),
            if (payloadIds.length <= 1024)
              for (final id in payloadIds) DeleteLogOp(Ns.outbox, id),
            PutOp(Ns.settings, _sk(_outboxCleanupKey), Uint8List.fromList([1])),
          ]);
        } catch (_) {
          _outboxLoaded = false;
          _outboxById.clear();
          rethrow;
        }
        for (final id in oldIds) {
          _outboxById.remove(id);
        }
        return true;
      });
    });
  }

  @override
  Future<void> finishOutboxCleanup() => _trackLogWrite(
    (store) => _outboxSerialized(() async {
      if (!identical(store, _store)) {
        throw StateError('outbox cleanup session changed');
      }
      if (await store.get(Ns.settings, _sk(_outboxCleanupKey)) == null) return;
      if (!await _ensureOutboxLoadedCritical()) {
        throw StateError('durable outbox could not be loaded');
      }
      await _cleanupIndexedOutboxCritical();
      await scrubDeleted();
      await store.commit([DeleteOp(Ns.settings, _sk(_outboxCleanupKey))]);
    }),
  );

  Future<void> _invalidateOutboxCache() => _outboxSerialized(() async {
    _outboxById.clear();
    _outboxLoaded = false;
  });

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
  // Composite key -> the namespace + log_id the live message was written
  // under, so delete can rewrite the SAME legacy/sharded record without an
  // independent full scan.
  final Map<String, ({int namespace, int logId})> _scanLogIds = {};
  // Composite keys (and legacy bare ids) that have been tombstoned — lets
  // isMessageDeleted answer in O(1) off the warm fold instead of re-scanning.
  final Set<String> _scanDeletedKeys = {};
  final Map<
    String,
    ({
      PendingMessageDeletion pending,
      int namespace,
      int logId,
      Map<String, dynamic> tomb,
    })
  >
  _scanPendingDeletions = {};
  final Set<String> _scanDeletedLegacyIds = {};
  final Set<String> _scanBlockedKeys = {};
  // Composite key -> latest delivery status (status ops carry their conversation).
  final Map<String, MessageStatus> _scanStatusOps = {};
  // Legacy (pre-scoping) status ops had no conversation; applied by bare id.
  final Map<String, MessageStatus> _scanStatusLegacy = {};
  // Composite key -> latest attestation state (op:'sig' rows, conversation-scoped).
  final Map<String, MessageSignature> _scanSigOps = {};
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
  /// Per conversation, per author: the cleared seq CEILING and WHEN the clear
  /// that set it happened.
  ///
  /// The ceiling alone never expires: once a peer's counter sits at or below it
  /// — after a reinstall, a restored container, any counter reset — every
  /// message it sends afterwards is dropped at birth, silently, forever.
  /// Reported by a user as "cleared the history and now nothing from the phone
  /// arrives", and measured: 67 writes, seq 277 through 307, every one
  /// swallowed, while this device's own rows from after the same clear stayed
  /// visible. A clear means "everything sent before this moment", so the moment
  /// is what bounds it.
  ///
  /// The two numbers are kept TOGETHER, per author, and never max-merged apart.
  /// Two clears can disagree — an older one with a higher ceiling, a newer one
  /// with a lower one after the peer's counter reset — and taking the highest
  /// ceiling beside the latest time would invent a clear that never happened,
  /// suppressing a message neither of them covers.
  final Map<String, Map<String, ({int seq, int at})>> _clearedWatermark = {};

  /// Per conversation: WHEN this identity's OWN newest clear of it happened.
  ///
  /// Set only by a clear WE made — locally, or on one of this identity's other
  /// devices — never by a peer's, which keeps its existing bounded semantics
  /// untouched.
  ///
  /// It exists because the per-author ceiling cannot carry a clear between a
  /// person's own devices. The bounding in [applyRemoteClear] drops every
  /// watermark key that is neither the author nor ourselves — for a peer's
  /// clear the dropped key is a stranger, but for our OWN clear the dropped key
  /// is THE PEER, which is half the conversation. So a sibling would receive a
  /// clear that reached only its own outgoing rows.
  ///
  /// Time is the bound that works for both halves, and it is a SAFE one: the
  /// stamp is written by the device that APPLIES the clear, never carried in
  /// from the wire, so no sender can widen it.
  final Map<String, int> _clearedAt = {};
  int _scanFoldedUpTo = 0; // next log_id not yet folded into the state above
  int? _foldReadingUpTo;
  bool _messageScanNeedsRebuild = false;
  List<Message>?
  _scanResult; // materialised; valid while _scanFoldedUpTo == nextId

  // Namespace discovery is lazy and per-open-space. The retired namespace 3
  // is excluded; marker keys recover supported shards even when a concurrent
  // commit persisted a slightly stale global next-id.
  final Set<int> _messageLogNamespaces = <int>{};
  final Set<int> _messageLogNamespaceMarkers = {};
  Future<void>? _messageLogNamespacesInit;
  final Map<int, Future<void>> _messageLogMarkerWrites = {};

  // Single-flight gate serializing all scan-cache access (scan + invalidate).
  Future<void> _scanGate = Future<void>.value();
  // Destructive operations discover their rows through the scan gate, then
  // scrub them outside it. A prepared insert must not straddle that discovery
  // and publish bytes the eraser never saw. Do not wait while holding the scan
  // gate: refuse this page so erasure can finish and history can retry safely.
  int _messageErasureEpoch = 0, _messageErasures = 0;
  void Function() _preparedErasureCheck() {
    final epoch = _messageErasureEpoch;
    void check() {
      if (_messageErasures != 0 || epoch != _messageErasureEpoch) {
        throw StateError('Message erasure crossed prepared publication');
      }
    }

    check();
    return check;
  }

  Future<T> _withMessageErasure<T>(Future<T> Function() body) async {
    _messageErasureEpoch++;
    _messageErasures++;
    try {
      return await body();
    } finally {
      _messageErasures--;
      _messageErasureEpoch++;
    }
  }

  Future<T> _serialized<T>(Future<T> Function() body) {
    final result = _scanGate.then((_) => body());
    _scanGate = result.then((_) {}, onError: (_) {});
    return result;
  }

  // A sequence and its event/cursor commit are one operation. Global log ids
  // already have their own nonblocking allocator; they do not protect this
  // per-(conversation, author) cursor from two callers reading the same value.
  final _convSequenceTails = <(String, String), Future<void>>{};
  final _positionedMessageAppends =
      <(String, String), _PositionedMessageAppends>{};
  final _pendingOrderingAdoptions =
      <(String, String), _PendingOrderingAdoptions>{};
  int _convSequenceFences = 0;

  Future<T> _withConvSequence<T>(
    String conversation,
    String author,
    Future<T> Function() body, {
    bool acceptedBeforeFence = false,
  }) {
    final session = _store;
    if (session == null || (_convSequenceFences > 0 && !acceptedBeforeFence)) {
      return Future.error(StateError('storage is closing or locked'));
    }
    final key = (conversation, author);
    // An edit, clear, local allocation or large row must retain its own turn.
    _positionedMessageAppends.remove(key);
    _pendingOrderingAdoptions.remove(key);
    final previous = _convSequenceTails[key] ?? Future<void>.value();
    final result = previous.then((_) {
      if (!identical(session, _store)) {
        throw StateError('storage session changed before message write');
      }
      return runZoned(body, zoneValues: {_acceptedConvWriteZone: this});
    });
    late final Future<void> tail;
    tail = result.then<void>((_) {}, onError: (_) {}).whenComplete(() {
      if (identical(_convSequenceTails[key], tail)) {
        _convSequenceTails.remove(key);
      }
    });
    _convSequenceTails[key] = tail;
    return result;
  }

  Future<T> _drainConvSequenceWrites<T>(Future<T> Function() body) async {
    _convSequenceFences++;
    try {
      // Edits accepted before the fence may still join their stream. New
      // edits/appends/clears are refused until maintenance has finished.
      await _editGate;
      await Future.wait(_convSequenceTails.values.toList());
      while (_logWrites.isNotEmpty) {
        await Future.wait(_logWrites.toList());
      }
      return await body();
    } finally {
      _convSequenceFences--;
    }
  }

  // Single-flight gate serializing file-blob stores. storeFile reads the
  // file_next_log counter from the store, appends the chunks across SEVERAL
  // commits, then bumps the counter LAST — so two concurrent stores (e.g. the
  // user sending a file while an inbound one completes) could otherwise read the
  // same base and write colliding chunk log-ids, corrupting both blobs. Kept
  // SEPARATE from _scanGate so a multi-MiB store never blocks message scans.
  Future<void> _fileGate = Future<void>.value();
  int _fileIoFences = 0;
  int _fileReadEpoch = 0;

  // Reads stay concurrent: putting a large download ahead of journal reads on
  // the write gate would create another head-of-line wait. Pin the backing
  // space and blob tier instead, and reject results invalidated by maintenance.
  // In particular, never reacquire _as after the on-disk metadata await: an
  // older identity's request could otherwise read the newly opened identity.
  Future<T> _readFileSession<T>(
    Future<T> Function(_FileReadSession session) read,
  ) async {
    final session = (store: _as, blobs: _blobs, epoch: _fileReadEpoch);
    _checkFileReadSession(session);
    final result = await read(session);
    _checkFileReadSession(session);
    return result;
  }

  void _checkFileReadSession(_FileReadSession session) {
    if (!identical(session.store, _store) ||
        !identical(session.blobs, _blobs) ||
        session.epoch != _fileReadEpoch ||
        _closePending != null ||
        _convSequenceFences > 0 ||
        _fileIoFences > 0) {
      throw StateError('file storage session changed or is closing or erasing');
    }
  }

  Future<T> _fileSerialized<T>(Future<T> Function() body) {
    // Maintenance begins at the conversation fence, before it reaches the
    // file gate. Refuse new producers immediately, but finish accepted work
    // against the same space before closing or erasing it.
    if (_closePending != null || _convSequenceFences > 0 || _fileIoFences > 0) {
      return Future<T>.error(StateError('file storage is closing or erasing'));
    }
    final session = _store;
    if (session == null) {
      return Future<T>.error(StateError('file storage is locked'));
    }
    final result = _fileGate.then((_) {
      if (!identical(session, _store)) {
        throw StateError('storage session changed before file operation');
      }
      return body();
    });
    _fileGate = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<T> _drainFileIo<T>(Future<T> Function() body) async {
    _fileIoFences++;
    _fileReadEpoch++;
    try {
      final result = _fileGate.then((_) => body());
      _fileGate = result.then<void>((_) {}, onError: (_) {});
      return await result;
    } finally {
      _fileIoFences--;
    }
  }

  // Reserve a durable window before handing out any global log ids. Start
  // small on each open, then grow after successful reservations, up to 64:
  // sustained history must not pay a separate commit every eight records.
  // The unused reservation is bounded by 64 ids, unless a caller explicitly
  // requests a larger batch (which still reserves that complete batch).
  // Data commits may finish out of order; they must never write an older
  // msg_next_id over a newer one. A crash can skip unused internal ids, but
  // conversation sequence numbers are still committed gap-free with events.
  static const int _logIdReserveAhead = 8;
  static const int _logIdReserveMax = 64;
  static final Object _acceptedConvWriteZone = Object();
  final _logWrites = <Future<void>>{};
  AsyncKvLogStore? _allocatorStore;
  int? _nextIdCache;
  int? _visibleNextLogId;
  int _logReservedUntil = 0;
  int _logReservationSize = _logIdReserveAhead;
  Future<void>? _idInit;
  Future<void>? _idReservation;

  void _resetLogAllocator() {
    _allocatorStore = null;
    _nextIdCache = null;
    _visibleNextLogId = null;
    _logReservedUntil = 0;
    _logReservationSize = _logIdReserveAhead;
    _idInit = null;
    _idReservation = null;
  }

  Future<void> _ensureLogAllocator(AsyncKvLogStore store) async {
    if (!identical(_allocatorStore, store)) {
      _resetLogAllocator();
      _allocatorStore = store;
    }
    if (_nextIdCache != null) return;
    var init = _idInit;
    if (init == null) {
      init = () async {
        final raw = await store.get(Ns.settings, _sk('msg_next_id'));
        final first = raw == null ? 1 : int.tryParse(utf8.decode(raw)) ?? 1;
        if (first < 1) throw StateError('invalid message log cursor');
        if (!identical(store, _store) || !identical(store, _allocatorStore)) {
          throw StateError('storage session changed during log allocation');
        }
        _nextIdCache = first;
        _visibleNextLogId = first;
        _logReservedUntil = first;
      }();
      _idInit = init;
    }
    try {
      await init;
    } catch (_) {
      if (identical(_idInit, init)) _idInit = null;
      rethrow;
    }
  }

  Future<int> _allocLogId(AsyncKvLogStore store, {int? maximum}) =>
      _allocLogIds(store, count: 1, maximum: maximum);

  Future<int> _allocLogIds(
    AsyncKvLogStore store, {
    required int count,
    int? maximum,
  }) async {
    await _ensureLogAllocator(store);
    while (true) {
      if (!identical(store, _store) || !identical(store, _allocatorStore)) {
        throw StateError('storage session changed during log allocation');
      }
      final next = _nextIdCache!;
      if (maximum != null && next + count - 1 > maximum) {
        throw RangeError.range(next + count - 1, 1, maximum, 'message log id');
      }
      if (next + count <= _logReservedUntil) {
        _nextIdCache = next + count;
        return next;
      }
      var reservation = _idReservation;
      if (reservation == null) {
        final int end = maximum == null
            ? next + max<int>(_logReservationSize, count)
            : min<int>(
                next + max<int>(_logReservationSize, count),
                maximum + 1,
              );
        late final Future<void> write;
        write =
            () async {
              await store.commit([
                PutOp(Ns.settings, _sk('msg_next_id'), _sk('$end')),
              ]);
              if (!identical(store, _store) ||
                  !identical(store, _allocatorStore)) {
                throw StateError(
                  'storage session changed during log reservation',
                );
              }
              _logReservedUntil = end;
              _logReservationSize = min(
                _logReservationSize * 2,
                _logIdReserveMax,
              );
            }().whenComplete(() {
              if (identical(_idReservation, write)) _idReservation = null;
            });
        _idReservation = reservation = write;
      }
      await reservation;
    }
  }

  Future<T> _trackLogWrite<T>(Future<T> Function(AsyncKvLogStore) body) {
    final store = _store;
    if (store == null ||
        (_convSequenceFences > 0 &&
            Zone.current[_acceptedConvWriteZone] != this)) {
      return Future.error(StateError('storage is closing or locked'));
    }
    final result = body(store);
    late final Future<void> settled;
    settled = result.then<void>((_) {}, onError: (_) {}).whenComplete(() {
      _logWrites.remove(settled);
    });
    _logWrites.add(settled);
    return result;
  }

  void _noteLogCommit(
    AsyncKvLogStore store,
    int logId, {
    bool message = false,
  }) {
    if (!identical(store, _store) || !identical(store, _allocatorStore)) return;
    _visibleNextLogId = max(_visibleNextLogId ?? 1, logId + 1);
    if (message) {
      // An earlier allocated record can arrive after a later one was folded.
      // Replay the complete prefix in that rare case: replaying only an old
      // post over warm edit/delete maps is not idempotent.
      if (logId < _scanFoldedUpTo ||
          (_foldReadingUpTo != null && logId < _foldReadingUpTo!)) {
        _messageScanNeedsRebuild = true;
      }
      _scanResult = null;
    }
  }

  Future<int> _commitAtNextLogId(List<KvLogOp> Function(int logId) opsFor) =>
      _trackLogWrite((store) async {
        final logId = await _allocLogId(store);
        await store.commit(opsFor(logId));
        _noteLogCommit(store, logId);
        return logId;
      });

  /// Route a fresh global id to its deterministic message shard. Only the
  /// first record in a shard waits for its durable discovery marker; data
  /// commits in unrelated streams remain independent.
  Future<int> _commitAtNextMessageLogId(
    List<KvLogOp> Function(int namespace, int logId) opsFor,
  ) => _trackLogWrite((store) async {
    final logId = await _allocLogId(store, maximum: Ns.messageLogShardCapacity);
    final namespace = Ns.messageLogNamespaceFor(logId);
    await _ensureMessageLogNamespacesLoaded();
    final messageOps = <KvLogOp>[];
    final namespaces = <int>{namespace};
    var lastId = logId;
    for (final op in opsFor(namespace, logId)) {
      if (op is! AppendLogOp ||
          op.namespace != namespace ||
          op.logId != logId ||
          op.payload.length <= _messageInlineBytes) {
        messageOps.add(op);
        continue;
      }
      final payload = op.payload;
      if (payload.length > _messagePayloadMaxBytes) {
        throw ArgumentError('message event exceeds the storage bound');
      }
      final count =
          (payload.length + _messagePartBytes - 1) ~/ _messagePartBytes;
      final first = await _allocLogIds(
        store,
        count: count,
        maximum: Ns.messageLogShardCapacity,
      );
      lastId = first + count - 1;
      for (var i = 0; i < count; i++) {
        final id = first + i;
        final ns = Ns.messageLogNamespaceFor(id);
        namespaces.add(ns);
        messageOps.add(
          AppendLogOp(
            ns,
            id,
            _sk(
              jsonEncode({
                'messagePart': 1,
                'k': EventKind.void_.index,
                'owner': logId,
                'i': i,
                'd': base64Encode(
                  Uint8List.sublistView(
                    payload,
                    i * _messagePartBytes,
                    min((i + 1) * _messagePartBytes, payload.length),
                  ),
                ),
              }),
            ),
          ),
        );
      }
      messageOps.add(
        AppendLogOp(
          namespace,
          logId,
          _sk(
            jsonEncode({
              'messageParts': 1,
              'k': EventKind.void_.index,
              'first': first,
              'count': count,
              'length': payload.length,
              'sha256': crypto.sha256.convert(payload).toString(),
            }),
          ),
        ),
      );
    }
    await _publishMessageOps(store, messageOps, namespaces, logId, lastId);
    return logId;
  });

  // Bounded inline posts/metadata consume only internal global ids, never
  // author sequence numbers. The whole bounded set and all shard markers are
  // durable before any append future completes.
  Future<void> _commitPositionedMessageBatch(
    List<Uint8List> payloads, {
    Future<void> Function()? beforeCommit,
    void Function()? checkBeforePublish,
  }) => _trackLogWrite((store) async {
    final first = await _allocLogIds(
      store,
      count: payloads.length,
      maximum: Ns.messageLogShardCapacity,
    );
    await _ensureMessageLogNamespacesLoaded();
    final namespaces = <int>{};
    final ops = <KvLogOp>[];
    for (var i = 0; i < payloads.length; i++) {
      final id = first + i;
      final ns = Ns.messageLogNamespaceFor(id);
      namespaces.add(ns);
      ops.add(AppendLogOp(ns, id, payloads[i]));
    }
    await _publishMessageOps(
      store,
      ops,
      namespaces,
      first,
      first + payloads.length - 1,
      beforeCommit: beforeCommit,
      checkBeforePublish: checkBeforePublish,
    );
  });

  Future<void> _publishMessageOps(
    AsyncKvLogStore store,
    List<KvLogOp> messageOps,
    Set<int> namespaces,
    int logId,
    int lastId, {
    Future<void> Function()? beforeCommit,
    void Function()? checkBeforePublish,
  }) async {
    // Join earlier first-use publications before claiming any new shard.
    // Register one shared flight for all newly touched shards, so a crossing
    // record publishes every fragment and discovery marker in the same commit.
    for (final ns in namespaces) {
      final pending = _messageLogMarkerWrites[ns];
      if (pending != null) await pending;
    }
    final missing = namespaces.difference(_messageLogNamespaceMarkers);
    late final Future<void> publish;
    publish = () async {
      if (beforeCommit != null) await beforeCommit();
      checkBeforePublish?.call();
      await store.commit([
        ...messageOps,
        for (final ns in missing)
          PutOp(
            Ns.settings,
            _sk('$_messageLogNamespaceMarkerPrefix$ns'),
            _sk('1'),
          ),
      ]);
      _messageLogNamespaces.addAll(namespaces);
      _messageLogNamespaceMarkers.addAll(missing);
    }();
    for (final ns in missing) {
      _messageLogMarkerWrites[ns] = publish;
    }
    try {
      await publish;
    } catch (_) {
      // A worker can lose its reply after the atomic commit. Include the
      // possible rows in subsequent reads, without claiming that the write
      // succeeded or spending another author sequence on its behalf.
      _messageLogNamespaces.addAll(namespaces);
      _noteLogCommit(store, logId, message: true);
      if (lastId != logId) _noteLogCommit(store, lastId, message: true);
      rethrow;
    } finally {
      for (final ns in missing) {
        if (identical(_messageLogMarkerWrites[ns], publish)) {
          _messageLogMarkerWrites.remove(ns);
        }
      }
    }
    _noteLogCommit(store, logId, message: true);
    if (lastId != logId) _noteLogCommit(store, lastId, message: true);
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
    _scanPendingDeletions.clear();
    _scanDeletedLegacyIds.clear();
    _scanBlockedKeys.clear();
    _scanStatusOps.clear();
    _scanStatusLegacy.clear();
    _scanSigOps.clear();
    _scanEditWinSeq.clear();
    _clearedWatermark.clear();
    _clearedAt.clear();
    _scanFoldedUpTo = 0;
    _scanResult = null;
    _messageLogNamespaces.clear();
    _messageLogNamespaceMarkers.clear();
    _messageLogNamespacesInit = null;
    _messageLogMarkerWrites.clear();
    _messageScanNeedsRebuild = false;
    // Logical log ids survive a scrub. Keep active reservations across a fold
    // rebuild; open/close/erase reset them only after accepted writers drain.
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
    if ((_deleteScrubPending == null || _deleteScrubRecoveryNeeded) &&
        await _recoverMessageDeletion()) {
      _clearScanState();
    }
    final nextId = await _nextLogId();
    final cached = _scanResult;
    if (cached != null &&
        _scanFoldedUpTo == nextId &&
        !_messageScanNeedsRebuild) {
      return cached;
    }
    await _foldCritical();
    // Materialise from the (now-current) fold state, applying delivery status.
    final result = _scanOrder
        .map((k) {
          final msg = _scanById[k]!;
          // Status by composite (conversation-scoped) key; fall back to a legacy
          // by-id op for messages whose status predates conversation scoping.
          final s = _scanStatusOps[k] ?? _scanStatusLegacy[msg.id];
          final sig = _scanSigOps[k];
          var out = s != null && msg.status != MessageStatus.delivered
              ? msg.copyWith(status: s)
              : msg;
          if (sig != null) out = out.copyWith(signature: sig);
          return out;
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
    if ((_deleteScrubPending == null || _deleteScrubRecoveryNeeded) &&
        await _recoverMessageDeletion()) {
      _clearScanState();
    }
    final nextId = await _nextLogId();
    if (_messageScanNeedsRebuild) _clearScanState();
    if (_scanFoldedUpTo == nextId) return; // fold state already current
    // The fold state is about to change, so the materialised list is now stale.
    // Drop it here (not only in _scanLogCritical) because a NON-materialising
    // caller (isMessageDeleted / _liveEntryFor) advances the fold too — without
    // this, a later loadMessages would see _scanFoldedUpTo == nextId next to a
    // stale _scanResult and return the OLD list.
    _scanResult = null;
    // Read one record of overlap to tolerate either range boundary convention.
    // Filter it below: replaying an old post over a warm edit is not idempotent.
    final start = _scanFoldedUpTo == 0 ? null : _scanFoldedUpTo - 1;
    final scanT0 = DateTime.now();
    var scanned = 0;
    final List<_MessageLogEntry> entries;
    _foldReadingUpTo = nextId;
    try {
      entries = await _messageLogEntries(start: start);
    } catch (_) {
      _messageScanNeedsRebuild = true;
      rethrow;
    } finally {
      _foldReadingUpTo = null;
    }
    final rebuildAfterRead = _messageScanNeedsRebuild;
    _messageScanNeedsRebuild =
        true; // a failed decode must retry from clean maps
    for (final e in entries) {
      if (e.logId < _scanFoldedUpTo || e.logId >= nextId) continue;
      scanned++;
      final m = jsonDecode(utf8.decode(e.payload)) as Map<String, dynamic>;
      if (m['op'] == 'status') {
        final id = m['id'] as String;
        final c = m['c'] as String?;
        final s = MessageStatus.values[m['s'] as int];
        if (c != null) {
          final key = _msgKey(c, id);
          if (_scanStatusOps[key] != MessageStatus.delivered) {
            _scanStatusOps[key] = s;
          }
        } else {
          if (_scanStatusLegacy[id] != MessageStatus.delivered) {
            _scanStatusLegacy[id] = s; // pre-scoping op — applied by bare id
          }
        }
        continue;
      }
      if (m['op'] == 'sig') {
        // Attestation-state op (conversation-scoped), folded onto the message
        // like a status op — latest wins.
        final id = m['id'] as String;
        final c = m['c'] as String?;
        final sig = _sigFromIndex(m['sig']);
        if (c != null) _scanSigOps[_msgKey(c, id)] = sig;
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
          _foldPendingDeletion(m, e.namespace, e.logId);
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
      if (m['op'] == 'ordering') {
        final c = m['c'], id = m['id'];
        if (c is! String || id is! String) continue;
        final key = _msgKey(c, id);
        final post = _scanById[key];
        final author = m['orderAu'], seq = m['orderSq'];
        if (post != null &&
            post.direction == MessageDirection.outgoing &&
            post.author == m['fromAu'] &&
            post.seq == m['fromSq'] &&
            post.ordering == null &&
            author is String &&
            seq is int) {
          _scanById[key] = post.copyWith(ordering: (author: author, seq: seq));
        }
        continue;
      }
      // A blocked-message void also names the id locally, so a sender retry
      // after unblock cannot enter the ordinary chat before Show is pressed.
      // The recovery wire still carries only the void slot, never that id.
      if (m['k'] == EventKind.void_.index) {
        final c = m['c'], blockedId = m['bi'];
        if (c is String && blockedId is String) {
          _scanBlockedKeys.add(_msgKey(c, blockedId));
        }
        continue;
      }
      // Event-log CLEAR row (k:clear): the conversation was cleared up to a
      // per-author seq WATERMARK. Record it (max-merge across repeated clears),
      // then RETROACTIVELY purge already-folded messages at/below it. Messages
      // folded LATER (out-of-order arrival after the clear) are caught by the
      // born-clear guard in the post arm below — together they converge.
      if (m['k'] == EventKind.clear.index) {
        final c = m['c'] as String?;
        final wmRaw = m['wm'];
        if (c != null && wmRaw is Map) {
          final at = m['t'] is int ? m['t'] as int : 0;
          final wm = _clearedWatermark.putIfAbsent(
            c,
            () => <String, ({int seq, int at})>{},
          );
          wmRaw.forEach((au, hw) {
            if (au is String && hw is int && hw > (wm[au]?.seq ?? 0)) {
              wm[au] = (seq: hw, at: at);
            }
          });
          // OUR OWN clear also bounds the conversation by TIME — see
          // [_clearedAt]. A peer's clear does not, so its careful per-author
          // bounding keeps working exactly as it did.
          final ownAtRaw = m['ownAt'];
          final ownAt = ownAtRaw is int ? ownAtRaw : null;
          if (ownAt != null && ownAt > (_clearedAt[c] ?? 0)) {
            _clearedAt[c] = ownAt;
          }
          for (final key in _scanOrder.toList()) {
            final msg = _scanById[key];
            if (msg == null || msg.conversationId != c) continue;
            final a = msg.author, s = msg.seq;
            final tsMs = msg.timestamp.millisecondsSinceEpoch;
            if (ownAt != null && tsMs <= ownAt) {
              _scanById.remove(key);
              _scanOrder.remove(key);
              _scanLogIds.remove(key);
              continue;
            }
            final cleared = a == null ? null : wm[a];
            if (cleared != null &&
                s != null &&
                s <= cleared.seq &&
                tsMs <= cleared.at) {
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
          final authorOk =
              post.author == null ||
              editAuthor == null ||
              post.author == editAuthor;
          final win = _scanEditWinSeq[tk];
          final body = m['b'] as String? ?? post.body;
          final emoji = parseInlineCustomEmoji(body, m['ce']);
          final reflected = m['er'] == true;
          final newer =
              editSeq == null ||
              messageEditWins(
                revision: editSeq,
                contentHash: messageEditContentHash(body, emoji),
                heldRevision: win,
                heldContentHash: messageEditContentHash(
                  post.body,
                  post.customEmoji,
                ),
                reflected: reflected,
                heldReflected: post.reflectedEdit,
              );
          if (authorOk && newer) {
            _scanById[tk] = post.copyWith(
              body: body,
              customEmoji: emoji,
              edited: true,
              reflectedEdit: reflected,
            );
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
      final pTs = m['t'];
      final pCleared = pAu == null ? null : _clearedWatermark[c]?[pAu];
      if (pCleared != null &&
          pSq != null &&
          pSq <= pCleared.seq &&
          pTs is int &&
          pTs <= pCleared.at) {
        final dk = _msgKey(c, id);
        _scanById.remove(dk);
        _scanOrder.remove(dk);
        _scanLogIds.remove(dk);
        continue;
      }
      // Born-clear against OUR OWN clear, which bounds by time rather than by
      // a per-author ceiling (see [_clearedAt]). This is the ordinary case, not
      // an exotic one: a mirror travels the device group, which on a loaded
      // stand runs minutes behind, so the message from before the clear usually
      // arrives after it. Without this, emptying a conversation and then
      // receiving that mirror puts the message back on a screen the person had
      // just emptied.
      if (pTs is int && pTs <= (_clearedAt[c] ?? -1)) {
        final dk = _msgKey(c, id);
        _scanById.remove(dk);
        _scanOrder.remove(dk);
        _scanLogIds.remove(dk);
        continue;
      }
      final k = _msgKey(c, id);
      if (!_scanById.containsKey(k)) _scanOrder.add(k);
      // Replayed originals and metadata updates carry no edit revision. They
      // must not replace a resolved edit while leaving its winning revision in
      // the index: that mismatches text and version and can poison subsequent
      // peer reconciliation. Actual edit rows above remain authoritative.
      final heldEdit = _scanEditWinSeq.containsKey(k) ? _scanById[k] : null;
      _scanById[k] = Message(
        id: id,
        conversationId: c,
        direction: MessageDirection.values[m['d'] as int],
        body: heldEdit?.body ?? m['b'] as String,
        timestamp: DateTime.fromMillisecondsSinceEpoch(m['t'] as int),
        status: MessageStatus.values[m['s'] as int],
        edited: heldEdit?.edited ?? (m['e'] == 1),
        reflectedEdit: heldEdit?.reflectedEdit ?? (m['er'] == true),
        fileId: m['fi'] as String?,
        fileName: m['fn'] as String?,
        fileSize: m['fs'] as int?,
        fileContentId: m['fc'] as String?,
        fileExternal: m['fx'] == 1,
        thumb: m['tb'] as String?,
        customEmoji:
            heldEdit?.customEmoji ??
            parseInlineCustomEmoji(m['b'] as String, m['ce']),
        author: m['au'] as String?,
        seq: m['sq'] as int?,
        positionVerified: m['pv'] is bool ? m['pv'] as bool : null,
        replyToId: m['rt'] as String?,
        forwardedFrom: m['fw'] as String?,
        signature: _sigFromIndex(m['sig']),
      );
      _scanLogIds[k] = (namespace: e.namespace, logId: e.logId);
      _scanBlockedKeys.remove(k);
      _scanDeletedKeys.remove(
        k,
      ); // a live record supersedes an earlier tombstone
      _scanPendingDeletions.remove(k);
    }
    _scanFoldedUpTo = nextId;
    _messageScanNeedsRebuild = rebuildAfterRead;
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
  Future<void> close() {
    final pending = _closePending;
    if (pending != null) return pending;
    late final Future<void> closing;
    closing =
        _drainConvSequenceWrites(
          () => _drainRatchetIo(() => _drainFileIo(_close)),
        ).whenComplete(() {
          if (identical(_closePending, closing)) _closePending = null;
        });
    _closePending = closing;
    return closing;
  }

  Future<void>? _closePending;

  Future<void> _close() async {
    final s = _store;
    // Clear the handle FIRST: a throwing native close must never leave a stale
    // _store behind — that would wedge every later open of the same container
    // behind its exclusive flock until an app restart. The error itself is
    // logged and swallowed (callers close best-effort on teardown paths).
    _store = null;
    _ratchetSavesSinceScrub = null;
    _ratchetCommittedChunks.clear();
    _resetLogAllocator();
    _deleteScrubPending = null;
    _legacyDeleteScrubReady = null;
    _deleteScrubRecoveryNeeded = false;
    _anchorBeforeDeletionRecovery = null;
    try {
      await s?.close();
    } catch (e) {
      devLog(() => 'xVeil[storage]: close failed (handle dropped anyway): $e');
    }
    await _invalidateScanCache();
    await _invalidateOutboxCache();
  }
}
