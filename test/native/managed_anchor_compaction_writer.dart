import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/managed_anchor_state.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/managed_metadata_blob.dart';
import 'package:xveil/data/storage/managed_store_tag.dart';

final _id = ManagedIdentityId('1' * 32);
final _password = Uint8List.fromList([4, 5, 6]);

Future<void> _waitForKill() async {
  // An unresolved Completer alone does not keep the Dart VM alive. A real
  // event source must keep this owned writer at the observed crash boundary.
  while (true) {
    await Future<void>.delayed(const Duration(seconds: 1));
  }
}

HvKvLogStore _open(String path) {
  final space = hv.HvSpace.open(path: path, password: _password)
    ..cancelDeferredVacuum();
  space.setPaddingPolicy(hv.PaddingPreset.none);
  return HvKvLogStore(space);
}

ManagedAnchorSnapshot _observe(HvKvLogStore content, ManagedAnchorState state) {
  final tag = ManagedStoreTag.read(
    content,
    identity: _id,
    role: ManagedStoreRole.content,
  );
  return state.resolve(
    contentIdentity: tag.identity,
    contentMarker: tag.generation!,
    innerSequence: content.commitSeq(),
    innerRoots: content.commitRoots(),
  );
}

Future<void> main(List<String> args) async {
  if (args.length != 2 || !ensureHiddenVolumeLoaded()) exit(2);
  final root = Directory(args[0]).resolveSymbolicLinksSync();
  final temporary = Directory.systemTemp.resolveSymbolicLinksSync();
  final phase = args[1];
  if (!root.startsWith('$temporary/xveil-managed-repack-') ||
      !['prepared', 'published', 'complete'].contains(phase)) {
    exit(3);
  }
  void mark() =>
      File('$root/ready').writeAsStringSync('$pid:$phase', flush: true);
  final maintenance = _open('$root/maintenance.hv');
  try {
    ManagedStoreTag.read(
      maintenance,
      identity: _id,
      role: ManagedStoreRole.maintenance,
    );
    final blob = ManagedMetadataBlob(maintenance);
    final state = ManagedAnchorState.decode(blob.read());
    late ManagedAnchorSnapshot source;
    final content = _open('$root/content.hv');
    try {
      source = _observe(content, state);
    } finally {
      content.close();
    }
    await hv.compactKnownPreparedAsync(
      '$root/content.hv',
      [_password],
      dylibPath: Platform.environment['XVEIL_HV_DYLIB'],
      repairMetadata: (stagedPath) async {
        final staged = _open(stagedPath);
        try {
          ManagedStoreTag.read(
            staged,
            identity: _id,
            role: ManagedStoreRole.content,
          );
          staged.commit([
            ManagedStoreTag(
              identity: _id,
              role: ManagedStoreRole.content,
              generation: 'b' * 64,
            ).putOp(),
          ]);
          final floor = staged.commitSeq();
          final pending = state.prepare(
            source: source,
            replacement: ManagedGeneration(
              marker: 'b' * 64,
              innerFloor: floor,
              offset: source.sequence + 1 - floor,
            ),
          );
          blob.write(pending.encode());
        } finally {
          staged.close();
        }
        if (phase == 'prepared') {
          mark();
          await _waitForKill();
        }
      },
    );
    if (phase == 'published') {
      mark();
      await _waitForKill();
    }
    final pending = ManagedAnchorState.decode(blob.read());
    final published = _open('$root/content.hv');
    try {
      blob.write(pending.settle(_observe(published, pending)).encode());
    } finally {
      published.close();
    }
  } finally {
    maintenance.close();
  }
  mark();
}
