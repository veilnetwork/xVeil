import 'dart:typed_data';

import 'package:hidden_volume/hidden_volume.dart' as hv;

import 'kv_log_store.dart';
import 'multi_space_store.dart';
import 'package:xveil/core/log.dart';

/// Map domain [KvLogOp]s to the plugin's `HvWriteOp`s (1:1). Shared by the
/// single-space and multi-space backings.
List<hv.HvWriteOp> _toHvOps(List<KvLogOp> ops) => ops.map<hv.HvWriteOp>((op) {
  return switch (op) {
    PutOp(:final namespace, :final key, :final value) => hv.HvWriteOpPut(
      namespace: namespace,
      key: key,
      value: value,
    ),
    DeleteOp(:final namespace, :final key) => hv.HvWriteOpDelete(
      namespace: namespace,
      key: key,
    ),
    AppendLogOp(:final namespace, :final logId, :final payload) =>
      hv.HvWriteOpAppendLog(
        namespace: namespace,
        logId: logId,
        payload: payload,
      ),
    DeleteLogOp(:final namespace, :final logId) => hv.HvWriteOpDeleteLog(
      namespace: namespace,
      logId: logId,
    ),
  };
}).toList();

/// Production [KvLogStore] backed by a real unlocked `HvSpace` from the
/// hidden-volume plugin. The mapping is 1:1, so the domain storage layer
/// (HiddenVolumeStorage) is unchanged whether it runs over this or the fake.
class HvKvLogStore implements KvLogStore {
  HvKvLogStore(this._space);

  final hv.HvSpace _space;

  @override
  int commit(List<KvLogOp> ops) => _space.commit(_toHvOps(ops));

  @override
  Uint8List? get(int namespace, Uint8List key) => _space.get(namespace, key);

  @override
  Uint8List? readLog(int namespace, int logId) =>
      _space.readLog(namespace, logId);

  @override
  List<KvLogEntry> iterLogRange({
    required int namespace,
    int? start,
    int? end,
    required int limit,
  }) => _space
      .iterLogRange(namespace: namespace, start: start, end: end, limit: limit)
      .map((e) => KvLogEntry(e.logId, e.payload))
      .toList();

  @override
  int count(int namespace) => _space.count(namespace);

  @override
  List<Uint8List> kvKeys(int namespace) => _space.kvKeys(namespace);

  @override
  int eraseNamespace(int namespace) => _space.eraseNamespace(namespace);

  @override
  void scrub() {
    // Reclaim/overwrite chunks orphaned by edited or tombstoned messages so the
    // prior plaintext can no longer be recovered from the container — true
    // deniable erasure, not a logical tombstone.
    _space.vacuumDataBatches();
  }

  @override
  Uint8List exportKeys() => _space.spaceKeys();

  @override
  SlotUtilization? slotUtilization() {
    // Best-effort: this only feeds a maintenance READOUT, so a container that
    // will not report its stats must degrade to "unknown" rather than take
    // down the storage call that asked.
    try {
      final s = _space.stats();
      return SlotUtilization(
        ownedChunks: s.ownedChunkCount,
        totalSlots: s.totalSlotCount,
      );
    } catch (e) {
      devLog(() => 'xVeil[storage]: slot utilization unavailable: $e');
      return null;
    }
  }

  @override
  String? hardeningWarning() {
    // Best-effort for the same reason `slotUtilization` is: this feeds a
    // readout, and a container that will not report its stats must degrade to
    // "unknown" rather than take down the call that asked.
    try {
      final failure = _space.stats().hardeningFailure;
      if (failure == null) return null;
      return '${failure.step.name}: ${failure.message}';
    } catch (e) {
      devLog(() => 'xVeil[storage]: hardening warning unavailable: $e');
      return null;
    }
  }

  @override
  void acknowledgeHardeningWarning() {
    // NOT best-effort, unlike its reader. The reader feeds a readout and may
    // degrade to "unknown"; this one CHANGES the container, and the layer
    // above deletes the app's kept copy of the warning as soon as it returns.
    //
    // Swallowing here made that deletion unconditional: the container's record
    // stayed — correctly, nobody acknowledged it — while the app's copy was
    // wiped, so the warning was invisible from then on. The comment above this
    // layer already promised the opposite, that a refused acknowledgement
    // leaves it unacknowledged on BOTH sides; that promise was this call's to
    // keep (report15 X15-M4).
    _space.acknowledgeHardeningError();
  }

