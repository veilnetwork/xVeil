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

const _auto = 'storage.autocompact.v1';

enum _Stage {
  roster,
  masterKeys,
  masterClose,
  childOpen,
  childRead,
  childWrite,
  options,
  padding,
}

class _Gate {
  _Gate(this.stage);
  final _Stage stage;
  final entered = Completer<void>();
  final release = Completer<void>();
  Future<void> at(_Stage stage) async {
    if (stage != this.stage || entered.isCompleted) return;
    entered.complete();
    await release.future;
  }
}

class _Storage extends HiddenVolumeStorage {
  _Storage(super.opener, this.gate, {super.keysOpener});
  final _Gate gate;
  final io = <String>[];
  Uint8List? returnedMasterKeys;
  List<RosterEntry>? returnedRoster;
  bool child = false;
  bool failKeys = false;
  bool failClose = false;
  @override
  Future<List<RosterEntry>?> loadRoster() async {
    io.add('roster');
    final result = await super.loadRoster();
    returnedRoster = result;
    await gate.at(_Stage.roster);
    return result;
  }

  @override
  Future<Uint8List> exportSpaceKeys() async {
    io.add('master-keys');
    if (failKeys) throw StateError('fixture export refusal');
    final keys = await super.exportSpaceKeys();
    returnedMasterKeys = keys;
    await gate.at(_Stage.masterKeys);
    return keys;
  }

  @override
  Future<void> close() async {
    if (returnedMasterKeys != null && !child) await gate.at(_Stage.masterClose);
    if (failClose) {
      failClose = false;
      throw StateError('fixture close refusal');
    }
    await super.close();
    child = false;
  }

  @override
  Future<bool> openWithKeys(Uint8List keys) async {
    io.add('child-open');
    // A real worker consumes its own bytes before returning asynchronously.
    // Keep that accepted open valid even when lock wipes the controller copy.
    final owned = Uint8List.fromList(keys);
    try {
      await gate.at(_Stage.childOpen);
      child = await super.openWithKeys(owned);
      return child;
    } finally {
      owned.fillRange(0, owned.length, 0);
    }
  }

  @override
  Future<String?> getSetting(String key) async {
    final result = await super.getSetting(key);
    if (child && key == _auto) {
      io.add('child-read');
      await gate.at(_Stage.childRead);
    }
    return result;
  }

  @override
  Future<void> putSetting(String key, String value) async {
    await super.putSetting(key, value);
    if (child && key == _auto) {
      io.add('child-write');
      await gate.at(_Stage.childWrite);
    }
  }
}

class _Controller extends AppController {
  _Controller(this.gate);
  final _Gate gate;
  int builds = 0;
  @override
  AppState build() => const AppState(AppPhase.locked);
  @override
  Future<bool> leanStoragePaddingEnabled() async {
    await gate.at(_Stage.padding);
    return true;
  }
}

class _Options extends KeepAllOnlineController {
  _Options(this.gate, this.enabled);
  final _Gate gate;
  final bool enabled;
  @override
  bool build() => enabled;
  @override
  Future<bool> resolved() async {
    await gate.at(_Stage.options);
    return enabled;
  }
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
    _Gate gate,
    FakeHvContainer fake,
    File file,
    void Function() dispose,
  })
