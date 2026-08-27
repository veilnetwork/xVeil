import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/core/error_journal.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/on_disk_blob_store.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/data/vpn/vpn_backend.dart';
import 'package:xveil/data/vpn/vpn_routing_policy.dart';
import 'package:xveil/data/transport/bootstrap_invite.dart';
import 'package:xveil/data/node/fake_node_controller.dart';
import 'package:xveil/data/veil_stack.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/p2p_policy.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/data/whisper_model_store.dart';
import 'package:xveil/state/whisper_model_controller.dart';
import 'package:xveil/state/voice_record_controller.dart';
import 'package:xveil/state/vpn_controller.dart';
import 'package:xveil/state/identity_scoped_prefs.dart';
import 'package:xveil/state/messaging.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/translation_model_controller.dart';

import 'support/fake_hv_container.dart';

Future<void> _settle(ProviderContainer c) async {
  for (
    var i = 0;
    i < 20 && c.read(appControllerProvider).phase == AppPhase.bootstrapping;
    i++
  ) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  _p2pPolicyTests();
  _keyWipeOnLockTests();
  _nodeIdSourceOfTruthTests();
  _damagedIdentityTests();
  _onboardingOpenFailureTests();
  _runtimeBaseTeardownTests();
  _wipeRemovesBlobsTests();
  _lockAlwaysCompletesTests();
  _wipeClearsPostureTests();
  _vpnTeardownIsJournalledTests();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    errorJournal.clear();
  });

  test(
    'lean storage padding is enabled by default and can be disabled',
    () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctrl = c.read(appControllerProvider.notifier);
      await _settle(c);

      expect(await ctrl.leanStoragePaddingEnabled(), isTrue);
      await ctrl.setLeanStoragePaddingEnabled(false);
      expect(await ctrl.leanStoragePaddingEnabled(), isFalse);
      await ctrl.setLeanStoragePaddingEnabled(true);
      expect(await ctrl.leanStoragePaddingEnabled(), isTrue);
    },
  );

  test(
    'first run lands on onboarding; completes into a ready session',
    () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctrl = c.read(appControllerProvider.notifier);
      await _settle(c);
      expect(c.read(appControllerProvider).phase, AppPhase.onboarding);

      await ctrl.completeOnboarding(
        displayName: 'Me',
        password: 'pw',
        mode: StorageMode.hiddenSpace,
      );
      final s = c.read(appControllerProvider);
      expect(s.phase, AppPhase.ready);
      // The name the person typed is theirs; the node id is the TRANSPORT's
      // (audit XV-06). Onboarding no longer invents one, so with no real stack
      // this is the loopback stand-in's obviously-fake id — not a random value
      // that would then disagree with the node forever.
      expect(s.identity!.displayName, 'Me');
      expect(s.identity!.nodeId, await c.read(veilTransportProvider).nodeId());
    },
  );

  test('the onboarding recovery phrase can only be read once', () async {
    // Audit X-02. The phrase used to be cleared AFTER the node boot it was
    // handed to — so a boot that threw left it in the controller, and the next
    // unlock of a DIFFERENT legacy or decoy identity consumed it and derived
    // the same node identity. Two spaces that must not know about each other
    // would then share one identity on the wire.
    //
    // There is no longer a way to read it without spending it, which is the
    // property that makes the ordering irrelevant.
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    await _settle(c);

    await ctrl.completeOnboarding(
      displayName: 'Me',
      password: 'pw',
      mode: StorageMode.hiddenSpace,
      identityPhrase: 'correct horse battery staple',
    );

    expect(ctrl.takePendingIdentityPhrase(), 'correct horse battery staple');
    expect(
      ctrl.takePendingIdentityPhrase(),
      isNull,
      reason: 'a second consumer must not be able to reuse it',
    );
  });

  test('locking discards a phrase no node boot consumed', () async {
    // The user finished onboarding and locked before the stack came up. The
    // next unlock may be an entirely different identity.
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    await _settle(c);

    await ctrl.completeOnboarding(
      displayName: 'Me',
      password: 'pw',
      mode: StorageMode.hiddenSpace,
      identityPhrase: 'correct horse battery staple',
    );
    await ctrl.lock();

    expect(ctrl.takePendingIdentityPhrase(), isNull);
  });

  test(
    'lock then unlock with the right password restores the session',
    () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctrl = c.read(appControllerProvider.notifier);
      await _settle(c);

      await ctrl.completeOnboarding(
        password: 'pw',
        mode: StorageMode.hiddenSpace,
      );
      await ctrl.lock();
      expect(c.read(appControllerProvider).phase, AppPhase.locked);

      await ctrl.unlock('pw');
      expect(c.read(appControllerProvider).phase, AppPhase.ready);
    },
  );

  test(
    'eager conversations listener stays idle while locked and reloads on unlock',
    () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctrl = c.read(appControllerProvider.notifier);
      await _settle(c);

      await ctrl.completeOnboarding(
        password: 'pw',
        mode: StorageMode.hiddenSpace,
      );
      await ctrl.lock();
      expect(c.read(appControllerProvider).phase, AppPhase.locked);

      final values = <AsyncValue<List<Conversation>>>[];
      final sub = c.listen(
        conversationsProvider,
        (_, next) => values.add(next),
        fireImmediately: true,
      );
      addTearDown(sub.close);
      await Future<void>.delayed(Duration.zero);

      expect(values.whereType<AsyncError<List<Conversation>>>(), isEmpty);
      expect(
        values.whereType<AsyncData<List<Conversation>>>().last.value,
        isEmpty,
      );

      await ctrl.unlock('pw');
      for (
        var i = 0;
        i < 20 && values.whereType<AsyncData<List<Conversation>>>().length < 2;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(c.read(appControllerProvider).phase, AppPhase.ready);
      expect(values.whereType<AsyncError<List<Conversation>>>(), isEmpty);
      expect(
        values.whereType<AsyncData<List<Conversation>>>().length,
        greaterThanOrEqualTo(2),
      );
    },
  );

  test('startOver clears onboarding and returns to onboarding', () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    await _settle(c);
    await ctrl.completeOnboarding(
      password: 'pw',
      mode: StorageMode.hiddenSpace,
    );
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
      password: 'pw',
      mode: StorageMode.hiddenSpace,
    );
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

  test(
    'a container that could not be deleted is NOT reported as wiped',
    () async {
      // audit report11 XV-H3. Every step of the wipe is best-effort by design —
      // aborting halfway would leave MORE behind than carrying on. What was
      // wrong is that the silence was total: the phase flipped to onboarding
      // unconditionally, the function returned nothing, and a person whose
      // container was still on disk saw the same screen as one whose container
      // was gone. In an app whose whole promise is deniability, that is the
      // worst direction for a lie to point.
      final dir = Directory.systemTemp.createTempSync('xveil_wipe_locked_');
      final file = File('${dir.path}/test.store')
        ..writeAsStringSync('container');
      try {
        // Make the DIRECTORY unwritable: the file itself stays readable, but the
        // unlink cannot happen. This is what a read-only volume, an ACL drift or
        // a backup agent holding the directory looks like from here.
        Process.runSync('chmod', ['a-w', dir.path]);
        SharedPreferences.setMockInitialValues({'onboarded': true});
        final container = FakeHvContainer();
        final c = ProviderContainer(
          overrides: [
            storageProvider.overrideWith((ref) => container.storage()),
            deniableBootProvider.overrideWithValue(
              DeniableBootConfig(
                runtimeDir: '/run',
                listenPort: 9000,
                storePath: file.path,
              ),
            ),
          ],
        );
        addTearDown(c.dispose);
        final ctrl = c.read(appControllerProvider.notifier);
        await _settle(c);

        final remaining = await ctrl.wipeContainers();

        // Checked by LOOKING. `delete()` returning without throwing is not the
        // same as the file being gone, and this is the assertion the fix exists
        // for: it cannot pass while the wipe reports success unconditionally.
        expect(file.existsSync(), isTrue, reason: 'precondition: it survived');
        expect(
          remaining,
          contains('container'),
          reason: 'a wipe that could not delete the container must say so',
        );
        // The phase still flips, deliberately: parking a person on a lock screen
        // for a container that may already be gone is its own disclosure. This
        // assertion is a GUARD — it stays green with the fix removed.
        expect(c.read(appControllerProvider).phase, AppPhase.onboarding);
      } finally {
        Process.runSync('chmod', ['u+w', dir.path]);
        dir.deleteSync(recursive: true);
      }
    },
    testOn: '!windows',
  );

  test('a wipe that removes everything reports nothing left', () async {
    // The positive control. Without it, "reports what survived" would also be
    // satisfied by a function that names the container every single time.
    final dir = Directory.systemTemp.createTempSync('xveil_wipe_ok_');
    final file = File('${dir.path}/test.store')..writeAsStringSync('container');
    try {
      SharedPreferences.setMockInitialValues({'onboarded': true});
      final container = FakeHvContainer();
      final c = ProviderContainer(
        overrides: [
          storageProvider.overrideWith((ref) => container.storage()),
          // The tunnel is a leg of the wipe like the two model roots below,
          // and for the same reason it has to be ANSWERABLE here: the real
          // backend reaches a platform channel a test binary has no handler
          // for, the stop cannot return, and the wipe now says so — correctly.
          // Overriding it is what makes this a control for a complete wipe
          // rather than for an unreachable plugin (report17 XV17-M14).
          vpnBackendProvider.overrideWithValue(_SilentVpnBackend()),
          // Both model roots have to be RESOLVABLE here, or this control is
          // asserting the wrong thing. Without them the real store reaches
          // `path_provider`, which a test binary has no answer for, and the
          // wipe now says so — correctly: a root it could not resolve is a
          // place it did not look, and "nothing left" would be a claim about
          // it. Overriding them is what makes this a test of a COMPLETE wipe
          // rather than of an unanswerable platform channel.
          whisperModelStoreProvider.overrideWithValue(
            WhisperModelStore(supportDirectory: () async => dir),
          ),
          translationModelsRootProvider.overrideWithValue(
            () async => Directory('${dir.path}/translations'),
          ),
          deniableBootProvider.overrideWithValue(
            DeniableBootConfig(
              runtimeDir: '/run',
              listenPort: 9000,
              storePath: file.path,
            ),
          ),
        ],
      );
      addTearDown(c.dispose);
      final ctrl = c.read(appControllerProvider.notifier);
      await _settle(c);
      expect(await ctrl.wipeContainers(), isEmpty);
      expect(file.existsSync(), isFalse);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('wipeContainers deletes the on-disk container file', () async {
    final dir = Directory.systemTemp.createTempSync('xveil_wipe_');
    final file = File('${dir.path}/test.store')..writeAsStringSync('container');
    try {
      SharedPreferences.setMockInitialValues({'onboarded': true});
      final container = FakeHvContainer();
      final app = container.storage();
      final c = ProviderContainer(
        overrides: [
          storageProvider.overrideWith((ref) => app),
          deniableBootProvider.overrideWithValue(
            DeniableBootConfig(
              runtimeDir: '/run',
              listenPort: 9000,
              storePath: file.path,
            ),
          ),
        ],
      );
      addTearDown(c.dispose);
      final ctrl = c.read(appControllerProvider.notifier);
      await _settle(c);
      expect(file.existsSync(), isTrue);

      await ctrl.wipeContainers();
      expect(
        file.existsSync(),
        isFalse,
        reason: 'the container file must be permanently deleted',
      );
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

  test(
    'unlocking a MASTER lands on the picker, then a pick enters the session',
    () async {
      SharedPreferences.setMockInitialValues({'onboarded': true});
      final container = FakeHvContainer();

      // Seed a child identity space, then a master whose roster points at it.
      const aliceProfile = UserProfile(displayName: 'Alice');
      final child = container.storage();
      await child.open(password: 'childpw', createIfMissing: true);
      await child.saveProfile(aliceProfile);
      final aliceKeys = await child.exportSpaceKeys();
      await child.close();

      final master = container.storage();
      await master.open(password: 'masterpw', createIfMissing: true);
      await master.saveRoster([
        RosterEntry(label: 'alice', spaceKeys: aliceKeys),
      ]);
      await master.close();

      final app = container.storage(); // the app's single storage handle
      final c = ProviderContainer(
        overrides: [storageProvider.overrideWith((ref) => app)],
      );
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
    },
  );

  test('lockout-prevention flow: onboard -> add identity -> lock -> EVERY '
      'password still opens (master picker + each identity directly)', () async {
    final container = FakeHvContainer();
    final app = container.storage();
    final c = ProviderContainer(
      overrides: [storageProvider.overrideWith((ref) => app)],
    );
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    await _settle(c);

    // Onboard the first identity (Personal / 111111).
    await ctrl.completeOnboarding(
      displayName: 'Personal',
      password: '111111',
      mode: StorageMode.hiddenSpace,
    );
    expect(c.read(appControllerProvider).phase, AppPhase.ready);

    // Add a second identity, converting to a master (master 000000, Work 222222).
    final ok = await ctrl.addIdentity(
      masterPassword: '000000',
      label: 'Work',
      password: '222222',
      existingLabel: 'Personal',
    );
    expect(ok, isTrue);

    // The lockout bug made NONE of the passwords open after an add. Verify all
    // three still work across a lock cycle.
    await ctrl.lock();
    await ctrl.unlock('000000'); // master -> picker with BOTH identities
    expect(c.read(appControllerProvider).phase, AppPhase.pickingIdentity);
    expect(c.read(appControllerProvider).identities.toSet(), {
      'Personal',
      'Work',
    });

    await ctrl.lock();
    await ctrl.unlock('111111'); // Personal's own password -> opens directly
    expect(
      c.read(appControllerProvider).phase,
      AppPhase.ready,
      reason: 'the original identity must still open by its own password',
    );

    await ctrl.lock();
    await ctrl.unlock('222222'); // Work's own password -> opens directly
    expect(
      c.read(appControllerProvider).phase,
      AppPhase.ready,
      reason: 'the added identity must open by its own password',
    );
  });

  test(
    'switchIdentity swaps the active identity within a master session',
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
        await child.saveProfile(UserProfile(displayName: name));
        roster.add(
          RosterEntry(label: label, spaceKeys: await child.exportSpaceKeys()),
        );
        await child.close();
      }
      final master = container.storage();
      await master.open(password: 'masterpw', createIfMissing: true);
      await master.saveRoster(roster);
      await master.close();

      final app = container.storage();
      final c = ProviderContainer(
        overrides: [storageProvider.overrideWith((ref) => app)],
      );
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
    },
  );

  test(
    'addIdentity converts a single identity into a master and switches',
    () async {
      SharedPreferences.setMockInitialValues({'onboarded': true});
      final container = FakeHvContainer();
      final solo = container.storage();
      await solo.open(password: 'solopw', createIfMissing: true);
      await solo.saveProfile(UserProfile(displayName: 'Solo'));
      await solo.close();

      final app = container.storage();
      final c = ProviderContainer(
        overrides: [storageProvider.overrideWith((ref) => app)],
      );
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
    },
  );

  test('addIdentity appends to an existing master', () async {
    SharedPreferences.setMockInitialValues({'onboarded': true});
    final container = FakeHvContainer();
    final alice = container.storage();
    await alice.open(password: 'pw-alice', createIfMissing: true);
    await alice.saveProfile(UserProfile(displayName: 'Alice'));
    final aliceKeys = await alice.exportSpaceKeys();
    await alice.close();
    final master = container.storage();
    await master.open(password: 'masterpw', createIfMissing: true);
    await master.saveRoster([
      RosterEntry(label: 'alice', spaceKeys: aliceKeys),
    ]);
    await master.close();

    final app = container.storage();
    final c = ProviderContainer(
      overrides: [storageProvider.overrideWith((ref) => app)],
    );
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    await _settle(c);
    await ctrl.unlock('masterpw');
    await ctrl.pickIdentity('alice');

    final ok = await ctrl.addIdentity(
      masterPassword: 'masterpw',
      label: 'work',
      password: 'pw-work',
    );
    expect(ok, isTrue);
    final s = c.read(appControllerProvider);
    expect(s.identities, containsAll(['alice', 'work']));
    expect(ctrl.activeIdentity, 'work');
  });

  test(
    'addIdentity rejects a duplicate label without corrupting the roster',
    () async {
      SharedPreferences.setMockInitialValues({'onboarded': true});
      final container = FakeHvContainer();
      final alice = container.storage();
      await alice.open(password: 'pw-alice', createIfMissing: true);
      await alice.saveProfile(UserProfile(displayName: 'Alice'));
      final aliceKeys = await alice.exportSpaceKeys();
      await alice.close();
      final master = container.storage();
      await master.open(password: 'masterpw', createIfMissing: true);
      await master.saveRoster([
        RosterEntry(label: 'alice', spaceKeys: aliceKeys),
      ]);
      await master.close();

      final app = container.storage();
      final c = ProviderContainer(
        overrides: [storageProvider.overrideWith((ref) => app)],
      );
      addTearDown(c.dispose);
      final ctrl = c.read(appControllerProvider.notifier);
      await _settle(c);
      await ctrl.unlock('masterpw');
      await ctrl.pickIdentity('alice');

      // A label that collides with an existing identity must be refused (a
      // duplicate label would break label-based switching) — and the guard fires
      // BEFORE any child space is created, so the roster is untouched.
      final ok = await ctrl.addIdentity(
        masterPassword: 'masterpw',
        label: 'alice',
        password: 'pw-other',
      );
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
    },
  );

  test(
    'unbindIdentity removes it from the master but leaves the space intact',
    () async {
      SharedPreferences.setMockInitialValues({'onboarded': true});
      final container = FakeHvContainer();
      final alice = container.storage();
      await alice.open(password: 'pw-alice', createIfMissing: true);
      await alice.saveProfile(UserProfile(displayName: 'Alice'));
      final aliceKeys = await alice.exportSpaceKeys();
      await alice.close();
      final bob = container.storage();
      await bob.open(password: 'pw-bob', createIfMissing: true);
      await bob.saveProfile(UserProfile(displayName: 'Bob'));
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
        overrides: [storageProvider.overrideWith((ref) => app)],
      );
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
      expect((await bobAgain.loadProfile())?.displayName, 'Bob');
      await bobAgain.close();
    },
  );

  test('deleteIdentity erases the space AND drops it from the master', () async {
    SharedPreferences.setMockInitialValues({'onboarded': true});
    final container = FakeHvContainer();
    final alice = container.storage();
    await alice.open(password: 'pw-alice', createIfMissing: true);
    await alice.saveProfile(UserProfile(displayName: 'Alice'));
    final aliceKeys = await alice.exportSpaceKeys();
    await alice.close();
    final bob = container.storage();
    await bob.open(password: 'pw-bob', createIfMissing: true);
    await bob.saveProfile(UserProfile(displayName: 'Bob'));
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
      overrides: [storageProvider.overrideWith((ref) => app)],
    );
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
    expect(
      await bobGone.loadProfile(),
      isNull,
      reason: 'delete must forensically erase the identity, not just unlink',
    );
    await bobGone.close();
  });

  test(
    'bindExistingIdentity shares an existing identity space into the master',
    () async {
      SharedPreferences.setMockInitialValues({'onboarded': true});
      final container = FakeHvContainer();
      final alice = container.storage();
      await alice.open(password: 'pw-alice', createIfMissing: true);
      await alice.saveProfile(UserProfile(displayName: 'Alice'));
      final aliceKeys = await alice.exportSpaceKeys();
      await alice.close();
      // Carol exists as a standalone identity, not yet in any master.
      final carol = container.storage();
      await carol.open(password: 'pw-carol', createIfMissing: true);
      await carol.saveProfile(UserProfile(displayName: 'Carol'));
      await carol.close();
      final master = container.storage();
      await master.open(password: 'masterpw', createIfMissing: true);
      await master.saveRoster([
        RosterEntry(label: 'alice', spaceKeys: aliceKeys),
      ]);
      await master.close();

      final app = container.storage();
      final c = ProviderContainer(
        overrides: [storageProvider.overrideWith((ref) => app)],
      );
      addTearDown(c.dispose);
      final ctrl = c.read(appControllerProvider.notifier);
      await _settle(c);
      await ctrl.unlock('masterpw');
      await ctrl.pickIdentity('alice');

      // Wrong password → refused; the master itself → refused; duplicate label → refused.
      expect(
        await ctrl.bindExistingIdentity(identityPassword: 'nope', label: 'x'),
        isFalse,
      );
      expect(
        await ctrl.bindExistingIdentity(
          identityPassword: 'masterpw',
          label: 'y',
        ),
        isFalse,
      );
      expect(
        await ctrl.bindExistingIdentity(
          identityPassword: 'pw-carol',
          label: 'alice',
        ),
        isFalse,
      );

      // Bind carol by her own password.
      expect(
        await ctrl.bindExistingIdentity(
          identityPassword: 'pw-carol',
          label: 'carol',
        ),
        isTrue,
      );

      await ctrl.lock();
      final check = container.storage();
      await check.open(password: 'masterpw');
      expect(
        (await check.loadRoster())!.map((e) => e.label),
        containsAll(['alice', 'carol']),
      );
      await check.close();
      // Carol's own space is untouched (shared, not moved).
      final carolAgain = container.storage();
      expect(await carolAgain.open(password: 'pw-carol'), isTrue);
      expect((await carolAgain.loadProfile())?.displayName, 'Carol');
      await carolAgain.close();
    },
  );

  test('unbindIdentity refuses to unbind the last identity', () async {
    SharedPreferences.setMockInitialValues({'onboarded': true});
    final container = FakeHvContainer();
    final alice = container.storage();
    await alice.open(password: 'pw-alice', createIfMissing: true);
    await alice.saveProfile(UserProfile(displayName: 'Alice'));
    final aliceKeys = await alice.exportSpaceKeys();
    await alice.close();
    final master = container.storage();
    await master.open(password: 'masterpw', createIfMissing: true);
    await master.saveRoster([
      RosterEntry(label: 'alice', spaceKeys: aliceKeys),
    ]);
    await master.close();

    final app = container.storage();
    final c = ProviderContainer(
      overrides: [storageProvider.overrideWith((ref) => app)],
    );
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    await _settle(c);
    await ctrl.unlock('masterpw');
    await ctrl.pickIdentity('alice');

    expect(await ctrl.unbindIdentity('alice'), isFalse);
  });

  test(
    'setIdentityAnonymous flips an identity flag and persists to the master',
    () async {
      SharedPreferences.setMockInitialValues({'onboarded': true});
      final container = FakeHvContainer();
      final alice = container.storage();
      await alice.open(password: 'pw-alice', createIfMissing: true);
      await alice.saveProfile(UserProfile(displayName: 'Alice'));
      final aliceKeys = await alice.exportSpaceKeys();
      await alice.close();
      final master = container.storage();
      await master.open(password: 'masterpw', createIfMissing: true);
      await master.saveRoster([
        RosterEntry(label: 'alice', spaceKeys: aliceKeys),
      ]);
      await master.close();

      final app = container.storage();
      final c = ProviderContainer(
        overrides: [storageProvider.overrideWith((ref) => app)],
      );
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
      final entry = (await check.loadRoster())!.firstWhere(
        (e) => e.label == 'alice',
      );
      await check.close();
      expect(entry.anonymous, isTrue);
    },
  );

  test('addIdentity appends to the master ON-DISK roster even with a stale '
      'in-memory roster (regression: overwrite/lockout)', () async {
    SharedPreferences.setMockInitialValues({'onboarded': true});
    final container = FakeHvContainer();
    // Two identities already under the master, on disk.
    final alice = container.storage();
    await alice.open(password: 'pw-alice', createIfMissing: true);
    await alice.saveProfile(UserProfile(displayName: 'Alice'));
    final aliceKeys = await alice.exportSpaceKeys();
    await alice.close();
    final bob = container.storage();
    await bob.open(password: 'pw-bob', createIfMissing: true);
    await bob.saveProfile(UserProfile(displayName: 'Bob'));
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
      overrides: [storageProvider.overrideWith((ref) => app)],
    );
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    await _settle(c);

    // Add 'work' WITHOUT unlocking first — _pendingRoster is null (maximally
    // stale). The OLD code rebuilt the roster from in-memory state and
    // OVERWROTE the master, dropping bob (and alice). The fix reads the master's
    // on-disk [alice, bob] and appends.
    final ok = await ctrl.addIdentity(
      masterPassword: 'masterpw',
      label: 'work',
      password: 'pw-work',
    );
    expect(ok, isTrue);

    // Release the now-active 'work' space (it holds the exclusive lock) before
    // inspecting the master out of band.
    await ctrl.lock();
    final check = container.storage();
    await check.open(password: 'masterpw');
    final labels = (await check.loadRoster())!.map((e) => e.label).toList();
    await check.close();
    expect(labels, containsAll(['alice', 'bob', 'work']));
    expect(
      labels.length,
      3,
      reason: 'no identity dropped from the master roster',
    );
  });

  test('addIdentity fails (no corruption) if the master password collides '
      'with an identity', () async {
    SharedPreferences.setMockInitialValues({'onboarded': true});
    final container = FakeHvContainer();
    final solo = container.storage();
    await solo.open(password: 'solopw', createIfMissing: true);
    await solo.saveProfile(UserProfile(displayName: 'Solo'));
    await solo.close();

    final app = container.storage();
    final c = ProviderContainer(
      overrides: [storageProvider.overrideWith((ref) => app)],
    );
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    await _settle(c);
    await ctrl.unlock('solopw');

    // Master password == the existing identity's own password → clash.
    final ok = await ctrl.addIdentity(
      masterPassword: 'solopw',
      label: 'Work',
      password: 'workpw',
    );
    expect(ok, isFalse);

    // The original identity is intact — re-unlock still opens single Solo.
    await ctrl.unlock('solopw');
    final s = c.read(appControllerProvider);
    expect(s.isMaster, isFalse);
    expect(s.identity!.displayName, 'Solo');
  });

  test(
    'createDecoyMaster builds a duress master with only the shared identities',
    () async {
      SharedPreferences.setMockInitialValues({'onboarded': true});
      final container = FakeHvContainer();
      final roster = <RosterEntry>[];
      for (final (label, pw) in [('alice', 'pw-a'), ('bob', 'pw-b')]) {
        final ch = container.storage();
        await ch.open(password: pw, createIfMissing: true);
        await ch.saveProfile(UserProfile(displayName: label));
        roster.add(
          RosterEntry(label: label, spaceKeys: await ch.exportSpaceKeys()),
        );
        await ch.close();
      }
      final m = container.storage();
      await m.open(password: 'masterpw', createIfMissing: true);
      await m.saveRoster(roster);
      await m.close();

      final app = container.storage();
      final c = ProviderContainer(
        overrides: [storageProvider.overrideWith((ref) => app)],
      );
      addTearDown(c.dispose);
      final ctrl = c.read(appControllerProvider.notifier);
      await _settle(c);
      await ctrl.unlock('masterpw');
      await ctrl.pickIdentity('alice');

      final ok = await ctrl.createDecoyMaster(
        duressPassword: 'duresspw',
        includeLabels: ['bob'],
      );
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
    },
  );

  test(
    'createDecoyMaster refuses to overwrite the real master (clash)',
    () async {
      SharedPreferences.setMockInitialValues({'onboarded': true});
      final container = FakeHvContainer();
      final roster = <RosterEntry>[];
      for (final (label, pw) in [('alice', 'pw-a'), ('bob', 'pw-b')]) {
        final ch = container.storage();
        await ch.open(password: pw, createIfMissing: true);
        await ch.saveProfile(UserProfile(displayName: label));
        roster.add(
          RosterEntry(label: label, spaceKeys: await ch.exportSpaceKeys()),
        );
        await ch.close();
      }
      final m = container.storage();
      await m.open(password: 'masterpw', createIfMissing: true);
      await m.saveRoster(roster);
      await m.close();

      final app = container.storage();
      final c = ProviderContainer(
        overrides: [storageProvider.overrideWith((ref) => app)],
      );
      addTearDown(c.dispose);
      final ctrl = c.read(appControllerProvider.notifier);
      await _settle(c);
      await ctrl.unlock('masterpw');
      await ctrl.pickIdentity('alice');

      // Duress password == the real master password → would clobber it.
      final ok = await ctrl.createDecoyMaster(
        duressPassword: 'masterpw',
        includeLabels: ['bob'],
      );
      expect(ok, isFalse);
      await ctrl.lock();

      final real = container.storage();
      await real.open(password: 'masterpw');
      expect((await real.loadRoster())!.map((e) => e.label), ['alice', 'bob']);
      await real.close();
    },
  );

  test(
    'a single-identity space unlocks straight to ready (no picker)',
    () async {
      SharedPreferences.setMockInitialValues({'onboarded': true});
      final container = FakeHvContainer();

      const soloProfile = UserProfile(displayName: 'Solo');
      final seed = container.storage();
      await seed.open(password: 'pw', createIfMissing: true);
      await seed.saveProfile(soloProfile);
      await seed.close();

      final app = container.storage();
      final c = ProviderContainer(
        overrides: [storageProvider.overrideWith((ref) => app)],
      );
      addTearDown(c.dispose);
      final ctrl = c.read(appControllerProvider.notifier);
      await _settle(c);

      await ctrl.unlock('pw');
      final s = c.read(appControllerProvider);
      expect(s.phase, AppPhase.ready); // skipped the picker entirely
      expect(s.identity!.displayName, 'Solo');
    },
  );

  group('what an unlock failure puts in the error report', () {
    // The report exists for the person who cannot get in. Its usefulness rests
    // on a distinction: a container that REFUSES to open is a defect worth
    // sending, a mistyped password is not. Recording both would bury the first
    // under the second and would put a count of someone's typos in a file they
    // hand to another person.
    test('a wrong password records NOTHING', () async {
      SharedPreferences.setMockInitialValues({'onboarded': true});
      final container = FakeHvContainer();
      final seeded = container.storage();
      await seeded.open(password: 'right', createIfMissing: true);
      await seeded.close();

      final c = ProviderContainer(
        overrides: [storageProvider.overrideWith((ref) => container.storage())],
      );
      addTearDown(c.dispose);
      final ctrl = c.read(appControllerProvider.notifier);
      await _settle(c);

      await ctrl.unlock('wrong');
      expect(c.read(appControllerProvider).unlockError, isTrue);
      expect(
        errorJournal.entries,
        isEmpty,
        reason: 'a typo is not a defect and does not belong in a report',
      );
    });

    test('a container that cannot be opened at all IS recorded', () async {
      // The real shape of this: the native container holds an exclusive lock,
      // so a second handle throws while the password is perfectly correct.
      // "The correct password does not open it" is precisely the field report
      // that used to be undiagnosable.
      SharedPreferences.setMockInitialValues({'onboarded': true});
      final container = FakeHvContainer();
      final holder = container.storage();
      await holder.open(password: 'right', createIfMissing: true);
      addTearDown(holder.close);

      final c = ProviderContainer(
        overrides: [storageProvider.overrideWith((ref) => container.storage())],
      );
      addTearDown(c.dispose);
      final ctrl = c.read(appControllerProvider.notifier);
      await _settle(c);

      await ctrl.unlock('right');
      expect(c.read(appControllerProvider).unlockError, isTrue);
      expect(errorJournal.entries, hasLength(1));
      final entry = errorJournal.entries.single;
      expect(entry.kind, 'unlock');
      expect(
        entry.message,
        contains('busy'),
        reason: 'the report must name the cause, not just say it failed',
      );
    });
  });
}