  @override
  void close() => _space.close();
}

/// Builds a real [SpaceOpener] over a hidden-volume container file at [path].
///
/// On create, an existing space matching the password is adopted (the library
/// raises `SpaceAlreadyExists`). `AuthFailed` — which deliberately conflates
/// wrong-password and no-such-space — maps to null so the lock screen cannot
/// leak the difference.
/// Runtime padding override (in-memory `set_padding_policy`, no write), applied
/// on every open so it also governs existing containers without a format change.
/// Best-effort: a failure here must never block opening.
hv.HvSpace _withPadding(hv.HvSpace space, hv.PaddingPreset preset) {
  try {
    space.setPaddingPolicy(preset);
  } catch (_) {}
  return space;
}

SpaceOpener hvSpaceOpener(
  String path, {
  hv.ArgonPreset argon = hv.ArgonPreset.heavy,
  hv.PaddingPreset paddingPreset = hv.PaddingPreset.bucket256KiB,
}) {
  return ({required Uint8List password, required bool create}) {
    try {
      final space = create
          ? _createOrOpen(path, password, argon)
          : hv.HvSpace.open(path: path, password: password);
      return HvKvLogStore(_withPadding(space, paddingPreset));
    } on hv.HvException catch (e) {
      if (e.kind == 'AuthFailed') return null;
      rethrow;
    }
  };
}

/// Builds a real [KeysSpaceOpener] over the container at [path] — a master
/// opening one of its children directly from stored `SpaceKeys`, no password.
/// `AuthFailed` (keys match no space) maps to null, same as the password path.
KeysSpaceOpener hvKeysSpaceOpener(
  String path, {
  hv.PaddingPreset paddingPreset = hv.PaddingPreset.bucket256KiB,
}) {
  return (Uint8List keys) {
    try {
      return HvKvLogStore(
        _withPadding(
          hv.HvSpace.openWithKeys(path: path, keys: keys),
          paddingPreset,
        ),
      );
    } on hv.HvException catch (e) {
      if (e.kind == 'AuthFailed') return null;
      rethrow;
    }
  };
}

/// Resolve a space for a "create identity" request:
/// - container already on disk → add a **new parallel, deniable space** (a new
///   identity hidden in the same file), unless this password already maps to a
///   space, in which case adopt that one;
/// - no container yet → bootstrap a fresh one with its first space.
///
/// **Never relies on `File.existsSync`.** An earlier version chose
/// create-vs-add-space from a filesystem stat; when that stat reported "absent"
/// for a container that actually existed (e.g. a `/tmp` symlink path or a
/// not-yet-flushed create), it took the `HvSpace.create` branch and
/// **bootstrapped a fresh container, clobbering the existing spaces** — a
/// catastrophic data-loss bug (only the last-created identity survived). Instead
/// we try the non-destructive `add_space` FIRST and only `create` when that
/// fails because there is genuinely no container at `path`. A container on disk
/// is thus NEVER re-created.
hv.HvSpace _createOrOpen(
  String path,
  Uint8List password,
  hv.ArgonPreset argon,
) {
  try {
    return hv.HvSpace.addSpace(path: path, password: password);
  } on hv.HvException catch (e) {
    // This password already opens a space here — adopt it (open-by-password
    // would otherwise be ambiguous).
    if (e.kind == 'SpaceAlreadyExists') {
      return hv.HvSpace.open(path: path, password: password);
    }
    // No usable container at `path` (missing / not a hidden-volume file) — the
    // only case where bootstrapping a fresh one is correct.
    if (e.kind == 'Io' || e.kind == 'Malformed') {
      devLog(
        () =>
            'xVeil[storage]: bootstrapping FRESH container at $path'
            ' (add_space failed: ${e.kind}) — expected ONLY on first run',
      );
      return hv.HvSpace.create(path: path, password: password, argon: argon);
    }
    rethrow;
  }
}

