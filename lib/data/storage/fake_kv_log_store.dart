import 'dart:typed_data';

import 'kv_log_store.dart';

String _hexKey(Uint8List key) {
  final sb = StringBuffer();
  for (final b in key) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

/// In-memory [KvLogStore] — exercises the real domain→namespace/log mapping
/// without the native library. Backs the dev/test build and is the harness
/// for the storage unit tests.
class FakeKvLogStore implements KvLogStore {
  FakeKvLogStore({Uint8List? keys})
      : _keys = keys ?? Uint8List.fromList(List.filled(64, 0));

  final Map<int, Map<String, Uint8List>> _kv = {};
  final Map<int, List<KvLogEntry>> _log = {};
  final Uint8List _keys;
  int _seq = 0;

  /// Invoked on [close]. Lets a multi-space container model the native
  /// exclusive per-file lock by releasing it when this handle closes.
  void Function()? onClose;

  @override
  int commit(List<KvLogOp> ops) {
    if (ops.isEmpty) return _seq;
    for (final op in ops) {
      switch (op) {
        case PutOp(:final namespace, :final key, :final value):
          (_kv[namespace] ??= {})[_hexKey(key)] = value;
        case DeleteOp(:final namespace, :final key):
          _kv[namespace]?.remove(_hexKey(key));
        case AppendLogOp(:final namespace, :final logId, :final payload):
          // Last-write-wins by log_id — faithful to the real core, where
          // re-appending an existing log_id REPLACES the prior value on read
          // (the documented edit/delete primitive). A naive append would let
          // both the old and new record survive and diverge from native.
          final list = _log[namespace] ??= [];
          final i = list.indexWhere((e) => e.logId == logId);
          if (i >= 0) {
            list[i] = KvLogEntry(logId, payload);
          } else {
            list.add(KvLogEntry(logId, payload));
          }
      }
    }
    return ++_seq;
  }

  @override
  Uint8List? get(int namespace, Uint8List key) =>
      _kv[namespace]?[_hexKey(key)];

  @override
  Uint8List? readLog(int namespace, int logId) {
    for (final e in _log[namespace] ?? const <KvLogEntry>[]) {
      if (e.logId == logId) return e.payload;
    }
    return null;
  }

  @override
  List<KvLogEntry> iterLogRange({
    required int namespace,
    int? start,
    int? end,
    required int limit,
  }) {
    final entries = (_log[namespace] ?? const <KvLogEntry>[])
        .where((e) =>
            (start == null || e.logId >= start) &&
            (end == null || e.logId < end))
        .toList()
      ..sort((a, b) => a.logId.compareTo(b.logId));
    return entries.take(limit).toList();
  }

  @override
  int count(int namespace) => _kv[namespace]?.length ?? 0;

  @override
  int eraseNamespace(int namespace) {
    final n = (_kv[namespace]?.length ?? 0) + (_log[namespace]?.length ?? 0);
    _kv.remove(namespace);
    _log.remove(namespace);
    return n;
  }

  @override
  void scrub() {
    // The in-memory fake never persists, so there are no orphaned chunks to
    // reclaim — replaced/tombstoned entries are already gone from [_log].
  }

  @override
  Uint8List exportKeys() => _keys;

  @override
  void close() {
    onClose?.call();
    onClose = null;
  }
}
