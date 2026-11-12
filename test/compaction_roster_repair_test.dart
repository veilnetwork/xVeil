import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/notifications/notification_service.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/domain/storage_compaction_policy.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/notifications.dart';
import 'package:xveil/state/providers.dart';

import 'support/fake_hv_container.dart';

enum _Fault { none, childRefused, childThrows, masterReopenRefused, duressSave }

class _Controller extends AppController {
  final reopened = <String>[];
  int remaps = 0;
  void Function(int)? beforeRemap;
  @override
  AppState build() => const AppState(AppPhase.ready);
  @override
  Future<void> unlock(String password) async => reopened.add(password);
  @override
  Future<List<String>> remapRostersAfterCompaction(
    List<({List<int> password, List<int> oldSpaceKeys})> credentials, {
    Storage? storageOverride,
  }) {
    remaps++;
    beforeRemap?.call(remaps);
    return super.remapRostersAfterCompaction(
      credentials,
      storageOverride: storageOverride,
    );
  }
}

class _Notifications extends NotificationService {
  @override
  Future<void> cancelAll() async {}
}

class _Storage extends HiddenVolumeStorage {
  _Storage(super.opener, {super.keysOpener});
  _Fault fault = _Fault.none;
  String? password;
  final visits = <String, int>{};
  final writes = <String, int>{};

  @override
  Future<bool> open({
    required String password,
    bool createIfMissing = false,
  }) async {
    this.password = password;
    visits[password] = (visits[password] ?? 0) + 1;
    if (password == 'child-fixture' && fault == _Fault.childRefused) {
      return false;
    }
    if (password == 'child-fixture' && fault == _Fault.childThrows) {
      throw StateError('fixture read failure');
    }
    if (password == 'master-fixture' &&
        visits[password] == 2 &&
        fault == _Fault.masterReopenRefused) {
      return false;
    }
    return super.open(password: password, createIfMissing: createIfMissing);
  }

  @override
  Future<void> saveRoster(List<RosterEntry> entries) {
    if (password == 'duress-fixture' && fault == _Fault.duressSave) {
      throw StateError('fixture write failure');
    }
    writes[password!] = (writes[password!] ?? 0) + 1;
    return super.saveRoster(entries);
  }
}

class _Fixture {
  final fake = FakeHvContainer();
  final roster = CompactionRoster();
  final before = <String, Uint8List>{};
  late final _Storage storage;
  late final ProviderContainer providers;
  final owner = _Controller();
  var nativeCalls = 0;
  Object? compactionOutcome;
  AppController get controller =>
      providers.read(appControllerProvider.notifier);

  Future<void> prepare({bool rotate = true, String? path}) async {
    for (final password in [
      'child-fixture',
      'master-fixture',
      'duress-fixture',
    ]) {
      final seed = fake.storage();
      await seed.open(password: password, createIfMissing: true);
      await seed.saveProfile(UserProfile(displayName: password));
      if (password != 'child-fixture') {
        await seed.saveRoster([
          RosterEntry(
            label: 'child',
            spaceKeys: before['child-fixture']!,
            anonymous: password == 'duress-fixture',
          ),
        ]);
      }
      before[password] = await seed.exportSpaceKeys();
      roster.addUnlocked(
        password,
        passwordBytes: password.codeUnits,
        spaceKeys: before[password],
      );
      await seed.close();
    }
    if (rotate) {
      fake.rotateSalt();
    }
    storage = _Storage(fake.passwordOpener, keysOpener: fake.keysOpener);
    providers = ProviderContainer(
      overrides: [
        appControllerProvider.overrideWith(() => owner),
        storageProvider.overrideWith((ref) => storage),
        compactionStagedStorageProvider.overrideWithValue((_) => storage),
        notificationServiceProvider.overrideWithValue(_Notifications()),
        if (path != null)
          deniableBootProvider.overrideWithValue(
            DeniableBootConfig(
              runtimeDir: '${File(path).parent.path}/runtime',
              storePath: path,
            ),
          ),
        if (path != null)
          preparedContainerCompactorProvider.overrideWithValue((
            path,
            passwords, {
            required repairMetadata,
            dylibPath,
          }) async {
            nativeCalls++;
            fake.rotateSalt();
            await repairMetadata(path);
            if (compactionOutcome case final error?) throw error;
          }),
      ],
    );
    providers.read(appControllerProvider);
  }

