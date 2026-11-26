import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/posix_file_facts.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/profile_preferences_file.dart';
import 'package:xveil/data/storage/storage_acl_approval.dart';

void main() {
  const fs = ManagedFsPlatform();
  final skip = !Platform.isMacOS && !Platform.isLinux;
  late Directory temp;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('xveil-access-choices-');
    expect(posixChmod(temp.path, 0x1c0), 0);
    final before = storageAclApprovalsForWorker();
    addTearDown(() {
      restoreStorageAclApprovals(before);
      temp.deleteSync(recursive: true);
    });
  });

  ManagedStorageAclWarning allowGroupRead(String path) {
    expect(posixChmod(path, 0x1a0), 0);
    return fs.inspectAcl(path).aclWarning!;
  }

  test(
    'approved identity leases, usage and erasure use the same grants',
    () async {
      final root = ManagedDirectoryCatalog.createOrOpen(temp.path);
      addTearDown(root.close);
      final id = ManagedIdentityId('1' * 32);
      final created = ManagedIdentityFiles.createUnencrypted(root, id: id);
      final entry = created.entry;
      created.close();
      final directory = '${root.directory}/${id.value}';
      for (final name in ['identity.meta.lock', 'data.store']) {
        final warning = allowGroupRead('$directory/$name');
        expect(warning.path, endsWith(name));
        approveStorageAcl(warning.fingerprint);
      }
      final opened = ManagedIdentityFiles.openUnencrypted(root, id: id);
      try {
        expect((await opened.storageUsage()).dataBytes, greaterThan(0));
      } finally {
        opened.close();
      }
      await ManagedIdentityFiles.erase(root, entry: entry);
      expect(Directory(directory).existsSync(), isFalse);
    },
    skip: skip,
  );

  test(
    'settings lock exposes path and honors only the approved read grant',
    () async {
      final file = File('${temp.path}/settings');
      await withProfilePreferencesWriteLock(file, () {});
      final lock = '${file.path}.lock';
      final warning = allowGroupRead(lock);
      await expectLater(
        withProfilePreferencesWriteLock(file, () {}),
        throwsA(
          isA<ManagedFsFailure>()
              .having((e) => e.path, 'path', lock)
              .having(
                (e) => e.aclWarnings.single.canContinue,
                'can continue',
                isTrue,
              ),
        ),
      );
      approveStorageAcl(warning.fingerprint);
      expect(await withProfilePreferencesWriteLock(file, () => 42), 42);

      final choice = File('${temp.path}/active-profile');
      expect(await writeProfileChoiceAtomically(choice, 'first'), isTrue);
      approveStorageAcl(allowGroupRead('${choice.path}.lock').fingerprint);
      expect(await writeProfileChoiceAtomically(choice, 'second'), isTrue);
      expect(choice.readAsStringSync(), 'second');
    },
    skip: skip,
  );

  test('an early write refusal preserves an unrelated temporary', () async {
    final target = File('${temp.path}/settings')..writeAsStringSync('initial');
    final sibling = File('${target.path}.tmp')..writeAsStringSync('keep');
    expect(posixChmod(target.path, 0x1b0), 0);
    expect(await writePrivateFileAtomically(target, 'replacement'), isFalse);
    expect(writePrivateFileAtomicallySync(target, 'replacement'), isFalse);
    expect(target.readAsStringSync(), 'initial');
    expect(sibling.readAsStringSync(), 'keep');
  }, skip: skip);

  test(
    'a POSIX traversal refusal retains its error and file path',
    () {
      final parent = Directory('${temp.path}/closed')..createSync();
      final file = File('${parent.path}/child')..createSync();
      expect(posixChmod(parent.path, 0), 0);
      try {
        expect(
          () => fs.inspectAcl(file.path),
          throwsA(
            isA<ManagedFsFailure>()
                .having((e) => e.path, 'path', file.path)
                .having((e) => e.posixError, 'errno', 13),
          ),
        );
      } finally {
        expect(posixChmod(parent.path, 0x1c0), 0);
      }
    },
    skip: skip || posixEuid() == 0,
  );

  test(
    'repacking preserves the read policy of both payloads',
    () async {
      final root = ManagedDirectoryCatalog.createOrOpen(temp.path);
      addTearDown(root.close);
      final id = ManagedIdentityId('4' * 32);
      final store = ManagedIdentityFiles.createEncrypted(
        root,
        id: id,
        password: Uint8List.fromList('fixture'.codeUnits),
      );
      addTearDown(store.close);
      final content = '${root.directory}/${id.value}/content.hv';
      final maintenance = '${root.directory}/${id.value}/maintenance.hv';
      final before = fs.inspect(content);
      approveStorageAcl(allowGroupRead(content).fingerprint);
      final pending = allowGroupRead(maintenance);
      await expectLater(
        store.reclaim(force: true),
        throwsA(
          isA<ManagedFsFailure>().having((e) => e.path, 'path', maintenance),
        ),
      );
      expect(before.sameObject(fs.inspect(content)), isTrue);
      approveStorageAcl(pending.fingerprint);
      final report = await store.reclaim(force: true);
      expect(report.contentRepacked, isTrue);
      expect(report.maintenanceRepacked, isTrue);
      for (final path in [content, maintenance]) {
        expect(posixLstat(path)?.permissions, 0x1a0);
        expect(fs.inspectAcl(path).aclApproved, isTrue);
      }
    },
    skip: skip || Platform.environment['XVEIL_HV_DYLIB'] == null,
  );
}