/// Production [MultiSpaceBacking] over a native `HvMultiSpace`: hosts several
/// spaces of one container open at once under a single lock. Build N
/// [MultiSpaceKvLogStore] views over it (one per identity).
/// The refusal a multi-space handle answers an acknowledgement with.
///
/// A named value rather than a `throw` written inline, because that is the
/// only way to exercise the decision: `HvMultiSpaceBacking` needs an open
/// native container to construct, and a test that skips without the dynamic
/// library is an unverified claim rather than a test.
///
/// NOT `Internal` — that kind documents itself as a library bug, and this is a
/// surface that genuinely does not exist yet.
hv.HvException multiSpaceCannotAcknowledgeHardening() => hv.HvException(
  'Unsupported',
  'this container is open for several spaces at once, and the multi-space '
      'handle cannot acknowledge a hardening record — the warning stays until '
      'it can be acknowledged for real',
);

class HvMultiSpaceBacking implements MultiSpaceBacking {
  HvMultiSpaceBacking(this._multi);

  final hv.HvMultiSpace _multi;

  /// Open the container at [path] for multi-space hosting (takes its lock).
  factory HvMultiSpaceBacking.open(
    String path, {
    hv.PaddingPreset paddingPreset = hv.PaddingPreset.bucket256KiB,
  }) {
    final multi = hv.HvMultiSpace.open(path: path);
    try {
      multi.setPaddingPolicy(paddingPreset);
    } catch (_) {}
    return HvMultiSpaceBacking(multi);
  }

  @override
  int openSpace(Uint8List keys) => _multi.openSpace(keys);

  @override
  int commit(int id, List<KvLogOp> ops) => _multi.commit(id, _toHvOps(ops));

  @override
  Uint8List? get(int id, int namespace, Uint8List key) =>
      _multi.get(id, namespace, key);

  @override
  Uint8List? readLog(int id, int namespace, int logId) =>
      _multi.readLog(id, namespace, logId);

  @override
  List<KvLogEntry> iterLogRange(
    int id, {
    required int namespace,
    int? start,
    int? end,
    required int limit,
  }) => _multi
      .iterLogRange(
        id: id,
        namespace: namespace,
        start: start,
        end: end,
        limit: limit,
      )
      .map((e) => KvLogEntry(e.logId, e.payload))
      .toList();

  @override
  int count(int id, int namespace) => _multi.count(id, namespace);

  @override
  List<Uint8List> kvKeys(int id, int namespace) => _multi.kvKeys(id, namespace);

  @override
  Uint8List exportKeys(int id) => _multi.spaceKeys(id);

  @override
  void scrub(int id) => _multi.vacuumDataBatches(id);

  @override
  SlotUtilization? slotUtilization(int id) {
    // Unknown, honestly. `MultiSpaceHandle` has no `stats` on the FFI surface
    // (only `SpaceHandle` does), and inventing a number here would be worse
    // than saying nothing. Nothing is lost in practice: a container hosting
    // several spaces is exactly the one where compaction is NOT offered —
    // `compact_known` keeps only the spaces whose passwords it was given.
    return null;
  }

  @override
  void acknowledgeHardeningWarning(int id) {
    // REFUSED, not quietly done. `MultiSpaceHandle` has no `stats` on the FFI
    // surface, so there is no container record to clear — and returning
    // normally said the opposite. The acknowledgement's contract is "both
    // copies or neither", and its caller writes the app's copy off as soon as
    // this returns: on a multi-space container that cleared a kept warning
    // with nothing on the native side agreeing, which is the same silent
    // dismissal the ordering fix was written for (report14 X14-M6, report16
    // XV-08).
    //
    // Costs nothing in the ordinary case: with no record to show, the button
    // that calls this is never on the screen. It is reached only when a
    // warning IS kept — exactly the case where clearing it silently is wrong.
    // The storage screen already shows the refusal and leaves the warning up.
    throw multiSpaceCannotAcknowledgeHardening();
  }

  @override
  String? hardeningWarning(int id) {
    // Unknown for the same reason as above, and said the same way: the
    // multi-space handle has no `stats` on the FFI surface, and a null that
    // means "not reported" is the only honest answer. It must never be read
    // as "there was no warning".
    //
    // What that null does NOT do any more is let the record be dismissed: the
    // acknowledgement above refuses rather than pretending, so a kept warning
    // survives a multi-space session instead of being cleared by one.
    return null;
  }

  @override
  void vacuumOrphans(int id) => _multi.vacuumSpace(id);

  @override
  void close() => _multi.close();
}