/// Plant an identity record that no writer would ever produce: present, but
/// unparseable. Reaches under the storage API on purpose — `saveIdentity` only
/// ever writes well-formed records, so there is no other way to stand up the
/// state the field reports describe.
Uint8List _damageIdentityRecord(FakeHvContainer container, String password) {
  final store = container.rawStoreFor(password)!;
  final key = Uint8List.fromList(utf8.encode('identity'));
  final damaged = Uint8List.fromList(utf8.encode('{"dn":{"not":"a name"}}'));
  store.commit([PutOp(Ns.settings, key, damaged)]);
  return damaged;
}

Uint8List? _rawIdentityRecord(FakeHvContainer container, String password) =>
    container
        .rawStoreFor(password)!
        .get(Ns.settings, Uint8List.fromList(utf8.encode('identity')));

void _keyWipeOnLockTests() {
  /// A master session with two children, unlocked and ready for roster edits.
  Future<(ProviderContainer, AppController, FakeHvContainer)>
  unlockedMaster() async {
    SharedPreferences.setMockInitialValues({'onboarded': true});
    errorJournal.clear();
    final container = FakeHvContainer();
    final roster = <RosterEntry>[];
    for (final (label, pw) in [('alice', 'pw-a'), ('bob', 'pw-b')]) {
      final ch = container.storage();
      await ch.open(password: pw, createIfMissing: true);
      await ch.saveProfile(UserProfile(displayName: label));
      roster.add(
        RosterEntry(label: label, spaceKeys: await ch.exportSpaceKeys()),
      );
      await ch.close();
    }
    final m = container.storage();
    await m.open(password: 'masterpw', createIfMissing: true);
    await m.saveRoster(roster);
    await m.close();

    final c = ProviderContainer(
      overrides: [storageProvider.overrideWith((ref) => container.storage())],
    );
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    await _settle(c);
    await ctrl.unlock('masterpw');
    return (c, ctrl, container);
  }

  test(
    'a roster edit zeroes the keys it supersedes, not just the last set',
    () async {
      // audit report10 X-04. Only the CURRENT references were wiped at lock, and
      // `loadRoster` hands back FRESH buffers every call — so every anonymity
      // toggle, bind, unbind, delete and addIdentity abandoned a whole set of
      // child space keys intact in the heap. A session with a few edits left
      // several full sets readable after the container closed.
      final (c, ctrl, _) = await unlockedMaster();
      final before = [for (final e in ctrl.debugRoster!) e.spaceKeys];
      expect(before, hasLength(2));
      expect(
        before.every((k) => k.any((b) => b != 0)),
        isTrue,
        reason: 'sanity: real key material before the edit',
      );

      await ctrl.setIdentityAnonymous('bob', true);
      final after = [for (final e in ctrl.debugRoster!) e.spaceKeys];

      // Anti-vacuity: if the edit did not actually replace the buffers there is
      // nothing superseded and the next assertion means nothing.
      expect(
        before.any((b) => after.any((a) => identical(a, b))),
        isFalse,
        reason: 'the edit must have replaced the buffers, or the test is empty',
      );
      for (final k in before) {
        expect(
          k.every((b) => b == 0),
          isTrue,
          reason:
              'superseded child keys must be zeroed AT THE SWAP, not at the '
              'next lock — the next lock never sees them',
        );
      }
      // And the live ones must survive: over-wiping here would leave the app
      // holding keys that open nothing.
      expect(after.every((k) => k.any((b) => b != 0)), isTrue);
      expect(c.read(appControllerProvider).phase, isNot(AppPhase.locked));
    },
  );

  test('replacing the master keys zeroes the old buffer', () async {
    final (_, ctrl, _) = await unlockedMaster();
    final before = ctrl.debugMasterKeys!;
    expect(before.any((b) => b != 0), isTrue);

    await ctrl.addIdentity(
      masterPassword: 'masterpw',
      label: 'carol',
      password: 'pw-c',
    );

    expect(
      before.every((b) => b == 0),
      isTrue,
      reason: 'the superseded master keys must be gone, not merely dropped',
    );
    expect(ctrl.debugMasterKeys!.any((b) => b != 0), isTrue);
    // Proves the LIVE master keys still open the master: a fix that wiped the
    // adopted buffer instead would pass the assertion above and break this.
    expect(await ctrl.setIdentityAnonymous('carol', true), isTrue);
  });

  test('an edit that aborts leaves every live key usable', () async {
    // Named for what it establishes. It was written to exercise the identity
    // guard in _releaseKeys, and it does NOT: with an unreadable roster blob
    // `saveRoster` refuses fail-closed BEFORE the swap, so no release runs at
    // all. Deleting the guard leaves this green — checked, not assumed.
    //
    // The guard stays anyway, and is documented as defensive rather than
    // covered: `onDisk = await storage.loadRoster() ?? roster` aliases the live
    // roster on its fallback branch, and `createDecoyMaster` builds from live
    // entries. Neither reaches a swap today. If one ever does, wiping by
    // content equality or without an identity check would zero buffers the app
    // is still holding, and nothing else would say so.
    //
    // What this DOES prove is worth having on its own: a failed roster edit
    // must not take the session's keys with it.
    final (c, ctrl, container) = await unlockedMaster();
    final live = [for (final e in ctrl.debugRoster!) e.spaceKeys];
    final master = ctrl.debugMasterKeys!;
    expect(live.every((k) => k.any((b) => b != 0)), isTrue);

    container.rawStoreFor('masterpw')!.commit([
      PutOp(
        Ns.settings,
        Uint8List.fromList(utf8.encode('master:roster')),
        Uint8List.fromList(utf8.encode('{not a roster}')),
      ),
    ]);

    // Precondition, asserted rather than assumed: without an unreadable roster
    // there is no aliasing and this test proves nothing.
    final probe = container.storage();
    await probe.open(password: 'masterpw');
    expect(
      await probe.loadRoster(),
      isNull,
      reason:
          'the damaged blob must make loadRoster fall back, or the '
          'aliasing this test exists for never happens',
    );
    await probe.close();

    // The edit aborts in saveRoster's fail-closed guard; what matters is what
    // it leaves behind.
    try {
      await ctrl.setIdentityAnonymous('alice', false);
    } catch (_) {
      // The abort itself is not what this test is about.
    }

    for (final k in live) {
      expect(
        k.any((b) => b != 0),
        isTrue,
        reason:
            'a buffer the roster still holds was wiped — it opens nothing '
            'now, and the app cannot tell why',
      );
    }
    expect(
      master.any((b) => b != 0),
      isTrue,
      reason: 'the master keys are still in use',
    );
  });

  test('locking ZEROES the cached space keys, not just the reference', () async {
    // Audit XV-22. A SpaceKeys blob opens a space with no password; the master
    // session caches its own and one per child. They used to be dropped by
    // reference alone, which hands them to the collector intact and leaves them
    // readable in the heap until something happens to reuse that memory. Lock
    // is the one moment a person has explicitly said "I am done, protect this".
    SharedPreferences.setMockInitialValues({'onboarded': true});
    errorJournal.clear();
    final container = FakeHvContainer();
    final roster = <RosterEntry>[];
    for (final (label, pw) in [('alice', 'pw-a'), ('bob', 'pw-b')]) {
      final ch = container.storage();
      await ch.open(password: pw, createIfMissing: true);
      await ch.saveProfile(UserProfile(displayName: label));
      roster.add(
        RosterEntry(label: label, spaceKeys: await ch.exportSpaceKeys()),
      );
      await ch.close();
    }
    final m = container.storage();
    await m.open(password: 'masterpw', createIfMissing: true);
    await m.saveRoster(roster);
    await m.close();

    final c = ProviderContainer(
      overrides: [storageProvider.overrideWith((ref) => container.storage())],
    );
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    await _settle(c);
    await ctrl.unlock('masterpw');

    // Hold the LIVE buffers — a copy would prove nothing about the originals.
    final master = ctrl.debugMasterKeys!;
    final children = [for (final e in ctrl.debugRoster!) e.spaceKeys];
    expect(children, hasLength(2));
    expect(
      master.any((b) => b != 0),
      isTrue,
      reason: 'sanity: this must be real key material before the lock',
    );
    expect(children.every((k) => k.any((b) => b != 0)), isTrue);

    await ctrl.lock();

    expect(ctrl.debugMasterKeys, isNull);
    expect(ctrl.debugRoster, isNull);
    expect(
      master.every((b) => b == 0),
      isTrue,
      reason: 'the master key bytes must be gone, not merely unreferenced',
    );
    for (final k in children) {
      expect(
        k.every((b) => b == 0),
        isTrue,
        reason: 'every child key too — each one opens a space on its own',
      );
    }
  });
}

