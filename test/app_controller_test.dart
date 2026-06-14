import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/state/app_controller.dart';

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
}
