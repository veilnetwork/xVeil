import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/domain/storage_compaction_policy.dart';
import 'package:xveil/domain/storage_locator.dart';
import 'package:xveil/domain/storage_protection.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/providers.dart';

import 'support/fake_hv_container.dart';

class _Controller extends AppController {
  _Controller({this.managed = false});
  final bool managed;

  @override
  AppState build() => const AppState(AppPhase.ready);

  @override
  bool get usesManagedStorage => managed;
}

class _Storage extends HiddenVolumeStorage {
  _Storage(super.opener);
  final opens = <String>[];
  var closes = 0;

  @override
  Future<bool> open({required String password, bool createIfMissing = false}) {
    opens.add(password);
    return super.open(password: password, createIfMissing: createIfMissing);
  }

  @override
  Future<void> close() {
    closes++;
    return super.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final managed in [false, true]) {
    for (final repair in [false, true]) {
      test(
        'legacy credential operation checks active root: managed=$managed repair=$repair',
        () async {
          final fake = FakeHvContainer();
          final seed = fake.storage();
          expect(
            await seed.open(password: 'fixture', createIfMissing: true),
            isTrue,
          );
          final oldKeys = await seed.exportSpaceKeys();
          await seed.close();
          final storage = _Storage(fake.passwordOpener);
          final controller = _Controller(managed: managed);
          final container = ProviderContainer(
            overrides: [
              appControllerProvider.overrideWith(() => controller),
              storageProvider.overrideWithValue(storage),
            ],
          );
          addTearDown(container.dispose);
          addTearDown(storage.close);
          container.read(appControllerProvider);
          Future<void> operation() async {
            if (repair) {
              expect(
                await controller.remapRostersAfterCompaction([
                  (password: 'fixture'.codeUnits, oldSpaceKeys: oldKeys),
                ]),
                isEmpty,
              );
            } else {
              expect(
                (await controller.probeCompactionIdentity('fixture')).opened,
                isTrue,
              );
            }
          }

          if (managed) {
            await expectLater(operation(), throwsStateError);
            expect(storage.opens, isEmpty);
            expect(storage.closes, 0);
          } else {
            await operation();
            expect(storage.opens, ['fixture']);
            expect(storage.closes, 1);
          }
        },
      );
    }
  }

  for (final collection in [false, true]) {
    test(
      'owned root refuses legacy maintenance before teardown ($collection)',
      () async {
        final fake = FakeHvContainer();
        final storage = _Storage(fake.passwordOpener);
        expect(
          await storage.open(password: 'fixture', createIfMissing: true),
          isTrue,
        );
        final controller = _Controller(managed: true);
        final container = ProviderContainer(
          overrides: [
            appControllerProvider.overrideWith(() => controller),
            storageProvider.overrideWithValue(storage),
          ],
        );
        addTearDown(container.dispose);
        addTearDown(storage.close);
        container.read(appControllerProvider);
        final Future<Object?> attempt = collection
            ? controller.beginCompactionCollection()
            : controller.compactStorageKeeping(
                roster: CompactionRoster()
                  ..addUnlocked(
                    'fixture',
                    passwordBytes: 'fixture'.codeUnits,
                    spaceKeys: await storage.exportSpaceKeys(),
                  ),
                reopenWith: 'fixture',
              );
        await expectLater(attempt, throwsStateError);
        expect(storage.opens, ['fixture']);
        expect(storage.closes, 0);
        expect(storage.isOpen, isTrue);
        expect(container.read(appControllerProvider).phase, AppPhase.ready);
      },
    );
  }

