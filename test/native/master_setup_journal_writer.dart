import 'dart:convert';
import 'dart:io';

import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/master_setup_journal.dart';
import 'package:xveil/domain/master_setup_intent.dart';
import 'package:xveil/domain/storage_protection.dart';
import 'package:xveil/domain/storage_setup.dart';
import 'support/master_setup_fixture.dart';

Never mark(String directory, String phase) {
  File(
    '$directory/ready.pending',
  ).writeAsStringSync('$pid:$phase', flush: true);
  File('$directory/ready.pending').renameSync('$directory/ready');
  while (true) {
    sleep(const Duration(milliseconds: 50));
  }
}

class _BeforePublication extends SyncWrappedAsyncKvLogStore {
  _BeforePublication(super.inner, this.fixture);
  final String fixture;
  @override
  Future<int> commit(List<KvLogOp> ops) async {
    if (ops.whereType<PutOp>().any(
      (op) => utf8.decode(op.key) == 'set:$kPendingMasterSetupSetting',
    )) {
      mark(fixture, 'before-publication');
    }
    return super.commit(ops);
  }
}

Future<void> main(List<String> args) async {
  if (args.length != 3 ||
      !['before-publication', 'prepared', 'child-known'].contains(args[1])) {
    exit(2);
  }
  final path = Directory(args[0]).resolveSymbolicLinksSync();
  if (!path.startsWith(
    '${Directory.systemTemp.resolveSymbolicLinksSync()}/xveil-master-journal-',
  )) {
    exit(3);
  }
  if (!ensureHiddenVolumeLoaded()) exit(4);
  final fixture = MasterSetupFixture(
    Directory(path),
    StorageProtection.values.byName(args[2]),
  );
  final request =
      jsonDecode(File('$path/request-private.json').readAsStringSync()) as Map;
  final keys = base64.decode(request['keys'] as String);
  final intent = MasterSetupIntent.decode(
    base64.decode(request['intent'] as String),
  );
  final owner = ManagedDirectoryCatalog.openExisting(fixture.profile)!;
  final raw = fixture.openRoot(owner);
  var storage = args[1] == 'before-publication'
      ? HiddenVolumeStorage.fromAsyncStore(_BeforePublication(raw, path))
      : HiddenVolumeStorage.fromStore(raw);
  await MasterSetupJournal.prepare(
    storage: storage,
    intent: intent,
    root: fixture.root,
    keys: keys,
    check: () {},
  );
  if (args[1] == 'prepared') mark(path, args[1]);
  await storage.close();
  final child = ManagedIdentityFiles.createEncrypted(
    owner,
    id: fixture.id('b'),
    password: fixture.password,
  );
  final childKeys = child.exportKeys();
  child.close();
  storage = HiddenVolumeStorage.fromStore(fixture.openRoot(owner));
  final ready = await MasterSetupJournal.attachChild(
    storage: storage,
    intent: intent,
    childKeys: childKeys,
    root: fixture.root,
    keys: keys,
    check: () {},
  );
  if (!ready.childKnown) exit(5);
  mark(path, args[1]);
}
