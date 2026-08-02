import 'dart:typed_data';

import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/multi_space_store.dart';

/// In-memory [MultiSpaceBacking]: hosts N spaces (each a [FakeKvLogStore]), all
/// usable AT ONCE with no lock — models the native `HvMultiSpace` for tests.
/// `openSpace(keys)` returns a stable id for those keys (creating the space on
/// first open), so two distinct keys give two isolated, concurrently-usable
/// stores.
class FakeMultiSpaceBacking implements MultiSpaceBacking {
  /// Space ids handed out by [openSpace], in call order. Paired with
  /// [vacuumed] so a test can assert every space that OPENED also got its
  /// post-unlock scrub, without hardcoding how ids are assigned.
  final List<int> opened = [];

  final _byKeyHex = <String, FakeKvLogStore>{};
  final _hosted = <FakeKvLogStore>[];

  String _hex(Uint8List b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  FakeKvLogStore _s(int id) => _hosted[id];

  @override
  int openSpace(Uint8List keys) {
    final store =
        _byKeyHex.putIfAbsent(_hex(keys), () => FakeKvLogStore(keys: keys));
    _hosted.add(store);
    final id = _hosted.length - 1;
    opened.add(id);
    return id;
  }

  @override
  int commit(int id, List<KvLogOp> ops) => _s(id).commit(ops);

  @override
  Uint8List? get(int id, int namespace, Uint8List key) =>
      _s(id).get(namespace, key);

  @override
  Uint8List? readLog(int id, int namespace, int logId) =>
      _s(id).readLog(namespace, logId);

  @override
  List<KvLogEntry> iterLogRange(
    int id, {
    required int namespace,
    int? start,
    int? end,
    required int limit,
  }) =>
      _s(id).iterLogRange(
          namespace: namespace, start: start, end: end, limit: limit);

  @override
  int count(int id, int namespace) => _s(id).count(namespace);

  @override
  List<Uint8List> kvKeys(int id, int namespace) => _s(id).kvKeys(namespace);

  @override
  Uint8List exportKeys(int id) => _s(id).exportKeys();

  @override
  void scrub(int id) => _s(id).scrub();

  /// Space ids the host asked to vacuum, in call order.
  ///
  /// Recorded rather than ignored so a test can prove the post-unlock scrub
  /// actually reaches the backing — the constant-time open no longer does it
  /// inline, so if nobody calls this the erase silently stops happening
  /// (audit HV-02).
  final List<int> vacuumed = [];

  @override
  void vacuumOrphans(int id) {
    _s(id); // same "unknown space" failure as any other per-space call
    vacuumed.add(id);
  }

  @override
  void close() {}
}
