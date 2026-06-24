import 'dart:io';

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

  test('wipeContainers clears onboarding and returns to onboarding', () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    await _settle(c);
    await ctrl.completeOnboarding(
        identity: AppController.generateIdentity(),
        password: 'pw',
        mode: StorageMode.hiddenSpace);
    expect(c.read(appControllerProvider).phase, AppPhase.ready);

    // No deniableBootProvider in tests → no on-disk file to delete; the wipe
    // still tears down, forgets the flag, and returns to onboarding.
    await ctrl.wipeContainers();
    expect(c.read(appControllerProvider).phase, AppPhase.onboarding);

    final c2 = ProviderContainer();
    addTearDown(c2.dispose);
    c2.read(appControllerProvider.notifier);
    await _settle(c2);
    expect(c2.read(appControllerProvider).phase, AppPhase.onboarding);
  });

  test('wipeContainers deletes the on-disk container file', () async {
    final dir = Directory.systemTemp.createTempSync('xveil_wipe_');
    final file = File('${dir.path}/test.store')..writeAsStringSync('container');
    try {
      SharedPreferences.setMockInitialValues({'onboarded': true});
      final container = FakeHvContainer();
      final app = container.storage();
      final c = ProviderContainer(overrides: [
        storageProvider.overrideWith((ref) => app),
        deniableBootProvider.overrideWithValue(
            DeniableBootConfig(runtimeDir: '/run', listenPort: 9000, storePath: file.path)),
      ]);
      addTearDown(c.dispose);
      final ctrl = c.read(appControllerProvider.notifier);
      await _settle(c);
      expect(file.existsSync(), isTrue);

      await ctrl.wipeContainers();
      expect(file.existsSync(), isFalse,
          reason: 'the container file must be permanently deleted');
      expect(c.read(appControllerProvider).phase, AppPhase.onboarding);
    } finally {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
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
    final aliceKeys = await child.exportSpaceKeys();
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

  test('lockout-prevention flow: onboard -> add identity -> lock -> EVERY '
      'password still opens (master picker + each identity directly)', () async {
    final container = FakeHvContainer();
    final app = container.storage();
    final c = ProviderContainer(
        overrides: [storageProvider.overrideWith((ref) => app)]);
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    await _settle(c);

    // Onboard the first identity (Personal / 111111).
    await ctrl.completeOnboarding(
        identity: AppController.generateIdentity(displayName: 'Personal'),
        password: '111111',
        mode: StorageMode.hiddenSpace);
    expect(c.read(appControllerProvider).phase, AppPhase.ready);

    // Add a second identity, converting to a master (master 000000, Work 222222).
    final ok = await ctrl.addIdentity(
        masterPassword: '000000',
        label: 'Work',
        password: '222222',
        existingLabel: 'Personal');
    expect(ok, isTrue);

    // The lockout bug made NONE of the passwords open after an add. Verify all
    // three still work across a lock cycle.
    await ctrl.lock();
    await ctrl.unlock('000000'); // master -> picker with BOTH identities
    expect(c.read(appControllerProvider).phase, AppPhase.pickingIdentity);
    expect(c.read(appControllerProvider).identities.toSet(),
        {'Personal', 'Work'});

    await ctrl.lock();
    await ctrl.unlock('111111'); // Personal's own password -> opens directly
    expect(c.read(appControllerProvider).phase, AppPhase.ready,
        reason: 'the original identity must still open by its own password');

    await ctrl.lock();
    await ctrl.unlock('222222'); // Work's own password -> opens directly
    expect(c.read(appControllerProvider).phase, AppPhase.ready,
        reason: 'the added identity must open by its own password');
  });

  test('switchIdentity swaps the active identity within a master session',
      () async {
    SharedPreferences.setMockInitialValues({'onboarded': true});
    final container = FakeHvContainer();

    final roster = <RosterEntry>[];
    for (final (label, pw, name) in [
      ('alice', 'pw-a', 'Alice'),
      ('bob', 'pw-b', 'Bob'),
    ]) {
      final child = container.storage();
      await child.open(password: pw, createIfMissing: true);
      await child.saveIdentity(AppController.generateIdentity(displayName: name));
      roster.add(RosterEntry(label: label, spaceKeys: await child.exportSpaceKeys()));
      await child.close();
    }
    final master = container.storage();
    await master.open(password: 'masterpw', createIfMissing: true);
    await master.saveRoster(roster);
    await master.close();

    final app = container.storage();
    final c = ProviderContainer(
        overrides: [storageProvider.overrideWith((ref) => app)]);
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    await _settle(c);

    await ctrl.unlock('masterpw');
    await ctrl.pickIdentity('alice');
    expect(c.read(appControllerProvider).identity!.displayName, 'Alice');
    expect(ctrl.activeIdentity, 'alice');

    await ctrl.switchIdentity('bob');
    final s = c.read(appControllerProvider);
    expect(s.phase, AppPhase.ready);
    expect(s.identity!.displayName, 'Bob');
    expect(ctrl.activeIdentity, 'bob');
  });

  test('addIdentity converts a single identity into a master and switches',
      () async {
    SharedPreferences.setMockInitialValues({'onboarded': true});
    final container = FakeHvContainer();
    final solo = container.storage();
    await solo.open(password: 'solopw', createIfMissing: true);
    await solo.saveIdentity(AppController.generateIdentity(displayName: 'Solo'));
    await solo.close();

    final app = container.storage();
    final c = ProviderContainer(
        overrides: [storageProvider.overrideWith((ref) => app)]);
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    await _settle(c);
    await ctrl.unlock('solopw');
    expect(c.read(appControllerProvider).isMaster, isFalse);

    final ok = await ctrl.addIdentity(
      masterPassword: 'masterpw',
      label: 'Work',
      password: 'workpw',
      existingLabel: 'Personal',
    );
    expect(ok, isTrue);
    final s = c.read(appControllerProvider);
    expect(s.phase, AppPhase.ready);
    expect(s.isMaster, isTrue);
    expect(s.identities, containsAll(['Personal', 'Work']));
    expect(ctrl.activeIdentity, 'Work');
    expect(s.identity!.displayName, 'Work');

    // The original identity is preserved as the 'Personal' child.
    await ctrl.switchIdentity('Personal');
    expect(c.read(appControllerProvider).identity!.displayName, 'Solo');
  });

  test('addIdentity appends to an existing master', () async {
    SharedPreferences.setMockInitialValues({'onboarded': true});
    final container = FakeHvContainer();
    final alice = container.storage();
    await alice.open(password: 'pw-alice', createIfMissing: true);
    await alice.saveIdentity(AppController.generateIdentity(displayName: 'Alice'));
    final aliceKeys = await alice.exportSpaceKeys();
    await alice.close();
    final master = container.storage();
    await master.open(password: 'masterpw', createIfMissing: true);
    await master.saveRoster([RosterEntry(label: 'alice', spaceKeys: aliceKeys)]);
    await master.close();

    final app = container.storage();
    final c = ProviderContainer(
        overrides: [storageProvider.overrideWith((ref) => app)]);
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    await _settle(c);
    await ctrl.unlock('masterpw');
    await ctrl.pickIdentity('alice');

    final ok = await ctrl.addIdentity(
        masterPassword: 'masterpw', label: 'work', password: 'pw-work');
    expect(ok, isTrue);
    final s = c.read(appControllerProvider);
    expect(s.identities, containsAll(['alice', 'work']));
    expect(ctrl.activeIdentity, 'work');
  });

  test('addIdentity rejects a duplicate label without corrupting the roster',
      () async {
    SharedPreferences.setMockInitialValues({'onboarded': true});
    final container = FakeHvContainer();
    final alice = container.storage();
    await alice.open(password: 'pw-alice', createIfMissing: true);
    await alice.saveIdentity(AppController.generateIdentity(displayName: 'Alice'));
    final aliceKeys = await alice.exportSpaceKeys();
    await alice.close();
    final master = container.storage();
    await master.open(password: 'masterpw', createIfMissing: true);
    await master
        .saveRoster([RosterEntry(label: 'alice', spaceKeys: aliceKeys)]);
    await master.close();

    final app = container.storage();
    final c = ProviderContainer(
        overrides: [storageProvider.overrideWith((ref) => app)]);
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    await _settle(c);
    await ctrl.unlock('masterpw');
    await ctrl.pickIdentity('alice');

    // A label that collides with an existing identity must be refused (a
    // duplicate label would break label-based switching) — and the guard fires
    // BEFORE any child space is created, so the roster is untouched.
    final ok = await ctrl.addIdentity(
        masterPassword: 'masterpw', label: 'alice', password: 'pw-other');
    expect(ok, isFalse);

    // A failed add must NOT strand the user: it tears the session down to edit
    // the master, so on failure it must recover to the previously-active
    // identity (ready, on alice — not stuck on a closed space or the lock screen).
    expect(ctrl.activeIdentity, 'alice');
    expect(c.read(appControllerProvider).phase, AppPhase.ready);

    await ctrl.lock();
    final check = container.storage();
    await check.open(password: 'masterpw');
    final labels = (await check.loadRoster())!.map((e) => e.label).toList();
    await check.close();
    expect(labels, ['alice'], reason: 'roster unchanged, no duplicate added');
  });

  test('unbindIdentity removes it from the master but leaves the space intact',
      () async {
    SharedPreferences.setMockInitialValues({'onboarded': true});
    final container = FakeHvContainer();
    final alice = container.storage();
    await alice.open(password: 'pw-alice', createIfMissing: true);
    await alice.saveIdentity(AppController.generateIdentity(displayName: 'Alice'));
    final aliceKeys = await alice.exportSpaceKeys();
    await alice.close();
    final bob = container.storage();
    await bob.open(password: 'pw-bob', createIfMissing: true);
    await bob.saveIdentity(AppController.generateIdentity(displayName: 'Bob'));
    final bobKeys = await bob.exportSpaceKeys();
    await bob.close();
    final master = container.storage();
    await master.open(password: 'masterpw', createIfMissing: true);
    await master.saveRoster([
      RosterEntry(label: 'alice', spaceKeys: aliceKeys),
      RosterEntry(label: 'bob', spaceKeys: bobKeys),
    ]);
    await master.close();

    final app = container.storage();
    final c = ProviderContainer(
        overrides: [storageProvider.overrideWith((ref) => app)]);
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    await _settle(c);
    await ctrl.unlock('masterpw');
    await ctrl.pickIdentity('alice');

    expect(await ctrl.unbindIdentity('bob'), isTrue);
    expect(ctrl.activeIdentity, 'alice'); // bob wasn't active; alice stays

    // Master roster no longer lists bob...
    await ctrl.lock();
    final check = container.storage();
    await check.open(password: 'masterpw');
    expect((await check.loadRoster())!.map((e) => e.label), ['alice']);
    await check.close();
    // ...but bob's SPACE is untouched: still opens by its own password.
    final bobAgain = container.storage();
    expect(await bobAgain.open(password: 'pw-bob'), isTrue);
    expect((await bobAgain.loadIdentity())?.displayName, 'Bob');
    await bobAgain.close();
  });

  test('deleteIdentity erases the space AND drops it from the master', () async {
    SharedPreferences.setMockInitialValues({'onboarded': true});
    final container = FakeHvContainer();
    final alice = container.storage();
    await alice.open(password: 'pw-alice', createIfMissing: true);
    await alice.saveIdentity(AppController.generateIdentity(displayName: 'Alice'));
    final aliceKeys = await alice.exportSpaceKeys();
    await alice.close();
    final bob = container.storage();
    await bob.open(password: 'pw-bob', createIfMissing: true);
    await bob.saveIdentity(AppController.generateIdentity(displayName: 'Bob'));
    final bobKeys = await bob.exportSpaceKeys();
    await bob.close();
    final master = container.storage();
    await master.open(password: 'masterpw', createIfMissing: true);
    await master.saveRoster([
      RosterEntry(label: 'alice', spaceKeys: aliceKeys),
      RosterEntry(label: 'bob', spaceKeys: bobKeys),
    ]);
    await master.close();

    final app = container.storage();
    final c = ProviderContainer(
        overrides: [storageProvider.overrideWith((ref) => app)]);
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    await _settle(c);
    await ctrl.unlock('masterpw');
    await ctrl.pickIdentity('alice');

    expect(await ctrl.deleteIdentity('bob'), isTrue);

    // Roster no longer lists bob...
    await ctrl.lock();
    final check = container.storage();
    await check.open(password: 'masterpw');
    expect((await check.loadRoster())!.map((e) => e.label), ['alice']);
    await check.close();
    // ...and bob's space DATA is erased (unlike unbind — opening finds nothing).
    final bobGone = container.storage();
    await bobGone.open(password: 'pw-bob');
    expect(await bobGone.loadIdentity(), isNull,
        reason: 'delete must forensically erase the identity, not just unlink');
    await bobGone.close();
  });

  test('bindExistingIdentity shares an existing identity space into the master',
      () async {
    SharedPreferences.setMockInitialValues({'onboarded': true});
    final container = FakeHvContainer();
    final alice = container.storage();
    await alice.open(password: 'pw-alice', createIfMissing: true);
    await alice.saveIdentity(AppController.generateIdentity(displayName: 'Alice'));
    final aliceKeys = await alice.exportSpaceKeys();
    await alice.close();
    // Carol exists as a standalone identity, not yet in any master.
    final carol = container.storage();
    await carol.open(password: 'pw-carol', createIfMissing: true);
    await carol.saveIdentity(AppController.generateIdentity(displayName: 'Carol'));
    await carol.close();
    final master = container.storage();
    await master.open(password: 'masterpw', createIfMissing: true);
    await master
        .saveRoster([RosterEntry(label: 'alice', spaceKeys: aliceKeys)]);
    await master.close();

    final app = container.storage();
    final c = ProviderContainer(
        overrides: [storageProvider.overrideWith((ref) => app)]);
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    await _settle(c);
    await ctrl.unlock('masterpw');
    await ctrl.pickIdentity('alice');

    // Wrong password → refused; the master itself → refused; duplicate label → refused.
    expect(
        await ctrl.bindExistingIdentity(identityPassword: 'nope', label: 'x'),
        isFalse);
    expect(
        await ctrl.bindExistingIdentity(
            identityPassword: 'masterpw', label: 'y'),
        isFalse);
    expect(
        await ctrl.bindExistingIdentity(
            identityPassword: 'pw-carol', label: 'alice'),
        isFalse);

    // Bind carol by her own password.
    expect(
        await ctrl.bindExistingIdentity(
            identityPassword: 'pw-carol', label: 'carol'),
        isTrue);

    await ctrl.lock();
    final check = container.storage();
    await check.open(password: 'masterpw');
    expect((await check.loadRoster())!.map((e) => e.label),
        containsAll(['alice', 'carol']));
    await check.close();
    // Carol's own space is untouched (shared, not moved).
    final carolAgain = container.storage();
    expect(await carolAgain.open(password: 'pw-carol'), isTrue);
    expect((await carolAgain.loadIdentity())?.displayName, 'Carol');
    await carolAgain.close();
  });

  test('unbindIdentity refuses to unbind the last identity', () async {
    SharedPreferences.setMockInitialValues({'onboarded': true});
    final container = FakeHvContainer();
    final alice = container.storage();
    await alice.open(password: 'pw-alice', createIfMissing: true);
    await alice.saveIdentity(AppController.generateIdentity(displayName: 'Alice'));
    final aliceKeys = await alice.exportSpaceKeys();
    await alice.close();
    final master = container.storage();
    await master.open(password: 'masterpw', createIfMissing: true);
    await master
        .saveRoster([RosterEntry(label: 'alice', spaceKeys: aliceKeys)]);
    await master.close();

    final app = container.storage();
    final c = ProviderContainer(
        overrides: [storageProvider.overrideWith((ref) => app)]);
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    await _settle(c);
    await ctrl.unlock('masterpw');
    await ctrl.pickIdentity('alice');

    expect(await ctrl.unbindIdentity('alice'), isFalse);
  });

  test('setIdentityAnonymous flips an identity flag and persists to the master',
      () async {
    SharedPreferences.setMockInitialValues({'onboarded': true});
    final container = FakeHvContainer();
    final alice = container.storage();
    await alice.open(password: 'pw-alice', createIfMissing: true);
    await alice.saveIdentity(AppController.generateIdentity(displayName: 'Alice'));
    final aliceKeys = await alice.exportSpaceKeys();
    await alice.close();
    final master = container.storage();
    await master.open(password: 'masterpw', createIfMissing: true);
    await master
        .saveRoster([RosterEntry(label: 'alice', spaceKeys: aliceKeys)]);
    await master.close();

    final app = container.storage();
    final c = ProviderContainer(
        overrides: [storageProvider.overrideWith((ref) => app)]);
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    await _settle(c);
    await ctrl.unlock('masterpw');
    await ctrl.pickIdentity('alice');
    expect(ctrl.isIdentityAnonymous('alice'), isFalse);

    // Toggle on (active identity) — reopens the master by its cached keys, no
    // password re-prompt, and reboots alice.
    expect(await ctrl.setIdentityAnonymous('alice', true), isTrue);
    expect(ctrl.isIdentityAnonymous('alice'), isTrue);

    // Persisted: a fresh master open sees the flag set.
    await ctrl.lock();
    final check = container.storage();
    await check.open(password: 'masterpw');
    final entry =
        (await check.loadRoster())!.firstWhere((e) => e.label == 'alice');
    await check.close();
    expect(entry.anonymous, isTrue);
  });

  test('addIdentity appends to the master ON-DISK roster even with a stale '
      'in-memory roster (regression: overwrite/lockout)', () async {
    SharedPreferences.setMockInitialValues({'onboarded': true});
    final container = FakeHvContainer();
    // Two identities already under the master, on disk.
    final alice = container.storage();
    await alice.open(password: 'pw-alice', createIfMissing: true);
    await alice.saveIdentity(AppController.generateIdentity(displayName: 'Alice'));
    final aliceKeys = await alice.exportSpaceKeys();
    await alice.close();
    final bob = container.storage();
    await bob.open(password: 'pw-bob', createIfMissing: true);
    await bob.saveIdentity(AppController.generateIdentity(displayName: 'Bob'));
    final bobKeys = await bob.exportSpaceKeys();
    await bob.close();
    final master = container.storage();
    await master.open(password: 'masterpw', createIfMissing: true);
    await master.saveRoster([
      RosterEntry(label: 'alice', spaceKeys: aliceKeys),
      RosterEntry(label: 'bob', spaceKeys: bobKeys),
    ]);
    await master.close();

    final app = container.storage();
    final c = ProviderContainer(
        overrides: [storageProvider.overrideWith((ref) => app)]);
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    await _settle(c);

    // Add 'work' WITHOUT unlocking first — _pendingRoster is null (maximally
    // stale). The OLD code rebuilt the roster from in-memory state and
    // OVERWROTE the master, dropping bob (and alice). The fix reads the master's
    // on-disk [alice, bob] and appends.
    final ok = await ctrl.addIdentity(
        masterPassword: 'masterpw', label: 'work', password: 'pw-work');
    expect(ok, isTrue);

    // Release the now-active 'work' space (it holds the exclusive lock) before
    // inspecting the master out of band.
    await ctrl.lock();
    final check = container.storage();
    await check.open(password: 'masterpw');
    final labels = (await check.loadRoster())!.map((e) => e.label).toList();
    await check.close();
    expect(labels, containsAll(['alice', 'bob', 'work']));
    expect(labels.length, 3, reason: 'no identity dropped from the master roster');
  });

  test('addIdentity fails (no corruption) if the master password collides '
      'with an identity', () async {
    SharedPreferences.setMockInitialValues({'onboarded': true});
    final container = FakeHvContainer();
    final solo = container.storage();
    await solo.open(password: 'solopw', createIfMissing: true);
    await solo.saveIdentity(AppController.generateIdentity(displayName: 'Solo'));
    await solo.close();

    final app = container.storage();
    final c = ProviderContainer(
        overrides: [storageProvider.overrideWith((ref) => app)]);
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    await _settle(c);
    await ctrl.unlock('solopw');

    // Master password == the existing identity's own password → clash.
    final ok = await ctrl.addIdentity(
        masterPassword: 'solopw', label: 'Work', password: 'workpw');
    expect(ok, isFalse);

    // The original identity is intact — re-unlock still opens single Solo.
    await ctrl.unlock('solopw');
    final s = c.read(appControllerProvider);
    expect(s.isMaster, isFalse);
    expect(s.identity!.displayName, 'Solo');
  });

  test('createDecoyMaster builds a duress master with only the shared identities',
      () async {
    SharedPreferences.setMockInitialValues({'onboarded': true});
    final container = FakeHvContainer();
    final roster = <RosterEntry>[];
    for (final (label, pw) in [('alice', 'pw-a'), ('bob', 'pw-b')]) {
      final ch = container.storage();
      await ch.open(password: pw, createIfMissing: true);
      await ch.saveIdentity(AppController.generateIdentity(displayName: label));
      roster.add(RosterEntry(label: label, spaceKeys: await ch.exportSpaceKeys()));
      await ch.close();
    }
    final m = container.storage();
    await m.open(password: 'masterpw', createIfMissing: true);
    await m.saveRoster(roster);
    await m.close();

    final app = container.storage();
    final c = ProviderContainer(
        overrides: [storageProvider.overrideWith((ref) => app)]);
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    await _settle(c);
    await ctrl.unlock('masterpw');
    await ctrl.pickIdentity('alice');

    final ok = await ctrl.createDecoyMaster(
        duressPassword: 'duresspw', includeLabels: ['bob']);
    expect(ok, isTrue);
    await ctrl.lock(); // release the active handle to inspect the container

    // The duress password opens a master listing ONLY the shared identity.
    final decoy = container.storage();
    expect(await decoy.open(password: 'duresspw'), isTrue);
    expect((await decoy.loadRoster())!.map((e) => e.label), ['bob']);
    await decoy.close();

    // The real master is untouched.
    final real = container.storage();
    await real.open(password: 'masterpw');
    expect((await real.loadRoster())!.map((e) => e.label), ['alice', 'bob']);
    await real.close();

    // DURESS PROTECTION (app flow): unlocking with the DURESS password lands on
    // a picker showing ONLY the decoy identity — the real master and the hidden
    // identity (alice) never surface. This is the decoy's entire purpose under
    // coercion, verified through the real unlock/master-detection path.
    await ctrl.unlock('duresspw');
    expect(c.read(appControllerProvider).phase, AppPhase.pickingIdentity);
    expect(c.read(appControllerProvider).identities, ['bob']);
  });

  test('createDecoyMaster refuses to overwrite the real master (clash)',
      () async {
    SharedPreferences.setMockInitialValues({'onboarded': true});
    final container = FakeHvContainer();
    final roster = <RosterEntry>[];
    for (final (label, pw) in [('alice', 'pw-a'), ('bob', 'pw-b')]) {
      final ch = container.storage();
      await ch.open(password: pw, createIfMissing: true);
      await ch.saveIdentity(AppController.generateIdentity(displayName: label));
      roster.add(RosterEntry(label: label, spaceKeys: await ch.exportSpaceKeys()));
      await ch.close();
    }
    final m = container.storage();
    await m.open(password: 'masterpw', createIfMissing: true);
    await m.saveRoster(roster);
    await m.close();

    final app = container.storage();
    final c = ProviderContainer(
        overrides: [storageProvider.overrideWith((ref) => app)]);
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    await _settle(c);
    await ctrl.unlock('masterpw');
    await ctrl.pickIdentity('alice');

    // Duress password == the real master password → would clobber it.
    final ok = await ctrl.createDecoyMaster(
        duressPassword: 'masterpw', includeLabels: ['bob']);
    expect(ok, isFalse);
    await ctrl.lock();

    final real = container.storage();
    await real.open(password: 'masterpw');
    expect((await real.loadRoster())!.map((e) => e.label), ['alice', 'bob']);
    await real.close();
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
