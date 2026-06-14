import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/file_store.dart';

Uint8List _bytes(int n) {
  final r = Random(n);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

void main() {
  late FileStore store;
  setUp(() => store = FileStore(FakeKvLogStore()));

  test('stores and reloads files of various sizes (incl. multi-chunk/empty)',
      () {
    for (final n in [0, 1, 7999, 8000, 8001, 50000]) {
      final data = _bytes(n);
      final id = 'f$n';
      store.storeFile(id, data, name: 'pic$n.bin');
      expect(store.loadFile(id), data, reason: 'size $n');
      final meta = store.metadata(id)!;
      expect(meta.size, n);
      expect(meta.name, 'pic$n.bin');
    }
  });

  test('multiple files do not overlap (sequential log ids)', () {
    final a = _bytes(12000);
    final b = _bytes(9000);
    store.storeFile('a', a);
    store.storeFile('b', b);
    expect(store.loadFile('a'), a);
    expect(store.loadFile('b'), b);
  });

  test('unknown file id returns null', () {
    expect(store.loadFile('nope'), isNull);
    expect(store.metadata('nope'), isNull);
  });
}
