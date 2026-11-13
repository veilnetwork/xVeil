import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/storage/multi_space_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/domain/storage_locator.dart';
import 'package:xveil/domain/storage_protection.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/multi_identity_session.dart';
import 'package:xveil/state/providers.dart';

import 'support/fake_hv_container.dart';
import 'support/fake_multi_space.dart';

class _RetrySession extends MultiIdentitySession {
  _RetrySession()
    : super(
        SyncWrappedAsyncMultiSpaceBacking(FakeMultiSpaceBacking()),
        runtimeDirBase: '/synthetic',
        listenPortBase: 19000,
      );
  bool allowClose = false;
  int closes = 0;
  @override
  Future<void> disposeAll() async {
    closes++;
  }

  @override
  bool get containerLockReleased => allowClose;
}

void main() {
  test(
    'legacy attestation cleanup never probes a managed credential',
    () async {
      SharedPreferences.setMockInitialValues({});
      var probes = 0;
      final storage = HiddenVolumeStorage(
        ({required password, required create}) => null,
        keysOpener: (_) {
          probes++;
          throw StateError('unexpected legacy probe');
        },
      );
      final c = ProviderContainer(
        overrides: [singleSpaceStorageProvider.overrideWithValue(storage)],
      );
      addTearDown(c.dispose);
      final controller = c.read(appControllerProvider.notifier);
      await c.read(prefsProvider.future);
      await Future<void>.delayed(Duration.zero);
      final unresolved = await controller.revokeAutoCompactAcross([
        for (final protection in [
          StorageProtection.encrypted,
          StorageProtection.unencrypted,
        ])
          RosterEntry(
            label: protection.name,
            spaceKeys: Uint8List(64),
            storageLocator: ManagedStorageLocator(
              id: ManagedIdentityId('a' * 32),
              protection: protection,
            ),
          ),
      ]);
      expect(unresolved, isEmpty);
      expect(probes, 0);
    },
  );
  test(
    'lock retains an unreleased session and unlock drains it before any store open',
    () async {
      SharedPreferences.setMockInitialValues({'onboarded': true});
      final container = FakeHvContainer();
      final seed = container.storage();
      expect(
        await seed.open(password: 'fixture password', createIfMissing: true),
        isTrue,
      );
      await seed.saveProfile(
        const UserProfile(displayName: 'Synthetic fixture'),
      );
      await seed.close();
      var opens = 0;
      // Count physical opener requests independently of the session-close counter.
      final facade = HiddenVolumeStorage(({
        required password,
        required create,
      }) {
        opens++;
        return container.passwordOpener(password: password, create: create);
      }, keysOpener: container.keysOpener);
      final c = ProviderContainer(
        overrides: [singleSpaceStorageProvider.overrideWithValue(facade)],
      );
      addTearDown(() async {
        await facade.close();
        c.dispose();
      });
      final controller = c.read(appControllerProvider.notifier);
      await c.read(prefsProvider.future);
      await Future<void>.delayed(Duration.zero);
      final session = _RetrySession();
      c.read(sessionProvider.notifier).state = session;
      await controller.lock();
      expect(session.closes, 1);
      expect(
        controller.lastTeardown.incomplete,
        contains('container-lock-unknown'),
      );
      await controller.unlock('fixture password');
      expect(session.closes, 2);
      expect(
        opens,
        0,
        reason: 'an unreleased native owner must block new storage acquisition',
      );
      expect(c.read(appControllerProvider).unlockError, isTrue);
      session.allowClose = true;
      await controller.unlock('fixture password');
      expect(session.closes, 3);
      expect(opens, 1);
      expect(facade.isOpen, isTrue);
    },
  );
}