  test('explicit staged repair does not use the selected owned root', () async {
    final fake = FakeHvContainer();
    final staged = _Storage(fake.passwordOpener);
    expect(
      await staged.open(password: 'fixture', createIfMissing: true),
      isTrue,
    );
    final keys = await staged.exportSpaceKeys();
    await staged.close();
    staged.opens.clear();
    staged.closes = 0;
    final controller = _Controller(managed: true);
    final container = ProviderContainer(
      overrides: [
        appControllerProvider.overrideWith(() => controller),
        storageProvider.overrideWith(
          (_) => throw StateError('wrong root read'),
        ),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(staged.close);
    container.read(appControllerProvider);
    expect(
      await controller.remapRostersAfterCompaction([
        (password: 'fixture'.codeUnits, oldSpaceKeys: keys),
      ], storageOverride: staged),
      isEmpty,
    );
    expect(staged.opens, ['fixture']);
    expect(staged.closes, 1);
  });

  test(
    'legacy password coverage excludes independently owned children',
    () async {
      final fake = FakeHvContainer();
      final seed = fake.storage();
      expect(
        await seed.open(password: 'master', createIfMissing: true),
        isTrue,
      );
      await seed.saveRoster([
        RosterEntry(label: 'hidden child', spaceKeys: Uint8List(64)..[0] = 1),
        for (final (mode, id) in [
          (StorageProtection.encrypted, '1'),
          (StorageProtection.unencrypted, '2'),
        ])
          RosterEntry(
            label: '${mode.name} child',
            spaceKeys: Uint8List(64)..[0] = 2,
            storageLocator: ManagedStorageLocator(
              id: ManagedIdentityId(id * 32),
              protection: mode,
            ),
          ),
      ]);
      await seed.close();
      final controller = _Controller();
      final storage = fake.storage();
      final container = ProviderContainer(
        overrides: [
          appControllerProvider.overrideWith(() => controller),
          storageProvider.overrideWithValue(storage),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(storage.close);
      container.read(appControllerProvider);
      final probe = await controller.probeCompactionIdentity('master');
      expect(probe.opened, isTrue);
      expect(probe.isMaster, isTrue);
      expect(probe.subordinates, ['hidden child']);
      expect(probe.children.map((e) => e.label), ['hidden child']);
      expect(probe.children.single.keys, Uint8List(64)..[0] = 1);
    },
  );

  for (final mode in [
    StorageProtection.encrypted,
    StorageProtection.unencrypted,
  ]) {
    for (final collidingKeys in [false, true]) {
      test(
        'hidden repair preserves ${mode.name} locator and keys (collision=$collidingKeys)',
        () async {
          final fake = FakeHvContainer();
          final seed = fake.storage();
          expect(
            await seed.open(password: 'child', createIfMissing: true),
            isTrue,
          );
          final childKeys = await seed.exportSpaceKeys();
          await seed.close();
          expect(
            await seed.open(password: 'master', createIfMissing: true),
            isTrue,
          );
          final managedKeys = collidingKeys
              ? Uint8List.fromList(childKeys)
              : (Uint8List(64)..fillRange(0, 64, 42));
          final locator = ManagedStorageLocator(
            id: ManagedIdentityId('1' * 32),
            protection: mode,
          );
          await seed.saveRoster([
            RosterEntry(label: 'hidden child', spaceKeys: childKeys),
            RosterEntry(
              label: 'owned child',
              spaceKeys: managedKeys,
              storageLocator: locator,
              anonymous: true,
            ),
          ]);
          final masterKeys = await seed.exportSpaceKeys();
          await seed.close();
          fake.rotateSalt();
          final storage = fake.storage();
          final controller = _Controller();
          final container = ProviderContainer(
            overrides: [
              appControllerProvider.overrideWith(() => controller),
              storageProvider.overrideWithValue(storage),
            ],
          );
          addTearDown(container.dispose);
          addTearDown(storage.close);
          container.read(appControllerProvider);
          for (var attempt = 0; attempt < 2; attempt++) {
            expect(
              await controller.remapRostersAfterCompaction([
                (password: 'child'.codeUnits, oldSpaceKeys: childKeys),
                (password: 'master'.codeUnits, oldSpaceKeys: masterKeys),
              ]),
              isEmpty,
            );
            expect(await storage.open(password: 'master'), isTrue);
            final rows = (await storage.loadRoster())!;
            await storage.close();
            expect(rows.map((e) => e.label), ['hidden child', 'owned child']);
            expect(rows.first.spaceKeys, isNot(childKeys));
            final child = fake.storage();
            expect(await child.openWithKeys(rows.first.spaceKeys), isTrue);
            await child.close();
            expect(rows.last.spaceKeys, managedKeys);
            expect(rows.last.storageLocator, locator);
            expect(rows.last.anonymous, isTrue);
          }
        },
      );
    }
  }
}
