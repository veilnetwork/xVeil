import 'dart:typed_data';

/// Namespace tags inside a hidden-volume space. Byte 0 is RESERVED by the
/// library; these mirror the conventional layout from the integration guide.
class Ns {
  static const int settings = 1;
  static const int contacts = 2;

  /// Retired pre-sharding message-log namespace. Nothing reads or writes it;
  /// it stays declared so the id is never reused, and so the erase paths can
  /// still name it when destroying a container outright.
  static const int messageLog = 3;
  static const int media = 4;

  /// Append-log namespace for file-transfer chunk bytes (KV values are capped
  /// ~2KB, so large files live here as <=8KiB log records — deniable, in the
  /// container, not plaintext on disk).
  static const int fileChunks = 5;

  /// Append-log namespace for the DURABLE FRAME OUTBOX: control frames (sign
  /// request/response, edit, delete, clear, accept, reconnect) that must reach a
  /// peer are persisted here so a post-restart flush re-drives them until the
  /// recipient acks. Chat messages have their own durability via [messageLog];
  /// this gives everything else the same guarantee by construction.
  static const int outbox = 6;

  /// Append-log namespace for the CALL JOURNAL: one immutable record per
  /// finished call. The journal must NOT live in a single rewritten KV value —
  /// the at-rest store bounds one commit's DataBatch to ~4KB and a hot key's
  /// accumulated versions made every whole-journal rewrite throw
  /// PayloadTooLarge after ~11 rows (rows were then silently lost).
  static const int callLog = 7;

  /// KV namespace mapping a stable hash of each pending outbox frame id to the
  /// frame's [outbox] log id. The payload remains in the log (control frames
  /// can exceed the KV value limit); this small index makes restart and every
  /// retry proportional to the number of pending frames instead of the entire
  /// historical enqueue/ack journal.
  static const int outboxIndex = 8;

  /// KV namespace holding the DOUBLE-RATCHET state of one-to-one conversations
  /// — the one thing in this app that cannot be rebuilt from anything public.
  ///
  /// veil keeps its ratchet sessions in memory and never persists them: its
  /// only database belongs to the mailbox, and neither the send path nor the
  /// frame dispatcher can reach it. So the host keeps them, and "the host"
  /// here means the deniable container — every byte of an exported session is
  /// key material.
  ///
  /// Its own namespace rather than a prefix inside [settings] for two reasons.
  /// Enumerating what to restore at startup is then exactly `kvKeys` with no
  /// prefix filtering, and the settings namespace is the one the content
  /// collector already walks key-by-key — hundreds of conversation rows would
  /// be paid for on every sweep that has nothing to do with them.
  static const int ratchet = 9;

  /// Message-log shards occupy an otherwise-unused namespace range.
  ///
  /// hidden-volume's log index is bounded per namespace (roughly 10–20K log
  /// ids with the current two-level tree). Keeping each deterministic segment
  /// below that floor lets an aged profile continue appending without moving
  /// or deleting its legacy history. The global log id remains the ordering
  /// source of truth, so no mutable "active shard" pointer or append lock is
  /// needed.
  /// The native commit payload can carry at most 95 active namespace roots.
  /// NINE are reserved above (including the legacy message log and the ratchet
  /// store), leaving 86 shards without ever making a fully-populated app space
  /// exceed that format ceiling. Namespace is a u8, but using all 224 remaining
  /// byte values would fail much earlier with `TooManyNamespaces`.
  ///
  /// The last shard byte came down by one when [ratchet] was added, and that is
  /// the only safe direction to move it: [messageLogNamespaceFor] is a pure
  /// function of the log id and does not shift, so lowering the bound lowers
  /// the CEILING and renumbers nothing. Raising it would have moved existing
  /// rows out from under the shard that holds them.
  static const int messageLogShardFirst = 32;
  static const int messageLogShardLast = 117;