void _nodeIdSourceOfTruthTests() {
  group('the node id has ONE source: the node (audit XV-06)', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      errorJournal.clear();
    });

    test('a space cannot pin one — two runtimes each get their own', () async {
      // The finding, end to end. Onboarding used to mint a RANDOM node id and
      // write it into the space before any node existed; the node then derived
      // or mined its own and the two never agreed. The app hid it (it displayed
      // the node's id and never wrote it back) while headless compared them and
      // refused to start — one profile, two answers, and only one of them could
      // open it.
      //
      // Nothing is stored to disagree with now. The same space, opened by two
      // runtimes whose transports report different ids, gives each of them ITS
      // OWN id and the same human details.
      final first = NodeId(Uint8List.fromList(List.filled(32, 0x5c)));
      final second = NodeId(Uint8List.fromList(List.filled(32, 0x3e)));
      final container = FakeHvContainer();

      final c1 = ProviderContainer(
        overrides: [
          storageProvider.overrideWith((ref) => container.storage()),
          veilTransportProvider.overrideWith(
            (ref) => LoopbackTransport(localNodeId: first),
          ),
        ],
      );
      addTearDown(c1.dispose);
      final ctrl1 = c1.read(appControllerProvider.notifier);
      await _settle(c1);
      await ctrl1.completeOnboarding(
        displayName: 'Me',
        password: 'pw',
        mode: StorageMode.hiddenSpace,
      );
      expect(c1.read(appControllerProvider).identity!.nodeId, first);
      await ctrl1.lock();

      final c2 = ProviderContainer(
        overrides: [
          storageProvider.overrideWith((ref) => container.storage()),
          veilTransportProvider.overrideWith(
            (ref) => LoopbackTransport(localNodeId: second),
          ),
        ],
      );
      addTearDown(c2.dispose);
      final ctrl2 = c2.read(appControllerProvider.notifier);
      await _settle(c2);
      await ctrl2.unlock('pw');

      final s = c2.read(appControllerProvider);
      expect(s.phase, AppPhase.ready);
      expect(
        s.identity!.nodeId,
        second,
        reason: 'a node id read out of the space is a stale one',
      );
      expect(
        s.identity!.nodeId,
        isNot(first),
        reason: 'the FIRST runtime\'s id must not have been persisted',
      );
      expect(
        s.identity!.displayName,
        'Me',
        reason: 'what the person chose IS the space\'s to keep',
      );
    });

    test('addIdentity writes a space with no node id in it either', () async {
      // The other place that minted one. A child space created here is opened
      // later by whatever node boots for it; a random id written at creation
      // would be the same stale copy, one per identity.
      SharedPreferences.setMockInitialValues({'onboarded': true});
      final marker = NodeId(Uint8List.fromList(List.filled(32, 0x77)));
      final container = FakeHvContainer();
      final seed = container.storage();
      await seed.open(password: 'pw', createIfMissing: true);
      await seed.saveProfile(const UserProfile(displayName: 'Solo'));
      await seed.close();

      final c = ProviderContainer(
        overrides: [
          storageProvider.overrideWith((ref) => container.storage()),
          veilTransportProvider.overrideWith(
            (ref) => LoopbackTransport(localNodeId: marker),
          ),
        ],
      );
      addTearDown(c.dispose);
      final ctrl = c.read(appControllerProvider.notifier);
      await _settle(c);
      await ctrl.unlock('pw');
      expect(
        await ctrl.addIdentity(
          label: 'work',
          password: 'pw-work',
          masterPassword: 'masterpw',
        ),
        isTrue,
      );

      expect(c.read(appControllerProvider).identity!.nodeId, marker);
      final raw = container
          .rawStoreFor('pw-work')!
          .get(Ns.settings, Uint8List.fromList(utf8.encode('identity')))!;
      final decoded = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
      expect(decoded['dn'], 'work');
      expect(
        decoded.containsKey('n'),
        isFalse,
        reason: 'no node id may be written where no node has spoken',
      );
    });
  });
}

