import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/data/notifications/notification_service.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/data/vpn/vpn_backend.dart';
import 'package:xveil/data/whisper_model_store.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/notifications.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/translation_model_controller.dart';
import 'package:xveil/state/vpn_controller.dart';
import 'package:xveil/state/whisper_model_controller.dart';

import 'support/fake_hv_container.dart';

class _Prefs extends SharedPreferencesStorePlatform {
  final values = <String, Object>{};
  final marking = Completer<void>();
  final release = Completer<void>();
  bool parkMarker = false;
  bool refuseMarker = false;
  bool throwMarker = false;
  int markerWrites = 0;
  @override
  Future<Map<String, Object>> getAll() async => Map.of(values);
  @override
  Future<Map<String, Object>> getAllWithParameters(
    GetAllParameters parameters,
  ) => getAll();
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (key == 'flutter.onboarded' && value == true) {
      markerWrites++;
      if (!marking.isCompleted) marking.complete();
      if (parkMarker) await release.future;
      if (throwMarker) throw StateError('fixture preference refusal');
      if (refuseMarker) return false;
    }
    values[key] = value;
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    values.remove(key);
    return true;
  }

  @override
  Future<bool> clear() async {
    values.clear();
    return true;
  }

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) => clear();
}

class _Storage extends HiddenVolumeStorage {
  _Storage(super.opener);
  final opening = Completer<void>();
  final release = Completer<void>();
  bool parkOpen = false;
  bool failOpen = false;
  bool parkProfile = false;
  bool corruptProfile = false;
  final readingProfile = Completer<void>();
  final profileRelease = Completer<void>();
  bool parkClose = false;
  final closing = Completer<void>();
  final closeRelease = Completer<void>();
  int opens = 0;
  @override
  Future<bool> open({
    required String password,
    bool createIfMissing = false,
  }) async {
    opens++;
    if (!opening.isCompleted) opening.complete();
    if (parkOpen) await release.future;
    final result = await super.open(
      password: password,
      createIfMissing: createIfMissing,
    );
    if (failOpen) throw StateError('fixture open refusal');
    return result;
  }

  @override
  Future<UserProfile?> loadProfile() async {
    final result = await super.loadProfile();
    if (!readingProfile.isCompleted) readingProfile.complete();
    if (parkProfile) await profileRelease.future;
    if (corruptProfile) {
      throw CorruptIdentityRecord(3, 'fixture record failure');
    }
    return result;
  }

  @override
  Future<void> close() async {
    if (parkClose && !closing.isCompleted) {
      closing.complete();
      await closeRelease.future;
    }
    await super.close();
  }
}

class _Controller extends AppController {
  final waiting = Completer<void>();
  @override
  AppState build() => const AppState(AppPhase.onboarding);
  @override
  Future<void> waitForCompaction() {
    if (!waiting.isCompleted) waiting.complete();
    return super.waitForCompaction();
  }
}

class _Node implements NodeController {
  @override
  NodeStatus get current => const NodeStatus(phase: NodePhase.connected);
  @override
  Stream<NodeStatus> status() => const Stream.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> setEconomyMode(bool economy) async {}
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
    File file,
    void Function() dispose,
  })
>
_fixture({bool deniable = false}) async {
  final dir = await Directory.systemTemp.createTemp('xveil-reopen-session-');
  addTearDown(() => dir.delete(recursive: true));
  final file = File('${dir.path}/fixture.hv');
  await file.writeAsString('synthetic source');
  final fake = FakeHvContainer();
  final seed = fake.storage();
  await seed.open(password: 'fixture', createIfMissing: true);
  await seed.saveProfile(const UserProfile(displayName: 'Original fixture'));
  await seed.close();
  final storage = _Storage(fake.passwordOpener);
  final ctrl = _Controller();
  final transport = LoopbackTransport();
  addTearDown(transport.dispose);
  final c = ProviderContainer(
    overrides: [
      appControllerProvider.overrideWith(() => ctrl),
      singleSpaceStorageProvider.overrideWithValue(storage),
      nodeControllerProvider.overrideWithValue(_Node()),
      veilTransportProvider.overrideWithValue(transport),
      notificationServiceProvider.overrideWithValue(_Notifications()),
      vpnBackendProvider.overrideWithValue(_Vpn()),
      whisperModelStoreProvider.overrideWithValue(
        WhisperModelStore(supportDirectory: () async => dir),
      ),
      translationModelsRootProvider.overrideWithValue(() async => null),
      deniableBootProvider.overrideWithValue(
        deniable
            ? DeniableBootConfig(
                runtimeDir: '${dir.path}/runtime',
                storePath: file.path,
              )
            : null,
      ),
    ],
  );
  var disposed = false;
  void dispose() {
    if (disposed) return;
    disposed = true;
    c.dispose();
  }

  addTearDown(dispose);
  addTearDown(storage.close);
  c.read(appControllerProvider);
  ctrl.debugDeniableStackStarter = (_) async {
    throw StateError('fixture forbids native boot');
  };
  return (c: c, ctrl: ctrl, storage: storage, file: file, dispose: dispose);
}

