import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/notifications/notification_service.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/vpn/vpn_backend.dart';
import 'package:xveil/data/whisper_model_store.dart';
import 'package:xveil/domain/storage_compaction_policy.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/notifications.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/translation_model_controller.dart';
import 'package:xveil/state/vpn_controller.dart';
import 'package:xveil/state/whisper_model_controller.dart';

import 'support/fake_hv_container.dart';

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

class _Controller extends AppController {
  final waiting = Completer<void>();
  @override
  AppState build() => const AppState(AppPhase.ready);
  @override
  Future<void> waitForCompaction() {
    if (!waiting.isCompleted) waiting.complete();
    return super.waitForCompaction();
  }
}

ProviderContainer _idleWipeContainer(Directory directory, String path) =>
    ProviderContainer(
      overrides: [
        appControllerProvider.overrideWith(_Controller.new),
        singleSpaceStorageProvider.overrideWithValue(
          FakeHvContainer().storage(),
        ),
        notificationServiceProvider.overrideWithValue(_Notifications()),
        vpnBackendProvider.overrideWithValue(_Vpn()),
        whisperModelStoreProvider.overrideWithValue(
          WhisperModelStore(supportDirectory: () async => directory),
        ),
        translationModelsRootProvider.overrideWithValue(() async => null),
        deniableBootProvider.overrideWithValue(
          DeniableBootConfig(
            runtimeDir: '${directory.path}/runtime',
            storePath: path,
          ),
        ),
      ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final failRewrite in [false, true]) {
    test('wipe waits for rewrite to settle (failure=$failRewrite)', () async {
      final directory = await Directory.systemTemp.createTemp('xveil-wipe-');
      addTearDown(() => directory.delete(recursive: true));
      final source = File('${directory.path}/fixture.hv');
      final staged = File('${directory.path}/fixture-staged.hv');
      final orphan = File(
        '${directory.path}/.fixture.hv.hv-compact.0123456789abcdef.tmp',
      );
      final rotated = File(
        '${directory.path}/.fixture.hv.hv-rotate.fedcba9876543210.tmp',
      );
      final foreign = File(
        '${directory.path}/.other.hv.hv-compact.0123456789abcdef.tmp',
      );
      await source.writeAsString('old encrypted container');
      await orphan.writeAsString('interrupted compaction');
      await rotated.writeAsString('interrupted rotation');
      await foreign.writeAsString('other container');
      final entered = Completer<void>();
      final publish = Completer<void>();
      final fake = FakeHvContainer();
      var openAttempts = 0;
      final storage = HiddenVolumeStorage(({
        required password,
        required create,
      }) {
        openAttempts++;
        return fake.passwordOpener(password: password, create: create);
      });
      await storage.open(password: 'fixture', createIfMissing: true);
      final controller = _Controller();
      final container = ProviderContainer(
        overrides: [
          appControllerProvider.overrideWith(() => controller),
          singleSpaceStorageProvider.overrideWithValue(storage),
          notificationServiceProvider.overrideWithValue(_Notifications()),
          vpnBackendProvider.overrideWithValue(_Vpn()),
          whisperModelStoreProvider.overrideWithValue(
            WhisperModelStore(supportDirectory: () async => directory),
          ),
          translationModelsRootProvider.overrideWithValue(() async => null),
          deniableBootProvider.overrideWithValue(
            DeniableBootConfig(
              runtimeDir: '${directory.path}/runtime',
              storePath: source.path,
            ),
          ),
          preparedContainerCompactorProvider.overrideWithValue((
            path,
            passwords, {
            required repairMetadata,
            dylibPath,
          }) async {
            // External backend contract: its accepted operation may still
            // publish a replacement file later. The raw native probe verifies
            // this same pre-rename window independently with the real library.
            await staged.writeAsString('new encrypted container', flush: true);
            entered.complete();
            await publish.future;
            if (failRewrite) {
              await staged.delete();
              throw StateError('fixture backend refusal');
            }
            try {
              await repairMetadata(staged.path);
              await staged.rename(path);
            } finally {
              if (await staged.exists()) await staged.delete();
            }
          }),
        ],
      );
      addTearDown(container.dispose);
      container.read(appControllerProvider);
      final compacting = controller.compactStorageKeeping(
        roster: CompactionRoster()
          ..addUnlocked('fixture', passwordBytes: 'fixture'.codeUnits),
        reopenWith: 'fixture',
      );
      final refused = expectLater(compacting, throwsStateError);
      await entered.future;
      final wiping = controller.wipeContainers();
      try {
        await Future.any<void>([
          controller.waiting.future,
          wiping.then((_) {
            throw StateError('wipe returned before the accepted rewrite');
          }),
        ]);
        expect(await source.readAsString(), 'old encrypted container');
        expect(identical(wiping, controller.wipeContainers()), isTrue);
        await controller.unlock('must-not-open-during-wipe');
        expect(openAttempts, 1);
        await expectLater(
          controller.compactStorageKeeping(
            roster: CompactionRoster()
              ..addUnlocked('fixture', passwordBytes: 'fixture'.codeUnits),
            reopenWith: 'fixture',
          ),
          throwsStateError,
        );
      } finally {
        publish.complete();
        await refused;
      }
      expect(await wiping, isEmpty);
      expect(await source.exists(), isFalse);
      expect(await staged.exists(), isFalse);
      expect(await orphan.exists(), isFalse);
      expect(await rotated.exists(), isFalse);
      expect(await foreign.readAsString(), 'other container');
      expect(storage.isOpen, isFalse);
      expect(openAttempts, 1);
      expect(container.read(appControllerProvider).phase, AppPhase.onboarding);
    });
  }

  test(
    'wipe reports an unexpected temporary directory without removing it',
    () async {
      final directory = await Directory.systemTemp.createTemp('xveil-wipe-');
      addTearDown(() => directory.delete(recursive: true));
      final source = File('${directory.path}/fixture.hv');
      await source.writeAsString('container');
      final unexpected = Directory(
        '${directory.path}/.fixture.hv.hv-compact.0123456789abcdef.tmp',
      );
      await unexpected.create();
      await File('${unexpected.path}/keep').writeAsString('not native content');
      final container = _idleWipeContainer(directory, source.path);
      addTearDown(container.dispose);
      expect(
        await container.read(appControllerProvider.notifier).wipeContainers(),
        ['container-rewrite'],
      );
      expect(await source.exists(), isFalse);
      expect(
        await File('${unexpected.path}/keep').readAsString(),
        'not native content',
      );
    },
  );

  test(
    'wipe reports a failed temporary inventory instead of claiming empty',
    () async {
      final directory = await Directory.systemTemp.createTemp('xveil-wipe-');
      addTearDown(() => directory.delete(recursive: true));
      final notDirectory = File('${directory.path}/file');
      await notDirectory.writeAsString('keep');
      final container = _idleWipeContainer(
        directory,
        '${notDirectory.path}/fixture.hv',
      );
      addTearDown(container.dispose);
      expect(
        await container.read(appControllerProvider.notifier).wipeContainers(),
        ['container-rewrite-unknown'],
      );
      expect(await notDirectory.readAsString(), 'keep');
    },
    skip: Platform.isWindows ? 'POSIX ENOTDIR fixture' : false,
  );
}
