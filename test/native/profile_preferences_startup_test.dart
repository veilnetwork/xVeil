@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:collection';
import 'dart:io';
import 'dart:ffi' show nullptr;
import 'dart:isolate';
import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:win32/win32.dart' as win;
import 'package:xveil/core/storage_unlock_scope.dart';
import 'package:xveil/data/storage/app_profile.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_identity_lease.dart';
import 'package:xveil/data/storage/managed_sqlite_connection.dart';
import 'package:xveil/data/storage/profile_preferences_bootstrap.dart';
import 'package:xveil/data/storage/profile_preferences.dart';
import 'package:xveil/data/storage/profile_prefs_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final busy = anyOf(
    isA<ManagedLeaseFailure>().having(
      (e) => e.kind,
      'kind',
      ManagedLeaseFailureKind.busy,
    ),
    isA<ManagedSqliteFailure>().having(
      (e) => e.sqliteCode == null ? null : e.sqliteCode! & 0xff,
      'sqlite busy/locked',
      isIn([5, 6]),
    ),
  );
  late Directory support;
  late SharedPreferencesStorePlatform original, legacy;
  final files = <ManagedProfilePreferencesFile>[];
  final stores = <ProfilePreferencesStore>[];
  String prefs([String name = 'default']) =>
      profilePrefsPath(support.path, name);
  String base([String name = 'default']) =>
      AppProfiles.directory(support.path, name);
  String managed([String name = 'default']) => '${base(name)}/visible-storage';
  Map<String, String> contents() => {
    for (final f
        in support
            .listSync(recursive: true, followLinks: false)
            .whereType<File>())
      f.path: sha256.convert(f.readAsBytesSync()).toString(),
  };
  Future<ManagedProfilePreferencesFile> open(String path) async {
    final owner = await ManagedProfilePreferencesFile.open(path);
    files.add(owner);
    return owner;
  }

  Future<String> install({List<String> args = const []}) async {
    final name = await installProfilePreferencesOrFallback(
      supportDir: () async => support.path,
      args: args,
      environment: const {},
      openOwnedFile: open,
    );
    stores.add(
      SharedPreferencesStorePlatform.instance as ProfilePreferencesStore,
    );
    return name;
  }

  Future<void> pending([String name = 'default']) async {
    Directory(base(name)).createSync(recursive: true);
    StorageProfileCoordinator.forPreferences(base(name)).close();
    final gate = StorageProfileCoordinator.openExisting(
      managed(name),
      exclusive: true,
    )!;
    try {
      await ManagedRootErasure.prepareAbsent(
        gate,
        unlockScopes: StorageUnlockScopes(['a' * 64]),
      );
    } finally {
      gate.close();
    }
  }

  setUp(() {
    support = Directory.systemTemp.createTempSync('xveil-prefs-startup-');
    original = SharedPreferencesStorePlatform.instance;
    legacy = InMemorySharedPreferencesStore.withData({'flutter.locale': 'ru'});
    SharedPreferencesStorePlatform.instance = legacy;
  });
  tearDown(() async {
    for (final store in stores) {
      await store.releaseFile();
    }
    for (final file in files) {
      await file.close();
    }
    stores.clear();
    files.clear();
    SharedPreferencesStorePlatform.instance = original;
    support.deleteSync(recursive: true);
  });

  for (final choice in ['legacy', 'saved', 'explicit']) {
    test('unreadable legacy preferences with profile choice $choice', () async {
      const activeKey = 'flutter.${AppProfiles.activePref}';
      const legacyValues = {activeKey: 'older', 'flutter.locale.older': 'ru'};
      final source = _UnreadableLegacyPreferences(legacyValues);
      legacy = source;
      SharedPreferencesStorePlatform.instance = source;
      Directory(base('older')).createSync(recursive: true);
      final args = choice == 'explicit'
          ? ['--profile', 'selected']
          : <String>[];
      if (choice == 'saved') {
        expect(await writeRememberedProfile(support.path, 'selected'), isTrue);
      }

      if (choice == 'legacy') {
        await expectLater(
          install(),
          throwsA(
            isA<ProfileChoiceReadFailure>().having(
              (failure) => failure.fromLegacy,
              'legacy source',
              isTrue,
            ),
          ),
        );
        expect(files, isEmpty);
        expect(SharedPreferencesStorePlatform.instance, same(source));
        expect(File(activeProfilePath(support.path)).existsSync(), isFalse);
      } else {
        expect(await install(args: args), 'selected');
        await stores.last.releaseFile();
        SharedPreferencesStorePlatform.instance = source;
      }
      expect(Directory(managed()).existsSync(), isFalse);
      expect(File(prefs()).existsSync(), isFalse);
      source.unreadable = false;
      expect(await source.getAll(), legacyValues);

      final recovered = await install();
      expect(recovered, choice == 'saved' ? 'selected' : 'older');
      final old = await open(prefs('older'));
      final persisted = await ProfilePreferencesStore.load(
        prefs('older'),
        ownedFile: old,
      );
      stores.add(persisted);
      expect(await persisted.getAll(), {'flutter.locale': 'ru'});
      expect(await source.getAll(), isEmpty);
    });
  }

  for (final legacyRead in ['cleared', 'stale', 'refused']) {
    test(
      'startup sees a choice saved during a $legacyRead legacy read',
      () async {
        const activeKey = 'flutter.${AppProfiles.activePref}';
        const oldSettings = {activeKey: 'older', 'flutter.locale.older': 'ru'};
        final source = _GatedLegacyPreferences(oldSettings);
        SharedPreferencesStorePlatform.instance = source;
        Directory(base('older')).createSync(recursive: true);
        final writer = await ManagedProfilePreferencesFile.open(
          prefs('selected'),
        );
        try {
          expect(
            await writer.write(
              '{"v":1,"e":{"flutter.locale":{"t":"String","v":"de"}}}',
            ),
            isTrue,
          );
        } finally {
          await writer.close();
        }

        final result = expectLater(install(), completion('selected'));
        await source.started.future;
        try {
          expect(files, isEmpty);
          expect(
            await writeRememberedProfile(support.path, 'selected'),
            isTrue,
          );
          if (legacyRead == 'cleared') {
            expect(await source.remove(activeKey), isTrue);
            expect(await source.remove('flutter.locale.older'), isTrue);
          } else if (legacyRead == 'refused') {
            source.unreadable = true;
          }
        } finally {
          source.release.complete();
        }
        await result;
        expect(files.first.path, prefs('selected'));
        expect(File(prefs()).existsSync(), isFalse);
        expect(Directory(managed()).existsSync(), isFalse);
        expect(await SharedPreferencesStorePlatform.instance.getAll(), {
          'flutter.locale': 'de',
        });
        expect(await readRememberedProfile(support.path), 'selected');
        if (legacyRead == 'refused') {
          source.unreadable = false;
          expect(await source.getAll(), oldSettings);
        }
      },
    );
  }

  for (final temporary in [true, false]) {
    test(
      'Windows startup while a file is held open (temporary=$temporary)',
      () async {
        // Use the same local data directory as the installed Windows app.
        support.deleteSync();
        support = Directory(Platform.environment['LOCALAPPDATA']!)
            .createTempSync('xveil-prefs-contention-');
        const stored = '{"v":1,"e":{"flutter.locale":{"t":"String","v":"es"}}}';
        final writer = await open(prefs());
        expect(await writer.write(stored), isTrue);
        await writer.close();
        final name = prefs().toNativeUtf16();
        final handle = win.CreateFile(
          name,
          win.GENERIC_READ,
          0,
          nullptr,
          win.OPEN_EXISTING,
          win.FILE_ATTRIBUTE_NORMAL,
          0,
        );
        calloc.free(name);
        expect(handle, isNot(win.INVALID_HANDLE_VALUE));
        var held = true;
        void unlock() {
          if (!held) return;
          held = false;
          expect(win.CloseHandle(handle), isNot(0));
        }

        Timer? release;
        try {
          expect(
            () => File(prefs()).readAsStringSync(),
            throwsA(
              isA<FileSystemException>().having(
                (error) => error.osError?.errorCode,
                'Windows error code',
                32,
              ),
            ),
          );
          final startup = install();
          if (temporary) {
            release = Timer(const Duration(milliseconds: 250), unlock);
            expect(
              await startup.timeout(const Duration(seconds: 5)),
              AppProfiles.defaultName,
            );
          } else {
            await expectLater(
              startup.timeout(const Duration(seconds: 5)),
              throwsA(
                isA<ManagedWorkerFailure>()
                    .having(
                      (error) => error.kind,
                      'kind',
                      ManagedWorkerFailureKind.busy,
                    )
                    .having(
                      (error) => error.preferencesReadReason,
                      'read reason',
                      ManagedPreferencesFailureReason.busy,
                    ),
              ),
            );
            expect(SharedPreferencesStorePlatform.instance, same(legacy));
            expect(await legacy.getAll(), {'flutter.locale': 'ru'});
          }
        } finally {
          release?.cancel();
          unlock();
        }
        if (!temporary) expect(await install(), AppProfiles.defaultName);
        final settings = await SharedPreferencesStorePlatform.instance.getAll();
        expect(settings['flutter.locale'], 'es');
        expect(File(prefs()).readAsStringSync(), stored);
      },
      skip: !Platform.isWindows,
    );
  }

  test(
    'an unreadable remembered choice never opens the default profile',
    () async {
      final pointer = Directory(activeProfilePath(support.path))..createSync();
      final marker = File('${pointer.path}/fixture')..writeAsStringSync('keep');
      final source = await legacy.getAll();
      await expectLater(
        install(),
        throwsA(
          isA<ProfileChoiceReadFailure>().having((e) => e.busy, 'busy', false),
        ),
      );
      expect(files, isEmpty);
      expect(SharedPreferencesStorePlatform.instance, same(legacy));
      expect(await legacy.getAll(), source);
      expect(marker.readAsStringSync(), 'keep');
      expect(File(prefs()).existsSync(), isFalse);

      pointer.deleteSync(recursive: true);
      expect(await writeRememberedProfile(support.path, 'decoy'), isTrue);
      expect(await install(), 'decoy');
      expect(files.first.path, prefs('decoy'));
    },
  );

  test(
    'an explicit profile keeps the legacy source when choice cannot be read',
    () async {
      final pointer = Directory(activeProfilePath(support.path))..createSync();
      await legacy.setValue('String', 'flutter.locale.decoy', 'ru');
      final source = await legacy.getAll();
      expect(await install(args: const ['--profile=decoy']), 'decoy');
      expect(pointer.existsSync(), isTrue);
      expect(await legacy.getAll(), source);
      expect(files.any((file) => file.path == prefs('decoy')), isTrue);
    },
  );

  test('a cold restart refreshes a retained legacy setting', () async {
    const key = 'flutter.locale';
    expect(
      await installProfilePreferences(
        supportDir: support.path,
        args: const [],
        environment: const {},
        legacyBackend: legacy,
        openOwnedFile: (path) async {
          // The source has already been snapshotted when the owner is opened.
          expect(await legacy.setValue('String', key, 'es'), isTrue);
          return open(path);
        },
      ),
      AppProfiles.defaultName,
    );
    final first =
        SharedPreferencesStorePlatform.instance as ProfilePreferencesStore;
    stores.add(first);
    expect(await first.getAll(), {key: 'ru'});
    expect(await legacy.getAll(), {key: 'es'});
    await first.releaseFile();

    SharedPreferencesStorePlatform.instance = legacy;
    expect(await install(), AppProfiles.defaultName);
    expect(await SharedPreferencesStorePlatform.instance.getAll(), {key: 'es'});
    expect(await legacy.getAll(), isEmpty);
    await stores.last.releaseFile();

    SharedPreferencesStorePlatform.instance = legacy;
    expect(await install(), AppProfiles.defaultName);
    expect(await SharedPreferencesStorePlatform.instance.getAll(), {key: 'es'});
  });

  for (final (raw, reason) in [
    (
      '{"v":2,"e":{"flutter.locale":{"t":"String","v":"es"}}}',
      ProfilePreferencesFormatReason.unsupportedVersion,
    ),
    ('{"v":1,"e":', ProfilePreferencesFormatReason.invalidJson),
    (
      '{"v":1,"e":{"flutter.locale":{"t":"FutureType","v":"es"}}}',
      ProfilePreferencesFormatReason.invalidEntries,
    ),
    (
      '{"v":1,"e":{"flutter.apps":{"t":"StringList","v":["app",2]}}}',
      ProfilePreferencesFormatReason.invalidEntries,
    ),
  ]) {
    test(
      'refuses startup migration over unsupported preferences $raw',
      () async {
        final previous = await open(prefs());
        expect(await previous.write(raw), isTrue);
        await previous.close();
        final source = await legacy.getAll();

        final outcome = await install().then<Object>(
          (value) => value,
          onError: (Object error) => error,
        );

        expect(File(prefs()).readAsStringSync(), raw);
        expect(
          outcome,
          isA<ProfilePreferencesFormatFailure>().having(
            (e) => e.reason,
            'reason',
            reason,
          ),
        );
        expect(await legacy.getAll(), source);
        expect(SharedPreferencesStorePlatform.instance, same(legacy));
        expect(File(activeProfilePath(support.path)).existsSync(), isFalse);
      },
    );
  }

  test(
    'unreadable UTF-8 is a format error and preserves preference files',
    () async {
      const valid = '{"v":1,"e":{"flutter.locale":{"t":"String","v":"es"}}}';
      const corrupt = [0x7b, 0xff, 0x7d];
      final owner = await open(prefs());
      expect(await owner.write(valid), isTrue);
      final file = File(prefs())..writeAsBytesSync(corrupt, flush: true);
      final source = await legacy.getAll();

      final formatError = throwsA(
        isA<ProfilePreferencesFormatFailure>().having(
          (error) => error.reason,
          'reason',
          ProfilePreferencesFormatReason.invalidEncoding,
        ),
      );
      await expectLater(install(), formatError);
      await expectLater(owner.compareAndWrite(valid, valid), formatError);
      expect(file.readAsBytesSync(), corrupt);
      expect(await legacy.getAll(), source);
      expect(SharedPreferencesStorePlatform.instance, same(legacy));

      file.writeAsStringSync(valid, flush: true);
      expect(await install(), AppProfiles.defaultName);
      expect(await stores.single.getAll(), {'flutter.locale': 'es'});
    },
  );

  test(
    'a running preference writer never replaces an unknown snapshot',
    () async {
      const original = '{"v":1,"e":{"flutter.locale":{"t":"String","v":"es"}}}';
      const future = '{"v":2,"e":{"flutter.locale":{"codec":2,"value":"es"}}}';
      final owner = await open(prefs());
      expect(await owner.write(original), isTrue);
      final store = await ProfilePreferencesStore.load(
        prefs(),
        ownedFile: owner,
      );
      stores.add(store);
      final other = await open(prefs());
      expect(await other.write(future), isTrue);
      await expectLater(
        store.setValue('Bool', 'flutter.changed', true),
        throwsA(isA<ProfilePreferencesFormatFailure>()),
      );
      await expectLater(
        store.readPersistedString('locale'),
        throwsA(isA<ProfilePreferencesFormatFailure>()),
      );
      expect(await other.read(), future);
      expect(await store.getAll(), {'flutter.locale': 'es'});

      expect(await other.write(original), isTrue);
      expect(await store.setValue('Bool', 'flutter.changed', true), isTrue);
      expect(await store.getAll(), {
        'flutter.locale': 'es',
        'flutter.changed': true,
      });
    },
  );

  test('an unsupported sibling keeps its file and the legacy source', () async {
    const future = '{"v":2,"e":{"flutter.locale":{"codec":2,"value":"es"}}}';
    final sibling = await open(prefs('decoy'));
    expect(await sibling.write(future), isTrue);
    await sibling.close();
    await legacy.setValue('String', 'flutter.locale.decoy', 'en');
    final source = await legacy.getAll();

    expect(await install(), AppProfiles.defaultName);

    expect(File(prefs('decoy')).readAsStringSync(), future);
    expect(await legacy.getAll(), source);
    expect(await stores.single.getAll(), {'flutter.locale': 'ru'});
  });

  test('preference admission preserves the typed filesystem reason', () async {
    Directory(base()).createSync(recursive: true);
    final marker = File(managed())..writeAsStringSync('fixture');
    await expectLater(
      ManagedProfilePreferencesFile.open(prefs()),
      throwsA(
        isA<ManagedWorkerFailure>()
            .having((e) => e.kind, 'kind', ManagedWorkerFailureKind.invalid)
            .having(
              (e) => e.preferencesOpenReason,
              'reason',
              ManagedPreferencesFailureReason.filesystemUnsafe,
            ),
      ),
    );
    expect(marker.readAsStringSync(), 'fixture');
    expect(File(prefs()).existsSync(), isFalse);
  });

  test('a preference read reports a directory without modifying it', () async {
    final owner = await open(prefs());
    final directory = Directory(prefs())..createSync();
    final marker = File('${directory.path}/marker')
      ..writeAsStringSync('fixture');
    await expectLater(
      owner.read(),
      throwsA(
        isA<ManagedWorkerFailure>()
            .having((e) => e.kind, 'kind', ManagedWorkerFailureKind.invalid)
            .having(
              (e) => e.preferencesReadReason,
              'read reason',
              ManagedPreferencesFailureReason.fileType,
            )
            .having((e) => e.preferencesOpenReason, 'open reason', isNull),
      ),
    );
    expect(marker.readAsStringSync(), 'fixture');
  });

  test(
    'pending erasure refuses before preference or pointer migration with no ephemeral fallback',
    () async {
      await legacy.setValue(
        'String',
        'flutter.${AppProfiles.activePref}',
        'decoy',
      );
      await pending();
      final before = contents(), source = await legacy.getAll();
      var fallbacks = 0;
      await expectLater(
        installProfilePreferencesOrFallback(
          supportDir: () async => support.path,
          args: const ['--profile', 'default'],
          environment: const {},
          openOwnedFile: open,
          onError: (_, _) => fallbacks++,
        ),
        throwsA(isA<ProfilePreferencesErasurePending>()),
      );
      expect(fallbacks, 0);
      expect(SharedPreferencesStorePlatform.instance, same(legacy));
      expect(await legacy.getAll(), source);
      expect(contents(), before);
      expect(File(prefs()).existsSync(), isFalse);
      expect(File(activeProfilePath(support.path)).existsSync(), isFalse);
      expect(Directory('${managed()}/identities').existsSync(), isFalse);
    },
  );

  test(
    'the application startup helper stops before ordinary preference bootstrap',
    () async {
      await pending();
      final before = contents();
      final result = await bootstrapProfilePreferences(
        supportDir: () async => support.path,
        args: const [],
        environment: const {},
        managedStorage: true,
      );
      expect(result.erasurePending, isTrue);
      expect(result.profile, isNull);
      expect(SharedPreferencesStorePlatform.instance, same(legacy));
      expect(contents(), before);
      expect(File(prefs()).existsSync(), isFalse);
    },
  );

  test(
    'ordinary startup preserves pending erasure without a QA opt-in',
    () async {
      await pending();
      final before = contents();
      final result = await bootstrapProfilePreferences(
        supportDir: () async => support.path,
        args: const [],
        environment: const {},
      );
      final installed = SharedPreferencesStorePlatform.instance;
      if (installed is ProfilePreferencesStore &&
          !identical(installed, legacy)) {
        stores.add(installed);
      }
      expect(result.erasurePending, isTrue);
      expect(result.profile, isNull);
      expect(SharedPreferencesStorePlatform.instance, same(legacy));
      expect(contents(), before);
      expect(File(prefs()).existsSync(), isFalse);
    },
    skip: const bool.hasEnvironment('XVEIL_MANAGED_STORAGE')
        ? 'default-build policy; explicit legacy/QA definitions are separate controls'
        : false,
  );

  test(
    'the application startup helper binds the selected physical profile',
    () async {
      final result = await bootstrapProfilePreferences(
        supportDir: () async => support.path,
        args: const ['--profile', 'decoy'],
        environment: const {},
        managedStorage: true,
      );
      stores.add(
        SharedPreferencesStorePlatform.instance as ProfilePreferencesStore,
      );
      expect(result.erasurePending, isFalse);
      expect(result.profile, 'decoy');
      expect(
        File(prefs()).existsSync(),
        isTrue,
      ); // The default legacy keys migrated separately.
      expect(File(prefs('decoy')).existsSync(), isTrue);
      expect(Directory('${managed('decoy')}/identities').existsSync(), isFalse);
    },
  );

  test(
    'startup returns the exact directory used for admitted preferences',
    () async {
      var reads = 0;
      final result = await bootstrapProfilePreferences(
        supportDir: () async =>
            ++reads == 1 ? support.path : '${support.path}/different',
        args: const [],
        environment: const {},
        managedStorage: true,
      );
      stores.add(
        SharedPreferencesStorePlatform.instance as ProfilePreferencesStore,
      );
      expect(reads, 1);
      expect(result.supportDirectory, support.path);
      expect(result.erasurePending, isFalse);
      expect(File(prefs()).existsSync(), isTrue);
      expect(Directory('${support.path}/different').existsSync(), isFalse);
    },
  );

  test(
    'shared native admission is retained across ordinary preference writes',
    () async {
      expect(await install(), 'default');
      final backend =
          SharedPreferencesStorePlatform.instance as ProfilePreferencesStore;
      expect((await backend.getAll())['flutter.locale'], 'ru');
      expect(await legacy.getAll(), isEmpty);
      expect(Directory('${managed()}/identities').existsSync(), isFalse);
      expect(
        () =>
            StorageProfileCoordinator.openExisting(managed(), exclusive: true),
        throwsA(busy),
      );
      await backend.setValue('Bool', 'flutter.accepted', true);
      await backend.retire();
      // Local settlement is deliberately NOT native release.
      expect(
        () =>
            StorageProfileCoordinator.openExisting(managed(), exclusive: true),
        throwsA(busy),
      );
      await backend.releaseFile();
      final exclusive = StorageProfileCoordinator.openExisting(
        managed(),
        exclusive: true,
      )!;
      exclusive.close();
      final raw = jsonDecode(File(prefs()).readAsStringSync()) as Map;
      expect((raw['e'] as Map)['flutter.accepted'], {'t': 'Bool', 'v': true});
      expect(
        () => backend.setValue('Bool', 'flutter.late', true),
        throwsStateError,
      );
    },
  );

  test(
    'an admitted write owns the native grant until completion and release',
    () async {
      final gate = ReceivePort();
      addTearDown(gate.close);
      final owner =
          await ManagedProfilePreferencesFile.openWithWriteGateForTesting(
            prefs(),
            gate.sendPort,
          );
      files.add(owner);
      final backend = await ProfilePreferencesStore.load(
        prefs(),
        ownedFile: owner,
      );
      stores.add(backend);
      final save = backend.setValue('String', 'flutter.accepted', 'value');
      final resume = await gate.first as SendPort;
      addTearDown(() => resume.send(true));
      var released = false;
      final closing = backend.releaseFile().then((_) => released = true);
      await Future<void>.value();
      expect(released, isFalse);
      expect(
        () =>
            StorageProfileCoordinator.openExisting(managed(), exclusive: true),
        throwsA(busy),
      );
      expect(File(prefs()).existsSync(), isFalse);
      resume.send(true);
      expect(await save, isTrue);
      await closing;
      expect(released, isTrue);
      final exclusive = StorageProfileCoordinator.openExisting(
        managed(),
        exclusive: true,
      )!;
      exclusive.close();
      expect(File(prefs()).readAsStringSync(), contains('accepted'));
    },
  );

  test('refused write admission cannot fall back to a local write', () async {
    final gate = ReceivePort();
    addTearDown(gate.close);
    final owner =
        await ManagedProfilePreferencesFile.openWithWriteGateForTesting(
          prefs(),
          gate.sendPort,
        );
    files.add(owner);
    final backend = await ProfilePreferencesStore.load(
      prefs(),
      ownedFile: owner,
    );
    stores.add(backend);
    final save = backend.setValue('String', 'flutter.refused', 'value');
    final failed = expectLater(save, throwsA(isA<ManagedWorkerFailure>()));
    (await gate.first as SendPort).send(false);
    await failed;
    await backend.releaseFile();
    expect(File(prefs()).existsSync(), isFalse);
    expect(File('${prefs()}.tmp').existsSync(), isFalse);
  });

  test(
    'a blocked sibling migration preserves its data and the entire legacy source',
    () async {
      await legacy.setValue('String', 'flutter.locale.decoy', 'de');
      await pending('decoy');
      final otherBefore = contents().map((k, v) => MapEntry(k, v));
      final source = await legacy.getAll();
      expect(await install(), 'default');
      expect(await legacy.getAll(), source);
      expect(File(prefs('decoy')).existsSync(), isFalse);
      for (final entry in otherBefore.entries) {
        expect(
          sha256.convert(File(entry.key).readAsBytesSync()).toString(),
          entry.value,
        );
      }
      expect((await stores.last.getAll())['flutter.locale'], 'ru');
    },
  );

  test(
    'every successful migration destination has its own native admission',
    () async {
      Directory(base('decoy')).createSync(recursive: true);
      await legacy.setValue('String', 'flutter.locale.decoy', 'de');
      expect(await install(), 'default');
      expect(await legacy.getAll(), isEmpty);
      expect(File(prefs('decoy')).readAsStringSync(), contains('de'));
      final releasedSibling = StorageProfileCoordinator.openExisting(
        managed('decoy'),
        exclusive: true,
      )!;
      releasedSibling.close();
      expect(
        () =>
            StorageProfileCoordinator.openExisting(managed(), exclusive: true),
        throwsA(busy),
      );
      expect(Directory('${managed('decoy')}/identities').existsSync(), isFalse);
    },
  );

  test(
    'migration leaves an up-to-date native preference file byte-for-byte',
    () async {
      final current = const JsonEncoder.withIndent('  ').convert({
        'v': 1,
        'e': {
          'flutter.locale': {'t': 'String', 'v': 'es'},
        },
      });
      final owner = await open(prefs());
      expect(await owner.write(current), isTrue);
      await owner.close();

      expect(await install(), 'default');
      expect((await stores.last.getAll())['flutter.locale'], 'es');
      expect(File(prefs()).readAsStringSync(), current);
      expect(await legacy.getAll(), isEmpty);
    },
  );

  test(
    'a malformed pending marker blocks startup without preference writes',
    () async {
      StorageProfileCoordinator.forPreferences(base()).close();
      final marker = File(
        '${managed()}/${StorageProfileCoordinator.directoryName}/${ManagedRootErasure.completionName}',
      );
      marker.writeAsStringSync('not a completion record');
      final before = contents();
      await expectLater(
        install(),
        throwsA(isA<ProfilePreferencesErasurePending>()),
      );
      expect(contents(), before);
      expect(File(prefs()).existsSync(), isFalse);
    },
  );

  test(
    'a failed managed opener never invokes the ordinary preference fallback',
    () async {
      var fallbacks = 0;
      await expectLater(
        installProfilePreferencesOrFallback(
          supportDir: () async => support.path,
          args: const [],
          environment: const {},
          openOwnedFile: (_) async =>
              throw StateError('synthetic admission refusal'),
          onError: (_, _) => fallbacks++,
        ),
        throwsStateError,
      );
      expect(fallbacks, 0);
      expect(SharedPreferencesStorePlatform.instance, same(legacy));
      expect(support.listSync(), isEmpty);
    },
  );

  test(
    'an override outside the profile is refused before native admission or pointer write',
    () async {
      var opens = 0;
      await expectLater(
        installProfilePreferencesOrFallback(
          supportDir: () async => support.path,
          args: const [],
          environment: const {},
          validateSelectedFile: (path) => validateManagedPreferencesContainer(
            path,
            '${support.path}/other/container',
          ),
          openOwnedFile: (path) async {
            opens++;
            return open(path);
          },
        ),
        throwsA(isA<ManagedWorkerFailure>()),
      );
      expect(opens, 0);
      expect(support.listSync(), isEmpty);
      validateManagedPreferencesContainer(prefs(), '${support.path}/container');
      validateManagedPreferencesContainer(prefs(), null);
    },
  );

  test('environment lookup semantics are retained before validation', () async {
    final env = HashMap<String, String>(
      equals: (a, b) => a.toLowerCase() == b.toLowerCase(),
      hashCode: (key) => key.toLowerCase().hashCode,
    )..['xveil_store_path'] = '${support.path}/outside/container';
    await expectLater(
      bootstrapProfilePreferences(
        supportDir: () async => support.path,
        args: const [],
        environment: env,
        managedStorage: true,
      ),
      throwsA(isA<ManagedWorkerFailure>()),
    );
    expect(support.listSync(), isEmpty);
    expect(SharedPreferencesStorePlatform.instance, same(legacy));
  });

  test(
    'a separate process observes the held grant and its confirmed release',
    () async {
      await install();
      expect(await _probe(managed()), 'busy');
      await stores.last.releaseFile();
      expect(await _probe(managed()), 'acquired');
    },
  );

  test('native file errors never become a new empty local backend', () async {
    Directory(prefs()).createSync();
    await expectLater(install(), throwsA(isA<ManagedWorkerFailure>()));
    expect(Directory(prefs()).existsSync(), isTrue);
    expect(SharedPreferencesStorePlatform.instance, same(legacy));
    expect(File('${prefs()}.tmp').existsSync(), isFalse);
    // Lifetime-role metadata may be initialized, but no preference data is created.
  });

  test('two owners can race the first preference write', () async {
    const first = '{"v":1,"e":{}}';
    const second = '{"v":1,"e":{"flutter.flag":{"t":"Bool","v":true}}}';
    for (var i = 0; i < 8; i++) {
      final path = prefs('fresh$i');
      final a = await open(path);
      final b = await open(path);
      final results = await Future.wait([
        a.compareAndWrite(null, first),
        b.compareAndWrite(null, second),
      ]);
      expect(results, unorderedEquals([true, null]));
      expect(await a.read(), results.first == true ? first : second);
      await a.close();
      await b.close();
    }
  });

  test('concurrent preference owners retain each other’s changes', () async {
    final aFile = await open(prefs());
    final bFile = await open(prefs());
    final a = await ProfilePreferencesStore.load(prefs(), ownedFile: aFile);
    final b = await ProfilePreferencesStore.load(prefs(), ownedFile: bFile);
    stores.addAll([a, b]);
    expect(await a.setValue('String', 'flutter.prior', 'value'), isTrue);
    final prior = (await aFile.read())!;
    expect(await b.remove('flutter.prior'), isTrue);
    final current = await bFile.read();
    expect(await aFile.compareAndWrite(prior, prior), isNull);
    expect(await aFile.read(), current);
    expect(
      await Future.wait([
        a.setValue('Bool', 'flutter.first', true),
        b.setValue('Int', 'flutter.second', 2),
      ]),
      [true, true],
    );
    final reopened = await ProfilePreferencesStore.load(
      prefs(),
      ownedFile: await open(prefs()),
    );
    stores.add(reopened);
    expect(await reopened.getAll(), {
      'flutter.first': true,
      'flutter.second': 2,
    });
  });

  test(
    'a separate process blocks publication until its write lock is released',
    () async {
      final owner = await open(prefs());
      const original = '{"v":1,"e":{}}';
      const next = '{"v":1,"e":{"flutter.flag":{"t":"Bool","v":true}}}';
      expect(await owner.write(original), isTrue);
      final child = await Process.start('dart', [
        'run',
        'test/native/profile_preferences_admission_probe.dart',
        managed(),
        'hold-write',
      ]);
      final held = Completer<void>();
      final output = child.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .forEach((line) {
            if (line.contains('"state":"write-locked"')) held.complete();
          });
      final errors = child.stderr.transform(utf8.decoder).join();
      var exited = false;
      final done = child.exitCode.then((code) {
        exited = true;
        return code;
      });
      try {
        await Future.any([
          held.future,
          done.then((_) => throw StateError('write lock probe exited')),
        ]).timeout(const Duration(seconds: 30));
        await expectLater(
          owner.compareAndWrite(original, next),
          throwsA(
            isA<ManagedWorkerFailure>().having(
              (error) => error.kind,
              'kind',
              ManagedWorkerFailureKind.busy,
            ),
          ),
        );
        expect(await owner.read(), original);
        child.stdin.writeln('release');
        await child.stdin.close();
        expect(await done.timeout(const Duration(seconds: 10)), 0);
        expect(await owner.compareAndWrite(original, next), isTrue);
        expect(await owner.read(), next);
      } finally {
        if (!exited) child.kill(ProcessSignal.sigkill);
        await done;
        await output;
        await errors;
      }
    },
  );

  test(
    'the same preference owner writes after a temporary file refusal',
    () async {
      final owner = await open(prefs());
      final store = await ProfilePreferencesStore.load(
        prefs(),
        ownedFile: owner,
      );
      stores.add(store);
      const key = 'flutter.locale';
      final blocked = Directory(prefs())..createSync();
      await expectLater(
        store.setValue('String', key, 'ru'),
        throwsA(isA<ManagedWorkerFailure>()),
      );
      blocked.deleteSync();
      expect(await store.setValue('String', key, 'es'), isTrue);
      await store.releaseFile();

      final reopened = await open(prefs());
      final loaded = await ProfilePreferencesStore.load(
        prefs(),
        ownedFile: reopened,
      );
      stores.add(loaded);
      expect((await loaded.getAll())[key], 'es');
    },
  );

  test(
    'a refused preference read leaves the legacy profile choice in place',
    () async {
      final key = 'flutter.${AppProfiles.activePref}';
      await legacy.setValue('String', key, 'decoy');
      final blocked = Directory(prefs('decoy'))..createSync(recursive: true);
      final marker = File('${blocked.path}/marker')
        ..writeAsStringSync('fixture');
      await expectLater(
        install(),
        throwsA(
          isA<ManagedWorkerFailure>().having(
            (error) => error.preferencesReadReason,
            'read reason',
            ManagedPreferencesFailureReason.fileType,
          ),
        ),
      );
      expect(File(activeProfilePath(support.path)).existsSync(), isFalse);
      expect((await legacy.getAll())[key], 'decoy');
      expect(SharedPreferencesStorePlatform.instance, same(legacy));
      expect(marker.readAsStringSync(), 'fixture');

      blocked.deleteSync(recursive: true);
      expect(await install(), 'decoy');
      expect(await readRememberedProfile(support.path), 'decoy');
      expect((await legacy.getAll()).containsKey(key), isFalse);
    },
  );

  test(
    'local retirement and native release remain separate through the bound application view',
    () async {
      await install();
      final lifetime = ProfilePreferencesLifetime.current();
      final view = await lifetime.preferences;
      await view.setBool('accepted', true);
      await lifetime.retire();
      expect(
        () =>
            StorageProfileCoordinator.openExisting(managed(), exclusive: true),
        throwsA(busy),
      );
      await lifetime.releaseFile();
      final exclusive = StorageProfileCoordinator.openExisting(
        managed(),
        exclusive: true,
      )!;
      exclusive.close();
      await expectLater(view.setBool('late', true), throwsStateError);
    },
  );
}