void _damagedIdentityTests() {
  group('a DAMAGED identity is not an ABSENT one (audit XV-13)', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      errorJournal.clear();
    });

    test(
      'unlocking one parks the app instead of minting a new identity',
      () async {
        // The whole finding in one flow: the container opens (right password),
        // the identity record inside it is unreadable, and the app used to hand
        // the user a fresh random identity and a normal, working, EMPTY session.
        // Someone whose identity had actually been lost saw no sign of it.
        SharedPreferences.setMockInitialValues({'onboarded': true});
        final container = FakeHvContainer();
        final seeded = container.storage();
        await seeded.open(password: 'right', createIfMissing: true);
        await seeded.saveProfile(UserProfile(displayName: 'Real'));
        await seeded.close();
        final damaged = _damageIdentityRecord(container, 'right');

        final app = container.storage();
        final c = ProviderContainer(
          overrides: [storageProvider.overrideWith((ref) => app)],
        );
        addTearDown(c.dispose);
        final ctrl = c.read(appControllerProvider.notifier);
        await _settle(c);

        await ctrl.unlock('right');

        final s = c.read(appControllerProvider);
        expect(
          s.phase,
          AppPhase.identityDamaged,
          reason: 'a damaged record must not open a session',
        );
        expect(
          s.identity,
          isNull,
          reason: 'no placeholder identity may be presented as the user',
        );
        expect(
          s.unlockError,
          isFalse,
          reason:
              'the password was right; saying otherwise sends people to '
              'retype it forever',
        );
        // The record is EXACTLY as it was found — the session that would have
        // written over it never started.
        expect(_rawIdentityRecord(container, 'right'), damaged);
        expect(app.isOpen, isFalse, reason: 'the space is released, not held');
        // ...and it is diagnosable, which is the other half of the finding.
        expect(errorJournal.entries.map((e) => e.kind), contains('identity'));
      },
    );

    test('a decoy master refuses to write over one', () async {
      // The destructive edge. `createDecoyMaster` asks "is anything already
      // here?" via loadIdentity, and an unreadable record answered `null` —
      // no clash — so the decoy roster went straight over a damaged but
      // possibly recoverable identity space.
      SharedPreferences.setMockInitialValues({'onboarded': true});
      final container = FakeHvContainer();
      final roster = <RosterEntry>[];
      for (final (label, pw) in [('alice', 'pw-a'), ('bob', 'pw-b')]) {
        final ch = container.storage();
        await ch.open(password: pw, createIfMissing: true);
        await ch.saveProfile(UserProfile(displayName: label));
        roster.add(
          RosterEntry(label: label, spaceKeys: await ch.exportSpaceKeys()),
        );
        await ch.close();
      }
      // A third space, outside the roster, whose identity record is damaged.
      final hurt = container.storage();
      await hurt.open(password: 'pw-hurt', createIfMissing: true);
      await hurt.saveProfile(UserProfile(displayName: 'Hurt'));
      await hurt.close();
      final damaged = _damageIdentityRecord(container, 'pw-hurt');

      final m = container.storage();
      await m.open(password: 'masterpw', createIfMissing: true);
      await m.saveRoster(roster);
      await m.close();

      final app = container.storage();
      final c = ProviderContainer(
        overrides: [storageProvider.overrideWith((ref) => app)],
      );
      addTearDown(c.dispose);
      final ctrl = c.read(appControllerProvider.notifier);
      await _settle(c);
      await ctrl.unlock('masterpw');
      await ctrl.pickIdentity('alice');

      final ok = await ctrl.createDecoyMaster(
        duressPassword: 'pw-hurt',
        includeLabels: ['bob'],
      );
      expect(
        ok,
        isFalse,
        reason: 'something IS there — it just cannot be read',
      );
      expect(
        _rawIdentityRecord(container, 'pw-hurt'),
        damaged,
        reason: 'the damaged record must survive untouched',
      );

      await ctrl.lock();
      final hurtAgain = container.storage();
      expect(await hurtAgain.open(password: 'pw-hurt'), isTrue);
      expect(
        await hurtAgain.loadRoster(),
        isNull,
        reason: 'no decoy roster may have been written into it',
      );
      await hurtAgain.close();
    });

    test(
      'an ABSENT record still opens a session — the two are not merged',
      () async {
        // The control. If "damaged" were implemented by refusing on anything
        // unusual, a fresh/erased space would stop opening too and every
        // legitimate empty-identity install would be bricked.
        SharedPreferences.setMockInitialValues({'onboarded': true});
        final container = FakeHvContainer();
        final seeded = container.storage();
        await seeded.open(password: 'right', createIfMissing: true);
        await seeded.close(); // created, never given an identity

        final app = container.storage();
        final c = ProviderContainer(
          overrides: [storageProvider.overrideWith((ref) => app)],
        );
        addTearDown(c.dispose);
        final ctrl = c.read(appControllerProvider.notifier);
        await _settle(c);

        await ctrl.unlock('right');
        expect(c.read(appControllerProvider).phase, AppPhase.ready);
        expect(c.read(appControllerProvider).identity, isNotNull);
      },
    );
  });
}

