import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/notifications/notification_service.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/vpn/vpn_backend.dart';
import 'package:xveil/data/whisper_model_store.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/keep_all_online_controller.dart';
import 'package:xveil/state/notifications.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/translation_model_controller.dart';
import 'package:xveil/state/vpn_controller.dart';
import 'package:xveil/state/whisper_model_controller.dart';

import 'support/fake_hv_container.dart';

enum _Stage {
  activeKeys,
  masterOpen,
  roster,
  masterKeys,
  childOpen,
  childKeys,
  profile,
  saveRoster,
  activation,
}

class _Storage extends HiddenVolumeStorage {
  _Storage(super.opener, this.stage, {super.keysOpener});
  final _Stage stage;
  final entered = Completer<void>(), release = Completer<void>();
  bool armed = false,
      failActiveExport = false,
      failCloseOnce = false,
      failActivation = false;
  String owner = '';
  int keyOpens = 0;
  File? publishOnCreate;
  final io = <String>[];
  final keys = <Uint8List>[];
  Future<void> park(_Stage at) async {
    if (!armed || at != stage || entered.isCompleted) return;
    entered.complete();
    await release.future;
  }

  @override
  Future<bool> open({
    required String password,
    bool createIfMissing = false,
  }) async {
    if (armed) io.add('open:$password');
    owner = password;
    if (password == 'new-fixture') await park(_Stage.childOpen);
    final opened = await super.open(
      password: password,
      createIfMissing: createIfMissing,
    );
    if (opened && armed && password == 'new-fixture') {
      await publishOnCreate?.writeAsString('synthetic accepted create');
    }
    if (password == 'master-fixture') await park(_Stage.masterOpen);
    return opened;
  }

  @override
  Future<bool> openWithKeys(Uint8List keys) async {
    final owned = Uint8List.fromList(keys);
    try {
      if (armed) {
        io.add('open-keys');
        if (++keyOpens == 4) await park(_Stage.activation);
        if (keyOpens == 4 && failActivation) return false;
      }
      owner = 'by-keys';
      return await super.openWithKeys(owned);
    } finally {
      owned.fillRange(0, owned.length, 0);
    }
  }

  @override
  Future<Uint8List> exportSpaceKeys() async {
    if (armed && failActiveExport) throw StateError('fixture export refusal');
    final result = await super.exportSpaceKeys();
    if (armed) {
      io.add('keys:$owner');
      keys.add(result);
      await park(
        owner == 'master-fixture'
            ? _Stage.masterKeys
            : owner == 'new-fixture'
            ? _Stage.childKeys
            : _Stage.activeKeys,
      );
    }
    return result;
  }

  @override
  Future<List<RosterEntry>?> loadRoster() async {
    final result = await super.loadRoster();
    if (armed) {
      io.add('roster');
      if (result != null) keys.addAll(result.map((e) => e.spaceKeys));
      await park(_Stage.roster);
    }
    return result;
  }

  @override
  Future<void> saveProfile(UserProfile profile) async {
    if (armed) io.add('profile');
    await super.saveProfile(profile);
    await park(_Stage.profile);
  }

  @override
  Future<void> saveRoster(List<RosterEntry> roster) async {
    if (armed) io.add('save-roster');
    await super.saveRoster(roster);
    await park(_Stage.saveRoster);
  }

  @override
  Future<void> close() async {
    if (armed && failCloseOnce) {
      failCloseOnce = false;
      throw StateError('fixture close refusal');
    }
    await super.close();
  }
}

class _Controller extends AppController {
  @override
  AppState build() => const AppState(AppPhase.locked);
}

class _Options extends KeepAllOnlineController {
  @override
  bool build() => false;
  @override
  Future<bool> resolved() async => false;
}

class _Notifications extends NotificationService {
  @override
  Future<void> cancelAll() async {}
}

class _Vpn extends Fake implements VpnBackend {
  @override
  Future<VpnBackendState> probe() => status();
  @override
  Future<VpnBackendState> status() async =>
      const VpnBackendState(VpnBackendPhase.unsupported);
  @override
  Future<VpnBackendState> stop() => status();
}

