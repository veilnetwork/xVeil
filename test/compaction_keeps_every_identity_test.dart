// Compaction keeps SPACES, and a master is not its children.
//
// `compact_known` keeps exactly the spaces whose own passwords it is given and
// destroys every other one — the library's own test says so
// (`repack_drops_hidden_space_when_password_not_supplied`). Each identity under
// a master is a separate space with a separate password, so a compaction run
// with the master's password alone keeps the master and deletes every identity
// in it.
//
// The offer was built on the opposite belief — it printed "with N more under
// it" beneath "Will be kept" — and that made the one screen meant to prevent a
// data loss into a way to cause one, with a reassurance on top.
//
// What replaces the belief is a checklist the app builds itself: a master's
// roster names every child, so "did I remember them all?" is a question the
// app can answer instead of asking.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/domain/storage_compaction_policy.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/features/settings/compaction_offer_dialog.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/state/providers.dart';

import 'support/fake_hv_container.dart';

List<int> _keys(int seed) => List<int>.generate(64, (i) => (seed + i) & 0xff);

/// A storage whose close takes long enough for the tree to rebuild.
///
/// The real teardown tears down a session, a node and a store, and frames are
/// rendered while it does — which is what lets the router's redirect unmount
/// the screen that asked for the compaction BEFORE the collection opens. A
/// fake that closes within the same microtask never gives the redirect a
/// chance, so the test cannot see the defect (report27 X28).
class _SlowClose extends HiddenVolumeStorage {
  _SlowClose(super.opener, {required this.gate, super.keysOpener});

  /// Held until the test says so, so the teardown is PAUSED at the point the
  /// router's redirect has already happened. A delay would race the frame; a
  /// gate does not.
  final Future<void> gate;