void _p2pPolicyTests() {
  group('AppController.lanListenAllowed', () {
    test(
      'an unreadable policy denies, it does not fall back to the default',
      () {
        // Audit X-14. The old `catch` returned the DEFAULT, which is permissive,
        // so a transient storage error bound a LAN listener for a user who had
        // explicitly denied P2P.
        expect(
          AppController.lanListenAllowed(storedPolicy: null, readFailed: true),
          isFalse,
        );
        // Even when a policy string was already in hand, a failed read denies.
        expect(
          AppController.lanListenAllowed(
            storedPolicy: 'allowed',
            readFailed: true,
          ),
          isFalse,
        );
      },
    );

    test('an absent policy is not the same as an unreadable one', () {
      // Never set = fresh install. Denying here would break every one of them,
      // so the two cases must stay distinguishable.
      expect(
        AppController.lanListenAllowed(storedPolicy: null, readFailed: false),
        kDefaultP2PGlobalPolicy != P2PGlobalPolicy.denied,
      );
    });

    test('an explicit denial is honoured', () {
      expect(
        AppController.lanListenAllowed(
          storedPolicy: P2PGlobalPolicy.denied.name,
          readFailed: false,
        ),
        isFalse,
      );
    });
  });
}

/// A storage whose `open` refuses, and which records ANY other use.
///
/// Every member other than `open` throws through `noSuchMethod`, which is the
/// assertion: reaching one at all means onboarding carried on against a
/// storage that never unlocked.
class _OpenRefusingStorage implements Storage {
  bool usedAfterRefusal = false;

