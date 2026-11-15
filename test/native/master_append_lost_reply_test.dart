@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/node/node_controller.dart';
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

class _Fault {
  bool armed = false;
}

class _LostReply extends HiddenVolumeStorage {
  _LostReply(String path, this.fault)
    : super(
        hvSpaceOpener(
          path,
          argon: hv.ArgonPreset.min,
          paddingPreset: hv.PaddingPreset.none,
        ),
        keysOpener: hvKeysSpaceOpener(path),
      );
  final _Fault fault;
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
    if (fault.armed &&
        settingKey == kPendingMasterSetupSetting &&
        settingValue == '0') {
      fault.armed = false;
      throw StateError('synthetic lost accepted append completion reply');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'lost accepted append completion never restores an obsolete cached roster',
    () async {
      expect(ensureHiddenVolumeLoaded(), isTrue);
      SharedPreferences.setMockInitialValues({'onboarded': true});
      final directory = Directory.systemTemp.createTempSync(
        'xveil-master-journal-',
      );
      final fixture = MasterSetupFixture(
        directory,
        StorageProtection.hidden,
        append: true,
      );
      await fixture.create();
      final fault = _Fault();
      final router = await ProfileStorageRouter.open(
        profileDirectory: fixture.profile,
        legacyPath: fixture.legacy,
        legacyFactory: () => _LostReply(fixture.legacy, fault),
      );
      await router.select(fixture.root);
      final node = _Node();
      final app = ProviderContainer(
        overrides: [
          profileStorageRouterProvider.overrideWithValue(router),
          singleSpaceStorageProvider.overrideWith((ref) {
            ref.watch(storageRouteRevisionProvider);
            return router.storage;
          }),
          nodeControllerProvider.overrideWithValue(node),
        ],
      );
      final controller = app.read(appControllerProvider.notifier);
      try {
        await app.read(prefsProvider.future);
        await controller.unlock(utf8.decode(fixture.password));
        expect(app.read(appControllerProvider).phase, AppPhase.pickingIdentity);
        await controller.pickIdentity('original identity');
        expect(app.read(appControllerProvider).phase, AppPhase.ready);
        final sourceKeys = await router.storage.exportSpaceKeys();
        try {
          final starts = node.starts;
          fault.armed = true;
          expect(
            await controller.addIdentity(
              masterPassword: utf8.decode(fixture.password),
              label: 'new child',
              password: utf8.decode(fixture.childPassword),
              protection: StorageProtection.encrypted,
            ),
            isFalse,
          );
          expect(
            fault.armed,
            isFalse,
            reason: 'the final native publication was actually accepted',
          );
          expect(
            app.read(appControllerProvider).phase,
            AppPhase.locked,
            reason:
                'do not resume the old cached membership after durable append completion',
          );
          expect(node.starts, starts);
          await controller.unlock(utf8.decode(fixture.password));
          expect(
            app.read(appControllerProvider).phase,
            AppPhase.pickingIdentity,
          );
          expect(app.read(appControllerProvider).identities, [
            'original identity',
            'new child',
          ]);
          await controller.pickIdentity('new child');
          expect(app.read(appControllerProvider).phase, AppPhase.ready);
          expect(
            (await router.storage.loadProfile())!.displayName,
            'new child',
          );
          await controller.pickIdentity('original identity');
          expect(
            await router.storage.getSetting('fixture'),
            'original payload',
          );
          final actual = await router.storage.exportSpaceKeys();
          try {
            expect(actual, sourceKeys);
          } finally {
            actual.fillRange(0, actual.length, 0);
          }
        } finally {
          sourceKeys.fillRange(0, sourceKeys.length, 0);
        }
      } finally {
        await controller.lock();
        app.dispose();
        await router.close();
        directory.deleteSync(recursive: true);
      }
    },
  );
}