  Future<List<RosterEntry>> readRoster(String password) async {
    final reader = fake.storage();
    try {
      expect(await reader.open(password: password), isTrue);
      return (await reader.loadRoster())!;
    } finally {
      await reader.close();
    }
  }

  Future<void> expectUsable() async {
    for (final holder in ['master-fixture', 'duress-fixture']) {
      final entries = await readRoster(holder);
      expect(entries, hasLength(1));
      expect(entries.single.label, 'child');
      expect(entries.single.anonymous, holder == 'duress-fixture');
      final child = fake.storage();
      try {
        expect(
          await child.openWithKeys(entries.single.spaceKeys),
          isTrue,
          reason: 'the master lost access to its retained child',
        );
        expect((await child.loadProfile())?.displayName, 'child-fixture');
      } finally {
        await child.close();
      }
    }
  }
}

void main() {
  for (final kind in [
    'RenameVisibleAliasesNotRevoked',
    'RenameVisibleAliasesUnknown',
    'RenameVisibleAliasesAndDurabilityUncertain',
    'RenameVisibleDurabilityUncertain',
  ]) {
    test('repairs retained roster before reporting $kind', () async {
      final dir = await Directory.systemTemp.createTemp(
        'xveil-applied-repair-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/fixture.hv';
      await File(path).writeAsString('owned synthetic container');
      final f = _Fixture();
      await f.prepare(rotate: false, path: path);
      addTearDown(f.providers.dispose);
      final outcome = hv.HvException(kind, 'fixture post-publication outcome');
      f.compactionOutcome = outcome;
      await expectLater(
        f.controller.compactStorageKeeping(
          roster: f.roster,
          reopenWith: 'master-fixture',
        ),
        throwsA(same(outcome)),
      );
      expect(f.owner.remaps, 1);
      expect(f.nativeCalls, 1);
      await f.expectUsable();
      expect(f.owner.reopened, ['master-fixture']);
    });
  }

  test(
    'unverified publication result never triggers post-publication repair',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'xveil-unverified-repair-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/fixture.hv';
      await File(path).writeAsString('owned synthetic container');
      final f = _Fixture();
      await f.prepare(rotate: false, path: path);
      addTearDown(f.providers.dispose);
      final outcome = hv.HvException(
        'RenameVisibleContentUnverified',
        'fixture',
      );
      f.compactionOutcome = outcome;
      await expectLater(
        f.controller.compactStorageKeeping(
          roster: f.roster,
          reopenWith: 'master-fixture',
        ),
        throwsA(same(outcome)),
      );
      expect(f.owner.remaps, 1);
      expect(f.storage.writes, {'master-fixture': 1, 'duress-fixture': 1});
    },
  );

  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'repeating remap with the original credentials keeps repaired children',
    () async {
      final f = _Fixture();
      await f.prepare();
      addTearDown(f.providers.dispose);
      expect(
        await f.controller.remapRostersAfterCompaction(f.roster.credentials()),
        isEmpty,
      );
      await f.expectUsable();
      final writes = Map<String, int>.of(f.storage.writes);
      expect(
        await f.controller.remapRostersAfterCompaction(f.roster.credentials()),
        isEmpty,
      );
      await f.expectUsable();
      expect(
        f.storage.writes,
        writes,
        reason: 'a completed repair needs no new write',
      );
    },
  );

  for (final fault in [_Fault.childRefused, _Fault.childThrows]) {
    test(
      '${fault.name} leaves master entries intact for a later repair',
      () async {
        final f = _Fixture();
        await f.prepare();
        addTearDown(f.providers.dispose);
        f.storage.fault = fault;
        expect(
          await f.controller.remapRostersAfterCompaction(
            f.roster.credentials(),
          ),
          isNotEmpty,
        );
        for (final holder in ['master-fixture', 'duress-fixture']) {
          final saved = await f.readRoster(holder);
          expect(
            saved,
            hasLength(1),
            reason: 'a read failure deleted a retained child',
          );
          expect(saved.single.spaceKeys, f.before['child-fixture']);
        }
        expect(f.storage.writes, isEmpty);
        f.storage.fault = _Fault.none;
        expect(
          await f.controller.remapRostersAfterCompaction(
            f.roster.credentials(),
          ),
          isEmpty,
        );
        await f.expectUsable();
      },
    );
  }

  test('a refused master reopen is reported as incomplete repair', () async {
    final f = _Fixture();
    await f.prepare();
    addTearDown(f.providers.dispose);
    f.storage.fault = _Fault.masterReopenRefused;
    expect(
      await f.controller.remapRostersAfterCompaction(f.roster.credentials()),
      isNotEmpty,
    );
    expect(
      (await f.readRoster('master-fixture')).single.spaceKeys,
      f.before['child-fixture'],
    );
    f.storage.fault = _Fault.none;
    expect(
      await f.controller.remapRostersAfterCompaction(f.roster.credentials()),
      isEmpty,
    );
    await f.expectUsable();
  });

  test('an unresolved entry keeps the whole holder unchanged', () async {
    final f = _Fixture();
    await f.prepare();
    addTearDown(f.providers.dispose);
    final master = f.fake.storage();
    await master.open(password: 'master-fixture');
    final original = [
      ...(await master.loadRoster())!,
      RosterEntry(
        label: 'unresolved',
        spaceKeys: Uint8List(64)..fillRange(0, 64, 42),
      ),
    ];
    await master.saveRoster(original);
    await master.close();
    expect(
      await f.controller.remapRostersAfterCompaction(f.roster.credentials()),
      isNotEmpty,
    );
    final retained = await f.readRoster('master-fixture');
    expect(retained.map((e) => e.label), ['child', 'unresolved']);
    expect(retained.map((e) => e.spaceKeys), original.map((e) => e.spaceKeys));
    expect(f.storage.writes.containsKey('master-fixture'), isFalse);
  });

  test(
    'retry after a partial commit preserves the master already repaired',
    () async {
      final f = _Fixture();
      await f.prepare();
      addTearDown(f.providers.dispose);
      f.storage.fault = _Fault.duressSave;
      expect(
        await f.controller.remapRostersAfterCompaction(f.roster.credentials()),
        isNotEmpty,
      );
      expect(f.storage.writes['master-fixture'], 1);
      expect(
        (await f.readRoster('duress-fixture')).single.spaceKeys,
        f.before['child-fixture'],
      );
      f.storage.fault = _Fault.none;
      expect(
        await f.controller.remapRostersAfterCompaction(f.roster.credentials()),
        isEmpty,
      );
      await f.expectUsable();
      expect(f.storage.writes['master-fixture'], 1);
    },
  );

  for (final persistent in [false, true]) {
    test(
      'owner retries repair, never rewrite (persistent=$persistent)',
      () async {
        final dir = await Directory.systemTemp.createTemp('xveil-repair-');
        addTearDown(() => dir.delete(recursive: true));
        final path = '${dir.path}/fixture.hv';
        await File(path).writeAsString('owned synthetic container');
        final f = _Fixture();
        await f.prepare(rotate: false, path: path);
        addTearDown(f.providers.dispose);
        f.storage.fault = _Fault.childThrows;
        f.owner.beforeRemap = (attempt) {
          if (!persistent && attempt == 2) f.storage.fault = _Fault.none;
        };
        final operation = f.controller.compactStorageKeeping(
          roster: f.roster,
          reopenWith: 'master-fixture',
        );
        if (persistent) {
          await expectLater(
            operation,
            throwsA(isA<CompactionRosterRepairIncomplete>()),
          );
          expect(f.storage.writes, isEmpty);
          for (final holder in ['master-fixture', 'duress-fixture']) {
            expect(
              (await f.readRoster(holder)).single.spaceKeys,
              f.before['child-fixture'],
            );
          }
        } else {
          await operation;
          await f.expectUsable();
        }
        expect(f.owner.remaps, 2);
        expect(
          f.nativeCalls,
          1,
          reason: 'repair must not compact a second time',
        );
        expect(f.owner.reopened, ['master-fixture']);
        expect(f.storage.isOpen, isFalse);
      },
    );
  }
}
