import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/data/notifications/notification_service.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/data/vpn/vpn_backend.dart';
import 'package:xveil/data/whisper_model_store.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/storage_compaction_policy.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/notifications.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/translation_model_controller.dart';
import 'package:xveil/state/vpn_controller.dart';
import 'package:xveil/state/whisper_model_controller.dart';

import 'support/fake_hv_container.dart';

enum _Stage { beforeOpen, afterOpen, readConfig, profile, writeConfig }

class _Storage extends HiddenVolumeStorage {
  _Storage(super.opener, this.stage);
  final _Stage stage;
  final entered = Completer<void>();
  final release = Completer<void>();
  final calls = <String>[];
  bool failOpen = false;
  bool failProfile = false;
  bool blockClose = false;
  final closing = Completer<void>();
  final closeRelease = Completer<void>();
  File? publishOnOpen;

  Future<void> park(_Stage at) async {
    if (stage != at || entered.isCompleted) return;
    entered.complete();
    await release.future;
  }

  @override
  Future<bool> open({
    required String password,
    bool createIfMissing = false,
  }) async {
    calls.add('open');
    await park(_Stage.beforeOpen);
    final opened = await super.open(
      password: password,
      createIfMissing: createIfMissing,
    );
    if (opened && createIfMissing && publishOnOpen != null) {
      // An accepted native create can publish the container before returning
      // its worker response. This models that contract without production data.
      await publishOnOpen!.writeAsString('synthetic accepted create');
    }
    if (opened && failOpen) throw StateError('fixture preparation failure');
    await park(_Stage.afterOpen);
    return opened;
  }

  @override
  Future<String?> loadNodeConfig() async {
    final result = await super.loadNodeConfig();
    await park(_Stage.readConfig);
    return result;
  }

  @override
  Future<void> saveProfile(UserProfile profile) async {
    calls.add('profile');
    await super.saveProfile(profile);
    if (failProfile) throw StateError('fixture profile write failure');
    await park(_Stage.profile);
  }

  @override
  Future<void> saveNodeConfig(String config) async {
    calls.add('config');
    await super.saveNodeConfig(config);
    await park(_Stage.writeConfig);
  }

  @override
  Future<void> close() async {
    if (blockClose && !closing.isCompleted) {
      closing.complete();
      await closeRelease.future;
    }
    await super.close();
  }
}

class _Controller extends AppController {
  final waiting = Completer<void>();
  int rewrites = 0;
  @override
  AppState build() => const AppState(AppPhase.onboarding);
  @override
  Future<void> waitForCompaction() {
    if (!waiting.isCompleted) waiting.complete();
    return super.waitForCompaction();
  }
}

class _Notifications extends NotificationService {
  @override
  Future<void> cancelAll() async {}
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
    ProviderContainer container,
    _Controller controller,
    _Storage storage,
    File file,
    FakeHvContainer fake,
  })
>
_fixture(_Stage stage, {bool deniable = false}) async {
  final dir = await Directory.systemTemp.createTemp(
    'xveil-onboarding-maintenance-',
  );
  addTearDown(() => dir.delete(recursive: true));
  final file = File('${dir.path}/fixture.hv');
  await file.writeAsString('synthetic source');
  final fake = FakeHvContainer();
  final seed = fake.storage();
  await seed.open(password: 'original-fixture', createIfMissing: true);
  await seed.saveProfile(const UserProfile(displayName: 'Original fixture'));
  await seed.close();
  final storage = _Storage(fake.passwordOpener, stage);
  final controller = _Controller();
  final transport = LoopbackTransport();
  addTearDown(transport.dispose);
  final container = ProviderContainer(
    overrides: [
      appControllerProvider.overrideWith(() => controller),
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
      containerCompactorProvider.overrideWithValue((
        path,
        passwords, {
        dylibPath,
      }) async {
        controller.rewrites++;
        throw StateError('unexpected fixture rewrite');
      }),
    ],
  );
  addTearDown(container.dispose);
  addTearDown(storage.close);
  container.read(appControllerProvider);
  controller.debugDeniableStackStarter = (_) async {
    throw StateError('fixture forbids native node boot');
  };
  return (
    container: container,
    controller: controller,
    storage: storage,
    file: file,
    fake: fake,
  );
}

