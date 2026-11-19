import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/node/sovereign_identity_material.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/identity_setup_journal.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/identity_setup_intent.dart';
import 'package:xveil/domain/storage_initialization.dart';
import 'package:xveil/domain/storage_locator.dart';

void gate(String path) {
  // The parent treats the marker's existence as the crash boundary.
  final pending = File('$path.pending')
    ..writeAsStringSync('ready', flush: true);
  pending.renameSync(path);
  stdin.readByteSync();
  throw StateError('owned crash fixture must be killed');
}

class _Observed extends HvKvLogStore {
  _Observed(super.space, this.cut, this.marker);
  final String cut, marker;
  @override
  int commit(List<KvLogOp> ops) {
    final publishing = ops.whereType<PutOp>().any(
      (op) =>
          op.namespace == Ns.settings &&
          utf8.decode(op.key) == 'file:$kIdentitySetupJournalFile',
    );
    if (publishing && cut == 'before-pair') gate(marker);
    final result = super.commit(ops);
    if (publishing && cut == 'after-pair') gate(marker);
    return result;
  }
}

Future<void> main(List<String> args) async {
  if (args.length != 3 || !ensureHiddenVolumeLoaded()) exit(2);
  final root = Directory(args[0]).resolveSymbolicLinksSync();
  final temporary = Directory.systemTemp.resolveSymbolicLinksSync();
  if (!root.startsWith('$temporary/xveil-setup-crash-')) exit(3);
  final rawSpace = hv.HvSpace.create(
    path: '$root/hidden.hv',
    password: Uint8List.fromList(utf8.encode('synthetic crash password')),
    argon: hv.ArgonPreset.min,
  );
  rawSpace.setPaddingPolicy(hv.PaddingPreset.none);
  final raw = _Observed(rawSpace, args[1], args[2]);
  final storage = HiddenVolumeStorage(
    ({required password, required create}) => raw,
  );
  await storage.open(password: 'synthetic crash password');
  final keys = await storage.exportSpaceKeys();
  final intent = IdentitySetupIntent.create(
    root: const LegacyStorageLocator(),
    keys: keys,
    mode: StorageMode.hiddenSpace,
    persistLegacyMode: false,
    displayName: 'Preserved',
    phrase: 'synthetic crash phrase',
    credential: Uint8List.fromList([1, 2, 3]),
    nodeConfig: 'synthetic config',
  );
  await IdentitySetupJournal.save(storage, intent, () {});
  await storage.saveProfile(const UserProfile(displayName: 'Preserved'));
  if (args[1] == 'profile') gate(args[2]);
  await storage.saveNodeConfig('synthetic config');
  await storage.storeFile(
    kSovereignBundleSetting,
    Uint8List.fromList([1, 2, 3]),
  );
  if (args[1] == 'credential') gate(args[2]);
  await storage.putSetting(kPendingIdentitySetupSetting, '2');
  if (args[1] == 'boot') gate(args[2]);
  exit(4);
}
