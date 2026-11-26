import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/serve_source.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/managed_identity_storage.dart';
import 'package:xveil/domain/storage_protection.dart';
import 'package:xveil/core/document_export.dart';
import 'package:xveil/core/posix_file_facts.dart';
import 'package:xveil/core/storage_unlock_scope.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/profile_preferences_file.dart';
import 'package:xveil/data/storage/storage_acl_approval.dart';
import 'package:xveil/data/veil_stack.dart';
import 'package:xveil/headless/secret_file.dart';

class _Picker extends FilePickerPlatform {
  _Picker(this.path);
  final String path;

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  const fs = ManagedFsPlatform();
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('xveil-acl-proof-');
    expect(posixChmod(tmp.path, 0x1c0), 0);
    final before = storageAclApprovalsForWorker();
    addTearDown(() {
      restoreStorageAclApprovals(before);
      tmp.deleteSync(recursive: true);
    });
  });
  void grant(String path, String ace) {
    final result = Process.runSync('/bin/chmod', ['+a', ace, path]);
    expect(result.exitCode, 0, reason: result.stderr.toString());
  }

  group(
    'macOS permission decisions',
    skip: !Platform.isMacOS || posixEuid() == 0,
    () {
      test('whole-profile erasure accepts a verified read grant', () async {
        final created = ManagedDirectoryCatalog.createOrOpen(tmp.path);
        final id = ManagedIdentityId('a' * 32);
        final identity = ManagedIdentityFiles.createUnencrypted(
          created,
          id: id,
        );
        identity.close();
        final data = '${created.directory}/${id.value}/data.store';
        created.close();
        expect(posixChmod(data, 0x1a0), 0);
        final warning = fs.inspectAcl(data).aclWarning!;
        approveStorageAcl(warning.fingerprint);
        final exclusive = ManagedDirectoryCatalog.openExclusiveMaintenance(
          tmp.path,
        )!;
        try {
          final scopes = StorageUnlockScopes(['1' * 64]);
          await ManagedRootErasure.prepare(exclusive, unlockScopes: scopes);
        } finally {
          exclusive.close();
        }
        expect(File(data).existsSync(), isTrue);
      });

      test(
        'whole-profile erasure binds the extra-file review to its permissions',
        () async {
          final root = ManagedDirectoryCatalog.createOrOpen(tmp.path);
          final id = ManagedIdentityId('e' * 32);
          ManagedIdentityFiles.createUnencrypted(root, id: id).close();
          final file = File('${root.layout.directory(id)}/notes.txt')
            ..writeAsStringSync('synthetic');
          expect(posixChmod(file.path, 0x180), 0);
          root.close();
          final owner = ManagedDirectoryCatalog.openExclusiveMaintenance(
            tmp.path,
          )!;
          final request = ManagedProfileErasureRequest();
          Future<void> prepare() => ManagedRootErasure.prepare(
            owner,
            unlockScopes: StorageUnlockScopes(['1' * 64]),
            applicationRequest: request,
          );
          Future<ManagedErasureContentsReview> review() async {
            try {
              await prepare();
            } on ManagedFsFailure catch (error) {
              return error.erasureReview!;
            }
            fail('expected a review of the additional file');
          }

          try {
            final first = await review();
            expect(first.paths, ['identities/${id.value}/notes.txt']);
            approveStorageAcl(first.fingerprint);
            expect(posixChmod(file.path, 0x1a4), 0);
            final second = await review();
            expect(second.fingerprint, isNot(first.fingerprint));
            approveStorageAcl(second.fingerprint);
            await prepare();
            expect(file.readAsStringSync(), 'synthetic');
          } finally {
            owner.close();
          }
        },
      );

      test(
        'preferences staging protects new data under an inherited read grant',
        () async {
          grant(tmp.path, 'everyone allow file_inherit,only_inherit,read');
          final file = File('${tmp.path}/settings');
          expect(await writePrivateFileAtomically(file, 'synthetic'), isTrue);
          expect(fs.inspect(file.path).ownerOnly, isTrue);
          expect(file.readAsStringSync(), 'synthetic');
        },
      );

      test(
        'desktop export lets the owner choose whether to use a shared folder',
        () async {
          final saved = FilePickerPlatform.instance;
          debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
          addTearDown(() {
            FilePickerPlatform.instance = saved;
            debugDefaultTargetPlatformOverride = null;
          });
          final parent = Directory('${tmp.path}/shared')..createSync();
          expect(posixChmod(parent.path, 0x1ff), 0);
          final target = File('${parent.path}/file');
          FilePickerPlatform.instance = _Picker(target.path);
          final warnings = <ManagedStorageAclWarning>[];
          Future<ExportDocument?> open(bool decision) => openExportDocument(
            'file',
            reviewAccess: (failure) async {
              warnings.addAll(failure.aclWarnings);
              return decision;
            },
          );
          expect(await open(false), isNull);
          expect(target.existsSync(), isFalse);
          final opened = (await open(true))!;
          await opened.write([1, 2, 3]);
          await opened.finish();
          expect(warnings, hasLength(2));
          expect(
            warnings.every((warning) => warning.path.endsWith('/shared')),
            isTrue,
          );
          expect(target.readAsBytesSync(), [1, 2, 3]);
        },
      );

      test(
        'POSIX runtime explains a replaceable parent and accepts a private choice',
        () async {
          final parent = Directory('${tmp.path}/shared')..createSync();
          expect(posixChmod(parent.path, 0x1ff), 0);
          expect(fs.inspectAcl(parent.path).safeAncestor, isFalse);
          await expectLater(
            claimRuntimeDirUnder(parent.path, uniqueSuffix: 'fixture'),
            throwsA(
              isA<RuntimeDirNotPrivate>()
                  .having(
                    (e) => e.refusal,
                    'refusal',
                    RuntimeDirectoryRefusal.unsafeAncestor,
                  )
                  .having(
                    (e) => e.aclWarning?.path,
                    'path',
                    endsWith('/shared'),
                  ),
            ),
          );
          final path = await claimRuntimeDirUnder(
            tmp.path,
            uniqueSuffix: 'fixture',
          );
          expect(Directory(path).existsSync(), isTrue);
        },
      );

      test(
        'CLI requires and explains an exact writable-parent decision',
        () async {
          final parent = Directory('${tmp.path}/shared')..createSync();
          expect(posixChmod(parent.path, 0x1ff), 0);
          final file = File('${parent.path}/secret')
            ..writeAsStringSync('synthetic');
          expect(posixChmod(file.path, 0x180), 0);
          final warned = <String>[];
          final fingerprint = ManagedDirectoryAccess.capture(
            parent.path,
          ).warnings.single.fingerprint;
          await expectLater(
            readSecretFile(file.path, 'fixture', warn: warned.add),
            throwsA(
              isA<StateError>().having(
                (e) => e.message,
                'option',
                contains(fingerprint),
              ),
            ),
          );
          expect(
            await readSecretFile(
              file.path,
              'fixture',
              warn: warned.add,
              acceptedDirectoryAcls: {fingerprint},
            ),
            'synthetic',
          );
          expect(warned.single, contains('/shared'));
          expect(posixChmod(parent.path, 0x1fd), 0);
          await expectLater(
            readSecretFile(
              file.path,
              'fixture',
              warn: warned.add,
              acceptedDirectoryAcls: {fingerprint},
            ),
            throwsStateError,
          );
        },
      );

      test('startup choice read preserves the OS denial and path', () async {
        final parent = Directory('${tmp.path}/closed')..createSync();
        final file = File('${parent.path}/active-profile')
          ..writeAsStringSync('fixture');
        expect(posixChmod(parent.path, 0), 0);
        try {
          await expectLater(
            readStartupProfileChoice(file),
            throwsA(
              isA<ProfileChoiceReadFailure>()
                  .having((e) => e.busy, 'contention', isFalse)
                  .having((e) => e.filesystemFailure?.path, 'path', file.path)
                  .having((e) => e.filesystemFailure?.posixError, 'errno', 13),
            ),
          );
        } finally {
          expect(posixChmod(parent.path, 0x1c0), 0);
        }
      });

      test(
        'ordinary preferences saves leave a pre-existing temporary file intact',
        () async {
          final file = File('${tmp.path}/settings')
            ..writeAsStringSync('previous');
          final sibling = File('${file.path}.tmp')
            ..writeAsStringSync('keep these separate bytes');
          expect(
            await writePrivateFileAtomically(file, 'new contents'),
            isTrue,
          );
          expect(sibling.readAsStringSync(), 'keep these separate bytes');
          expect(writePrivateFileAtomicallySync(file, 'sync contents'), isTrue);
          expect(sibling.readAsStringSync(), 'keep these separate bytes');
          expect(file.readAsStringSync(), 'sync contents');
        },
      );

      test(
        'changing a reviewed file mode invalidates erasure consent',
        () async {
          final owner = ManagedDirectoryCatalog.createOrOpen(tmp.path);
          final id = ManagedIdentityId('b' * 32);
          final created = ManagedIdentityFiles.createUnencrypted(owner, id: id);
          final entry = created.entry;
          final keys = created.exportKeys();
          created.close();
          try {
            final file = File('${owner.layout.directory(id)}/unrecognized.txt')
              ..writeAsStringSync('fixture');
            expect(posixChmod(file.path, 0x180), 0);
            final review = await ManagedIdentityFiles.reviewErasure(
              owner,
              entry: entry,
              keys: keys,
            );
            expect(review.files, 1);
            expect(posixChmod(file.path, 0x1a4), 0);
            await expectLater(
              ManagedIdentityFiles.erase(
                owner,
                entry: entry,
                keys: keys,
                review: review,
              ),
              throwsA(isA<ManagedIdentityFailure>()),
            );
            expect(file.existsSync(), isTrue);
            final revised = await ManagedIdentityFiles.reviewErasure(
              owner,
              entry: entry,
              keys: keys,
            );
            await ManagedIdentityFiles.erase(
              owner,
              entry: entry,
              keys: keys,
              review: revised,
            );
            expect(file.existsSync(), isFalse);
          } finally {
            owner.close();
          }
        },
      );

      test(
        'native legacy prepared compaction can preserve the selected access mode',
        () async {
          final path = '${tmp.path}/legacy.hv';
          final password = Uint8List.fromList('fixture password'.codeUnits);
          final store = hvSpaceOpener(path, argon: hv.ArgonPreset.min)(
            password: password,
            create: true,
          );
          store!.close();
          expect(posixChmod(path, 0x1a0), 0);
          final destination = File(path);
          final access = FileReplacementAccess.capture(destination);
          late FileReplacementAccess prepared;
          await hv.compactKnownPreparedAsync(
            path,
            [password],
            dylibPath: Platform.environment['XVEIL_HV_DYLIB'],
            repairMetadata: (staged) async {
              prepared = access.prepareReplacement(destination, File(staged));
            },
          );
          expect(access.checkPublished(destination, prepared, null), isTrue);
          expect(posixLstat(path)!.permissions, 0x1a0);
        },
      );

      test(
        'managed repack carries an approved read grant to its caller',
        () async {
          final id = ManagedIdentityId('c' * 32);
          final binding = ManagedIdentityStorage.forCreation(
            profileDirectory: tmp.path,
            entry: ManagedIdentityEntry(
              id: id,
              protection: StorageProtection.encrypted,
            ),
          );
          final content = '${tmp.path}/identities/${id.value}/content.hv';
          expect(
            await binding.storage.open(
              password: 'fixture password',
              createIfMissing: true,
            ),
            isTrue,
          );
          try {
            expect(posixChmod(content, 0x1a0), 0);
            final old = fs.inspectAcl(content).aclWarning!.fingerprint;
            approveStorageAcl(old);
            final result = await binding.reclaim(force: true);
            expect(result.contentRepacked, isTrue);
            final current = fs.inspectAcl(content);
            expect(current.aclWarning!.fingerprint, isNot(old));
            expect(current.aclApproved, isTrue);
          } finally {
            await binding.storage.close();
          }
        },
      );

      test('attachment source identifies an OS read denial', () async {
        final file = File('${tmp.path}/attachment')
          ..writeAsStringSync('fixture');
        expect(posixChmod(file.path, 0), 0);
        expect(
          () => file.openSync(),
          throwsA(
            isA<FileSystemException>().having(
              (e) => e.osError?.errorCode,
              'errno',
              13,
            ),
          ),
        );
        final result = await veilOpenPinnedSource(file.path);
        expect(result.source, isNull);
        expect(result.refusal, contains('the OS denied'));
      });

      test('managed directory creation keeps errno and path', () {
        final parent = Directory('${tmp.path}/no-write')..createSync();
        expect(posixChmod(parent.path, 0x140), 0);
        try {
          final path = '${parent.path}/managed';
          expect(posixMkdirResult(path, 0x1c0)?.errno, 13);
          expect(
            () => fs.createPrivateDirectory(path),
            throwsA(
              isA<ManagedFsFailure>()
                  .having((e) => e.kind, 'kind', ManagedFsFailureKind.io)
                  .having((e) => e.path, 'path', path)
                  .having((e) => e.posixError, 'posix error', 13),
            ),
          );
        } finally {
          expect(posixChmod(parent.path, 0x1c0), 0);
        }
      });

      test(
        'download resume identifies an OS refusal with the original file in place',
        () async {
          final file = File('${tmp.path}/partial')
            ..writeAsStringSync('test bytes');
          final expected = plainDownloadDestinationIdentity(file.path);
          expect(expected, isNotNull);
          expect(posixChmod(file.path, 0), 0);
          expect(plainDownloadDestinationIdentity(file.path), expected);
          expect(
            () => file.openSync(),
            throwsA(
              isA<FileSystemException>().having(
                (e) => e.osError?.errorCode,
                'errno',
                13,
              ),
            ),
          );
          await expectLater(
            veilPlainFileSinkOpener(
              file.path,
              resume: true,
              expectedIdentity: expected,
            ),
            throwsA(
              isA<FileSystemException>()
                  .having((e) => e.path, 'path', file.path)
                  .having((e) => e.osError?.errorCode, 'errno', 13),
            ),
          );
          expect(plainDownloadDestinationIdentity(file.path), expected);
        },
      );

      test(
        'reviewed macOS read-only ACL permits erasure of the named file',
        () async {
          final owner = ManagedDirectoryCatalog.createOrOpen(tmp.path);
          final id = ManagedIdentityId('d' * 32);
          final created = ManagedIdentityFiles.createUnencrypted(owner, id: id);
          final entry = created.entry;
          final keys = created.exportKeys();
          created.close();
          try {
            final file = File('${owner.layout.directory(id)}/unrecognized.txt')
              ..writeAsStringSync('fixture');
            expect(posixChmod(file.path, 0x180), 0);
            grant(file.path, 'everyone allow read');
            approveStorageAcl(fs.inspectAcl(file.path).aclWarning!.fingerprint);
            final review = await ManagedIdentityFiles.reviewErasure(
              owner,
              entry: entry,
              keys: keys,
            );
            expect(review.files, 1);
            expect(review.paths, ['unrecognized.txt']);
            await ManagedIdentityFiles.erase(
              owner,
              entry: entry,
              keys: keys,
              review: review,
            );
            expect(file.existsSync(), isFalse);
          } finally {
            owner.close();
          }
        },
      );

      test('new staging directory is private under an inherited read ACL', () {
        grant(
          tmp.path,
          'everyone allow directory_inherit,only_inherit,list,search',
        );
        final staging = createPrivateStagingDirectory(tmp.path, 'node-stage');
        expect(fs.inspect(staging.path).ownerOnly, isTrue);
      });

      test('CLI reports denied traversal as an OS error', () async {
        final dir = Directory('${tmp.path}/closed')..createSync();
        final secret = File('${dir.path}/secret')..writeAsStringSync('fixture');
        expect(posixChmod(secret.path, 0x180), 0);
        expect(posixChmod(dir.path, 0), 0);
        try {
          expect(
            posixLstat(secret.path, onError: (code) => expect(code, 13)),
            isNull,
          );
          await expectLater(
            readSecretFile(secret.path, 'fixture'),
            throwsA(
              isA<FileSystemException>()
                  .having((e) => e.path, 'path', secret.path)
                  .having((e) => e.osError?.errorCode, 'errno', 13),
            ),
          );
        } finally {
          expect(posixChmod(dir.path, 0x1c0), 0);
        }
      });
    },
  );
}