Future<void> _settle(Future<Object?> future) async {
  try {
    await future;
  } catch (_) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferencesStorePlatform previous;
  late _Prefs backend;
  setUp(() {
    previous = SharedPreferencesStorePlatform.instance;
    SharedPreferences.setMockInitialValues({});
    backend = _Prefs();
    SharedPreferencesStorePlatform.instance = backend;
  });
  tearDown(() => SharedPreferencesStorePlatform.instance = previous);

  for (final prior in [false, true]) {
    test('wrong password never writes a marker (prior=$prior)', () async {
      if (prior) backend.values['flutter.onboarded'] = true;
      final f = await _fixture();
      expect(await f.ctrl.reopenExistingContainer('missing-fixture'), isFalse);
      expect(backend.markerWrites, 0);
      expect(backend.values['flutter.onboarded'], prior ? isTrue : isNull);
      expect(f.c.read(appControllerProvider).phase, AppPhase.onboarding);
    });
  }

  test('no marker is written before the password is checked', () async {
    final f = await _fixture();
    f.storage.parkOpen = true;
    final reopening = f.ctrl.reopenExistingContainer('missing-fixture');
    await f.storage.opening.future;
    try {
      expect(backend.markerWrites, 0);
    } finally {
      f.storage.release.complete();
      await _settle(reopening);
    }
    expect(await reopening, isFalse);
  });

  test('reopen during a probe is refused without marking success', () async {
    final f = await _fixture();
    f.storage.parkOpen = true;
    final probing = f.ctrl.probeCompactionIdentity('fixture');
    await f.storage.opening.future;
    try {
      expect(await f.ctrl.reopenExistingContainer('fixture'), isFalse);
      expect(backend.markerWrites, 0);
      expect(f.storage.opens, 1);
    } finally {
      f.storage.release.complete();
      await _settle(probing);
    }
    expect((await probing).opened, isTrue);
    expect(await f.ctrl.reopenExistingContainer('fixture'), isTrue);
    expect((await f.storage.loadProfile())!.displayName, 'Original fixture');
  });

  test('two reopen calls cannot borrow each other\'s success', () async {
    final f = await _fixture();
    f.storage.parkOpen = true;
    final reopening = f.ctrl.reopenExistingContainer('fixture');
    await f.storage.opening.future;
    try {
      expect(await f.ctrl.reopenExistingContainer('missing-fixture'), isFalse);
      expect(f.storage.opens, 1);
    } finally {
      f.storage.release.complete();
      await _settle(reopening);
    }
    expect(await reopening, isTrue);
    expect(f.c.read(appControllerProvider).phase, AppPhase.ready);
  });

  test('ready waits for durable marker after authentication', () async {
    final f = await _fixture();
    backend.parkMarker = true;
    final reopening = f.ctrl.reopenExistingContainer('fixture');
    await backend.marking.future;
    try {
      expect(f.storage.opens, 1, reason: 'the marker preceded authentication');
      expect(f.storage.isOpen, isTrue);
      expect(f.c.read(appControllerProvider).phase, isNot(AppPhase.ready));
    } finally {
      backend.release.complete();
      await _settle(reopening);
    }
    expect(await reopening, isTrue);
    expect(backend.values['flutter.onboarded'], isTrue);
    expect(f.c.read(appControllerProvider).phase, AppPhase.ready);
  });

  for (final throwsWrite in [false, true]) {
    test(
      'failed marker is not a completed reopen (throws=$throwsWrite)',
      () async {
        final f = await _fixture();
        backend.refuseMarker = !throwsWrite;
        backend.throwMarker = throwsWrite;
        expect(await f.ctrl.reopenExistingContainer('fixture'), isFalse);
        expect(f.storage.isOpen, isFalse);
        expect(f.c.read(appControllerProvider).phase, AppPhase.onboarding);
        expect(backend.values['flutter.onboarded'], isNull);
        expect(
          (await f.c.read(prefsProvider.future)).getBool('onboarded'),
          isNull,
          reason: 'failed SharedPreferences writes also update its RAM cache',
        );
      },
    );
  }

  for (final end in ['lock', 'startOver', 'wipe']) {
    for (final throwsOpen in [false, true]) {
      test(
        '$end during open never becomes successful reopen (throws=$throwsOpen)',
        () async {
          final f = await _fixture(deniable: end == 'wipe');
          f.storage.parkOpen = true;
          f.storage.failOpen = throwsOpen;
          final reopening = f.ctrl.reopenExistingContainer('fixture');
          await f.storage.opening.future;
          Future<List<String>>? wiping;
          try {
            if (end == 'lock') {
              await f.ctrl.lock();
            } else if (end == 'startOver') {
              await f.ctrl.startOver();
            } else {
              wiping = f.ctrl.wipeContainers();
              await f.ctrl.waiting.future;
            }
          } finally {
            f.storage.release.complete();
            await _settle(reopening);
            if (wiping != null) await _settle(wiping);
          }
          expect(await reopening, isFalse);
          expect(f.storage.isOpen, isFalse);
          expect(backend.markerWrites, 0);
          expect(backend.values['flutter.onboarded'], isNull);
          expect(
            f.c.read(appControllerProvider).phase,
            end == 'lock' ? AppPhase.locked : AppPhase.onboarding,
          );
          if (wiping != null) {
            expect(await wiping, isEmpty);
            expect(await f.file.exists(), isFalse);
          }
        },
      );
    }
  }

  for (final end in ['lock', 'startOver', 'wipe']) {
    test('$end orders marker completion before its own final state', () async {
      final f = await _fixture(deniable: end == 'wipe');
      backend.parkMarker = true;
      final reopening = f.ctrl.reopenExistingContainer('fixture');
      await backend.marking.future;
      Future<void>? restarting;
      Future<List<String>>? wiping;
      try {
        if (end == 'lock') {
          await f.ctrl.lock();
        } else if (end == 'startOver') {
          restarting = f.ctrl.startOver();
          var completed = false;
          restarting.then((_) => completed = true);
          await Future<void>.delayed(Duration.zero);
          expect(completed, isFalse);
        } else {
          wiping = f.ctrl.wipeContainers();
          await f.ctrl.waiting.future;
          var settled = false;
          final barrier = f.ctrl.waitForCompaction().then(
            (_) => settled = true,
          );
          await Future<void>.delayed(Duration.zero);
          expect(settled, isFalse);
          expect(await f.file.exists(), isTrue);
          backend.release.complete();
          await barrier;
        }
      } finally {
        if (!backend.release.isCompleted) backend.release.complete();
        await _settle(reopening);
        if (restarting != null) await _settle(restarting);
        if (wiping != null) await _settle(wiping);
      }
      expect(await reopening, isFalse);
      expect(f.storage.isOpen, isFalse);
      expect(
        f.c.read(appControllerProvider).phase,
        end == 'lock' ? AppPhase.locked : AppPhase.onboarding,
      );
      expect(
        backend.values['flutter.onboarded'],
        end == 'lock' ? isTrue : isNull,
      );
      if (wiping != null) {
        expect(await wiping, isEmpty);
        expect(await f.file.exists(), isFalse);
      }
    });
  }

  for (final end in ['lock', 'startOver']) {
    for (final corrupt in [false, true]) {
      test('$end revokes a late profile result (corrupt=$corrupt)', () async {
        final f = await _fixture();
        f.storage.parkProfile = true;
        f.storage.corruptProfile = corrupt;
        final reopening = f.ctrl.reopenExistingContainer('fixture');
        await f.storage.readingProfile.future;
        try {
          if (end == 'lock') {
            await f.ctrl.lock();
          } else {
            await f.ctrl.startOver();
          }
        } finally {
          f.storage.profileRelease.complete();
          await _settle(reopening);
        }
        expect(await reopening, isFalse);
        expect(f.storage.isOpen, isFalse);
        expect(
          f.c.read(appControllerProvider).phase,
          end == 'lock' ? AppPhase.locked : AppPhase.onboarding,
        );
        expect(
          backend.values['flutter.onboarded'],
          end == 'lock' ? isTrue : isNull,
        );
      });
    }
  }

  test('failed marker restores an explicit false value', () async {
    backend.values['flutter.onboarded'] = false;
    backend.refuseMarker = true;
    final f = await _fixture();
    expect(await f.ctrl.reopenExistingContainer('fixture'), isFalse);
    expect(backend.values['flutter.onboarded'], isFalse);
    expect(
      (await f.c.read(prefsProvider.future)).getBool('onboarded'),
      isFalse,
    );
    expect(f.storage.isOpen, isFalse);
  });

  test('lock during damaged-record cleanup keeps the lock screen', () async {
    final f = await _fixture();
    f.storage.corruptProfile = true;
    f.storage.parkClose = true;
    final reopening = f.ctrl.reopenExistingContainer('fixture');
    await f.storage.closing.future;
    try {
      await f.ctrl.lock();
    } finally {
      f.storage.closeRelease.complete();
      await _settle(reopening);
    }
    expect(await reopening, isFalse);
    expect(f.storage.isOpen, isFalse);
    expect(f.c.read(appControllerProvider).phase, AppPhase.locked);
  });

  for (final afterOpen in [false, true]) {
    test(
      'disposing the owner closes its late response (profile=$afterOpen)',
      () async {
        final f = await _fixture();
        f.storage.parkOpen = !afterOpen;
        f.storage.parkProfile = afterOpen;
        final reopening = f.ctrl.reopenExistingContainer('fixture');
        await (afterOpen
            ? f.storage.readingProfile.future
            : f.storage.opening.future);
        f.dispose();
        if (afterOpen) {
          f.storage.profileRelease.complete();
        } else {
          f.storage.release.complete();
        }
        expect(await reopening, isFalse);
        expect(f.storage.isOpen, isFalse);
        if (!afterOpen) expect(backend.markerWrites, 0);
      },
    );
  }
}