  @override
  Future<bool> open({
    required String password,
    bool createIfMissing = false,
  }) async => false;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    usedAfterRefusal = true;
    throw StateError(
      'storage used after open() refused: ${invocation.memberName}',
    );
  }
}

void _onboardingOpenFailureTests() {
  test('onboarding stops when storage refuses the password', () async {
    // Audit X-15. `open` ANSWERS whether it unlocked anything; the result was
    // dropped and `saveIdentity` ran regardless, against a storage that was
    // not open. The failure then surfaced later, somewhere else, on top of
    // half-written onboarding state.
    SharedPreferences.setMockInitialValues({});
    final storage = _OpenRefusingStorage();
    final c = ProviderContainer(
      overrides: [storageProvider.overrideWith((ref) => storage)],
    );
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    await _settle(c);

    await expectLater(
      ctrl.completeOnboarding(
        password: 'pw',
        displayName: 'Me',
        mode: StorageMode.hiddenSpace,
      ),
      throwsA(isA<StateError>()),
    );
    expect(
      storage.usedAfterRefusal,
      isFalse,
      reason: 'nothing may be written to a storage that did not open',
    );
    // And the user is back where they can try again, not stranded in a
    // half-prepared phase.
    expect(c.read(appControllerProvider).phase, AppPhase.onboarding);

    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getBool('onboarded'),
      isNot(true),
      reason: 'a refused open must not leave the app marked as onboarded',
    );
  });
}

void _runtimeBaseTeardownTests() {
  /// Drive a real `lock()` with `runtimeDir` pointed at [dir].
  ///
  /// The deniable boot below reaches `_ensureRealStack`, and with the native
  /// library present that starts a REAL in-process node: `node.start`, a UDP
  /// reflector on 0.0.0.0, and a thirty-second timeout this test then hits.
  /// It passed only because CI runs `flutter test` with no `VEIL_FFI_DYLIB` —
  /// green for the absence of the one thing production always has.
  ///
  /// `debugDeniableStackStarter` exists for exactly this and was not used
  /// here. What is under test is what `lock()` does to a directory, and a
  /// node is no part of that.
  Future<void> lockWithRuntimeDir(String dir) async {
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer(
      overrides: [
        deniableBootProvider.overrideWithValue(
          DeniableBootConfig(
            runtimeDir: dir,
            listenPort: 9000,
            storePath: '${dir}_store',
          ),
        ),
      ],
    );
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    ctrl.debugDeniableStackStarter = (plan) async => RealVeilStack.overParts(
      controller: FakeNodeController(),
      transport: LoopbackTransport(localNodeId: NodeId(Uint8List(32))),
      myInvite: BootstrapInvite(publicKey: Uint8List(32), nonce: Uint8List(8)),
    );
    await _settle(c);
    await ctrl.completeOnboarding(
      displayName: 'Me',
      password: 'pw',
      mode: StorageMode.hiddenSpace,
    );
    await ctrl.lock();
  }

  test('lock does not delete a runtime dir that is not ours', () async {
    // Audit X-12. `runtimeDir` can come from `XVEIL_RUNTIME_DIR`, and teardown
    // removes it RECURSIVELY. Pointed at the wrong path by a bad launcher entry
    // — or by the variable set for something else in the session — lock erased
    // whatever was there.
    //
    // Driven through `lock()` rather than through the predicate: a version with
    // the guard deleted still passed every test of `runtimeDirIsOurs`, because
    // the predicate was never the thing that was wrong.
    final dir = Directory.systemTemp.createTempSync('xveil_rt_notours');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final precious = File('${dir.path}/important.txt')
      ..writeAsStringSync('do not delete me');

    await lockWithRuntimeDir(dir.path);

    expect(dir.existsSync(), isTrue, reason: 'the directory must survive');
    expect(precious.existsSync(), isTrue);
    expect(precious.readAsStringSync(), 'do not delete me');
  });

  test('lock still removes a runtime dir we marked as ours', () async {
    // The guard must not turn teardown into a no-op: sockets and the obfs4 PSK
    // are supposed to be gone after lock, and leaving them is the trace the
    // recursive delete exists to remove.
    final dir = Directory.systemTemp.createTempSync('xveil_rt_ours');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    await markRuntimeDirOwned(dir.path);
    File('${dir.path}/app.sock').writeAsStringSync('');

    await lockWithRuntimeDir(dir.path);

    expect(dir.existsSync(), isFalse, reason: 'our own runtime dir is reaped');
  });
}

void _wipeRemovesBlobsTests() {
  test('wipe removes the large-file tier, not just the container', () async {
    // Audit XV-11. The blob tier lives BESIDE the container, so deleting the
    // container left the whole directory standing. The ciphertext is unreadable
    // once the keys go with the volume — but "unreadable" is not "absent": the
    // file count, the sizes and the directory's very existence still say this
    // machine ran xVeil and roughly how much was stored. A wipe that leaves a
    // shaped artifact behind is not the wipe the confirmation promised.
    SharedPreferences.setMockInitialValues({'onboarded': true});
    final dir = Directory.systemTemp.createTempSync('xveil_wipe_blobs');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final store = File('${dir.path}/test.store')
      ..writeAsStringSync('container');
    final blobs = blobRootFor(store.path)..createSync(recursive: true);
    File('${blobs.path}/aa/ciphertext').createSync(recursive: true);

    final container = FakeHvContainer();
    final app = container.storage();
    final c = ProviderContainer(
      overrides: [
        storageProvider.overrideWith((ref) => app),
        deniableBootProvider.overrideWithValue(
          DeniableBootConfig(
            runtimeDir: '${dir.path}/rt',
            listenPort: 9000,
            storePath: store.path,
          ),
        ),
      ],
    );
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    await _settle(c);
    expect(blobs.existsSync(), isTrue, reason: 'precondition');

    await ctrl.wipeContainers();

    expect(store.existsSync(), isFalse);
    expect(
      blobs.existsSync(),
      isFalse,
      reason: 'the blob tier must go with the container it belonged to',
    );
  });
}

/// A real storage that ALWAYS fails to close — the wedged storage worker behind
/// the "won't unlock until restart" reports.
///
/// Extends rather than wraps: every other method must behave exactly as
/// production does, or the test would be exercising a different lock.
class _CloseFailingStorage extends HiddenVolumeStorage {
  _CloseFailingStorage(FakeHvContainer c)
    : super(c.passwordOpener, keysOpener: c.keysOpener);

  bool closeAttempted = false;

  @override
  Future<void> close() async {
    closeAttempted = true;
    throw StateError('storage worker is wedged');
  }
}

void _lockAlwaysCompletesTests() {
  test('a failing cleanup leg does not abort the rest of lock', () async {
    // Audit XV-08. These were a plain `await` chain, so the FIRST failure
    // skipped everything after it: the container stayed OPEN, the master keys
    // stayed in memory and the phase never reached `locked` — while the caller
    // saw an exception it could do nothing useful with. A lock that stops
    // half-way is the one failure this screen exists to prevent.
    SharedPreferences.setMockInitialValues({});
    final dir = Directory.systemTemp.createTempSync('xveil_lock_legs');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    final container = FakeHvContainer();
    final failing = _CloseFailingStorage(container);
    final c = ProviderContainer(
      overrides: [
        storageProvider.overrideWith((ref) => failing),
        deniableBootProvider.overrideWithValue(
          DeniableBootConfig(
            runtimeDir: '${dir.path}/rt',
            listenPort: 9000,
            storePath: '${dir.path}/test.store',
          ),
        ),
      ],
    );
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    // The deniable boot below reaches `_ensureRealStack`, which with the
    // native library present starts a REAL in-process node and runs this test
    // into its thirty-second bound. What is under test is what `lock()` does
    // when one cleanup leg fails; a node is no part of that.
    ctrl.debugDeniableStackStarter = (plan) async => RealVeilStack.overParts(
      controller: FakeNodeController(),
      transport: LoopbackTransport(localNodeId: NodeId(Uint8List(32))),
      myInvite: BootstrapInvite(publicKey: Uint8List(32), nonce: Uint8List(8)),
    );
    await _settle(c);
    await ctrl.completeOnboarding(
      displayName: 'Me',
      password: 'pw',
      mode: StorageMode.hiddenSpace,
    );

    // The failure is surfaced — a lock that swallowed it would be worse.
    await expectLater(ctrl.lock(), throwsA(isA<StateError>()));

    expect(failing.closeAttempted, isTrue, reason: 'precondition');
    // ...and everything AFTER the failing leg still happened. This is the
    // assertion the old chain could not satisfy: it propagated immediately and
    // never reached either of these.
    expect(
      c.read(appControllerProvider).phase,
      AppPhase.locked,
      reason: 'the UI must not be left in an unlocked-looking phase',
    );
    expect(
      ctrl.takePendingIdentityPhrase(),
      isNull,
      reason: 'sensitive session state must be dropped regardless',
    );
  });
}