Future<
  ({
    ProviderContainer c,
    _Controller ctrl,
    _Storage storage,
    FakeHvContainer fake,
    File file,
  })
>
_fixture(_Stage stage) async {
  final directory = Directory.systemTemp.createTempSync('xveil-add-life-');
  addTearDown(() => directory.deleteSync(recursive: true));
  final file = File('${directory.path}/fixture.hv')
    ..writeAsStringSync('synthetic container');
  final fake = FakeHvContainer();
  final roster = <RosterEntry>[];
  for (final label in ['first-fixture', 'second-fixture', 'outside-fixture']) {
    final seed = fake.storage();
    await seed.open(password: label, createIfMissing: true);
    await seed.saveProfile(UserProfile(displayName: label));
    if (label != 'outside-fixture') {
      roster.add(
        RosterEntry(label: label, spaceKeys: await seed.exportSpaceKeys()),
      );
    }
    await seed.close();
  }
  final seed = fake.storage();
  await seed.open(password: 'master-fixture', createIfMissing: true);
  await seed.saveRoster(roster);
  await seed.close();
  final storage = _Storage(
    fake.passwordOpener,
    stage,
    keysOpener: fake.keysOpener,
  );
  final ctrl = _Controller();
  final c = ProviderContainer(
    overrides: [
      appControllerProvider.overrideWith(() => ctrl),
      singleSpaceStorageProvider.overrideWithValue(storage),
      keepAllOnlineProvider.overrideWith(_Options.new),
      notificationServiceProvider.overrideWithValue(_Notifications()),
      vpnBackendProvider.overrideWithValue(_Vpn()),
      whisperModelStoreProvider.overrideWithValue(
        WhisperModelStore(supportDirectory: () async => directory),
      ),
      translationModelsRootProvider.overrideWithValue(() async => null),
      deniableBootProvider.overrideWithValue(
        DeniableBootConfig(
          runtimeDir: '${directory.path}/runtime',
          storePath: file.path,
        ),
      ),
    ],
  );
  addTearDown(c.dispose);
  addTearDown(storage.close);
  c.read(appControllerProvider);
  ctrl.debugDeniableStackStarter = (_) async =>
      throw StateError('fixture forbids network boot');
  await ctrl.unlock('master-fixture');
  await ctrl.pickIdentity('first-fixture');
  expect(c.read(appControllerProvider).phase, AppPhase.ready);
  storage.armed = true;
  addTearDown(() {
    if (!storage.release.isCompleted) storage.release.complete();
  });
  return (c: c, ctrl: ctrl, storage: storage, fake: fake, file: file);
}