Future<void> _finish(
  AppController controller, {
  String password = 'new-fixture',
}) => controller.completeOnboarding(
  password: password,
  mode: StorageMode.plain,
  displayName: 'New fixture',
  nodeConfigToml: 'fixture-config',
  recoveryCertificateSaved: true,
);

Future<void> _settle(Future<Object?> future) async {
  try {
    await future;
  } catch (_) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final stage in _Stage.values) {
    for (final startOver in [false, true]) {
      test(
        'onboarding stops after ${startOver ? 'startOver' : 'lock'} at ${stage.name}',
        () async {
          final f = await _fixture(stage);
          final finishing = _finish(f.controller);
          final refused = expectLater(finishing, throwsStateError);
          await f.storage.entered.future;
          if (startOver) {
            await f.controller.startOver();
          } else {
            await f.controller.lock();
          }
          final callsAtEnd = List<String>.of(f.storage.calls);
          try {
            await f.controller.unlock('missing-fixture');
            expect(
              f.storage.calls,
              callsAtEnd,
              reason: 'unlock entered an accepted onboarding operation',
            );
          } finally {
            f.storage.release.complete();
            await _settle(refused);
          }
          await refused;
          expect(
            f.storage.calls,
            callsAtEnd,
            reason: 'the cancelled onboarding performed another write/open',
          );
          expect(f.storage.isOpen, isFalse);
          expect(
            f.container.read(appControllerProvider).phase,
            startOver ? AppPhase.onboarding : AppPhase.locked,
          );
          if (startOver) {
            final prefs = await f.container.read(prefsProvider.future);
            expect(prefs.getBool('onboarded'), isNot(true));
          }
          final reader = f.fake.storage();
          expect(await reader.open(password: 'original-fixture'), isTrue);
          expect((await reader.loadProfile())!.displayName, 'Original fixture');
          await reader.close();
          // The admission is released even after cancellation.
          await f.controller.unlock('missing-fixture');
          expect(f.storage.calls.length, callsAtEnd.length + 1);
        },
      );
    }
  }

  test(
    'startOver cannot create a new identity during an accepted password probe',
    () async {
      final f = await _fixture(_Stage.beforeOpen);
      final probing = f.controller.probeCompactionIdentity('original-fixture');
      await f.storage.entered.future;
      await f.controller.startOver();
      try {
        await expectLater(_finish(f.controller), throwsStateError);
        expect(f.storage.calls, ['open']);
        expect(
          f.container.read(appControllerProvider).phase,
          AppPhase.onboarding,
        );
      } finally {
        f.storage.release.complete();
        await _settle(probing);
      }
      expect((await probing).opened, isFalse);
      await _finish(f.controller);
      expect(f.container.read(appControllerProvider).phase, AppPhase.ready);
      expect(f.storage.isOpen, isTrue);
      expect((await f.storage.loadProfile())!.displayName, 'New fixture');
    },
  );

  test('a second onboarding is refused without replacing the first', () async {
    final f = await _fixture(_Stage.afterOpen);
    final finishing = _finish(f.controller);
    await f.storage.entered.future;
    try {
      await expectLater(
        _finish(f.controller, password: 'other-fixture'),
        throwsStateError,
      );
      expect(f.storage.calls, ['open']);
    } finally {
      f.storage.release.complete();
      await _settle(finishing);
    }
    await finishing;
    expect(f.container.read(appControllerProvider).phase, AppPhase.ready);
    expect((await f.storage.loadProfile())!.displayName, 'New fixture');
  });

  test(
    'failed preparation after open closes its handle and permits retry',
    () async {
      final f = await _fixture(_Stage.beforeOpen);
      f.storage.release.complete();
      f.storage.failOpen = true;
      await expectLater(_finish(f.controller), throwsStateError);
      expect(f.storage.isOpen, isFalse);
      expect(
        f.container.read(appControllerProvider).phase,
        AppPhase.onboarding,
      );
      f.storage.failOpen = false;
      await _finish(f.controller);
      expect(f.storage.isOpen, isTrue);
      expect(f.container.read(appControllerProvider).phase, AppPhase.ready);
    },
  );

  test(
    'wipe waits for an accepted create before deleting the container',
    () async {
      final f = await _fixture(_Stage.beforeOpen, deniable: true);
      f.storage.publishOnOpen = f.file;
      final finishing = _finish(f.controller);
      final refused = expectLater(finishing, throwsStateError);
      await f.storage.entered.future;
      final wiping = f.controller.wipeContainers();
      try {
        await Future.any<void>([
          f.controller.waiting.future,
          wiping.then(
            (_) => throw StateError('wipe returned before accepted create'),
          ),
        ]);
        var ended = false;
        final barrier = f.controller.waitForCompaction().then(
          (_) => ended = true,
        );
        // Drain microtasks using an event-queue marker, without a time bound.
        await Future<void>.delayed(Duration.zero);
        expect(ended, isFalse);
        expect(await f.file.exists(), isTrue);
        f.storage.release.complete();
        await barrier;
      } finally {
        if (!f.storage.release.isCompleted) f.storage.release.complete();
        await _settle(refused);
        await _settle(wiping);
      }
      await refused;
      expect(await wiping, isEmpty);
      expect(await f.file.exists(), isFalse);
      expect(f.storage.isOpen, isFalse);
    },
  );

  test(
    'lock during onboarding rollback cannot restore the onboarding screen',
    () async {
      final f = await _fixture(_Stage.beforeOpen);
      f.storage.release.complete();
      f.storage.failProfile = true;
      f.storage.blockClose = true;
      final finishing = _finish(f.controller);
      final refused = expectLater(finishing, throwsStateError);
      await f.storage.closing.future;
      try {
        await f.controller.lock();
        expect(f.container.read(appControllerProvider).phase, AppPhase.locked);
      } finally {
        f.storage.closeRelease.complete();
        await _settle(refused);
      }
      await refused;
      expect(f.container.read(appControllerProvider).phase, AppPhase.locked);
      expect(f.storage.isOpen, isFalse);
      f.storage.failProfile = false;
      await _finish(f.controller);
      expect(f.container.read(appControllerProvider).phase, AppPhase.ready);
    },
  );

  test(
    'probe is refused while a revoked onboarding opener still runs',
    () async {
      final f = await _fixture(_Stage.beforeOpen);
      final finishing = _finish(f.controller);
      final refused = expectLater(finishing, throwsStateError);
      await f.storage.entered.future;
      await f.controller.lock();
      try {
        await expectLater(
          f.controller.probeCompactionIdentity('original-fixture'),
          throwsStateError,
        );
        expect(f.storage.calls, ['open']);
      } finally {
        f.storage.release.complete();
        await _settle(refused);
      }
      await refused;
      expect(
        (await f.controller.probeCompactionIdentity('original-fixture')).opened,
        isTrue,
      );
    },
  );

  test(
    'rewrite is refused while onboarding still owns the container',
    () async {
      final f = await _fixture(_Stage.beforeOpen, deniable: true);
      final finishing = _finish(f.controller);
      final refused = expectLater(finishing, throwsStateError);
      await f.storage.entered.future;
      await f.controller.lock();
      try {
        await expectLater(
          f.controller.compactStorageKeeping(
            roster: CompactionRoster()
              ..addUnlocked(
                'fixture',
                passwordBytes: 'missing-fixture'.codeUnits,
              ),
            reopenWith: 'missing-fixture',
          ),
          throwsStateError,
        );
        expect(f.controller.rewrites, 0);
        expect(f.storage.calls, ['open']);
        expect(f.container.read(appControllerProvider).phase, AppPhase.locked);
      } finally {
        f.storage.release.complete();
        await _settle(refused);
      }
      await refused;
    },
  );

  test('onboarding is refused while ordinary unlock owns the opener', () async {
    final f = await _fixture(_Stage.beforeOpen);
    final unlocking = f.controller.unlock('missing-fixture');
    await f.storage.entered.future;
    try {
      await expectLater(_finish(f.controller), throwsStateError);
      expect(f.storage.calls, ['open']);
    } finally {
      f.storage.release.complete();
      await _settle(unlocking);
    }
    await unlocking;
    await _finish(f.controller);
    expect(f.container.read(appControllerProvider).phase, AppPhase.ready);
  });
}
