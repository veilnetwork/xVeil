import 'dart:typed_data';

import 'kv_log_store.dart';
import 'rollback_anchor.dart';

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
class FakeKvLogStore implements KvLogStore, SyncCommitAnchorSource {
  FakeKvLogStore({Uint8List? keys})
    : _keys = keys ?? Uint8List.fromList(List.filled(64, 0));

  final Map<int, Map<String, Uint8List>> _kv = {};
  final Map<int, List<KvLogEntry>> _log = {};
  final Uint8List _keys;
  int _seq = 0;

  /// What [hardeningWarning] answers. Settable so a test can stage the
  /// container condition this fake cannot produce for itself.
  String? stagedHardeningWarning;

  @override
  String? hardeningWarning() => stagedHardeningWarning;

  /// How many times the container was told the person has seen it.
  int hardeningAcknowledgements = 0;

  /// Make the container refuse the acknowledgement. Its record then stays, and
  /// so must the app's — a half-done acknowledgement is not one.
  bool hardeningAcknowledgeThrows = false;

  @override
  void acknowledgeHardeningWarning() {
    if (hardeningAcknowledgeThrows) {
      throw StateError('the container refused the acknowledgement');
    }
    hardeningAcknowledgements++;
    stagedHardeningWarning = null;
  }

  /// Invoked on [close]. Lets a multi-space container model the native
  /// exclusive per-file lock by releasing it when this handle closes.
  void Function()? onClose;

  /// Rejects exactly what hidden-volume's `Tx` rejects inside ONE transaction
  /// (R-NSKIND): a namespace is addressed either by key (`put`/`delete`) or by
  /// log id (`append_log`/`delete_log`), never both, and `delete_log` may not
  /// be mixed with `append_log` for the same namespace even though both are
  /// log-addressed (`Tx::delete_log`, `Tx::check_namespace_kind`).
  ///
  /// Without this the fake accepted a batch the native store answers with
  /// `WrongNamespaceKind` — and the call journal shipped for weeks writing a
  /// batch that every real device refused, with a green unit suite behind it.
  /// A fake that is more permissive than the thing it stands in for cannot
  /// fail the test that matters.
  static void _checkNamespaceKinds(List<KvLogOp> ops) {
    final byKey = <int>{};
    final appended = <int>{};
    final deletedLog = <int>{};
    for (final op in ops) {
      switch (op) {
        case PutOp(:final namespace) || DeleteOp(:final namespace):
          byKey.add(namespace);
        case AppendLogOp(:final namespace):
          appended.add(namespace);
        case DeleteLogOp(:final namespace):
          deletedLog.add(namespace);
      }
    }
    for (final ns in appended.union(deletedLog)) {
      if (byKey.contains(ns)) {
        throw StateError(
          'wrong namespace kind: namespace $ns is addressed both by key and '
          'by log id in one commit',
        );
      }
    }
    for (final ns in appended) {
      if (deletedLog.contains(ns)) {
        throw StateError(
          'wrong namespace kind: delete_log cannot be mixed with append_log '
          'in one Tx (namespace $ns)',
        );
      }
    }
  }

  @override
  int commit(List<KvLogOp> ops) {
    if (ops.isEmpty) return _seq;
    _checkNamespaceKinds(ops);
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
        case DeleteLogOp(:final namespace, :final logId):
          _log[namespace]?.removeWhere((entry) => entry.logId == logId);
      }
    }
    _history.add(++_seq);
    if (_history.length > anchorHorizon) _history.removeAt(0);
    return _seq;
  }

  /// The commits this fake still recognises — the same WINDOW shape the
  /// container keeps, so a test that walks past the horizon sees what a real
  /// container would rather than an unbounded list.
  final List<int> _history = <int>[];

  @override
  int commitSeq() => _seq;

  @override
  List<int> commitHistory() => List.unmodifiable(_history);

  @override
  Map<int, String> commitRoots() => {
    for (final seq in _history) seq: _rootFor(seq),
  };

  /// A stand-in root. Distinct per seq AND per fake, so a test can put two of
  /// these side by side and have them disagree the way two branches do.
  String _rootFor(int seq) =>
      '${_branch.toRadixString(16).padLeft(8, '0')}'
      '${seq.toRadixString(16).padLeft(8, '0')}';

  /// Which branch this fake is. Two fakes with different values model a
  /// container that was copied and then written to independently.
  int branch = 0;
  int get _branch => branch;

  /// Put this fake back to an earlier commit, the way restoring an older copy
  /// of a container file does. Test-only: there is no other way to produce
  /// the condition the anchor exists to detect.
  void rollbackTo(int seq) {
    _seq = seq;
    _history.removeWhere((s) => s > seq);
  }

  /// Give this fake a history that is not the one it wrote — a different
  /// timeline, put here. Test-only, for the same reason.
  void forkHistory(List<int> history, {required int seq}) {
    _seq = seq;
    _history
      ..clear()
      ..addAll(history);
  }

  @override
  Uint8List? get(int namespace, Uint8List key) => _kv[namespace]?[_hexKey(key)];

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
    final entries =
        (_log[namespace] ?? const <KvLogEntry>[])
            .where(
              (e) =>
                  (start == null || e.logId >= start) &&
                  (end == null || e.logId < end),
            )
            .toList()
          ..sort((a, b) => a.logId.compareTo(b.logId));
    return entries.take(limit).toList();
  }

  @override
  int count(int namespace) =>
      (_kv[namespace]?.length ?? 0) + (_log[namespace]?.length ?? 0);

  @override
  List<Uint8List> kvKeys(int namespace) {
    // Internal map keys are hex-encoded ([_hexKey]); decode back to bytes.
    // Hex order == byte order, so sorting the hex strings is byte-wise sort.
    final hexKeys =
        (_kv[namespace]?.keys ?? const Iterable<String>.empty()).toList()
          ..sort();
    return [
      for (final h in hexKeys)
        Uint8List.fromList([
          for (var i = 0; i < h.length; i += 2)
            int.parse(h.substring(i, i + 2), radix: 16),
        ]),
    ];
  }

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

  // A COPY, like every real backend: the native store returns fresh bytes and
  // the worker variant crosses an isolate port, so a caller owns what it gets
  // and may zero it when done (audit XV-22). Handing out `_keys` itself made
  // this fake the only place where wiping an exported key would have reached
  // back into the store and emptied the space.
  @override
  Uint8List exportKeys() => Uint8List.fromList(_keys);

  /// Unknown — deliberately not a fabricated 100%-live answer. There is no
  /// container file here, so there is no slot occupancy to report, and a fake
  /// that claimed "nothing to reclaim" would make the maintenance readout look
  /// correct in tests while saying nothing true about a real container.
  @override
  SlotUtilization? slotUtilization() => null;

  @override
  void close() {
    onClose?.call();
    onClose = null;
  }
}
