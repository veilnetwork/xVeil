@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/data/veil_stack.dart';
import 'package:xveil/data/storage/file_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/profile_storage_router.dart';
import 'package:xveil/domain/storage_protection.dart';
import 'package:xveil/domain/storage_setup.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/storage_router_providers.dart';
import '../support/erasure_writer_process.dart';
import 'support/master_setup_fixture.dart';

class _Node implements NodeController {
  int starts = 0;
  @override
  NodeStatus get current => const NodeStatus(phase: NodePhase.connected);
  @override
  Stream<NodeStatus> status() => const Stream.empty();
  @override
  Future<void> start() async {
    starts++;
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> setEconomyMode(bool economy) async {}
}

class _Gate {
  _Gate(this.value, {this.failReply = false});
  final String value;
  final bool failReply;
  bool armed = false;
  final entered = Completer<void>(), release = Completer<void>();
}

class _FailedSessionStack implements RealVeilStack {
  _FailedSessionStack(this.controller);
  @override
  final NodeController controller;
  bool disposed = false;
  @override
  Never get myInvite =>
      throw StateError('synthetic session publication failure');
  @override
  Future<void> dispose() async {
    disposed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected synthetic stack use');
}

class _AfterJournal extends HiddenVolumeStorage {
  _AfterJournal(String path, this.gate)
    : super(
        hvSpaceOpener(
          path,
          argon: hv.ArgonPreset.min,
          paddingPreset: hv.PaddingPreset.none,
        ),
        keysOpener: hvKeysSpaceOpener(path),
      );
  final _Gate gate;
  @override
  Future<void> storeFileWithSetting(
    StoredFileWrite file, {
    required String settingKey,
    required String settingValue,
  }) async {
    await super.storeFileWithSetting(
      file,
      settingKey: settingKey,
      settingValue: settingValue,
    );
    if (gate.armed &&
        settingKey == kPendingMasterSetupSetting &&
        settingValue == gate.value) {
      gate.entered.complete();
      await gate.release.future;
      if (gate.failReply) throw StateError('synthetic lost accepted reply');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final boundary in [
    'attachment',
    'finish',
    'lost-finish-reply',
    'dispose-attachment',
    'dispose-finish',
    'session-failure',
  ]) {
    final finalCommit =
        boundary.endsWith('finish') ||
        boundary == 'lost-finish-reply' ||
        boundary == 'session-failure';
    final lostReply = boundary == 'lost-finish-reply';
    final dispose = boundary.startsWith('dispose-');
    final sessionFailure = boundary == 'session-failure';
    test(
      'accepted master $boundary preserves recovery and prevents late activation',
      () async {
        expect(ensureHiddenVolumeLoaded(), isTrue);
        SharedPreferences.setMockInitialValues({'onboarded': true});
        final dir = Directory.systemTemp.createTempSync(
          'xveil-master-journal-',
        );
        final fixture = MasterSetupFixture(dir, StorageProtection.hidden);
        await fixture.create();
        final gate = _Gate(finalCommit ? '0' : '1', failReply: lostReply);
        final routers = <ProfileStorageRouter>[];
        final apps = <ProviderContainer>[];
        Future<ProfileStorageRouter> open() async {
          final router = await ProfileStorageRouter.open(
            profileDirectory: fixture.profile,
            legacyPath: fixture.legacy,
            legacyFactory: () => _AfterJournal(fixture.legacy, gate),
          );
          routers.add(router);
          await router.select(fixture.root);
          return router;
        }

        Future<(ProviderContainer, _Node)> app(
          ProfileStorageRouter router,
        ) async {
          final node = _Node();
          final container = ProviderContainer(
            overrides: [
              profileStorageRouterProvider.overrideWithValue(router),
              singleSpaceStorageProvider.overrideWith((ref) {
                ref.watch(storageRouteRevisionProvider);
                return router.storage;
              }),
              nodeControllerProvider.overrideWithValue(node),
            ],
          );
          apps.add(container);
          container.read(appControllerProvider);
          await container.read(prefsProvider.future);
          return (container, node);
        }

        Future<bool>? replay;
        try {
          await killErasureWriter(
            dir.path,
            finalCommit ? 'child-known' : 'prepared',
            () {},
            script: 'test/native/master_setup_journal_writer.dart',
            writerArguments: [StorageProtection.hidden.name],
          );
          final router = await open();
          final (container, node) = await app(router);
          final controller = container.read(appControllerProvider.notifier);
          await controller.unlock(utf8.decode(fixture.password));
          expect(controller.canReplayMasterSetup, isTrue);
          gate.armed = true;
          replay = controller.replayMasterSetup(
            utf8.decode(fixture.password),
            childPassword: utf8.decode(fixture.childPassword),
          );
          await gate.entered.future.timeout(const Duration(seconds: 30));
          expect(node.starts, 0);
          final failedStack = _FailedSessionStack(node);
          if (sessionFailure) {
            container.read(realStackProvider.notifier).state = failedStack;
          } else if (dispose) {
            container.dispose();
            apps.remove(container);
          } else if (!lostReply) {
            await controller.lock();
            expect(
              container.read(appControllerProvider).phase,
              AppPhase.locked,
            );
          }
          gate.armed = false;
          gate.release.complete();
          expect(await replay, isFalse);
          if (!dispose) {
            expect(
              container.read(appControllerProvider).phase,
              AppPhase.locked,
            );
          }
          expect(node.starts, 0);
          if (sessionFailure) {
            expect(
              failedStack.disposed,
              isTrue,
              reason: 'failed recovery must retire a published session stack',
            );
            expect(container.read(realStackProvider), isNull);
          }
          await router.close();
          if (!dispose) {
            container.dispose();
            apps.remove(container);
          }
          final coldRouter = await open();
          final (cold, _) = await app(coldRouter);
          final coldController = cold.read(appControllerProvider.notifier);
          await coldController.unlock(utf8.decode(fixture.password));
          if (finalCommit) {
            expect(
              cold.read(appControllerProvider).phase,
              AppPhase.pickingIdentity,
            );
          } else {
            expect(
              cold.read(appControllerProvider).phase,
              AppPhase.identitySetupRecovery,
            );
            expect(coldController.setupRecoveryChildProtection, isNull);
            expect(
              await coldController.replayMasterSetup(
                utf8.decode(fixture.password),
              ),
              isTrue,
            );
            expect(cold.read(appControllerProvider).phase, AppPhase.ready);
            await coldController.lock();
            await coldController.unlock(utf8.decode(fixture.password));
          }
          expect(cold.read(appControllerProvider).identities, [
            'original identity',
            'new child',
          ]);
          await coldController.pickIdentity('original identity');
          expect(
            await coldRouter.storage.getSetting('fixture'),
            'original payload',
          );
        } finally {
          gate.armed = false;
          if (!gate.release.isCompleted) gate.release.complete();
          if (replay != null) await replay;
          for (final container in apps.reversed) {
            await container.read(appControllerProvider.notifier).lock();
            container.dispose();
          }
          for (final router in routers.reversed) {
            await router.close();
          }
          dir.deleteSync(recursive: true);
        }
      },
    );
  }
}