Future<bool> _add(_Controller ctrl) => ctrl.addIdentity(
  masterPassword: 'master-fixture',
  label: 'new-label',
  password: 'new-fixture',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final stage in _Stage.values) {
    test('adding identity cannot resume after lock at ${stage.name}', () async {
      final f = await _fixture(stage);
      final adding = _add(f.ctrl);
      await f.storage.entered.future;
      await f.ctrl.lock();
      final ioAtLock = List.of(f.storage.io);
      f.storage.release.complete();
      expect(await adding, isFalse);
      expect(f.c.read(appControllerProvider).phase, AppPhase.locked);
      expect(f.storage.isOpen, isFalse);
      expect(f.ctrl.debugRoster, isNull);
      expect(f.ctrl.debugMasterKeys, isNull);
      expect(
        f.storage.io,
        ioAtLock,
        reason: 'No new I/O after the accepted pending operation settles',
      );
      for (final keys in f.storage.keys) {
        expect(
          keys.every((value) => value == 0),
          isTrue,
          reason: 'Unadopted exported/roster keys are retired',
        );
      }
    });
    test(
      'adding identity cannot resume after startOver at ${stage.name}',
      () async {
        final f = await _fixture(stage);
        final adding = _add(f.ctrl);
        await f.storage.entered.future;
        await f.ctrl.startOver();
        final ioAtStop = List.of(f.storage.io);
        f.storage.release.complete();
        expect(await adding, isFalse);
        expect(f.c.read(appControllerProvider).phase, AppPhase.onboarding);
        expect(f.storage.isOpen, isFalse);
        expect(f.ctrl.debugRoster, isNull);
        expect(f.ctrl.debugMasterKeys, isNull);
        expect(f.storage.io, ioAtStop);
      },
    );
  }
  final mutations = <String, Future<bool> Function(_Controller)>{
    'anonymity': (ctrl) => ctrl.setIdentityAnonymous('first-fixture', true),
    'unbind': (ctrl) => ctrl.unbindIdentity('second-fixture'),
    'delete': (ctrl) => ctrl.deleteIdentity('second-fixture'),
    'bind': (ctrl) => ctrl.bindExistingIdentity(
      identityPassword: 'outside-fixture',
      label: 'bound-label',
    ),
    'decoy': (ctrl) => ctrl.createDecoyMaster(
      duressPassword: 'duress-fixture',
      includeLabels: ['first-fixture'],
    ),
  };
  for (final mutation in mutations.entries) {
    for (final stage in [_Stage.roster, _Stage.saveRoster]) {
      test(
        '${mutation.key} cannot continue after lock at ${stage.name}',
        () async {
          final f = await _fixture(stage);
          final changing = mutation.value(f.ctrl);
          await f.storage.entered.future;
          await f.ctrl.lock();
          final ioAtLock = List.of(f.storage.io);
          f.storage.release.complete();
          expect(await changing, isFalse);
          expect(f.c.read(appControllerProvider).phase, AppPhase.locked);
          expect(f.storage.isOpen, isFalse);
          expect(f.ctrl.debugRoster, isNull);
          expect(f.ctrl.debugMasterKeys, isNull);
          expect(f.storage.io, ioAtLock);
          for (final key in f.storage.keys) {
            expect(key.every((value) => value == 0), isTrue);
          }
        },
      );
    }
  }
  test(
    'pending mutation excludes a second edit and a new unlock before any I/O',
    () async {
      final f = await _fixture(_Stage.childOpen);
      final adding = _add(f.ctrl);
      await f.storage.entered.future;
      final before = List.of(f.storage.io);
      expect(await _add(f.ctrl), isFalse);
      for (final mutation in mutations.values) {
        expect(await mutation(f.ctrl), isFalse);
      }
      await f.ctrl.unlock('outside-fixture');
      expect(await f.ctrl.reopenExistingContainer('outside-fixture'), isFalse);
      await expectLater(
        f.ctrl.completeOnboarding(
          password: 'other-fixture',
          mode: StorageMode.plain,
        ),
        throwsStateError,
      );
      expect(f.storage.io, before);
      f.storage.release.complete();
      expect(await adding, isTrue);
      expect(f.c.read(appControllerProvider).activeIdentity, 'new-label');
    },
  );
  test(
    'the latest identity switch waits for mutation cleanup and wins',
    () async {
      final f = await _fixture(_Stage.childOpen);
      final adding = _add(f.ctrl);
      await f.storage.entered.future;
      final earlier = f.ctrl.switchIdentity('second-fixture');
      final later = f.ctrl.switchIdentity('first-fixture');
      f.storage.release.complete();
      expect(await adding, isFalse);
      await Future.wait([earlier, later]);
      expect(f.c.read(appControllerProvider).phase, AppPhase.ready);
      expect(f.ctrl.activeIdentity, 'first-fixture');
      expect(
        f.c.read(appControllerProvider).identity!.displayName,
        'first-fixture',
      );
      expect(f.storage.isOpen, isTrue);
      expect(f.ctrl.debugRoster!.map((e) => e.label), [
        'first-fixture',
        'second-fixture',
      ]);
    },
  );
  test(
    'failed final activation does not claim success or retain master keys',
    () async {
      final f = await _fixture(_Stage.activation);
      f.storage.failActivation = true;
      final adding = _add(f.ctrl);
      await f.storage.entered.future;
      f.storage.release.complete();
      expect(await adding, isFalse);
      expect(f.c.read(appControllerProvider).phase, AppPhase.locked);
      expect(f.ctrl.debugMasterKeys, isNull);
      expect(f.ctrl.debugRoster, isNull);
      expect(f.storage.isOpen, isFalse);
    },
  );
  test(
    'invalid choice cannot discard a valid switch waiting for cleanup',
    () async {
      final f = await _fixture(_Stage.childOpen);
      final adding = _add(f.ctrl);
      await f.storage.entered.future;
      final selected = f.ctrl.switchIdentity('second-fixture');
      await f.ctrl.switchIdentity('missing-fixture');
      f.storage.release.complete();
      expect(await adding, isFalse);
      await selected;
      expect(f.c.read(appControllerProvider).phase, AppPhase.ready);
      expect(f.ctrl.activeIdentity, 'second-fixture');
      expect(f.storage.isOpen, isTrue);
    },
  );
  test(
    'choosing the current identity during initial export reenters a fresh session',
    () async {
      final f = await _fixture(_Stage.activeKeys);
      final adding = _add(f.ctrl);
      await f.storage.entered.future;
      final selected = f.ctrl.switchIdentity('first-fixture');
      f.storage.release.complete();
      expect(await adding, isFalse);
      await selected;
      expect(f.c.read(appControllerProvider).phase, AppPhase.ready);
      expect(f.ctrl.activeIdentity, 'first-fixture');
      expect(f.storage.isOpen, isTrue);
      expect(f.storage.keyOpens, 1);
    },
  );
  for (final stage in [_Stage.activeKeys, _Stage.childOpen]) {
    test(
      'disposed controller closes handles and wipes cache at ${stage.name}',
      () async {
        final f = await _fixture(stage);
        final adding = _add(f.ctrl);
        await f.storage.entered.future;
        final held = [
          f.ctrl.debugMasterKeys!,
          ...f.ctrl.debugRoster!.map((e) => e.spaceKeys),
        ];
        f.c.dispose();
        f.storage.release.complete();
        expect(await adding, isFalse);
        expect(f.storage.isOpen, isFalse);
        expect(f.ctrl.debugMasterKeys, isNull);
        expect(f.ctrl.debugRoster, isNull);
        for (final key in held) {
          expect(key.every((value) => value == 0), isTrue);
        }
        for (final key in f.storage.keys) {
          expect(key.every((value) => value == 0), isTrue);
        }
      },
    );
  }
  test(
    'teardown failure is caught and returns to the original identity',
    () async {
      final f = await _fixture(_Stage.childOpen);
      f.storage.failCloseOnce = true;
      expect(await _add(f.ctrl), isFalse);
      expect(f.storage.isOpen, isTrue);
      expect(f.c.read(appControllerProvider).phase, AppPhase.ready);
      expect(f.ctrl.activeIdentity, 'first-fixture');
      expect(f.fake.rawStoreFor('new-fixture'), isNull);
    },
  );
  test(
    'wipe joins an accepted child creation before deleting the container',
    () async {
      final f = await _fixture(_Stage.childOpen);
      f.storage.publishOnCreate = f.file;
      final adding = _add(f.ctrl);
      await f.storage.entered.future;
      var settled = false;
      final barrier = f.ctrl.waitForCompaction().then((_) => settled = true);
      // One event turn drains all immediate/null-await barriers. A still gated
      // creation is an actual dependency, not a duration-based expectation.
      await Future<void>.delayed(Duration.zero);
      expect(settled, isFalse);
      final wiping = f.ctrl.wipeContainers();
      f.storage.release.complete();
      await barrier;
      expect(await adding, isFalse);
      expect(await wiping, isEmpty);
      expect(f.file.existsSync(), isFalse);
      expect(f.storage.isOpen, isFalse);
    },
  );
  test(
    'an active key export failure does not tear down a healthy session',
    () async {
      final f = await _fixture(_Stage.childOpen);
      f.storage.failActiveExport = true;
      expect(await _add(f.ctrl), isFalse);
      expect(f.storage.isOpen, isTrue);
      expect(f.c.read(appControllerProvider).phase, AppPhase.ready);
      expect(f.storage.io, isEmpty);
      expect(f.fake.rawStoreFor('new-fixture'), isNull);
    },
  );
}