void _wipeClearsPostureTests() {
  test('wipe removes the network posture, not just the onboarding flag', () async {
    // Audit XV-15. `wipeContainers` cleared `onboarded` and `storage_mode` and
    // nothing else, so "clear all data" left the proxy exit, the VPN app list,
    // CIDR and DNS, the preview mode and the always-online choice sitting in
    // the preference store in plaintext. Someone who wiped because they HAD to
    // still had their whole network posture on disk, readable without opening
    // a container.
    final seeded = <String, Object>{
      'onboarded': true,
      for (final k in kIdentityPosturePrefKeys) k: 'set-by-the-user',
    };
    SharedPreferences.setMockInitialValues(seeded);

    final dir = Directory.systemTemp.createTempSync('xveil_wipe_posture');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final store = File('${dir.path}/test.store')..writeAsStringSync('c');

    final container = FakeHvContainer();
    final app = container.storage();
    final c = ProviderContainer(
      overrides: [
        storageProvider.overrideWith((ref) => app),
        deniableBootProvider.overrideWithValue(
          DeniableBootConfig(
            runtimeDir: '${dir.path}/rt',
            listenPort: 9000,
            storePath: store.path,
          ),
        ),
      ],
    );
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    await _settle(c);

    await ctrl.wipeContainers();

    final prefs = await SharedPreferences.getInstance();
    for (final key in kIdentityPosturePrefKeys) {
      expect(
        prefs.get(identityScopedPrefKey(key)),
        isNull,
        reason: '$key survived a wipe',
      );
    }
  });

  test(
    'wipe takes the translation models, which name the languages you read',
    () async {
      // A stronger disclosure than the speech model's. Whisper's is a single
      // generic file and says only that transcription was enabled; a translation
      // model is one directory per DIRECTION, so what survived a wipe was a list
      // of the languages this person reads — in plaintext directory names that
      // need nothing unlocked to read.
      SharedPreferences.setMockInitialValues(<String, Object>{
        'onboarded': true,
      });

      final dir = Directory.systemTemp.createTempSync('xveil_wipe_translate');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final store = File('${dir.path}/test.store')..writeAsStringSync('c');
      final translateRoot = Directory('${dir.path}/translate')..createSync();
      for (final id in ['ru-en', 'en-ru']) {
        final pair = Directory('${translateRoot.path}/$id')..createSync();
        File('${pair.path}/model.bin').writeAsStringSync('weights');
      }

      final container = FakeHvContainer();
      final app = container.storage();
      final c = ProviderContainer(
        overrides: [
          storageProvider.overrideWith((ref) => app),
          translationModelsRootProvider.overrideWithValue(
            () async => translateRoot,
          ),
          deniableBootProvider.overrideWithValue(
            DeniableBootConfig(
              runtimeDir: '${dir.path}/rt',
              listenPort: 9001,
              storePath: store.path,
            ),
          ),
        ],
      );
      addTearDown(c.dispose);
      final ctrl = c.read(appControllerProvider.notifier);
      await _settle(c);

      await ctrl.wipeContainers();

      expect(
        translateRoot.existsSync(),
        isFalse,
        reason: 'the directory names alone said which languages are read',
      );
    },
  );

  test('wipe takes the speech model and the OS tunnel down too', () async {
    // The remaining two halves of XV-15. The ~57 MiB model is fetched from a
    // public CDN, so its presence on disk says the user enabled voice
    // transcription and roughly when — a fact about HOW they used the app that
    // outlived a wipe of everything the app itself stored. And the VPN tunnel
    // lives in the OS, not this process, so it kept running after the wipe
    // with traffic still going through the configured exit.
    SharedPreferences.setMockInitialValues(<String, Object>{'onboarded': true});

    final dir = Directory.systemTemp.createTempSync('xveil_wipe_model');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final store = File('${dir.path}/test.store')..writeAsStringSync('c');
    final modelDir = Directory('${dir.path}/model')..createSync();
    final model = File('${modelDir.path}/${WhisperModelStore.fileName}')
      ..writeAsStringSync('x');

    final vpn = _RecordingVpn();
    final container = FakeHvContainer();
    final app = container.storage();
    final c = ProviderContainer(
      overrides: [
        storageProvider.overrideWith((ref) => app),
        whisperModelStoreProvider.overrideWithValue(
          WhisperModelStore(supportDirectory: () async => modelDir),
        ),
        vpnControllerProvider.overrideWith(() => vpn),
        vpnBackendProvider.overrideWithValue(_SilentVpnBackend()),
        deniableBootProvider.overrideWithValue(
          DeniableBootConfig(
            runtimeDir: '${dir.path}/rt',
            listenPort: 9000,
            storePath: store.path,
          ),
        ),
      ],
    );
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    await _settle(c);

    await ctrl.wipeContainers();

    expect(model.existsSync(), isFalse, reason: 'the model survived the wipe');
    expect(
      vpn.stops,
      1,
      reason: 'the tunnel is in the OS — a wipe that leaves it up is not one',
    );
  });

  test(
    'models the wipe could not delete are NAMED in what survived',
    () async {
      // The survivor list re-stat'd the container and the blob directory and
      // stopped there. The two model deletes were left out — and they are the
      // failure-prone steps of the whole wipe: each goes through a platform
      // channel, each is bounded by a timeout, and each catch swallows
      // everything it sees. So the two places something is most likely to be
      // left behind were the two places the report could not mention, and a
      // person whose list of languages was still on disk was told exactly what
      // a person with a clean disk was told.
      //
      // Real chmod, not a fake store: what is under test is that the re-stat
      // LOOKS, and a store that answers "still there" on command cannot show
      // that. Both deletes are driven through the real `wipeContainers`.
      SharedPreferences.setMockInitialValues(<String, Object>{
        'onboarded': true,
      });

      final dir = Directory.systemTemp.createTempSync('xveil_wipe_models_left');
      final modelDir = Directory('${dir.path}/model')..createSync();
      final model = File('${modelDir.path}/${WhisperModelStore.fileName}')
        ..writeAsStringSync('57 MiB, notionally');
      final translateRoot = Directory('${dir.path}/translate')..createSync();
      final pair = Directory('${translateRoot.path}/ru-en')..createSync();
      // Deliberately OUTSIDE the locked directories, so the container deletes
      // normally. That is what makes the assertion below about the two new
      // codes rather than about the old ones under new names.
      final store = File('${dir.path}/test.store')..writeAsStringSync('c');

      // Unwritable PARENTS: the entries stay readable, the unlink cannot
      // happen. What a read-only volume, an ACL drift or a backup agent
      // holding the directory looks like from here.
      expect(Process.runSync('chmod', ['a-w', translateRoot.path]).exitCode, 0);
      expect(Process.runSync('chmod', ['a-w', modelDir.path]).exitCode, 0);
      addTearDown(() {
        Process.runSync('chmod', ['u+w', modelDir.path]);
        Process.runSync('chmod', ['u+w', translateRoot.path]);
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });

      final container = FakeHvContainer();
      final c = ProviderContainer(
        overrides: [
          storageProvider.overrideWith((ref) => container.storage()),
          whisperModelStoreProvider.overrideWithValue(
            WhisperModelStore(supportDirectory: () async => modelDir),
          ),
          translationModelsRootProvider.overrideWithValue(
            () async => translateRoot,
          ),
          deniableBootProvider.overrideWithValue(
            DeniableBootConfig(
              runtimeDir: '${dir.path}/rt',
              listenPort: 9003,
              storePath: store.path,
            ),
          ),
        ],
      );
      addTearDown(c.dispose);
      final ctrl = c.read(appControllerProvider.notifier);
      await _settle(c);

      final remaining = await ctrl.wipeContainers();

      expect(model.existsSync(), isTrue, reason: 'precondition: it survived');
      expect(pair.existsSync(), isTrue, reason: 'precondition: it survived');
      // THE assertions. Neither can pass while the re-stat looks at two paths.
      expect(
        remaining,
        contains('speech-model'),
        reason: 'a wipe that could not delete the speech model must say so',
      );
      expect(
        remaining,
        contains('translations'),
        reason: 'the surviving directory names ARE the languages you read',
      );
      // The container really did go, so the report must not overstate either.
      expect(remaining, isNot(contains('container')));
      // Journalled as well as returned: the dialog is dismissible, the journal
      // is what is still there afterwards.
      expect(
        errorJournal.entries.where((e) => e.kind == 'wipe-incomplete'),
        isNotEmpty,
        reason: 'an incomplete wipe that leaves no trace cannot be diagnosed',
      );
    },
    testOn: '!windows',
  );
}

/// A VPN backend that answers without a platform channel.
///
/// Three teardown tests overrode `vpnControllerProvider` and left
/// `vpnBackendProvider` alone. With the native library present the teardown
/// reaches the NATIVE backend directly — a `MethodChannel` in a unit test with
/// no binding behind it — and the tests failed with "Binding has not yet been
/// initialized". Without the library that path is never taken, so they were
/// green for the absence of the one thing production always has.
class _SilentVpnBackend implements VpnBackend {
  int stops = 0;

  @override
  Future<VpnBackendState> probe() async =>
      const VpnBackendState(VpnBackendPhase.stopped);

  @override
  Future<VpnBackendState> status() async =>
      const VpnBackendState(VpnBackendPhase.stopped);

  @override
  Future<VpnBackendState> start({
    required VpnRoutingPolicy policy,
    required String socks5Listen,
    required String exitNodeId,
    List<String> exitNodeIds = const [],
    Map<String, String> applicationProxyListens = const {},
    String? obfs4Psk,
  }) async => const VpnBackendState(VpnBackendPhase.stopped);

  @override
  Future<VpnBackendState> stop() async {
    stops++;
    return const VpnBackendState(VpnBackendPhase.stopped);
  }
}