  @override
  Future<void> close() async {
    await gate;
    return super.close();
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('the checklist a master hands over', () {
    test('a master alone leaves every child uncovered', () {
      final roster = CompactionRoster();
      roster.expectSpaces([
        (label: 'me', keys: _keys(1)),
        (label: 'work', keys: _keys(2)),
      ]);
      roster.addUnlocked(
        'master',
        passwordBytes: 'm'.codeUnits,
        spaceKeys: _keys(9), // the master's own space, not a child's
      );

      expect(roster.uncovered, ['me', 'work']);
      expect(
        roster.isComplete,
        isFalse,
        reason: 'compacting here would delete both identities',
      );
    });

    test('each password typed ticks off exactly its own space', () {
      final roster = CompactionRoster();
      roster.expectSpaces([
        (label: 'me', keys: _keys(1)),
        (label: 'work', keys: _keys(2)),
      ]);
      roster.addUnlocked('a', passwordBytes: 'pw-me'.codeUnits,
          spaceKeys: _keys(1));
      expect(roster.uncovered, ['work']);

      roster.addUnlocked('b', passwordBytes: 'pw-work'.codeUnits,
          spaceKeys: _keys(2));
      expect(roster.uncovered, isEmpty);
      expect(roster.isComplete, isTrue);
    });

    test('one space under two names is one space', () {
      // A decoy master lists the same identity under a label of its own. The
      // keys are what say it is the same space; counting the label twice would
      // leave a checklist nobody can finish.
      final roster = CompactionRoster();
      roster.expectSpaces([(label: 'me', keys: _keys(1))]);
      roster.expectSpaces([(label: 'the cover story', keys: _keys(1))]);
      roster.addUnlocked('x', passwordBytes: 'pw'.codeUnits,
          spaceKeys: _keys(1));
      expect(roster.uncovered, isEmpty);
    });

    test('a password with no keys proves nothing', () {
      // Being generous here would be the whole defect again: "some passwords
      // were typed" is not "every identity is on the list".
      final roster = CompactionRoster();
      roster.expectSpaces([(label: 'me', keys: _keys(1))]);
      roster.addUnlocked('x', passwordBytes: 'pw'.codeUnits);
      expect(roster.uncovered, ['me']);
    });
  });

  group('the refusal is in the controller, not in the screen', () {
    test('a compaction that would drop an identity does not run', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctrl = c.read(appControllerProvider.notifier);

      final roster = CompactionRoster();
      roster.expectSpaces([
        (label: 'me', keys: _keys(1)),
        (label: 'work', keys: _keys(2)),
      ]);
      roster.addUnlocked('master', passwordBytes: 'm'.codeUnits,
          spaceKeys: _keys(9));

      await expectLater(
        ctrl.compactStorageKeeping(roster: roster, reopenWith: 'm'),
        throwsA(
          isA<CompactionWouldDropIdentities>().having(
            (e) => e.labels,
            'labels',
            ['me', 'work'],
          ),
        ),
      );
    });

    test('an empty roster is still refused', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctrl = c.read(appControllerProvider.notifier);
      await expectLater(
        ctrl.compactStorageKeeping(
          roster: CompactionRoster(),
          reopenWith: 'm',
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('what a password opens, as the app sees it', () {
    test('a master reports its children, by the keys that name them', () async {
      final container = FakeHvContainer();
      final c = ProviderContainer(
        overrides: [storageProvider.overrideWith((ref) => container.storage())],
      );
      addTearDown(c.dispose);

      // Two identities and a master that lists them.
      final childKeys = <String, Uint8List>{};
      for (final entry in {'me': 'pw-me', 'work': 'pw-work'}.entries) {
        final space = container.storage();
        expect(
          await space.open(password: entry.value, createIfMissing: true),
          isTrue,
        );
        await space.saveProfile(UserProfile(displayName: entry.key));
        childKeys[entry.key] = await space.exportSpaceKeys();
        await space.close();
      }
      final master = container.storage();
      expect(await master.open(password: 'm', createIfMissing: true), isTrue);
      await master.saveRoster([
        for (final e in childKeys.entries)
          RosterEntry(label: e.key, spaceKeys: e.value),
      ]);
      await master.close();

      final probe = await c
          .read(appControllerProvider.notifier)
          .probeCompactionIdentity('m');

      expect(probe.opened, isTrue);
      expect(probe.isMaster, isTrue);
      expect(probe.children.map((e) => e.label), ['me', 'work']);
      expect(probe.children.first.keys, childKeys['me']);
      expect(
        probe.spaceKeys,
        isNotNull,
        reason: 'without the space it opened, nothing can be ticked off',
      );

      // And the checklist built from it is only finished by the children's own
      // passwords.
      final roster = CompactionRoster()..expectSpaces(probe.children);
      roster.addUnlocked('master',
          passwordBytes: 'm'.codeUnits, spaceKeys: probe.spaceKeys);
      expect(roster.uncovered, ['me', 'work']);

      for (final pw in ['pw-me', 'pw-work']) {
        final p = await c
            .read(appControllerProvider.notifier)
            .probeCompactionIdentity(pw);
        roster.addUnlocked(pw,
            passwordBytes: pw.codeUnits, spaceKeys: p.spaceKeys);
      }
      expect(roster.uncovered, isEmpty);
    });
  });

  group('the attestation behind automatic compaction', () {
    test('a second identity takes it back from every space', () async {
      // Auto-compaction means "this container holds only me". Adding an
      // identity makes that false, and the person who turned it on months ago
      // has no way to notice — so the app takes it back rather than leaving a
      // maintenance job that deletes the new identity.
      final container = FakeHvContainer();
      final c = ProviderContainer(
        overrides: [storageProvider.overrideWith((ref) => container.storage())],
      );
      addTearDown(c.dispose);

      final entries = <RosterEntry>[];
      for (final pw in ['pw-me', 'pw-work']) {
        final space = container.storage();
        expect(await space.open(password: pw, createIfMissing: true), isTrue);
        await space.putSetting('storage.autocompact.v1', '1');
        entries.add(
          RosterEntry(label: pw, spaceKeys: await space.exportSpaceKeys()),
        );
        await space.close();
      }

      await c
          .read(appControllerProvider.notifier)
          .revokeAutoCompactAcross(entries);

      for (final entry in entries) {
        final space = container.storage();
        expect(await space.openWithKeys(entry.spaceKeys), isTrue);
        expect(
          await space.getSetting('storage.autocompact.v1'),
          '0',
          reason: '${entry.label} still claims to be alone in this container',
        );
        await space.close();
      }
    });

    test('a space that never claimed it is not rewritten for it', () async {
      // The revocation writes only where there is something to take back: a
      // container is a log, and a write that changes nothing still grows it.
      final container = FakeHvContainer();
      final c = ProviderContainer(
        overrides: [storageProvider.overrideWith((ref) => container.storage())],
      );
      addTearDown(c.dispose);

      final space = container.storage();
      expect(await space.open(password: 'pw', createIfMissing: true), isTrue);
      final keys = await space.exportSpaceKeys();
      await space.close();

      await c.read(appControllerProvider.notifier).revokeAutoCompactAcross([
        RosterEntry(label: 'me', spaceKeys: keys),
      ]);

      final reopened = container.storage();
      expect(await reopened.openWithKeys(keys), isTrue);
      expect(
        await reopened.getSetting('storage.autocompact.v1'),
        isNull,
        reason: 'nothing was claimed, so nothing had to be written',
      );
      await reopened.close();
    });

    test('a space that cannot be opened does not fail the operation', () async {
      // Revocation rides along with adding an identity. A space that will not
      // open must not take that down with it.
      final container = FakeHvContainer();
      final c = ProviderContainer(
        overrides: [storageProvider.overrideWith((ref) => container.storage())],
      );
      addTearDown(c.dispose);

      await c.read(appControllerProvider.notifier).revokeAutoCompactAcross([
        RosterEntry(
          label: 'gone',
          spaceKeys: Uint8List.fromList(_keys(200)),
        ),
      ]);
    });
  });

  group('the screen the person actually sees', () {
    /// The collection survives the screen that started it going away.
    ///
    /// `beginCompactionCollection` moves the app to `preparingNode`, and the
    /// router sends `/home` and the settings routes to `/preparing` when it
    /// sees that — so the screen this was called from is unmounted while the
    /// teardown is still awaiting. The old code then found its context gone,
    /// cancelled the collection it had just opened, and returned null: the
    /// person asked to compact and was handed back nothing, never having seen
    /// the dialog that collects the passwords (report27 X28).
    ///
    /// The MaterialApp in the test below never redirects, which is why this
    /// went unnoticed. Here the calling widget is replaced the moment the
    /// phase changes, which is what the real router does.
    testWidgets('the dialog opens even when its caller is unmounted', (
      tester,
    ) async {
      final container = FakeHvContainer();
      final master = container.storage();
      await master.open(password: 'm', createIfMissing: true);
      await master.saveProfile(const UserProfile(displayName: 'Master'));
      await master.close();

      late AppL10n l;
      final gate = Completer<void>();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            storageProvider.overrideWith(
              (ref) => _SlowClose(
                container.passwordOpener,
                gate: gate.future,
                keysOpener: container.keysOpener,
              ),
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: AppL10n.localizationsDelegates,
            supportedLocales: AppL10n.supportedLocales,
            home: Consumer(
              builder: (context, ref, _) {
                l = AppL10n.of(context);
                // What the router does: the phase decides which screen is
                // mounted, so the caller goes away mid-teardown.
                final phase = ref.watch(
                  appControllerProvider.select((s) => s.phase),
                );
                if (phase == AppPhase.preparingNode) {
                  return const Scaffold(body: Text('preparing'));
                }
                // The caller's context belongs to a widget INSIDE the branch
                // that goes away — which is what a route replacement does.
                // Passing the Consumer's own context would not reproduce it:
                // that element stays mounted at its position and only its
                // child subtree changes.
                return Scaffold(
                  body: Builder(
                    builder: (callerContext) => TextButton(
                      onPressed: () => showCompactionOffer(
                        callerContext,
                        ref,
                        estimate: const CompactionEstimate(
                          fileBytes: 4 << 30,
                          liveBytes: 1 << 28,
                          identitiesCounted: 1,
                          identitiesKnown: 1,
                        ),
                        currentPassword: 'm',
                      ),
                      child: const Text('open'),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      // One frame: the phase is already `preparingNode`, so the router's
      // stand-in has replaced the screen that asked — while the teardown is
      // still inside `close`.
      await tester.pump();
      expect(
        find.text('preparing'),
        findsOneWidget,
        reason: 'premise: the phase change really did replace the caller',
      );

      // Only now does the teardown finish and the collection open.
      gate.complete();
      await tester.pumpAndSettle();
      expect(
        find.text(l.compactOfferKeeping),
        findsOneWidget,
        reason:
            'the collection dialog never opened — the screen that asked for '
            'it was gone by the time the teardown finished, and the request '
            'was dropped',
      );
    });


    testWidgets('the master password alone cannot start a compaction', (
      tester,
    ) async {
      final container = FakeHvContainer();
      final childKeys = <String, Uint8List>{};
      for (final entry in {'me': 'pw-me', 'work': 'pw-work'}.entries) {
        final space = container.storage();
        await space.open(password: entry.value, createIfMissing: true);
        await space.saveProfile(UserProfile(displayName: entry.key));
        childKeys[entry.key] = await space.exportSpaceKeys();
        await space.close();
      }
      final master = container.storage();
      await master.open(password: 'm', createIfMissing: true);
      await master.saveProfile(const UserProfile(displayName: 'Master'));
      await master.saveRoster([
        for (final e in childKeys.entries)
          RosterEntry(label: e.key, spaceKeys: e.value),
      ]);
      await master.close();

      late AppL10n l;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            storageProvider.overrideWith((ref) => container.storage()),
          ],
          child: MaterialApp(
            localizationsDelegates: AppL10n.localizationsDelegates,
            supportedLocales: AppL10n.supportedLocales,
            home: Consumer(
              builder: (context, ref, _) {
                l = AppL10n.of(context);
                return TextButton(
                  onPressed: () => showCompactionOffer(
                    context,
                    ref,
                    estimate: const CompactionEstimate(
                      fileBytes: 4 << 30,
                      liveBytes: 1 << 28,
                      identitiesCounted: 1,
                      identitiesKnown: 3,
                    ),
                    currentPassword: 'm',
                  ),
                  child: const Text('open'),
                );
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      bool canRun() {
        final button = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, l.compactOfferRun),
        );
        return button.onPressed != null;
      }

      // The master is unlocked, and the two identities under it are named as
      // still missing — by the app, from the master's own roster.
      expect(
        find.text(l.compactOfferKeeping),
        findsOneWidget,
        reason: 'the password already in hand must be on the list by itself',
      );
      expect(find.text(l.compactOfferStillNeeded), findsOneWidget);
      expect(find.text('me'), findsOneWidget);
      expect(find.text('work'), findsOneWidget);
      expect(
        canRun(),
        isFalse,
        reason: 'this compaction would delete both identities',
      );

      await tester.enterText(find.byType(TextField), 'pw-me');
      await tester.tap(find.text(l.compactOfferAdd));
      await tester.pumpAndSettle();
      expect(find.text(l.compactOfferStillNeeded), findsOneWidget);
      expect(canRun(), isFalse, reason: 'one identity is still unaccounted for');

      await tester.enterText(find.byType(TextField), 'pw-work');
      await tester.tap(find.text(l.compactOfferAdd));
      await tester.pumpAndSettle();
      expect(find.text(l.compactOfferStillNeeded), findsNothing);
      expect(canRun(), isTrue);
    });
  });

  group('adding an identity takes the attestation back', () {
    test('the identity that was alone here stops claiming to be', () async {
      // The whole point, end to end: somebody turns auto-compaction on while
      // this really is the only identity in the container, adds a second one
      // months later, and never thinks about a storage switch again. Unlocking
      // the first identity by its own password would then compact the second
      // one away.
      SharedPreferences.setMockInitialValues({'onboarded': true});
      final container = FakeHvContainer();
      final solo = container.storage();
      await solo.open(password: 'solopw', createIfMissing: true);
      await solo.saveProfile(const UserProfile(displayName: 'Solo'));
      await solo.putSetting('storage.autocompact.v1', '1');
      final soloKeys = await solo.exportSpaceKeys();
      await solo.close();

      final app = container.storage();
      final c = ProviderContainer(
        overrides: [storageProvider.overrideWith((ref) => app)],
      );
      addTearDown(c.dispose);
      final ctrl = c.read(appControllerProvider.notifier);
      for (var i = 0; i < 20 &&
          c.read(appControllerProvider).phase == AppPhase.bootstrapping; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await ctrl.unlock('solopw');
      expect(await ctrl.autoCompactEnabled(), isTrue);

      expect(
        await ctrl.addIdentity(
          masterPassword: 'masterpw',
          label: 'Work',
          password: 'workpw',
          existingLabel: 'Personal',
        ),
        isTrue,
      );

      // Read it back from the space itself, not from the session: this has to
      // be true the next time that password is typed at the lock screen. The
      // live session holds the container's exclusive lock, so it goes first.
      await ctrl.lock();
      final probe = container.storage();
      expect(await probe.openWithKeys(soloKeys), isTrue);
      expect(
        await probe.getSetting('storage.autocompact.v1'),
        '0',
        reason:
            'unlocking this identity alone would compact the new one away',
      );
      await probe.close();
    });
  });

  group('what a compaction does to the master that names the children', () {
    test('a roster survives the fresh keys a repack gives every space', () async {
      // A repack writes its destination with a FRESH SALT — hidden-volume's
      // own documentation says the same password then derives different keys,
      // and that is a property worth keeping. What it breaks is every stored
      // reference to a space BY KEYS, and a master's roster is exactly that:
      // after a compaction that kept every identity, the master opened and
      // none of its children did (report27 X27).
      //
      // The fake container models the real rule: keys are derived from the
      // password AND the container's salt, so "compacting" it re-derives them.
      final container = FakeHvContainer();
      final childPasswords = {'me': 'pw-me', 'work': 'pw-work'};
      final roster = CompactionRoster();

      final before = <String, Uint8List>{};
      for (final entry in childPasswords.entries) {
        final space = container.storage();
        await space.open(password: entry.value, createIfMissing: true);
        await space.saveProfile(UserProfile(displayName: entry.key));
        before[entry.key] = await space.exportSpaceKeys();
        await space.close();
      }
      final master = container.storage();
      await master.open(password: 'm', createIfMissing: true);
      await master.saveRoster([
        for (final e in before.entries)
          RosterEntry(label: e.key, spaceKeys: e.value),
      ]);
      final masterKeys = await master.exportSpaceKeys();
      await master.close();

      roster.addUnlocked('master',
          passwordBytes: 'm'.codeUnits, spaceKeys: masterKeys);
      for (final entry in childPasswords.entries) {
        roster.addUnlocked(entry.key,
            passwordBytes: entry.value.codeUnits,
            spaceKeys: before[entry.key]);
      }

      // Every password the compaction would be given comes with the space it
      // opened — that pair is the only thing that can say which label a
      // password belongs to once the keys have changed.
      final credentials = roster.credentials();
      expect(credentials, hasLength(3));
      expect(
        credentials.map((c) => c.oldSpaceKeys).toSet(),
        {masterKeys, ...before.values},
      );

      // The repack: same passwords, new salt, so every space keys differently.
      container.rotateSalt();

      final c = ProviderContainer(
        overrides: [storageProvider.overrideWith((ref) => container.storage())],
      );
      addTearDown(c.dispose);
      final stale = await c
          .read(appControllerProvider.notifier)
          .remapRostersAfterCompaction(credentials);
      expect(stale, isEmpty);

      // The master now names its children by keys that open them.
      final reopened = container.storage();
      expect(await reopened.open(password: 'm'), isTrue);
      final repaired = await reopened.loadRoster();
      await reopened.close();
      expect(repaired, isNotNull);
      expect(repaired!.map((e) => e.label), ['me', 'work']);
      for (final entry in repaired) {
        final child = container.storage();
        expect(
          await child.openWithKeys(entry.spaceKeys),
          isTrue,
          reason:
              '"${entry.label}" is named by keys nothing in this container '
              'has any more — the master that names it stopped working',
        );
        await child.close();
      }
    });
  });
}