class _UnreadableLegacyPreferences extends InMemorySharedPreferencesStore {
  _UnreadableLegacyPreferences(super.values) : super.withData();

  bool unreadable = true;

  @override
  Future<Map<String, Object>> getAll() async {
    if (unreadable) {
      throw const FileSystemException('fixture could not read legacy settings');
    }
    return super.getAll();
  }
}

class _GatedLegacyPreferences extends _UnreadableLegacyPreferences {
  _GatedLegacyPreferences(super.values) {
    unreadable = false;
  }

  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<Map<String, Object>> getAll() async {
    if (!started.isCompleted) {
      started.complete();
      await release.future;
    }
    return super.getAll();
  }
}

Future<String> _probe(String profile) async {
  final process = await Process.start('dart', [
    'run',
    'test/native/profile_preferences_admission_probe.dart',
    profile,
  ]);
  final output = process.stdout.transform(utf8.decoder).join();
  final errors = process.stderr.transform(utf8.decoder).join();
  var exited = false;
  final done = process.exitCode.then((value) {
    exited = true;
    return value;
  });
  try {
    expect(await done.timeout(const Duration(seconds: 30)), 0);
    final text = await output;
    expect(
      (await errors).replaceAll('Running build hooks...', '').trim(),
      isEmpty,
    );
    final lines = text
        .split('\n')
        .where((line) => line.startsWith('{'))
        .toList();
    expect(lines, hasLength(1));
    return (jsonDecode(lines.single) as Map)['state'] as String;
  } finally {
    if (!exited) process.kill(ProcessSignal.sigkill);
    await done;
    await output;
    await errors;
  }
}
