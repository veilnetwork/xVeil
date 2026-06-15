import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/providers.dart';

import 'support/fake_hv_container.dart';

Future<void> _settle(ProviderContainer c) async {
  for (var i = 0;
      i < 20 && c.read(appControllerProvider).phase == AppPhase.bootstrapping;
      i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('first run lands on onboarding; completes into a ready session',
      () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    await _settle(c);
    expect(c.read(appControllerProvider).phase, AppPhase.onboarding);

    final id = AppController.generateIdentity(displayName: 'Me');
    await ctrl.completeOnboarding(
      identity: id,
      password: 'pw',
      mode: StorageMode.hiddenSpace,
    );
    final s = c.read(appControllerProvider);
    expect(s.phase, AppPhase.ready);
    // Loopback (no real stack): the onboarding identity is preserved.
    expect(s.identity!.nodeId, id.nodeId);
    expect(s.identity!.displayName, 'Me');
  });

  test('lock then unlock with the right password restores the session',
      () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    await _settle(c);

    final id = AppController.generateIdentity();
    await ctrl.completeOnboarding(
        identity: id, password: 'pw', mode: StorageMode.hiddenSpace);
    await ctrl.lock();
    expect(c.read(appControllerProvider).phase, AppPhase.locked);

    await ctrl.unlock('pw');
    expect(c.read(appControllerProvider).phase, AppPhase.ready);
  });

  test('startOver clears onboarding and returns to onboarding', () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    await _settle(c);
    await ctrl.completeOnboarding(
        identity: AppController.generateIdentity(),
        password: 'pw',
        mode: StorageMode.hiddenSpace);
    expect(c.read(appControllerProvider).phase, AppPhase.ready);

    await ctrl.startOver();
    expect(c.read(appControllerProvider).phase, AppPhase.onboarding);

    // A fresh controller now boots to onboarding (the flag was cleared).
    final c2 = ProviderContainer();
    addTearDown(c2.dispose);
    c2.read(appControllerProvider.notifier);
    await _settle(c2);
    expect(c2.read(appControllerProvider).phase, AppPhase.onboarding);
  });

  test('unlock with an empty password reports an error', () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    await _settle(c);

    await ctrl.unlock('');
    expect(c.read(appControllerProvider).unlockError, isTrue);
    expect(c.read(appControllerProvider).phase, isNot(AppPhase.ready));
  });

  test('unlocking a MASTER lands on the picker, then a pick enters the session',
      () async {
    SharedPreferences.setMockInitialValues({'onboarded': true});
    final container = FakeHvContainer();

    // Seed a child identity space, then a master whose roster points at it.
    final aliceId = AppController.generateIdentity(displayName: 'Alice');
    final child = container.storage();
    await child.open(password: 'childpw', createIfMissing: true);
    await child.saveIdentity(aliceId);
    final aliceKeys = child.exportSpaceKeys();
    await child.close();

    final master = container.storage();
    await master.open(password: 'masterpw', createIfMissing: true);
    await master.saveRoster([RosterEntry(label: 'alice', spaceKeys: aliceKeys)]);
    await master.close();

    final app = container.storage(); // the app's single storage handle
    final c = ProviderContainer(
        overrides: [storageProvider.overrideWith((ref) => app)]);
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    await _settle(c);
    expect(c.read(appControllerProvider).phase, AppPhase.locked);

    await ctrl.unlock('masterpw');
    final picking = c.read(appControllerProvider);
    expect(picking.phase, AppPhase.pickingIdentity);
    expect(picking.identities, ['alice']);

    await ctrl.pickIdentity('alice');
    final ready = c.read(appControllerProvider);
    expect(ready.phase, AppPhase.ready);
    expect(ready.identity!.displayName, 'Alice');
  });

  test('a single-identity space unlocks straight to ready (no picker)',
      () async {
    SharedPreferences.setMockInitialValues({'onboarded': true});
    final container = FakeHvContainer();

    final soloId = AppController.generateIdentity(displayName: 'Solo');
    final seed = container.storage();
    await seed.open(password: 'pw', createIfMissing: true);
    await seed.saveIdentity(soloId);
    await seed.close();

    final app = container.storage();
    final c = ProviderContainer(
        overrides: [storageProvider.overrideWith((ref) => app)]);
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    await _settle(c);

    await ctrl.unlock('pw');
    final s = c.read(appControllerProvider);
    expect(s.phase, AppPhase.ready); // skipped the picker entirely
    expect(s.identity!.displayName, 'Solo');
  });
}
