import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/managed_anchor_state.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/managed_keybox.dart';
import 'package:xveil/data/storage/managed_metadata_blob.dart';
import 'package:xveil/data/storage/managed_store_tag.dart';

final _id = ManagedIdentityId('1' * 32);
final _userPassword = Uint8List.fromList([4, 5, 6]);

Future<void> _waitForKill() async {
  // An unresolved Completer alone does not keep the Dart VM alive. A real
  // event source must keep this owned writer at the observed crash boundary.
  while (true) {
    await Future<void>.delayed(const Duration(seconds: 1));
  }
}

HvKvLogStore _open(String path, Uint8List password) {
  final space = hv.HvSpace.open(path: path, password: password)
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
  void mark() {
    final staged = File('$root/ready.pending');
    staged.writeAsStringSync('$pid:$phase', flush: true);
    staged.renameSync('$root/ready');
  }

  final keybox = ManagedKeybox.openOwned(
    _open('$root/keybox.hv', _userPassword),
    identity: _id,
  );
  final contentPassword = keybox.copyContentPassword();
  final maintenancePassword = keybox.copyMaintenancePassword();
  try {
    // Retain the immutable keybox lock across content-close/native-prepare.
    final maintenance = _open('$root/maintenance.hv', maintenancePassword);
    try {
      await _compact(root, phase, maintenance, contentPassword, mark);
    } finally {
      maintenance.close();
    }
  } finally {
    contentPassword.fillRange(0, contentPassword.length, 0);
    maintenancePassword.fillRange(0, maintenancePassword.length, 0);
    keybox.close();
  }
  mark();
}

Future<void> _compact(
  String root,
  String phase,
  HvKvLogStore maintenance,
  Uint8List contentPassword,
  void Function() mark,
) async {
  ManagedStoreTag.read(
    maintenance,
    identity: _id,
    role: ManagedStoreRole.maintenance,
  );
  final blob = ManagedMetadataBlob(maintenance);
  final state = ManagedAnchorState.decode(blob.read());
  late ManagedAnchorSnapshot source;
  final content = _open('$root/content.hv', contentPassword);
  try {
    source = _observe(content, state);
  } finally {
    content.close();
  }
  await hv.compactKnownPreparedAsync(
    '$root/content.hv',
    [contentPassword],
    dylibPath: Platform.environment['XVEIL_HV_DYLIB'],
    repairMetadata: (stagedPath) async {
      final staged = _open(stagedPath, contentPassword);
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
  final published = _open('$root/content.hv', contentPassword);
  try {
    blob.write(pending.settle(_observe(published, pending)).encode());
  } finally {
    published.close();
  }
}
