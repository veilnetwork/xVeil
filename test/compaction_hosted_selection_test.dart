import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/multi_space_store.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/keep_all_online_controller.dart';
import 'package:xveil/state/multi_identity_session.dart';
import 'package:xveil/state/providers.dart';
import 'support/fake_hv_container.dart';
import 'support/fake_multi_space.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final locked in [false, true]) {
    test(
      'collection restores only the authorized hosted selection (lock=$locked)',
      () async {
        SharedPreferences.setMockInitialValues({
          'onboarded': true,
          'keep_all_online': true,
        });
        final backing = FakeMultiSpaceBacking();
        final roster = [
          for (var n = 1; n <= 2; n++)
            RosterEntry(
              label: 'child-$n',
              spaceKeys: Uint8List.fromList(List.filled(64, n)),
            ),
        ];
        for (final entry in roster) {
          final st = HiddenVolumeStorage.fromStore(
            MultiSpaceKvLogStore(backing, backing.openSpace(entry.spaceKeys)),
          );
          await st.saveProfile(UserProfile(displayName: entry.label));
        }
        final master = FakeHvContainer();
        final st = master.storage();
        await st.open(password: 'master-fixture', createIfMissing: true);
        await st.saveRoster(roster);
        await st.close();
        final c = ProviderContainer(
          overrides: [
            singleSpaceStorageProvider.overrideWith((ref) => master.storage()),
            deniableBootProvider.overrideWithValue(
              const DeniableBootConfig(
                runtimeDir: '/private/tmp/unused-selection',
                listenPort: 19000,
                storePath: '/private/tmp/unused-selection.store',
              ),
            ),
            sessionBuilderProvider.overrideWithValue(
              ({
                required storePath,
                required runtimeDir,
                required listenPort,
                required peersFor,
                obfs4Psk,
                required udpReflectors,
                required lazyMining,
                required proxy,
                required paddingPreset,
              }) => MultiIdentitySession(
                SyncWrappedAsyncMultiSpaceBacking(backing),
                runtimeDirBase: runtimeDir,
                listenPortBase: listenPort,
                boot: (spec, storage) async => IdentityNode(
                  transport: LoopbackTransport(),
                  dispose: () async {},
                ),
              ),
            ),
          ],
        );
        addTearDown(c.dispose);
        final ctrl = c.read(appControllerProvider.notifier);
        c.read(keepAllOnlineProvider);
        for (
          var i = 0;
          i < 100 &&
              c.read(appControllerProvider).phase == AppPhase.bootstrapping;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        await ctrl.unlock('master-fixture');
        await ctrl.switchIdentity('child-2');
        expect(c.read(activeIdentityProvider), 'child-2');
        expect(await ctrl.beginCompactionCollection(), isTrue);
        if (locked) await ctrl.lock();
        await ctrl.cancelCompactionCollection('master-fixture');
        expect(
          c.read(appControllerProvider).phase,
          locked ? AppPhase.locked : AppPhase.ready,
        );
        if (!locked) {
          expect(c.read(activeIdentityProvider), 'child-2');
          expect(
            (await c.read(storageProvider).loadProfile())!.displayName,
            'child-2',
          );
          await ctrl.lock();
        }
        await ctrl.unlock('master-fixture');
        // A later ordinary unlock must not inherit the maintenance selection.
        expect(c.read(activeIdentityProvider), 'child-1');
        await ctrl.lock();
      },
    );
  }
}
