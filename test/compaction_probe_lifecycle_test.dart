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
import 'package:xveil/domain/storage_compaction_policy.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/notifications.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/translation_model_controller.dart';
import 'package:xveil/state/vpn_controller.dart';
import 'package:xveil/state/whisper_model_controller.dart';

import 'support/fake_hv_container.dart';

// Drain an owned operation even when an earlier assertion fails. The test
// awaits its actual result separately; cleanup must not leave a late opener
// running against the next test's disposed provider container.
Future<void> _settle(Future<Object?> operation) async {
  try {
    await operation;
  } catch (_) {}
}

enum _Stage { beforeOpen, afterOpen, roster, profile, keys }

class _Storage extends HiddenVolumeStorage {
  _Storage(super.opener, this.stage);
  final _Stage stage;
  final entered = Completer<void>();
  final release = Completer<void>();
  final calls = <String>[];
  bool failAfterOpen = false;
  bool blockFinalClose = false;
  final closeEntered = Completer<void>();
  final closeRelease = Completer<void>();

  Future<void> park(_Stage here) async {
    if (stage != here || entered.isCompleted) return;
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
    if (opened && failAfterOpen) throw StateError('fixture open failure');
    await park(_Stage.afterOpen);
    return opened;
  }

  @override
  Future<List<RosterEntry>?> loadRoster() async {
    calls.add('roster');
    final result = await super.loadRoster();
    await park(_Stage.roster);
    return result;
  }

  @override
  Future<UserProfile?> loadProfile() async {
    calls.add('profile');
    final result = await super.loadProfile();
    await park(_Stage.profile);
    return result;
  }

  @override
  Future<Uint8List> exportSpaceKeys() async {
    calls.add('keys');
    final result = await super.exportSpaceKeys();
    await park(_Stage.keys);
    return result;
  }

  @override
  Future<void> close() async {
    if (blockFinalClose && !closeEntered.isCompleted) {
      closeEntered.complete();
      await closeRelease.future;
    }
    await super.close();
  }
}

class _Controller extends AppController {
  final waiting = Completer<void>();
  @override
  AppState build() => const AppState(AppPhase.preparingNode);
  @override
  Future<void> waitForCompaction() {
    if (!waiting.isCompleted) waiting.complete();
    return super.waitForCompaction();
  }
}

class _RecoveryController extends _Controller {
  var unlocks = 0;
  @override
  Future<void> unlock(String password) async {
    unlocks++;
  }
}

class _Notifications extends NotificationService {
  @override
  Future<void> cancelAll() async {}
}

class _Vpn implements VpnBackend {
  @override
  Future<VpnBackendState> probe() => status();
  @override
  Future<VpnBackendState> status() async =>
      const VpnBackendState(VpnBackendPhase.unsupported);
  @override
  Future<VpnBackendState> stop() => status();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<({ProviderContainer container, _Storage storage, File file})> _fixture(
  _Controller controller,
  _Stage stage, {
  Future<void> Function()? rewrite,
}) async {
  final dir = await Directory.systemTemp.createTemp('xveil-probe-lifecycle-');
  addTearDown(() => dir.delete(recursive: true));
  final file = File('${dir.path}/fixture.hv');
  await file.writeAsString('synthetic container');
  final fake = FakeHvContainer();
  final seed = fake.storage();
  await seed.open(password: 'fixture', createIfMissing: true);
  await seed.saveProfile(const UserProfile(displayName: 'Synthetic identity'));
  await seed.close();
  final storage = _Storage(fake.passwordOpener, stage);
  final container = ProviderContainer(
    overrides: [
      appControllerProvider.overrideWith(() => controller),
      singleSpaceStorageProvider.overrideWithValue(storage),
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
      containerCompactorProvider.overrideWithValue((
        path,
        passwords, {
        dylibPath,
      }) async {
        if (rewrite != null) await rewrite();
        throw StateError('unexpected fixture rewrite');
      }),
    ],
  );
  addTearDown(container.dispose);
  addTearDown(storage.close);
  container.read(appControllerProvider);
  return (container: container, storage: storage, file: file);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final stage in _Stage.values) {
    test('lock revokes a password probe parked at ${stage.name}', () async {
      final controller = _Controller();
      final f = await _fixture(controller, stage);
      final probing = controller.probeCompactionIdentity('fixture');
      await f.storage.entered.future;
      await controller.lock();
      final callsAtLock = List<String>.of(f.storage.calls);
      try {
        await controller.unlock('missing-fixture');
        expect(
          f.storage.calls,
          callsAtLock,
          reason: 'a new unlock entered the unfinished probe',
        );
      } finally {
        f.storage.release.complete();
        await _settle(probing);
      }
      final result = await probing;
      expect(result.opened, isFalse);
      expect(result.displayName, isNull);
      expect(result.spaceKeys, isNull);
      expect(
        f.storage.calls,
        callsAtLock,
        reason: 'the revoked probe continued reading another space',
      );
      expect(f.storage.isOpen, isFalse);
      expect(f.container.read(appControllerProvider).phase, AppPhase.locked);
      await controller.unlock('missing-fixture');
      expect(
        f.storage.calls.where((s) => s == 'open').length,
        2,
        reason: 'the probe left a permanent unlock gate',
      );
    });
  }