  /// The highest shard byte any build has ever been able to allocate.
  ///
  /// Only the ERASE paths use it. Forensic deletion is about what a container
  /// holds, not about what this build would have put there, so narrowing the
  /// allocator must not narrow the sweep — exactly the reason namespace 3 is
  /// still named by [HiddenVolumeStorage.eraseSpace] long after it was retired.
  static const int messageLogShardRetiredLast = 118;
  static const int messageLogShardSize = 8192;
  static const int messageLogShardCapacity =
      (messageLogShardLast - messageLogShardFirst + 1) * messageLogShardSize;

  static int messageLogNamespaceFor(int logId) {
    if (logId <= 0 || logId > messageLogShardCapacity) {
      throw RangeError.range(
        logId,
        1,
        messageLogShardCapacity,
        'logId',
        'message-log namespace range exhausted',
      );
    }
    return messageLogShardFirst + ((logId - 1) ~/ messageLogShardSize);
  }
}

/// A single write in an atomic [KvLogStore.commit] batch. Mirrors
/// hidden-volume's `WriteOp` so the real adapter maps 1:1 onto `ffi.HvWriteOp`.
sealed class KvLogOp {
  const KvLogOp();
}

class PutOp extends KvLogOp {
  const PutOp(this.namespace, this.key, this.value);
  final int namespace;
  final Uint8List key;
  final Uint8List value;
}

class DeleteOp extends KvLogOp {
  const DeleteOp(this.namespace, this.key);
  final int namespace;
  final Uint8List key;
}

class AppendLogOp extends KvLogOp {
  const AppendLogOp(this.namespace, this.logId, this.payload);
  final int namespace;
  final int logId;
  final Uint8List payload;
}

/// Remove one logical record from a Log namespace. Unlike appending an empty
/// payload, this releases the log id from hidden-volume's bounded B+ index.
class DeleteLogOp extends KvLogOp {
  const DeleteLogOp(this.namespace, this.logId);
  final int namespace;
  final int logId;
}

class KvLogEntry {
  const KvLogEntry(this.logId, this.payload);
  final int logId;
  final Uint8List payload;
}

/// How much of the container file is still carrying live data, as ONE space
/// sees it. Mirrors hidden-volume's `SpaceStats` slot pair.
///
/// Superseded chunks are not freed for the writer to overwrite at will, so the
/// file only grows and a repack is what returns the space.
///
/// It is NOT true that a freed slot is never reused: that prohibition was
/// LIFTED. `third_party/hidden-volume/DESIGN.md` §9.1 says so in its first
/// line — "Retired slots are reused. This section replaces the slot-reuse
/// prohibition" — and reuse is live in the code (`reuse_count`,
/// `churn_decoys`, `CHURN_PER_REUSE`). What makes it safe is churn: a commit
/// that reuses k slots rewrites k decoys drawn from the same pool, in the same
/// commit, under the same fsync, so a snapshot pair cannot tell a rewritten
/// real slot from a rewritten decoy.
///
/// The stale wording mattered: it was read as an architectural reason the
/// container must grow, and that reasoning was then repeated elsewhere.
/// That is not a leak, but it means the file's size stops describing what is
/// in it, and NOTHING told the user — a container observed at 7.0 GB compacted
/// down to 4.8 MB.
///
/// [totalSlots] is the whole file's slot count; [ownedChunks] is what THIS
/// space still owns. So on a lone-space container the difference is dead
/// padding, and [deadFraction] is what a compaction would give back. On a
/// container hosting several spaces the other spaces' chunks are not "owned"
/// here either, so this UNDERSTATES utilization — which is why the one caller
/// that turns it into an offer to compact does so only where compaction is
/// available at all, i.e. a single identity.
final class SlotUtilization {
  const SlotUtilization({required this.ownedChunks, required this.totalSlots});

  /// Chunks decryptable under this space's key (superblock replicas, commits,
  /// index nodes, data batches).
  final int ownedChunks;

