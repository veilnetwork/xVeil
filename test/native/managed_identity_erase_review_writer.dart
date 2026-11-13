import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/domain/storage_protection.dart';

/// Holds the REAL lease after the first approved unlink+directory sync. Only
/// fixture code overrides this seam; production deletion has no pause hook.
class _HoldAfterUnknown extends ManagedFsPlatform {
  _HoldAfterUnknown(this.fixture, this.target);
  final String fixture, target;
  bool armed = false;
  @override
  void syncDirectory(String path) {
    super.syncDirectory(path);
    if (!armed || path != target) return;
    final left = Directory(target)
        .listSync(followLinks: false)
        .whereType<File>()
        .where((f) => f.uri.pathSegments.last.startsWith('unknown-'))
        .length;
    if (left != 2) return;
    armed = false;
    File(
      '$fixture/ready',
    ).writeAsStringSync('$pid:unknownRemoved', flush: true);
    stdin.readLineSync(); // Parent SIGKILLs the witnessed process group here.
    throw StateError('fixture must be killed, not resumed');
  }
}

Future<void> main(List<String> args) async {
  final fixture = args[0], mode = StorageProtection.values.byName(args[1]);
  final profile = '$fixture/profile';
  final id = ManagedIdentityId('1' * 32);
  final gate = _HoldAfterUnknown(fixture, '$profile/identities/${id.value}');
  final owner = ManagedDirectoryCatalog.openExisting(profile, fs: gate)!;
  final store = mode == StorageProtection.encrypted
      ? ManagedIdentityFiles.openWithPassword(
          owner,
          id: id,
          password: Uint8List.fromList(utf8.encode('fixture crash password')),
        )
      : ManagedIdentityFiles.openUnencrypted(owner, id: id);
  final keys = store.exportKeys();
  store.close();
  final entry = ManagedIdentityEntry(id: id, protection: mode);
  final review = await ManagedIdentityFiles.reviewErasure(
    owner,
    entry: entry,
    keys: keys,
  );
  gate.armed = true;
  await ManagedIdentityFiles.erase(
    owner,
    entry: entry,
    keys: keys,
    review: review,
  );
  throw StateError('fixture did not hold after partial removal');
}