>
_fixture(_Stage stage, {bool allOnline = false, int childCount = 2}) async {
  final dir = await Directory.systemTemp.createTemp('xveil-master-unlock-');
  addTearDown(() => dir.delete(recursive: true));
  final file = File('${dir.path}/fixture.hv');
  await file.writeAsString('synthetic container');
  final fake = FakeHvContainer();
  final children = <RosterEntry>[];
  for (final name in ['first-fixture', 'second-fixture'].take(childCount)) {
    final seed = fake.storage();
    await seed.open(password: name, createIfMissing: true);
    await seed.saveProfile(UserProfile(displayName: name));
    await seed.putSetting(_auto, '1');
    children.add(
      RosterEntry(label: name, spaceKeys: await seed.exportSpaceKeys()),
    );
    await seed.close();
  }
  final seed = fake.storage();
  await seed.open(password: 'master-fixture', createIfMissing: true);
  await seed.saveRoster(children);
  await seed.close();
  final gate = _Gate(stage);
  final ctrl = _Controller(gate);
  final storage = _Storage(
    fake.passwordOpener,
    gate,
    keysOpener: fake.keysOpener,
  );
  final c = ProviderContainer(
    overrides: [
      appControllerProvider.overrideWith(() => ctrl),
      singleSpaceStorageProvider.overrideWithValue(storage),
      keepAllOnlineProvider.overrideWith(() => _Options(gate, allOnline)),
      notificationServiceProvider.overrideWithValue(_Notifications()),
      vpnBackendProvider.overrideWithValue(_Vpn()),
      whisperModelStoreProvider.overrideWithValue(
        WhisperModelStore(supportDirectory: () async => dir),
      ),
      translationModelsRootProvider.overrideWithValue(() async => null),
      deniableBootProvider.overrideWithValue(
        DeniableBootConfig(
          runtimeDir: '${dir.path}/runtime',
          storePath: file.path,
        ),
      ),
      sessionBuilderProvider.overrideWithValue(({
        required storePath,
        required runtimeDir,
        required listenPort,
        required peersFor,
        obfs4Psk,
        required udpReflectors,
        required lazyMining,
        required proxy,
        required paddingPreset,
      }) {
        ctrl.builds++;
        throw StateError('fixture forbids native sessions');
      }),
    ],
  );
  var disposed = false;
  void dispose() {
    if (!disposed) {
      disposed = true;
      c.dispose();
    }
  }

  addTearDown(dispose);
  addTearDown(storage.close);
  c.read(appControllerProvider);
  return (
    c: c,
    ctrl: ctrl,
    storage: storage,
    gate: gate,
    fake: fake,
    file: file,
    dispose: dispose,
  );
}