  test(
    'overlapping probe is refused without replacing the first handle',
    () async {
      final controller = _Controller();
      final f = await _fixture(controller, _Stage.afterOpen);
      final probing = controller.probeCompactionIdentity('fixture');
      await f.storage.entered.future;
      try {
        await expectLater(
          controller.probeCompactionIdentity('missing-fixture'),
          throwsStateError,
        );
        expect(f.storage.calls, ['open']);
        expect(f.storage.isOpen, isTrue);
      } finally {
        f.storage.release.complete();
        await _settle(probing);
      }
      expect((await probing).displayName, 'Synthetic identity');
      expect(f.storage.isOpen, isFalse);
    },
  );

  test('rewrite cannot enter while a probe owns the facade', () async {
    final controller = _Controller();
    final f = await _fixture(controller, _Stage.beforeOpen);
    final probing = controller.probeCompactionIdentity('fixture');
    await f.storage.entered.future;
    try {
      await expectLater(
        controller.compactStorageKeeping(
          roster: CompactionRoster()
            ..addUnlocked('fixture', passwordBytes: 'fixture'.codeUnits),
          reopenWith: 'fixture',
        ),
        throwsStateError,
      );
      expect(f.storage.calls, ['open']);
      expect(
        f.container.read(appControllerProvider).phase,
        AppPhase.preparingNode,
      );
    } finally {
      f.storage.release.complete();
      await _settle(probing);
    }
    expect((await probing).opened, isTrue);
  });

  test('probe refuses a live session without closing it', () async {
    final controller = _Controller();
    final f = await _fixture(controller, _Stage.beforeOpen);
    f.storage.release.complete();
    await f.storage.open(password: 'fixture');
    await expectLater(
      controller.probeCompactionIdentity('missing-fixture'),
      throwsStateError,
    );
    expect(f.storage.calls, ['open']);
    expect(f.storage.isOpen, isTrue);
    expect((await f.storage.loadProfile())!.displayName, 'Synthetic identity');
  });

  test(
    'failed open after handle adoption closes it and releases admission',
    () async {
      final controller = _Controller();
      final f = await _fixture(controller, _Stage.beforeOpen);
      f.storage.release.complete();
      f.storage.failAfterOpen = true;
      await expectLater(
        controller.probeCompactionIdentity('fixture'),
        throwsStateError,
      );
      expect(f.storage.isOpen, isFalse);
      f.storage.failAfterOpen = false;
      expect(
        (await controller.probeCompactionIdentity('fixture')).opened,
        isTrue,
      );
      expect(f.storage.isOpen, isFalse);
    },
  );

  for (final viaRoute in [false, true]) {
    for (final lockDuringWait in [false, true]) {
      test(
        'collection recovery waits and revalidates (route=$viaRoute, lock=$lockDuringWait)',
        () async {
          final controller = _RecoveryController();
          final f = await _fixture(controller, _Stage.beforeOpen);
          final lease = controller.leaseIdentity();
          final probing = controller.probeCompactionIdentity('fixture');
          await f.storage.entered.future;
          final recovering = viaRoute
              ? controller.recoverCompactionCollection(
                  lease: lease,
                  reopenWith: 'fixture',
                )
              : controller.cancelCompactionCollection('fixture');
          try {
            expect(
              controller.unlocks,
              0,
              reason: 'recovery raced the outstanding probe',
            );
            if (lockDuringWait) await controller.lock();
          } finally {
            f.storage.release.complete();
            await _settle(probing);
            await _settle(recovering);
          }
          await probing;
          await recovering;
          expect(controller.unlocks, lockDuringWait ? 0 : 1);
          expect(f.storage.isOpen, isFalse);
        },
      );
    }
  }

