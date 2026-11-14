@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/profile_storage_router.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/storage_locator.dart';
import 'package:xveil/domain/storage_protection.dart';

class _CloseGate extends FakeKvLogStore {
  bool fail = false;
  int closes = 0;
  @override
  void close() {
    closes++;
    if (fail) throw StateError('synthetic close refusal');
    super.close();
  }
}

void main() {
  late Directory fixture;
  late String profile;
  final routers = <ProfileStorageRouter>[];
  final workers = <ManagedCatalogWorker>[];
  final stores = <AsyncKvLogStore>[];
  final gates = <_CloseGate>[];
  HiddenVolumeStorage legacy() => HiddenVolumeStorage(
    ({required password, required create}) => FakeKvLogStore(),
  );
  Future<ProfileStorageRouter> router({
    ProfileIdentityStorageFactory? factory,
    String? path,
  }) async {
    final result = await ProfileStorageRouter.open(
      profileDirectory: path ?? profile,
      legacyFactory: legacy,
      storageFactory: factory,
    );
    routers.add(result);
    return result;
  }

  Future<ManagedCatalogWorker> catalog() async {
    final result = await ManagedCatalogWorker.open(profile);
    workers.add(result);
    return result;
  }

  Future<ManagedIdentityEntry> plain(String digit) async {
    final entry = ManagedIdentityEntry(
      id: ManagedIdentityId(digit * 32),
      protection: StorageProtection.unencrypted,
    );
    final store = await ManagedWorkerIdentity.createUnencrypted(
      profileDirectory: profile,
      id: entry.id,
    );
    stores.add(store);
    await store.close();
    return entry;
  }

  setUp(() {
    expect(ensureHiddenVolumeLoaded(), isTrue);
    fixture = Directory.systemTemp.createTempSync('xveil-selection-native-');
    profile = '${fixture.path}/profile';
    expect(const ManagedFsPlatform().createPrivateDirectory(profile), isTrue);
  });
  tearDown(() async {
    for (final gate in gates) {
      gate.fail = false;
    }
    for (final item in routers) {
      await item.close();
    }
    for (final item in workers) {
      await item.close();
    }
    for (final store in stores) {
      await store.close();
    }
    routers.clear();
    workers.clear();
    stores.clear();
    gates.clear();
    fixture.deleteSync(recursive: true);
  });

  test('catalog reads never create a visible or hidden identity', () async {
    final worker = await catalog();
    expect((await worker.snapshot()).exists, isFalse);
    expect((await worker.select(null)).catalog.identities, isEmpty);
    expect(
      Directory(
        profile,
      ).listSync().map((e) => File(e.path).uri.pathSegments.last).toSet(),
      {'storage-lifetime'},
    );
    final role = Directory('$profile/storage-lifetime');
    expect(
      role.listSync().map((e) => File(e.path).uri.pathSegments.last).toSet(),
      {'profile.meta', 'profile.meta.lock'},
    );
    final before = {
      for (final file in role.listSync().whereType<File>())
        file.path: file.readAsBytesSync(),
    };
    expect((await worker.snapshot()).exists, isFalse);
    expect((await worker.select(null)).catalog.identities, isEmpty);
    expect({
      for (final file in role.listSync().whereType<File>())
        file.path: file.readAsBytesSync(),
    }, before);
    expect(Directory('$profile/identities').existsSync(), isFalse);
    final entry = await plain('a');
    expect(
      (await worker.snapshot()).snapshot.catalog.identities.single.id,
      entry.id,
    );
  });

  test(
    'selected ID is durable and a later registration preserves it',
    () async {
      final first = await plain('a');
      final actor = await catalog();
      final selected = await actor.select(first);
      expect(selected.catalog.selected, first.locator);
      final revision = selected.revision;
      expect((await actor.select(first)).revision, revision);
      final second = await plain('b');
      expect((await actor.snapshot()).snapshot.catalog.selected, first.locator);
      await expectLater(
        actor.select(
          ManagedIdentityEntry(
            id: first.id,
            protection: StorageProtection.encrypted,
          ),
        ),
        throwsA(isA<ManagedWorkerFailure>()),
      );
      expect((await actor.snapshot()).snapshot.catalog.selected, first.locator);
      await actor.close();
      final cold = await catalog();
      expect((await cold.snapshot()).snapshot.catalog.selected, first.locator);
      final cleared = await cold.select(null);
      expect(cleared.catalog.selected, isNull);
      expect(cleared.catalog.identities.map((e) => e.id), [
        first.id,
        second.id,
      ]);
    },
  );

  test(
    'new child preparation preserves access until an opened root is remembered',
    () async {
      final live = await router();
      await live.create(StorageProtection.unencrypted, access: false);
      final created = live.location;
      expect(live.access, const LegacyStorageLocator());
      await expectLater(live.rememberCurrentAccess(), throwsStateError);
      expect(live.access, const LegacyStorageLocator());
      expect(
        await live.storage.open(password: '', createIfMissing: true),
        isTrue,
      );
      await live.storage.saveProfile(
        const UserProfile(displayName: 'synthetic root'),
      );
      expect(live.catalog.selected, isNull);
      await live.rememberCurrentAccess();
      expect(live.access, created);
      expect(live.catalog.selected, created);
      await live.close();
      expect((await router()).access, created);
    },
  );

  test('refused catalog publication cannot adopt a new access root', () async {
    final live = await router(factory: (_, _) => legacy());
    await live.create(StorageProtection.encrypted, access: false);
    expect(await live.storage.open(password: 'synthetic'), isTrue);
    await expectLater(
      live.rememberCurrentAccess(),
      throwsA(isA<ManagedWorkerFailure>()),
    );
    expect(live.access, const LegacyStorageLocator());
    expect(live.catalog.selected, isNull);
  });

  test(
    'two actual managed modes keep data and remembered access across restart',
    () async {
      final live = await router();
      expect(live.location, const LegacyStorageLocator());
      final locations = <IdentityStorageLocator>[];
      for (final protection in [
        StorageProtection.encrypted,
        StorageProtection.unencrypted,
      ]) {
        await live.create(protection);
        locations.add(live.location);
        expect(
          await live.storage.open(
            password: 'synthetic password',
            createIfMissing: true,
          ),
          isTrue,
        );
        await live.storage.saveProfile(
          UserProfile(displayName: protection.name),
        );
        await live.storage.putSetting('fixture', protection.name);
        await live.rememberAccess();
      }
      await live.select(locations.first);
      expect(await live.storage.open(password: 'wrong password'), isFalse);
      expect(await live.storage.open(password: 'synthetic password'), isTrue);
      expect(await live.storage.getSetting('fixture'), 'encrypted');
      await live.rememberAccess();
      await live.close();
      final cold = await router();
      expect(cold.selectionRequired, isFalse);
      expect(cold.access, locations.first);
      expect(await cold.storage.open(password: 'synthetic password'), isTrue);
      expect(await cold.storage.getSetting('fixture'), 'encrypted');
      await cold.select(locations.last, access: false);
      expect(
        cold.access,
        locations.first,
        reason: 'a child selection must not replace master/vault access',
      );
      expect(await cold.storage.open(password: ''), isTrue);
      expect(await cold.storage.getSetting('fixture'), 'unencrypted');
    },
  );

  test(
    'visible catalog without a remembered choice requires explicit selection',
    () async {
      final entry = await plain('a');
      final live = await router();
      expect(live.selectionRequired, isTrue);
      expect(live.requireAccessSelection, throwsStateError);
      await live.select(entry.locator);
      expect(live.requireAccessSelection, returnsNormally);
      await live.select(const LegacyStorageLocator());
      await live.rememberAccess();
      expect(live.catalog.identities, hasLength(1));
      expect(live.catalog.selected, isNull);
    },
  );

  test(
    'selection joins accepted native preparation before retiring the old facade',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      var factories = 0;
      final raw = _CloseGate();
      gates.add(raw);
      final openingFacade = HiddenVolumeStorage.async(({
        required password,
        required create,
      }) async {
        entered.complete();
        await release.future;
        return SyncWrappedAsyncKvLogStore(raw);
      });
      final live = await router(
        factory: (_, _) {
          factories++;
          return factories == 1 ? openingFacade : legacy();
        },
      );
      final opening = live.storage.open(password: 'fixture');
      await entered.future;
      final selecting = live.create(StorageProtection.hidden);
      await Future<void>.delayed(Duration.zero);
      expect(factories, 1);
      expect(raw.closes, 0);
      release.complete();
      expect(await opening, isTrue);
      await selecting;
      expect(factories, 2);
      expect(raw.closes, 1);
      expect(openingFacade.isOpen, isFalse);
    },
  );

  test(
    'failed close blocks replacement and same-profile restart until actual retry',
    () async {
      final raw = _CloseGate()..fail = true;
      gates.add(raw);
      final facade = HiddenVolumeStorage(
        ({required password, required create}) => raw,
      );
      var factories = 0;
      final live = await router(
        factory: (_, _) {
          factories++;
          return facade;
        },
      );
      expect(await live.storage.open(password: 'fixture'), isTrue);
      await expectLater(
        live.create(StorageProtection.hidden),
        throwsStateError,
      );
      expect(factories, 1);
      await expectLater(live.close(), throwsStateError);
      await expectLater(router(path: '$profile/.'), throwsStateError);
      expect(factories, 1);
      raw.fail = false;
      await live.close();
      expect(raw.closes, greaterThan(1));
      final cold = await router();
      expect(cold.location, const LegacyStorageLocator());
    },
  );
}
