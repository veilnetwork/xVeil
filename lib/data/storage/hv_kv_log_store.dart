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

hv.HvSpace _createOrOpen(String path, Uint8List password, hv.ArgonPreset argon) {
  try {
    return hv.HvSpace.create(path: path, password: password, argon: argon);
  } on hv.HvException catch (e) {
    if (e.kind == 'SpaceAlreadyExists') {
      return hv.HvSpace.open(path: path, password: password);
    }
    rethrow;
  }
}