  test('lock during final close also revokes an already read result', () async {
    final controller = _Controller();
    final f = await _fixture(controller, _Stage.beforeOpen);
    f.storage.release.complete();
    f.storage.blockFinalClose = true;
    final probing = controller.probeCompactionIdentity('fixture');
    await f.storage.closeEntered.future;
    try {
      await controller.lock();
      await controller.unlock('missing-fixture');
      expect(f.storage.calls.where((s) => s == 'open').length, 1);
    } finally {
      f.storage.closeRelease.complete();
      await _settle(probing);
    }
    final result = await probing;
    expect(result.opened, isFalse);
    expect(result.displayName, isNull);
    expect(result.spaceKeys, isNull);
    expect(f.storage.isOpen, isFalse);
  });

  test('probe refuses an ordinary unlock awaiting its opener', () async {
    final controller = _Controller();
    final f = await _fixture(controller, _Stage.beforeOpen);
    final unlocking = controller.unlock('missing-fixture');
    await f.storage.entered.future;
    try {
      await expectLater(
        controller.probeCompactionIdentity('fixture'),
        throwsStateError,
      );
      expect(f.storage.calls, ['open']);
    } finally {
      f.storage.release.complete();
      await _settle(unlocking);
    }
    expect(f.storage.isOpen, isFalse);
  });

  test('new collection cannot tear down an outstanding probe', () async {
    final controller = _Controller();
    final f = await _fixture(controller, _Stage.afterOpen);
    final probing = controller.probeCompactionIdentity('fixture');
    await f.storage.entered.future;
    try {
      await expectLater(
        controller.beginCompactionCollection(),
        throwsStateError,
      );
      expect(f.storage.isOpen, isTrue);
    } finally {
      f.storage.release.complete();
      await _settle(probing);
    }
    expect((await probing).opened, isTrue);
  });

  test('probe cannot enter an accepted rewrite before it settles', () async {
    final controller = _Controller();
    final rewriting = Completer<void>();
    final releaseRewrite = Completer<void>();
    final f = await _fixture(
      controller,
      _Stage.beforeOpen,
      rewrite: () async {
        rewriting.complete();
        await releaseRewrite.future;
      },
    );
    // A regressed admission must fail the assertion, not park on a fixture
    // gate until the test timeout.
    f.storage.release.complete();
    final compacting = controller.compactStorageKeeping(
      roster: CompactionRoster()
        ..addUnlocked('fixture', passwordBytes: 'fixture'.codeUnits),
      reopenWith: 'fixture',
    );
    final refused = expectLater(compacting, throwsStateError);
    await rewriting.future;
    try {
      await expectLater(
        controller.probeCompactionIdentity('fixture'),
        throwsStateError,
      );
      expect(f.storage.calls, isEmpty);
    } finally {
      // Suppress automatic recovery without replacing the rewrite barrier.
      await controller.lock();
      releaseRewrite.complete();
      await refused;
    }
    expect(f.storage.isOpen, isFalse);
    expect(
      (await controller.probeCompactionIdentity('fixture')).opened,
      isTrue,
    );
  });

  test('wipe waits for an accepted opener and its final close', () async {
    final controller = _Controller();
    final f = await _fixture(controller, _Stage.beforeOpen);
    final probing = controller.probeCompactionIdentity('fixture');
    await f.storage.entered.future;
    final wiping = controller.wipeContainers();
    try {
      await Future.any<void>([
        controller.waiting.future,
        wiping.then((_) => throw StateError('wipe returned before probe')),
      ]);
      // Resolve the method-level barrier too: reaching its call site alone
      // does not prove that deletion actually waits for the outstanding open.
      var settled = false;
      final barrier = controller.waitForCompaction().then(
        (_) => settled = true,
      );
      await Future<void>.value();
      expect(settled, isFalse);
      expect(await f.file.exists(), isTrue);
      await expectLater(
        controller.probeCompactionIdentity('fixture'),
        throwsStateError,
      );
      f.storage.release.complete();
      await barrier;
    } finally {
      if (!f.storage.release.isCompleted) f.storage.release.complete();
      await _settle(probing);
      await _settle(wiping);
    }
    expect((await probing).opened, isFalse);
    expect(await wiping, isEmpty);
    expect(await f.file.exists(), isFalse);
    expect(f.storage.isOpen, isFalse);
  });
}
