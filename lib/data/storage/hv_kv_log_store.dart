import 'dart:io';
import 'dart:typed_data';

import 'package:hidden_volume/hidden_volume.dart' as hv;

import 'kv_log_store.dart';

/// Production [KvLogStore] backed by a real unlocked `HvSpace` from the
/// hidden-volume plugin. The mapping is 1:1, so the domain storage layer
/// (HiddenVolumeStorage) is unchanged whether it runs over this or the fake.
class HvKvLogStore implements KvLogStore {
  HvKvLogStore(this._space);

  final hv.HvSpace _space;

  @override
  int commit(List<KvLogOp> ops) {
    final mapped = ops.map<hv.HvWriteOp>((op) {
      return switch (op) {
        PutOp(:final namespace, :final key, :final value) =>
          hv.HvWriteOpPut(namespace: namespace, key: key, value: value),
        DeleteOp(:final namespace, :final key) =>
          hv.HvWriteOpDelete(namespace: namespace, key: key),
        AppendLogOp(:final namespace, :final logId, :final payload) =>
          hv.HvWriteOpAppendLog(
              namespace: namespace, logId: logId, payload: payload),
      };
    }).toList();
    return _space.commit(mapped);
  }

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
  }) =>
      _space
          .iterLogRange(
              namespace: namespace, start: start, end: end, limit: limit)
          .map((e) => KvLogEntry(e.logId, e.payload))
          .toList();

  @override
  int count(int namespace) => _space.count(namespace);

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
  void close() => _space.close();
}

/// Builds a real [SpaceOpener] over a hidden-volume container file at [path].
///
/// On create, an existing space matching the password is adopted (the library
/// raises `SpaceAlreadyExists`). `AuthFailed` — which deliberately conflates
/// wrong-password and no-such-space — maps to null so the lock screen cannot
/// leak the difference.
SpaceOpener hvSpaceOpener(
  String path, {
  hv.ArgonPreset argon = hv.ArgonPreset.heavy,
}) {
  return ({required Uint8List password, required bool create}) {
    try {
      final space = create
          ? _createOrOpen(path, password, argon)
          : hv.HvSpace.open(path: path, password: password);
      return HvKvLogStore(space);
    } on hv.HvException catch (e) {
      if (e.kind == 'AuthFailed') return null;
      rethrow;
    }
  };
}

/// Builds a real [KeysSpaceOpener] over the container at [path] — a master
/// opening one of its children directly from stored `SpaceKeys`, no password.
/// `AuthFailed` (keys match no space) maps to null, same as the password path.
KeysSpaceOpener hvKeysSpaceOpener(String path) {
  return (Uint8List keys) {
    try {
      return HvKvLogStore(hv.HvSpace.openWithKeys(path: path, keys: keys));
    } on hv.HvException catch (e) {
      if (e.kind == 'AuthFailed') return null;
      rethrow;
    }
  };
}

/// Resolve a space for a "create identity" request:
/// - no container yet → bootstrap a fresh one with its first space;
/// - container already on disk → add a **new parallel, deniable space** (a new
///   identity hidden in the same file), unless this password already maps to a
///   space, in which case adopt that one.
///
/// A container on disk is NEVER re-created (that would risk clobbering an
/// existing — possibly hidden — space); `add_space` opens it and bootstraps an
/// additional space alongside the others.
hv.HvSpace _createOrOpen(String path, Uint8List password, hv.ArgonPreset argon) {
  if (!File(path).existsSync()) {
    try {
      return hv.HvSpace.create(path: path, password: password, argon: argon);
    } on hv.HvException catch (e) {
      // TOCTOU: the file appeared between the existence check and create.
      // Fall through to add a space into the now-existing container.
      if (e.kind != 'Io' && e.kind != 'SpaceAlreadyExists') rethrow;
    }
  }
  try {
    return hv.HvSpace.addSpace(path: path, password: password);
  } on hv.HvException catch (e) {
    // This password already opens a space here — adopt it instead of adding a
    // duplicate (open-by-password would otherwise be ambiguous).
    if (e.kind == 'SpaceAlreadyExists') {
      return hv.HvSpace.open(path: path, password: password);
    }
    rethrow;
  }
}