bool _zero(Uint8List bytes) => bytes.every((byte) => byte == 0);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final stage in _Stage.values) {
    test('master unlock stops after lock at ${stage.name}', () async {
      final f = await _fixture(
        stage,
        allOnline: stage == _Stage.options || stage == _Stage.padding,
      );
      final unlocking = f.ctrl.unlock('master-fixture');
      await f.gate.entered.future;
      await f.ctrl.lock();
      final ioAtLock = List<String>.of(f.storage.io);
      f.gate.release.complete();
      await unlocking;
      expect(f.ctrl.debugMasterKeys, isNull);
      expect(f.ctrl.debugRoster, isNull);
      expect(f.storage.io, ioAtLock, reason: 'new access after cancellation');
      expect(
        f.ctrl.builds,
        0,
        reason: 'a session was constructed after cancellation',
      );
      expect(f.storage.isOpen, isFalse);
      expect(f.c.read(appControllerProvider).phase, AppPhase.locked);
      final returnedKeys = f.storage.returnedMasterKeys;
      if (returnedKeys != null) expect(_zero(returnedKeys), isTrue);
      for (final e in f.storage.returnedRoster ?? <RosterEntry>[]) {
        expect(
          _zero(e.spaceKeys),
          isTrue,
          reason: 'late roster keys were abandoned intact',
        );
      }
      if (stage != _Stage.options && stage != _Stage.padding) {
        final prefs = await f.c.read(prefsProvider.future);
        expect(
          prefs.getBool('storage.autocompact.swept.v1:${f.file.path}'),
          isNot(true),
        );
      }
    });
  }

  for (final wipe in [false, true]) {
    test(
      'late master keys stay cancelled after ${wipe ? 'wipe' : 'startOver'}',
      () async {
        final f = await _fixture(_Stage.masterKeys);
        final unlocking = f.ctrl.unlock('master-fixture');
        await f.gate.entered.future;
        if (wipe) {
          expect(await f.ctrl.wipeContainers(), isEmpty);
        } else {
          await f.ctrl.startOver();
        }
        final io = List<String>.of(f.storage.io);
        f.gate.release.complete();
        await unlocking;
        expect(f.storage.io, io);
        expect(f.ctrl.debugMasterKeys, isNull);
        expect(f.ctrl.debugRoster, isNull);
        expect(_zero(f.storage.returnedMasterKeys!), isTrue);
        expect(f.storage.isOpen, isFalse);
        expect(f.c.read(appControllerProvider).phase, AppPhase.onboarding);
        if (wipe) expect(await f.file.exists(), isFalse);
      },
    );
  }

  for (final stage in [_Stage.roster, _Stage.masterKeys]) {
    test(
      'disposed master owner releases late buffers at ${stage.name}',
      () async {
        final f = await _fixture(stage);
        final unlocking = f.ctrl.unlock('master-fixture');
        await f.gate.entered.future;
        f.dispose();
        f.gate.release.complete();
        await unlocking;
        expect(f.ctrl.debugMasterKeys, isNull);
        expect(f.ctrl.debugRoster, isNull);
        expect(f.storage.isOpen, isFalse);
        final keys = f.storage.returnedMasterKeys;
        if (keys != null) expect(_zero(keys), isTrue);
        for (final e in f.storage.returnedRoster!) {
          expect(_zero(e.spaceKeys), isTrue);
        }
      },
    );
  }

  for (final allOnline in [false, true]) {
    test(
      'uncancelled master still revokes every child (allOnline=$allOnline)',
      () async {
        final f = await _fixture(_Stage.roster, allOnline: allOnline);
        f.gate.release.complete();
        await f.ctrl.unlock('master-fixture');
        expect(f.c.read(appControllerProvider).phase, AppPhase.pickingIdentity);
        expect(f.ctrl.builds, allOnline ? 1 : 0);
        expect(f.ctrl.debugRoster, hasLength(2));
        expect(f.ctrl.debugMasterKeys, isNotNull);
        expect(_zero(f.ctrl.debugMasterKeys!), isFalse);
        for (final name in ['first-fixture', 'second-fixture']) {
          final reader = f.fake.storage();
          try {
            expect(await reader.open(password: name), isTrue);
            expect(await reader.getSetting(_auto), '0');
            expect((await reader.loadProfile())!.displayName, name);
          } finally {
            await reader.close();
          }
        }
        final prefs = await f.c.read(prefsProvider.future);
        expect(
          prefs.getBool('storage.autocompact.swept.v1:${f.file.path}'),
          isTrue,
        );
        await f.ctrl.lock();
        expect(_zero(f.storage.returnedMasterKeys!), isTrue);
      },
    );
  }

  test(
    'cancellation after the last accepted flag write does not mark the sweep complete',
    () async {
      final f = await _fixture(_Stage.childWrite, childCount: 1);
      final unlocking = f.ctrl.unlock('master-fixture');
      await f.gate.entered.future;
      await f.ctrl.lock();
      f.gate.release.complete();
      await unlocking;
      final prefs = await f.c.read(prefsProvider.future);
      expect(
        prefs.getBool('storage.autocompact.swept.v1:${f.file.path}'),
        isNot(true),
      );
      expect(f.storage.isOpen, isFalse);
      expect(f.c.read(appControllerProvider).phase, AppPhase.locked);
    },
  );

  for (final failClose in [false, true]) {
    test(
      'failed master classification releases adopted keys (close=$failClose)',
      () async {
        final f = await _fixture(_Stage.roster);
        f.gate.release.complete();
        f.storage.failKeys = !failClose;
        f.storage.failClose = failClose;
        await f.ctrl.unlock('master-fixture');
        expect(f.c.read(appControllerProvider).phase, AppPhase.locked);
        expect(f.c.read(appControllerProvider).unlockError, isTrue);
        expect(f.storage.isOpen, isFalse);
        expect(f.ctrl.debugMasterKeys, isNull);
        expect(f.ctrl.debugRoster, isNull);
        for (final e in f.storage.returnedRoster!) {
          expect(_zero(e.spaceKeys), isTrue);
        }
        final keys = f.storage.returnedMasterKeys;
        if (keys != null) expect(_zero(keys), isTrue);
        f.storage.failKeys = false;
        await f.ctrl.unlock('master-fixture');
        expect(f.c.read(appControllerProvider).phase, AppPhase.pickingIdentity);
        expect(f.ctrl.debugRoster, hasLength(2));
        await f.ctrl.lock();
      },
    );
  }
}