  /// Slots in the container file, excluding the cleartext header chunk.
  final int totalSlots;

  /// Share of the file that is still live data, in `[0, 1]`.
  ///
  /// An EMPTY container answers `0.0`, matching `SpaceStats::utilization_ratio`
  /// — which is why [deadFraction] cannot simply be `1 - liveFraction`.
  double get liveFraction {
    if (totalSlots <= 0) return 0.0;
    final live = ownedChunks / totalSlots;
    return live > 1.0 ? 1.0 : live;
  }

  /// Share of the file a compaction would reclaim, in `[0, 1]`.
  ///
  /// `0.0` for a container with no slots at all: there, `liveFraction` is 0
  /// because there is NOTHING, not because everything in it is dead, and
  /// inverting it blindly would report a brand-new container as 100% garbage.
  double get deadFraction => totalSlots <= 0 ? 0.0 : 1.0 - liveFraction;
}

/// Thin port over a single unlocked hidden-volume space (KV + append-log,
/// atomic batched commits). The production adapter wraps `HvSpace`; the fake
/// is pure in-memory.
abstract interface class KvLogStore {
  /// Apply a batch atomically; returns the new commit sequence.
  int commit(List<KvLogOp> ops);

  Uint8List? get(int namespace, Uint8List key);

  Uint8List? readLog(int namespace, int logId);

  List<KvLogEntry> iterLogRange({
    required int namespace,
    int? start,
    int? end,
    required int limit,
  });

  int count(int namespace);

  /// Keys of every KV entry in [namespace], sorted ascending (values are not
  /// transferred). Exists for settings-namespace garbage collection: a
  /// hidden-volume namespace's 2-level B+ index has a hard entry budget
  /// (`IndexFull`), so orphaned bookkeeping keys must be enumerable to be
  /// deletable. Maps to `HvSpace.kvKeys`.
  List<Uint8List> kvKeys(int namespace);

  /// Erase EVERY entry in [namespace] (KV keys or log records). Returns the
  /// number erased. Used to forensically delete an identity's data; pair with
  /// [scrub] so the prior plaintext can no longer be recovered. Maps to
  /// hidden-volume's `Space::erase_namespace`.
  int eraseNamespace(int namespace);

  /// Reclaim/overwrite data chunks orphaned by replaced or tombstoned log
  /// records (the edit/delete path) so the prior plaintext is no longer
  /// recoverable from the container. Maps to hidden-volume's
  /// `vacuum_data_batches`/`compact_known`; a no-op where unsupported.
  void scrub();

  /// This space's opaque `SpaceKeys` (64 bytes — the per-space decryption root),
  /// for a master roster to store and later reopen the space via a
  /// [KeysSpaceOpener] without its password. **Sensitive** — keep only inside a
  /// deniable space, never log. Maps to `HvSpace.spaceKeys`.
  Uint8List exportKeys();

  /// Live-vs-total slot occupancy of the container behind this space, or null
  /// where the backing cannot answer (the in-memory fake, which has no file,
  /// and the multi-space handle, whose FFI exposes no per-space stats). Maps
  /// to `HvSpace.stats()`.
  ///
  /// Null is "unknown", NOT "nothing to reclaim" — a caller must not render it
  /// as 0 bytes of dead padding.
  SlotUtilization? slotUtilization();

  void close();
}

/// Opens (or creates) the space for [password]. Returns null when no space
/// matches — the production opener maps hidden-volume's `AuthFailed` (which
/// deliberately conflates "wrong password" and "no such space") to null.
typedef SpaceOpener =
    KvLogStore? Function({required Uint8List password, required bool create});

/// Opens a space directly from its pre-derived [keys] (64 bytes from
/// [KvLogStore.exportKeys]) — the master-space path, no password. Returns null
/// when the keys match no space (`AuthFailed`). Maps to `HvSpace.openWithKeys`.
typedef KeysSpaceOpener = KvLogStore? Function(Uint8List keys);
