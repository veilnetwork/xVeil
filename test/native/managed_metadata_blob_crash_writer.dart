import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/managed_metadata_blob.dart';

class _BoundaryStore extends HvKvLogStore {
  _BoundaryStore(super.space, this.marker, this.boundary, this.after);
  final File marker;
  final int boundary;
  final bool after;
  int index = 0;

  void hold() {
    marker.writeAsStringSync('$pid', flush: true);
    // An owned process waits here without close/dispose. The parent kills it.
    while (true) {
      sleep(const Duration(seconds: 1));
    }
  }

  @override
  int commit(List<KvLogOp> ops) {
    final stop = index++ == boundary;
    if (stop && !after) hold();
    final result = super.commit(ops);
    if (stop) hold();
    return result;
  }
}

void main(List<String> args) {
  if (args.length != 3 || !ensureHiddenVolumeLoaded()) exit(2);
  final root = Directory(args[0]).resolveSymbolicLinksSync();
  final temporary = Directory.systemTemp.resolveSymbolicLinksSync();
  if (!root.startsWith('$temporary/xveil-metadata-')) exit(3);
  final space = hv.HvSpace.open(
    path: '$root/fixture.hv',
    password: Uint8List.fromList([1, 2, 3]),
  )..cancelDeferredVacuum();
  space.setPaddingPolicy(hv.PaddingPreset.none);
  final store = _BoundaryStore(
    space,
    File('$root/ready'),
    int.parse(args[1]),
    args[2] == 'after',
  );
  final random = Random(2);
  ManagedMetadataBlob(
    store,
  ).write(Uint8List.fromList(List.generate(49155, (_) => random.nextInt(256))));
  store.close();
  exit(4); // Expected boundary was not reached; never a passing crash test.
}
