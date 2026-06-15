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
    return _hosted.length - 1;
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
  Uint8List exportKeys(int id) => _s(id).exportKeys();

  @override
  void scrub(int id) => _s(id).scrub();

  @override
  void close() {}
}
