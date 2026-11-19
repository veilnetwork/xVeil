import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:xveil/data/storage/app_profile.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/profile_prefs_store.dart';

void main() {
  late Directory fixture;
  late File local;
  late _FileOwner owner;
  late SharedPreferencesStorePlatform originalBackend;
  const original =
      '{"v":1,"e":{"flutter.original":{"t":"String","v":"synthetic"}}}';
  setUp(() {
    originalBackend = SharedPreferencesStorePlatform.instance;
    fixture = Directory.systemTemp.createTempSync('xveil-owned-prefs-port-');
    local = File('${fixture.path}/xveil.prefs.json')
      ..writeAsStringSync(original);
    owner = _FileOwner(local.path);
  });
  tearDown(() async {
    final installed = SharedPreferencesStorePlatform.instance;
    SharedPreferencesStorePlatform.instance = originalBackend;
    try {
      if (installed is ProfilePreferencesStore &&
          installed != originalBackend) {
        await installed.releaseFile();
      }
    } finally {
      fixture.deleteSync(recursive: true);
    }
  });

  test('owned absence never falls through to an existing local file', () async {
    final store = await ProfilePreferencesStore.load(
      local.path,
      ownedFile: owner,
    );
    expect(await store.getAll(), isEmpty);
    expect(local.readAsStringSync(), original);
    await store.releaseFile();
    expect(owner.closes, 1);
  });
  test(
    'owned read refusal propagates instead of loading locally or starting empty',
    () async {
      owner.readFailure = StateError('synthetic refusal');
      await expectLater(
        ProfilePreferencesStore.load(local.path, ownedFile: owner),
        throwsStateError,
      );
      expect(local.readAsStringSync(), original);
      expect(owner.reads, 1);
      // A failed loader has not consumed its caller's file owner.
      await owner.close();
    },
  );
  for (final failure in ['false', 'throw']) {
    test('owned write $failure never triggers local file fallback', () async {
      owner.contents = original;
      owner.writeResult = false;
      if (failure == 'throw') {
        owner.writeFailure = StateError('synthetic refusal');
      }
      final store = await ProfilePreferencesStore.load(
        local.path,
        ownedFile: owner,
      );
      final save = store.setValue('String', 'flutter.changed', 'changed');
      if (failure == 'throw') {
        await expectLater(save, throwsStateError);
      } else {
        expect(await save, isFalse);
      }
      expect(owner.writes, hasLength(1));
      expect(
        (jsonDecode(owner.writes.single) as Map)['e'],
        contains('flutter.changed'),
      );
      await store.releaseFile();
      expect(owner.closes, 1);
      expect(local.readAsStringSync(), original);
      expect(File('${local.path}.tmp').existsSync(), isFalse);
    });
  }
  test(
    'startup preserves its read error if closing the file also fails',
    () async {
      const readFailure = ManagedWorkerFailure(
        ManagedWorkerFailureKind.invalid,
        preferencesReadReason: ManagedPreferencesFailureReason.filePermissions,
      );
      owner
        ..readFailure = readFailure
        ..closeFailures = 1;
      final backend = SharedPreferencesStorePlatform.instance;
      await expectLater(
        installProfilePreferences(
          supportDir: fixture.path,
          args: const [],
          environment: const {},
          legacyBackend: InMemorySharedPreferencesStore.empty(),
          openOwnedFile: (_) async => owner,
        ),
        throwsA(same(readFailure)),
      );
      expect(owner.closes, 1);
      expect(owner.writes, isEmpty);
      expect(SharedPreferencesStorePlatform.instance, same(backend));
      expect(local.readAsStringSync(), original);
      await owner.close();
    },
  );

  test('an upgrade preserves a profile choice saved during startup', () async {
    final source = InMemorySharedPreferencesStore.withData({
      'flutter.${AppProfiles.activePref}': 'old',
      'flutter.locale': 'ru',
    });
    final opening = Completer<void>();
    final resume = Completer<void>();
    final migration = installProfilePreferences(
      supportDir: fixture.path,
      args: const ['--profile', AppProfiles.defaultName],
      environment: const {},
      legacyBackend: source,
      openOwnedFile: (path) async {
        opening.complete();
        await resume.future;
        expect(path, owner.path);
        return owner;
      },
    );
    await opening.future;
    try {
      expect(await writeRememberedProfile(fixture.path, 'new'), isTrue);
    } finally {
      resume.complete();
      expect(await migration, AppProfiles.defaultName);
    }
    expect(await readRememberedProfile(fixture.path), 'new');
    expect(await source.getAll(), isEmpty);
    await (SharedPreferencesStorePlatform.instance as ProfilePreferencesStore)
        .releaseFile();
    expect(
      await installProfilePreferences(
        supportDir: fixture.path,
        args: const [],
        environment: const {},
        legacyBackend: source,
      ),
      'new',
    );
  });

  for (final refuseRead in [false, true]) {
    test(
      'a sibling close failure preserves startup and migration source (read refusal: $refuseRead)',
      () async {
        final siblingPath = profilePrefsPath(fixture.path, 'decoy');
        Directory(
          AppProfiles.directory(fixture.path, 'decoy'),
        ).createSync(recursive: true);
        final sibling = _FileOwner(siblingPath)
          ..contents = original
          ..closeFailures = 1;
        if (refuseRead) {
          sibling.readFailure = StateError('synthetic sibling read refusal');
        }
        const source = {'flutter.locale': 'ru', 'flutter.locale.decoy': 'es'};
        final legacy = InMemorySharedPreferencesStore.withData(Map.of(source));

        final profile = await installProfilePreferencesOrFallback(
          supportDir: () async => fixture.path,
          args: const [],
          environment: const {},
          legacyBackend: legacy,
          openOwnedFile: (path) async => path == siblingPath ? sibling : owner,
        );
        expect(profile, AppProfiles.defaultName);
        final installed = SharedPreferencesStorePlatform.instance;
        expect(installed, isA<ProfilePreferencesStore>());
        expect((await installed.getAll())['flutter.locale'], 'ru');
        expect(await legacy.getAll(), source);
        expect(owner.closes, 0);
        expect(sibling.closes, 1);
        expect(sibling.writes, hasLength(refuseRead ? 0 : 1));
        if (!refuseRead) {
          expect(
            jsonDecode(sibling.writes.single)['e']['flutter.locale']['v'],
            'es',
          );
        }
      },
    );
  }

  for (final selected in [true, false]) {
    test(
      'migration does not rewrite an up-to-date ${selected ? 'selected' : 'sibling'} file',
      () async {
        final siblingPath = profilePrefsPath(fixture.path, 'decoy');
        Directory(
          AppProfiles.directory(fixture.path, 'decoy'),
        ).createSync(recursive: true);
        final sibling = _FileOwner(siblingPath);
        final upToDate = selected ? owner : sibling;
        final pending = selected ? sibling : owner;
        upToDate
          ..contents = '{"v":1,"e":{"flutter.locale":{"t":"String","v":"es"}}}'
          ..writeFailure = StateError('synthetic write refusal');
        final legacy = InMemorySharedPreferencesStore.withData({
          'flutter.locale': 'ru',
          'flutter.locale.decoy': 'de',
        });
        final profile = await installProfilePreferencesOrFallback(
          supportDir: () async => fixture.path,
          args: const [],
          environment: const {},
          legacyBackend: legacy,
          openOwnedFile: (path) async => path == siblingPath ? sibling : owner,
        );
        final installed = SharedPreferencesStorePlatform.instance;
        expect(profile, AppProfiles.defaultName);
        expect(
          (await installed.getAll())['flutter.locale'],
          selected ? 'es' : 'ru',
        );
        expect(upToDate.writes, isEmpty);
        expect(
          jsonDecode(pending.writes.single)['e']['flutter.locale']['v'],
          selected ? 'de' : 'ru',
        );
        expect(sibling.closes, 1);
        expect(await legacy.getAll(), isEmpty);
      },
    );
  }

  test(
    'queued settings survive an earlier write error and drain before close',
    () async {
      final firstStarted = Completer<void>();
      final firstResult = Completer<bool>();
      final secondStarted = Completer<void>();
      final secondResult = Completer<bool>();
      final failure = StateError('synthetic write refusal');
      final store = await ProfilePreferencesStore.load(
        local.path,
        ownedFile: owner,
      );
      owner.writeGate = () {
        firstStarted.complete();
        return firstResult.future;
      };
      final first = expectLater(
        store.setValue('String', 'flutter.locale', 'ru'),
        throwsA(same(failure)),
      );
      await firstStarted.future;

      owner.writeGate = () {
        secondStarted.complete();
        return secondResult.future;
      };
      final second = store.setValue('String', 'flutter.locale', 'es');
      final secondStartedOrSettled = Future.any<void>([
        secondStarted.future,
        second.then<void>((_) {}),
      ])..ignore();
      final closing = store.releaseFile();
      expect(secondStarted.isCompleted, isFalse);
      expect(owner.writes, hasLength(1));
      firstResult.completeError(failure);
      await first;
      try {
        await secondStartedOrSettled;
        expect(secondStarted.isCompleted, isTrue);
        expect(owner.closes, 0);
        expect(jsonDecode(owner.writes.last)['e']['flutter.locale']['v'], 'es');
      } finally {
        secondResult.complete(true);
        await closing;
      }
      expect(await second, isTrue);
      expect(owner.writes, hasLength(2));
      expect(owner.closes, 1);
    },
  );

  test('file owner mismatch refuses before any read', () async {
    final wrong = _FileOwner('${fixture.path}/other.json');
    await expectLater(
      ProfilePreferencesStore.load(local.path, ownedFile: wrong),
      throwsStateError,
    );
    expect(wrong.reads, 0);
    expect(local.readAsStringSync(), original);
    await wrong.close();
  });
  test(
    'failed native close is retryable without reviving ordinary writes',
    () async {
      owner.closeFailures = 1;
      final store = await ProfilePreferencesStore.load(
        local.path,
        ownedFile: owner,
      );
      await expectLater(store.releaseFile(), throwsStateError);
      expect(owner.closes, 1);
      expect(
        () => store.setValue('Bool', 'flutter.late', true),
        throwsStateError,
      );
      await store.releaseFile();
      expect(owner.closes, 2);
      expect(owner.writes, isEmpty);
      expect(local.readAsStringSync(), original);
    },
  );
}

class _FileOwner implements ProfilePreferencesFile {
  _FileOwner(this.path);
  @override
  final String path;
  String? contents;
  Object? readFailure, writeFailure;
  Future<bool> Function()? writeGate;
  bool writeResult = true;
  int reads = 0, closes = 0, closeFailures = 0;
  final writes = <String>[];
  @override
  Future<String?> read() async {
    reads++;
    if (readFailure case final Object error) throw error;
    return contents;
  }

  @override
  Future<bool> write(String contents) async {
    writes.add(contents);
    if (writeFailure case final Object error) throw error;
    if (writeGate case final gate?) return gate();
    return writeResult;
  }

  @override
  Future<void> close() async {
    closes++;
    if (closeFailures > 0) {
      closeFailures--;
      throw StateError('synthetic close refusal');
    }
  }
}
