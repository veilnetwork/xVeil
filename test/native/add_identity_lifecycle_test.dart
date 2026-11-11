import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/notifications/notification_service.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/vpn/vpn_backend.dart';
import 'package:xveil/data/whisper_model_store.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/notifications.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/translation_model_controller.dart';
import 'package:xveil/state/vpn_controller.dart';
import 'package:xveil/state/whisper_model_controller.dart';

class _Controller extends AppController {
  @override
  AppState build() => const AppState(AppPhase.locked);
}

class _Storage extends HiddenVolumeStorage {
  _Storage(String path, this.stage)
    : super.async(
        workerSpaceOpener(path),
        keysOpener: workerKeysSpaceOpener(path),
      );
  final String stage;
  bool armed = false;
  final entered = Completer<void>(), release = Completer<void>();
  List<RosterEntry>? returnedRoster;
  @override
  Future<bool> open({
    required String password,
    bool createIfMissing = false,
  }) async {
    if (armed && stage == 'create' && password == 'new-fixture') {
      entered.complete();
      await release.future;
    }
    return super.open(password: password, createIfMissing: createIfMissing);
  }

  @override
  Future<List<RosterEntry>?> loadRoster() async {
    final result = await super.loadRoster();
    if (armed && stage == 'roster' && !entered.isCompleted) {
      returnedRoster = result;
      entered.complete();
      await release.future;
    }
    return result;
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

final _body = Uint8List.fromList(List.generate(70000, (i) => i % 251));
const _names = ['first-fixture', 'second-fixture', 'outside-fixture'];

Future<({ProviderContainer c, _Controller ctrl, _Storage storage, String path})>
_fixture(String stage, {bool unlock = true}) async {
  expect(ensureHiddenVolumeLoaded(), isTrue);
  final dir = await Directory.systemTemp.createTemp('xveil-native-add-');
  addTearDown(() => dir.delete(recursive: true));
  final path = '${dir.path}/fixture.hv';
  HvKvLogStore(
    hv.HvSpace.create(
      path: path,
      password: Uint8List.fromList(utf8.encode(_names.first)),
      argon: hv.ArgonPreset.min,
    ),
  ).close();
  final seed = HiddenVolumeStorage.async(
    workerSpaceOpener(path),
    keysOpener: workerKeysSpaceOpener(path),
  );
  final roster = <RosterEntry>[];
  try {
    for (final name in _names) {
      expect(await seed.open(password: name, createIfMissing: true), isTrue);
      await seed.saveProfile(UserProfile(displayName: name));
      await seed.storeFile('body-fixture', _body);
      if (name != 'outside-fixture') {
        roster.add(
          RosterEntry(label: name, spaceKeys: await seed.exportSpaceKeys()),
        );
      }
      await seed.close();
    }
    expect(
      await seed.open(password: 'master-fixture', createIfMissing: true),
      isTrue,
    );
    await seed.saveRoster(roster);
  } finally {
    await seed.close();
  }
  final storage = _Storage(path, stage);
  final ctrl = _Controller();
  final c = ProviderContainer(
    overrides: [
      appControllerProvider.overrideWith(() => ctrl),
      singleSpaceStorageProvider.overrideWithValue(storage),
      notificationServiceProvider.overrideWithValue(_Notifications()),
      vpnBackendProvider.overrideWithValue(_Vpn()),
      whisperModelStoreProvider.overrideWithValue(
        WhisperModelStore(supportDirectory: () async => dir),
      ),
      translationModelsRootProvider.overrideWithValue(() async => null),
      deniableBootProvider.overrideWithValue(
        DeniableBootConfig(runtimeDir: '${dir.path}/runtime', storePath: path),
      ),
    ],
  );
  addTearDown(c.dispose);
  addTearDown(storage.close);
  addTearDown(() {
    if (!storage.release.isCompleted) storage.release.complete();
  });
  c.read(appControllerProvider);
  ctrl.debugDeniableStackStarter = (_) async =>
      throw StateError('fixture forbids node boot');
  if (unlock) {
    await ctrl.unlock('master-fixture');
    await ctrl.pickIdentity(_names.first);
    expect(c.read(appControllerProvider).phase, AppPhase.ready);
  }
  storage.armed = true;
  return (c: c, ctrl: ctrl, storage: storage, path: path);
}

Future<bool> _add(_Controller ctrl) => ctrl.addIdentity(
  masterPassword: 'master-fixture',
  label: 'new-label',
  password: 'new-fixture',
);

Future<void> _verifyStored(String path, List<String> expected) async {
  final reader = HiddenVolumeStorage.async(
    workerSpaceOpener(path),
    keysOpener: workerKeysSpaceOpener(path),
  );
  try {
    expect(await reader.open(password: 'master-fixture'), isTrue);
    final roster = (await reader.loadRoster())!;
    expect(roster.map((e) => e.label), expected);
    await reader.close();
    for (final entry in roster) {
      expect(await reader.openWithKeys(entry.spaceKeys), isTrue);
      expect(
        (await reader.loadProfile())!.displayName,
        entry.label == 'new-label' ? 'new-label' : entry.label,
      );
      if (entry.label != 'new-label') {
        expect(await reader.loadFile('body-fixture'), _body);
      }
      await reader.close();
    }
    // An unrelated deniable identity was never part of the edited roster.
    expect(await reader.open(password: 'outside-fixture'), isTrue);
    expect((await reader.loadProfile())!.displayName, 'outside-fixture');
    expect(await reader.loadFile('body-fixture'), _body);
  } finally {
    await reader.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final enabled = Platform.environment['XVEIL_NATIVE_IDENTITY_EDIT'] == '1';
  final Object skip = enabled
      ? false
      : 'Set XVEIL_NATIVE_IDENTITY_EDIT=1 with a verified hidden-volume library';
  setUp(
    () => SharedPreferences.setMockInitialValues({'keep_all_online': false}),
  );
  test(
    'native roster cancellation retires returned keys without changing durable spaces',
    () async {
      final f = await _fixture('roster');
      final adding = _add(f.ctrl);
      await f.storage.entered.future;
      await f.ctrl.lock();
      f.storage.release.complete();
      expect(await adding, isFalse);
      expect(f.c.read(appControllerProvider).phase, AppPhase.locked);
      expect(f.storage.isOpen, isFalse);
      expect(f.storage.returnedRoster, hasLength(2));
      for (final entry in f.storage.returnedRoster!) {
        expect(entry.spaceKeys.every((b) => b == 0), isTrue);
      }
      await _verifyStored(f.path, _names.take(2).toList());
    },
    skip: skip,
  );
  test(
    'native accepted creation settles before wipe removes the container',
    () async {
      final f = await _fixture('create');
      final adding = _add(f.ctrl);
      await f.storage.entered.future;
      final wiping = f.ctrl.wipeContainers();
      var quiescent = false;
      final joined = f.ctrl.waitForCompaction().then((_) => quiescent = true);
      await Future<void>.delayed(Duration.zero);
      expect(quiescent, isFalse);
      f.storage.release.complete();
      await joined;
      expect(await adding, isFalse);
      expect(await wiping, isEmpty);
      expect(f.storage.isOpen, isFalse);
      expect(File(f.path).existsSync(), isFalse);
      expect(f.c.read(appControllerProvider).phase, AppPhase.onboarding);
    },
    skip: skip,
  );
  test(
    'native add to an existing master works without an earlier unlock',
    () async {
      final f = await _fixture('none', unlock: false);
      expect(await _add(f.ctrl), isTrue);
      expect(f.c.read(appControllerProvider).phase, AppPhase.ready);
      expect(f.ctrl.activeIdentity, 'new-label');
      await f.ctrl.lock();
      await _verifyStored(f.path, [..._names.take(2), 'new-label']);
    },
    skip: skip,
  );
}
