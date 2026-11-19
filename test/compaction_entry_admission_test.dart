import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/notifications/notification_service.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/domain/storage_compaction_policy.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/notifications.dart';
import 'package:xveil/state/providers.dart';

import 'support/fake_hv_container.dart';

Uint8List _bytes(String value) => Uint8List.fromList(utf8.encode(value));

class _ManualController extends AppController {
  final reopened = <String>[];
  @override
  AppState build() => const AppState(AppPhase.ready);
  @override
  Future<void> unlock(String password) async => reopened.add(password);
}

class _AutoController extends AppController {
  @override
  AppState build() => const AppState(AppPhase.locked);
}

class _Notifications extends NotificationService {
  @override
  Future<void> cancelAll() async {}
}

class _Storage extends HiddenVolumeStorage {
  _Storage(super.opener);
  var closes = 0;
  bool parkRead = false;
  final reading = Completer<void>(), releaseRead = Completer<void>();
  @override
  Future<List<RosterEntry>?> loadRosterForMaintenance() async {
    final result = await super.loadRosterForMaintenance();
    if (parkRead && !reading.isCompleted) {
      reading.complete();
      await releaseRead.future;
    }
    return result;
  }

  @override
  Future<String?> getSetting(String key) {
    if (key == 'anonymous') {
      throw StateError('stop fixture before network boot');
    }
    return super.getSetting(key);
  }

  @override
  Future<void> close() {
    closes++;
    return super.close();
  }
}

class _Fixture {
  final directory = Directory.systemTemp.createTempSync(
    'xveil-compaction-entry-',
  );
  final fake = FakeHvContainer();
  late final storage = _Storage(fake.passwordOpener);
  late ProviderContainer container;
  late Uint8List rootKeys;
  late Uint8List childKeys;
  var rewrites = 0;
  Future<void> Function()? beforeRepair;
  String get path => '${directory.path}/fixture.hv';

  Future<void> create({
    required String corruption,
    required bool automatic,
  }) async {
    final file = File(path).openSync(mode: FileMode.write);
    try {
      file.truncateSync(automatic ? 16 << 20 : 8);
    } finally {
      file.closeSync();
    }
    final seed = fake.storage();
    expect(await seed.open(password: 'child', createIfMissing: true), isTrue);
    childKeys = await seed.exportSpaceKeys();
    await seed.saveProfile(const UserProfile(displayName: 'Child fixture'));
    await seed.close();
    expect(await seed.open(password: 'root', createIfMissing: true), isTrue);
    await seed.saveProfile(const UserProfile(displayName: 'Root fixture'));
    if (corruption != 'none') {
      await seed.saveRoster([
        for (var i = 0; i < (corruption == 'file' ? 24 : 1); i++)
          RosterEntry(label: 'child-$i', spaceKeys: childKeys),
      ]);
    }
    await seed.putSetting('storage.autocompact.v1', 'v2:fixture-setup');
    rootKeys = await seed.exportSpaceKeys();
    await seed.close();
    final raw = fake.rawStoreFor('root')!;
    if (corruption == 'setting') {
      raw.commit([
        PutOp(Ns.settings, _bytes('master:roster'), _bytes('unreadable')),
      ]);
    } else if (corruption == 'file') {
      final key = _bytes('file:master:roster.v2');
      expect(raw.get(Ns.settings, key), isNotNull);
      raw.commit([PutOp(Ns.settings, key, _bytes('unreadable'))]);
    }
  }

  void bind(AppController controller) {
    container = ProviderContainer(
      overrides: [
        appControllerProvider.overrideWith(() => controller),
        singleSpaceStorageProvider.overrideWithValue(storage),
        notificationServiceProvider.overrideWithValue(_Notifications()),
        compactionStagedStorageProvider.overrideWithValue(
          (_) => fake.storage(),
        ),
        deniableBootProvider.overrideWithValue(
          DeniableBootConfig(
            runtimeDir: '${directory.path}/runtime',
            storePath: path,
          ),
        ),
        containerCompactorProvider.overrideWithValue((
          path,
          passwords, {
          dylibPath,
        }) async {
          rewrites++;
        }),
        preparedContainerCompactorProvider.overrideWithValue((
          path,
          passwords, {
          required repairMetadata,
          dylibPath,
        }) async {
          rewrites++;
          fake.rotateSalt();
          await beforeRepair?.call();
          await repairMetadata(path);
        }),
      ],
    );
    container.read(appControllerProvider);
  }

