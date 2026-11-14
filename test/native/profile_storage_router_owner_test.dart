@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/profile_storage_router.dart';
import 'package:xveil/data/storage/profile_storage_router_owner.dart';
import 'package:xveil/domain/storage_locator.dart';
import 'package:xveil/state/storage_router_providers.dart';

class _Storage extends HiddenVolumeStorage {
  _Storage()
    : super(({required password, required create}) => FakeKvLogStore());
  bool refuse = false;
  Completer<void>? closing;
  final entered = Completer<void>();
  @override
  Future<void> close() async {
    if (!entered.isCompleted) entered.complete();
    await closing?.future;
    if (refuse) throw StateError('synthetic close refusal');
    await super.close();
  }
}

Future<Object?> _outcome(Future<void> f) =>
    f.then<Object?>((_) => null, onError: (Object e) => e);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const fs = ManagedFsPlatform();
  late Directory fixture;
  late String profile;
  final owners = <ProfileStorageRouterOwner>[];
  final routers = <ProfileStorageRouter>[];
  final stores = <_Storage>[];
  final erasures = <ManagedErasureWorker>[];
  _Storage storage() {
    final s = _Storage();
    stores.add(s);
    return s;
  }

  Future<ProfileStorageRouter> open({String? path}) async {
    final r = await ProfileStorageRouter.open(
      profileDirectory: path ?? profile,
      legacyFactory: storage,
    );
    routers.add(r);
    return r;
  }

  Future<ProfileStorageRouterOwner> own({
    Future<ProfileStorageRouter> Function()? reopen,
  }) async {
    final owner = ProfileStorageRouterOwner(
      await open(),
      reopen: reopen ?? open,
    );
    owners.add(owner);
    return owner;
  }

  setUp(() {
    fixture = Directory.systemTemp.createTempSync('xveil-router-owner-');
    profile = '${fixture.path}/profile';
    expect(fs.createPrivateDirectory(profile), isTrue);
    ManagedDirectoryCatalog.createOrOpen(profile).close();
  });
  tearDown(() async {
    for (final s in stores) {
      s.refuse = false;
      if (s.closing case final c? when !c.isCompleted) c.complete();
    }
    for (final e in erasures) {
      await e.close();
    }
    for (final o in owners) {
      await o.close();
    }
    for (final r in routers) {
      await r.close();
    }
    stores.clear();
    erasures.clear();
    owners.clear();
    routers.clear();
    fixture.deleteSync(recursive: true);
  });

  test(
    'provider replaces a released router; suspended never means legacy',
    () async {
      final owner = await own();
      final container = ProviderContainer(
        overrides: [
          profileStorageRouterOwnerProvider.overrideWith((ref) {
            ref.onDispose(() => unawaited(owner.close()));
            return owner;
          }),
        ],
      );
      addTearDown(container.dispose);
      final old = container.read(profileStorageRouterProvider)!;
      final oldFacade = old.storage;
      expect(
        () => StorageProfileCoordinator.openExisting(profile, exclusive: true),
        throwsA(anything),
      );
      final suspended = owner.suspend();
      expect(() => owner.router, throwsStateError);
      expect(
        () => container.read(profileStorageRouterProvider),
        throwsA(anything),
      );
      await suspended;
      final exclusive = StorageProfileCoordinator.openExisting(
        profile,
        exclusive: true,
      );
      exclusive!.close();
      await owner.reopen();
      final fresh = container.read(profileStorageRouterProvider)!;
      expect(identical(old, fresh), isFalse);
      expect(identical(oldFacade, fresh.storage), isFalse);
      expect(fresh.location, const LegacyStorageLocator());
      await expectLater(
        old.select(const LegacyStorageLocator()),
        throwsStateError,
      );
      container.dispose();
      await owner.close();
      final released = StorageProfileCoordinator.openExisting(
        profile,
        exclusive: true,
      );
      released!.close();
    },
  );

  test(
    'refused storage close retains native role and forbids factory admission',
    () async {
      var opens = 0;
      final owner = await own(
        reopen: () {
          opens++;
          return open();
        },
      );
      final old = owner.router;
      await old.storage.open(password: 'synthetic');
      stores.single.refuse = true;
      await expectLater(owner.suspend(), throwsStateError);
      await expectLater(owner.reopen(), throwsStateError);
      expect(opens, 0);
      expect(() => owner.router, throwsStateError);
      expect(
        () => StorageProfileCoordinator.openExisting(profile, exclusive: true),
        throwsA(anything),
      );
      stores.single.refuse = false;
      await owner.suspend();
      await owner.reopen();
      expect(opens, 1);
      expect(identical(old, owner.router), isFalse);
    },
  );

  test(
    'suspend and reopen coalesce behind actual storage-close barrier',
    () async {
      var opens = 0;
      final owner = await own(
        reopen: () {
          opens++;
          return open();
        },
      );
      final s = stores.single;
      s.closing = Completer<void>();
      final suspended = owner.suspend();
      expect(identical(suspended, owner.suspend()), isTrue);
      final reopened = owner.reopen();
      expect(identical(reopened, owner.reopen()), isTrue);
      await s.entered.future;
      expect(opens, 0);
      expect(() => owner.router, throwsStateError);
      s.closing!.complete();
      await suspended;
      await reopened;
      expect(opens, 1);
      expect(owner.router.storage, isNotNull);
    },
  );

  for (final disposing in [false, true]) {
    test(
      'late candidate cannot publish after ${disposing ? 'dispose' : 'suspend'}',
      () async {
        final candidateGate = Completer<ProfileStorageRouter>();
        final opening = Completer<void>();
        final owner = await own(
          reopen: () {
            opening.complete();
            return candidateGate.future;
          },
        );
        await owner.suspend();
        final result = _outcome(owner.reopen());
        await opening.future;
        final closing = disposing ? owner.close() : owner.suspend();
        final candidate = await open();
        final candidateStorage = stores.last;
        candidateStorage.closing = Completer<void>();
        candidateGate.complete(candidate);
        await candidateStorage.entered.future;
        expect(() => owner.router, throwsStateError);
        var closed = false;
        final observed = closing.then((_) => closed = true);
        await Future<void>.value();
        expect(closed, isFalse);
        candidateStorage.closing!.complete();
        expect(await result, isA<StateError>());
        await observed;
        final exclusive = StorageProfileCoordinator.openExisting(
          profile,
          exclusive: true,
        );
        exclusive!.close();
        if (disposing) await expectLater(owner.reopen(), throwsStateError);
      },
    );
  }

  test(
    'unfinished erasure prevents replacement, final release permits a new router',
    () async {
      final owner = await own();
      await owner.suspend();
      final erasure = await ManagedErasureWorker.begin(
        profileDirectory: profile,
        profileNamespace: 'synthetic-profile',
        legacyPath: '${fixture.path}/absent-legacy',
      );
      erasures.add(erasure);
      await expectLater(owner.reopen(), throwsA(isA<ManagedWorkerFailure>()));
      expect(() => owner.router, throwsStateError);
      expect(
        Directory('$profile/storage-lifetime/erasure-pending').existsSync(),
        isTrue,
      );
      await erasure.removeManagedFiles(retireScopes: () async {});
      await erasure.finish(verifyOtherDataAbsent: () async {});
      await owner.reopen();
      expect(owner.router.catalog.identities, isEmpty);
      expect(Directory('$profile/identities').existsSync(), isFalse);
    },
  );

  test(
    'failed close of a cancelled replacement stays owned until retry',
    () async {
      final candidateGate = Completer<ProfileStorageRouter>();
      final opening = Completer<void>();
      final owner = await own(
        reopen: () {
          opening.complete();
          return candidateGate.future;
        },
      );
      await owner.suspend();
      final result = _outcome(owner.reopen());
      await opening.future;
      final closing = _outcome(owner.close());
      final candidate = await open();
      final candidateStorage = stores.last;
      candidateStorage.refuse = true;
      candidateGate.complete(candidate);
      expect(await result, isA<StateError>());
      expect(await closing, isA<StateError>());
      expect(() => owner.router, throwsStateError);
      expect(
        () => StorageProfileCoordinator.openExisting(profile, exclusive: true),
        throwsA(anything),
      );
      candidateStorage.refuse = false;
      await owner.close();
      final exclusive = StorageProfileCoordinator.openExisting(
        profile,
        exclusive: true,
      );
      exclusive!.close();
      await expectLater(owner.reopen(), throwsStateError);
    },
  );

  test(
    'replacement for another profile is closed and never published',
    () async {
      final other = '${fixture.path}/other';
      expect(fs.createPrivateDirectory(other), isTrue);
      final owner = await own(reopen: () => open(path: other));
      await owner.suspend();
      await expectLater(owner.reopen(), throwsStateError);
      expect(() => owner.router, throwsStateError);
      final exclusive = StorageProfileCoordinator.openExisting(
        other,
        exclusive: true,
      );
      exclusive!.close();
    },
  );
}