/// An OS tunnel that outlived the teardown leaves a trace in a RELEASE build.
void _vpnTeardownIsJournalledTests() {
  // `_stopVpnTunnel` handled both of its failure paths — a phase that is not
  // `stopped`, and a call that threw or timed out — with `devLog` alone, and
  // `devLog` is gated on `!_productMode || _releaseDiagnosticLog`
  // (`lib/core/log.dart`), so a shipped build eliminates it entirely. In the
  // build people actually run, a tunnel that survived a lock or a wipe left
  // ZERO trace anywhere — while the node half of the very same teardown has
  // recorded `node-stop-abandoned` all along. Of the two halves, the silent one
  // is the one still routing the person's traffic through the configured exit
  // while the app presents itself as locked.
  //
  // WHAT DOES NOT PROVE ANY OF THIS. Each of the following stays GREEN with the
  // fix reverted, and none of them may stand in for the assertions below:
  //   * `expect(vpn.stops, 1)` — the stop was always ATTEMPTED. What was
  //     missing is any record of it not having worked.
  //   * a bare `expect(errorJournal.entries, isNotEmpty)` — other legs of the
  //     same lock record their own kinds, so the journal is rarely empty.
  //     Filter by kind or the assertion means nothing.
  //   * `expect(phase, AppPhase.locked)` on its own — the flip is
  //     unconditional by design and was never in question. It is asserted in
  //     the first test only to PIN that design against drift, alongside a
  //     kind-filtered journal assertion that does the real work.

  test('a backend that reports it did not stop is journalled', () async {
    final vpn = _RecordingVpn(phase: VpnBackendPhase.error);
    final c = ProviderContainer(
      overrides: [
        vpnControllerProvider.overrideWith(() => vpn),
        // The native backend is reached directly by the teardown; a unit test
        // has no platform channel behind it.
        vpnBackendProvider.overrideWithValue(_SilentVpnBackend()),
      ],
    );
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    await _settle(c);

    await ctrl.lock();

    // Precondition, NOT the assertion: this stayed green throughout the defect.
    expect(vpn.stops, 1, reason: 'precondition: the teardown asked at all');
    final left = errorJournal.entries.where(
      (e) => e.kind == 'vpn-stop-incomplete',
    );
    expect(
      left,
      isNotEmpty,
      reason: 'a release build compiles devLog out — the journal is the trace',
    );
    expect(
      left.single.message,
      contains('traffic may still be routed'),
      reason: 'the record has to say what it means for the person',
    );
    // THE APPROVED DESIGN, pinned. Parking someone on an unlocked-looking
    // screen because the OS would not answer is its own failure, and in a
    // deniable app the wrong screen is a disclosure. The tunnel is reported,
    // not used as a veto.
    expect(
      c.read(appControllerProvider).phase,
      AppPhase.locked,
      reason: 'a surviving tunnel is reported; it does not hold the lock open',
    );
  });

  test('a stop that throws is journalled the same way', () async {
    final vpn = _RecordingVpn(fails: StateError('the VPN plugin is not there'));
    final c = ProviderContainer(
      overrides: [
        vpnControllerProvider.overrideWith(() => vpn),
        // The native backend is reached directly by the teardown; a unit test
        // has no platform channel behind it.
        vpnBackendProvider.overrideWithValue(_SilentVpnBackend()),
      ],
    );
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    await _settle(c);

    await ctrl.lock();

    expect(vpn.stops, 1, reason: 'precondition: the teardown asked at all');
    expect(
      errorJournal.entries.where((e) => e.kind == 'vpn-stop-incomplete'),
      isNotEmpty,
      reason: 'a throw leaves the tunnel exactly as up as an error phase does',
    );
  });

  test('a stop that never answers is journalled when its bound expires', () {
    // The case the three-second bound exists for: the tunnel is behind a
    // platform channel, and an unresponsive plugin is precisely the
    // arrangement in which the tunnel is still carrying traffic.
    //
    // Driven with `fakeAsync` so the bound is exercised without the suite
    // waiting three real seconds.
    final vpn = _RecordingVpn(neverAnswers: true, inertBuild: true);
    final c = ProviderContainer(
      overrides: [
        vpnControllerProvider.overrideWith(() => vpn),
        // The native backend is reached directly by the teardown; a unit test
        // has no platform channel behind it.
        vpnBackendProvider.overrideWithValue(_SilentVpnBackend()),
      ],
    );
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);

    fakeAsync((async) {
      // Deliberately not awaited. Everything in the lock past the tunnel is
      // real I/O that a fake clock cannot resolve, so the future is dropped
      // once the record we came for has landed; `ignore` keeps a late error
      // from that abandoned tail from surfacing as an unhandled one.
      ctrl.lock().ignore();
      // Past the bound, and not by much: a test that elapsed a minute would
      // pass against a timeout of any length.
      async.elapse(const Duration(seconds: 4));

      expect(vpn.stops, 1, reason: 'precondition: the teardown asked at all');
      expect(
        errorJournal.entries.where((e) => e.kind == 'vpn-stop-incomplete'),
        isNotEmpty,
        reason: 'a plugin that never answers must not be the silent case',
      );
    });
  });

  // The journal is a trace, not a verdict. Everything above records what went
  // wrong somewhere a person has to go and look; what the CALLERS got back was
  // the same for a clean teardown and for one that left the tunnel up. The API
  // answered `locked: true`, a wipe reported only what it could re-stat, and
  // `startOver` said nothing at all (report17 XV17-M14).

  test(
    'a tunnel that did not stop makes the lock verdict incomplete',
    () async {
      final vpn = _RecordingVpn(phase: VpnBackendPhase.error);
      final c = ProviderContainer(
        overrides: [
          vpnControllerProvider.overrideWith(() => vpn),
          vpnBackendProvider.overrideWithValue(_SilentVpnBackend()),
        ],
      );
      addTearDown(c.dispose);
      final ctrl = c.read(appControllerProvider.notifier);
      await _settle(c);

      await ctrl.lock();

      expect(vpn.stops, 1, reason: 'precondition: the teardown asked at all');
      expect(
        ctrl.lastTeardown.complete,
        isFalse,
        reason: 'the caller is told the privacy boundary closed',
      );
      expect(ctrl.lastTeardown.incomplete, contains('vpn'));
    },
  );

  test('CONTROL: a teardown with nothing outstanding is complete', () async {
    // Vacuity guard: a verdict that is never clean is a verdict nobody can act
    // on — every lock would read as a surviving tunnel.
    final vpn = _RecordingVpn();
    final c = ProviderContainer(
      overrides: [
        vpnControllerProvider.overrideWith(() => vpn),
        vpnBackendProvider.overrideWithValue(_SilentVpnBackend()),
      ],
    );
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    await _settle(c);

    await ctrl.lock();

    expect(ctrl.lastTeardown.complete, isTrue);
    expect(ctrl.lastTeardown.incomplete, isEmpty);
  });

  test('a lock stops the microphone (report17 XV17-M5)', () async {
    // The controllers that hold the microphone, the camera and playback are
    // GLOBAL providers: a lock does not dispose them and an identity switch
    // does not rebuild them. Nothing in the lifecycle asked them to stop, so
    // capture continued behind the lock screen and into the next identity.
    final rec = _RecordingMic();
    final c = ProviderContainer(
      overrides: [
        vpnBackendProvider.overrideWithValue(_SilentVpnBackend()),
        voiceRecorderFactoryProvider.overrideWithValue(() => rec),
        micPermissionProvider.overrideWithValue(() async => true),
      ],
    );
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    await _settle(c);
    await c.read(voiceRecordControllerProvider.notifier).start();
    expect(
      c.read(voiceRecordControllerProvider).isRecording,
      isTrue,
      reason: 'precondition: nothing was capturing, so this proves nothing',
    );

    await ctrl.lock();

    expect(
      rec.disposed,
      isTrue,
      reason: 'the microphone was still capturing behind the lock screen',
    );
    expect(c.read(voiceRecordControllerProvider).isRecording, isFalse);
  });

  test('a wipe reports a survivor that is not on disk', () async {
    // The wipe re-stats what it deleted and reports what is still there. A
    // tunnel still carrying this person's traffic is a survivor too, and it is
    // in no directory — so a wipe that destroyed every byte showed the same
    // screen as one that left the network side up.
    final vpn = _RecordingVpn(phase: VpnBackendPhase.error);
    SharedPreferences.setMockInitialValues({'onboarded': true});
    final c = ProviderContainer(
      overrides: [
        vpnControllerProvider.overrideWith(() => vpn),
        vpnBackendProvider.overrideWithValue(_SilentVpnBackend()),
      ],
    );
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    await _settle(c);

    final remaining = await ctrl.wipeContainers();

    expect(vpn.stops, 1, reason: 'precondition: the wipe asked at all');
    expect(
      remaining,
      contains('network'),
      reason: 'a wipe that left the tunnel up reported a clean wipe',
    );
  });
}

/// Records the teardown stop without touching a platform channel.
///
/// [VpnController.stopForTeardown], not `stop`: a lock or a wipe must not be
/// talked out of stopping the tunnel by a start still in flight or by the
/// default state of a controller the teardown itself just built, so that is the
/// entry point the teardown uses (audit XV-H2).
/// A microphone that says whether it was closed.
class _RecordingMic implements VoiceRecorder {
  bool started = false;
  bool disposed = false;

  @override
  bool start() {
    started = true;
    return true;
  }

  @override
  double get level => 0.5;
  @override
  int get elapsedMs => 100;
  @override
  VoiceClip? stop({int waveformBars = 48}) => null;
  @override
  void dispose() => disposed = true;
}

class _RecordingVpn extends VpnController {
  _RecordingVpn({
    this.phase = VpnBackendPhase.stopped,
    this.fails,
    this.neverAnswers = false,
    this.inertBuild = false,
  });

  int stops = 0;

  /// What the OS backend reports. `error` is the case that used to pass
  /// unnoticed: nothing is thrown, and the tunnel is still up.
  final VpnBackendPhase phase;

  /// Thrown instead of answering — a plugin that is not installed, a channel
  /// that is gone with the activity.
  final Object? fails;

  /// Never answers at all. The unresponsive plugin: the reason the call is
  /// bounded in the first place.
  final bool neverAnswers;

  /// Skip the controller's OWN restore-and-probe, which [build] schedules.
  ///
  /// Set by the fake-clock test only, and not to make anything pass: the
  /// restore awaits shared preferences, a real future that completes on the
  /// real event loop long after a `fakeAsync` block has ended and the
  /// container has been disposed, and the restore then resumes onto a dead
  /// `Ref`. That is a property of the restore under a fake clock — it happens
  /// with the teardown call removed entirely — and it is reported against
  /// whichever test is running. The other two tests here run the REAL build,
  /// which is what keeps the XV-H2 property (the teardown builds the
  /// controller itself and must still reach the backend) under test.
  final bool inertBuild;

  @override
  VpnState build() => inertBuild ? const VpnState() : super.build();

  @override
  Future<VpnBackendPhase> stopForTeardown() async {
    stops++;
    if (fails != null) throw fails!;
    if (neverAnswers) return Completer<VpnBackendPhase>().future;
    return phase;
  }
}