  Future<void> close() async {
    await storage.close();
    container.dispose();
    directory.deleteSync(recursive: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({
    'storage.autoCompactSetup.v1': 'fixture-setup',
  }));

  for (final corruption in ['setting', 'file']) {
    test(
      'single-password manual admission refuses damaged $corruption',
      () async {
        final f = _Fixture();
        await f.create(corruption: corruption, automatic: false);
        final controller = _ManualController();
        f.bind(controller);
        addTearDown(f.close);
        expect(await f.storage.open(password: 'root'), isTrue);
        expect(
          controller.canCompactStorage,
          isTrue,
          reason: 'cached controller state alone is insufficient',
        );
        await expectLater(controller.compactStorage('root'), throwsStateError);
        expect(f.rewrites, 0);
        expect(f.storage.closes, 0);
        expect(f.storage.isOpen, isTrue);
        expect(controller.reopened, isEmpty);
        expect(f.container.read(appControllerProvider).phase, AppPhase.ready);
      },
    );

    test('public unlock does not auto-rewrite damaged $corruption', () async {
      final f = _Fixture();
      await f.create(corruption: corruption, automatic: true);
      final controller = _AutoController();
      f.bind(controller);
      addTearDown(f.close);
      await controller.unlock('root');
      expect(f.rewrites, 0);
      expect(await f.storage.open(password: 'child'), isTrue);
      expect((await f.storage.loadProfile())!.displayName, 'Child fixture');
    });
  }

  test('password-only collection cannot skip the retained-key map', () async {
    final f = _Fixture();
    await f.create(corruption: 'none', automatic: false);
    final controller = _ManualController();
    f.bind(controller);
    addTearDown(f.close);
    await expectLater(
      controller.compactStorageKeeping(
        roster: CompactionRoster()
          ..addUnlocked('root', passwordBytes: _bytes('root')),
        reopenWith: 'root',
      ),
      throwsStateError,
    );
    expect(f.rewrites, 0);
  });

  for (final automatic in [false, true]) {
    test(
      'valid solo admission remains available (automatic=$automatic)',
      () async {
        final f = _Fixture();
        await f.create(corruption: 'none', automatic: automatic);
        final controller = automatic ? _AutoController() : _ManualController();
        f.bind(controller);
        addTearDown(f.close);
        if (automatic) {
          await controller.unlock('root');
        } else {
          expect(await f.storage.open(password: 'root'), isTrue);
          await controller.compactStorage('root');
        }
        expect(f.rewrites, 1);
      },
    );

    test(
      'lock revokes delayed solo admission (automatic=$automatic)',
      () async {
        final f = _Fixture();
        await f.create(corruption: 'none', automatic: automatic);
        final controller = automatic ? _AutoController() : _ManualController();
        f.bind(controller);
        addTearDown(f.close);
        f.storage.parkRead = true;
        if (!automatic) expect(await f.storage.open(password: 'root'), isTrue);
        final attempt = automatic
            ? controller.unlock('root')
            : controller.compactStorage('root');
        final completion = automatic
            ? expectLater(attempt, completes)
            : expectLater(attempt, throwsStateError);
        try {
          await f.storage.reading.future;
          await controller.lock();
        } finally {
          f.storage.releaseRead.complete();
          await completion;
        }
        expect(f.rewrites, 0);
        expect(f.storage.isOpen, isFalse);
        expect(f.container.read(appControllerProvider).phase, AppPhase.locked);
        if (controller is _ManualController) {
          expect(controller.reopened, isEmpty);
        }
        await controller.waitForCompaction();
      },
    );
  }

  test(
    'a live master cannot use the solo path even with stale classification',
    () async {
      final f = _Fixture();
      await f.create(corruption: 'roster', automatic: false);
      final controller = _ManualController();
      f.bind(controller);
      addTearDown(f.close);
      expect(await f.storage.open(password: 'root'), isTrue);
      expect(controller.canCompactStorage, isTrue);
      await expectLater(controller.compactStorage('root'), throwsStateError);
      expect(f.rewrites, 0);
      expect(f.storage.isOpen, isTrue);
      expect((await f.storage.loadRoster())!.single.spaceKeys, f.childKeys);
    },
  );

  test('a closed identity cannot authorize solo compaction', () async {
    final f = _Fixture();
    await f.create(corruption: 'none', automatic: false);
    final controller = _ManualController();
    f.bind(controller);
    addTearDown(f.close);
    await expectLater(controller.compactStorage('root'), throwsStateError);
    expect(f.rewrites, 0);
    expect(f.storage.closes, 0);
    expect(controller.reopened, isEmpty);
  });

  for (final invalid in [List<int>.filled(63, 1), List<int>.filled(64, 256)]) {
    test(
      'unverified key shape/range cannot authorize collection (${invalid.length})',
      () async {
        final f = _Fixture();
        await f.create(corruption: 'none', automatic: false);
        final controller = _ManualController();
        f.bind(controller);
        addTearDown(f.close);
        await expectLater(
          controller.compactStorageKeeping(
            roster: CompactionRoster()
              ..addUnlocked(
                'root',
                passwordBytes: _bytes('root'),
                spaceKeys: invalid,
              ),
            reopenWith: 'root',
          ),
          throwsStateError,
        );
        expect(f.rewrites, 0);
        expect(f.storage.closes, 0);
      },
    );
  }

  test(
    'collection owns its repair keys until native publication settles',
    () async {
      final f = _Fixture();
      await f.create(corruption: 'roster', automatic: false);
      final controller = _ManualController();
      f.bind(controller);
      addTearDown(f.close);
      final entered = Completer<void>(), publish = Completer<void>();
      f.beforeRepair = () async {
        entered.complete();
        await publish.future;
      };
      final rootPassword = _bytes('root'), childPassword = _bytes('child');
      final roster = CompactionRoster()
        ..expectSpaces([(label: 'child-0', keys: f.childKeys)])
        ..addUnlocked(
          'root',
          passwordBytes: rootPassword,
          spaceKeys: f.rootKeys,
        )
        ..addUnlocked(
          'child',
          passwordBytes: childPassword,
          spaceKeys: f.childKeys,
        );
      final compacting = controller.compactStorageKeeping(
        roster: roster,
        reopenWith: 'root',
      );
      final completion = expectLater(compacting, completes);
      try {
        await entered.future;
        for (final value in [
          rootPassword,
          childPassword,
          f.rootKeys,
          f.childKeys,
        ]) {
          value.fillRange(0, value.length, 0);
        }
      } finally {
        publish.complete();
        await completion;
      }
      expect(f.rewrites, 1);
      final reader = f.fake.storage();
      try {
        expect(await reader.open(password: 'root'), isTrue);
        final child = (await reader.loadRoster())!.single;
        await reader.close();
        expect(await reader.openWithKeys(child.spaceKeys), isTrue);
        expect((await reader.loadProfile())!.displayName, 'Child fixture');
      } finally {
        await reader.close();
      }
    },
  );
}
