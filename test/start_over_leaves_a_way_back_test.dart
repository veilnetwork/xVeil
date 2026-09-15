// "Start over" is not allowed to be a one-way door.
//
// Reported from the field, by someone who pressed it to see what it did:
// "восстановил личность, потом вернулся в меню, нажал начать всё заново, дошел
// до 24 слов, вернулся и теперь не могу открыть контейнер. Теперь только
// кнопка продолжить и там или создать или восстановить или привязать
// устройство".
//
// Every word of that is what the code did. `startOver` removes the onboarded
// flag and leaves the container file alone — on purpose, and its own
// confirmation says so: "existing data is not deleted, but you will need its
// password to reach it again". What it did not say is that it also removes the
// only screen that takes that password. The next boot reads the missing flag
// and lands on onboarding, and onboarding offered four doors — create,
// restore, link, archive — each of which ends in a NEW identity.
//
// So the data was never lost and never reachable. These tests hold the door
// that was missing.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/features/onboarding/onboarding_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/l10n/app_localizations_en.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/providers.dart';

Future<void> _settle(ProviderContainer c) async {
  for (
    var i = 0;
    i < 40 && c.read(appControllerProvider).phase == AppPhase.bootstrapping;
    i++
  ) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// Opens for nobody — a device with nothing on it, or a wrong password. The
/// screen must not be able to tell those apart, so neither does this.
class _OpensForNobody implements Storage {
  @override
  Future<bool> open({
    required String password,
    bool createIfMissing = false,
  }) async => false;

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('storage used after open() refused');
}

class _NoopNode implements NodeController {
  @override
  NodeStatus get current => const NodeStatus(phase: NodePhase.connected);
  @override
  Stream<NodeStatus> status() => const Stream.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> setEconomyMode(bool economy) async {}
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the container that start-over forgot can be opened again', () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    await _settle(c);
    await ctrl.completeOnboarding(
      password: 'pw',
      displayName: 'Me',
      mode: StorageMode.hiddenSpace,
    );
    expect(c.read(appControllerProvider).phase, AppPhase.ready);

    await ctrl.startOver();
    expect(c.read(appControllerProvider).phase, AppPhase.onboarding);
    // The control, and the whole defect in one line: at this moment a fresh
    // launch sees a device that was never set up.
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getBool('onboarded'),
      isNot(true),
      reason: 'without this the test below would prove nothing',
    );

    expect(await ctrl.reopenExistingContainer('pw'), isTrue);
    expect(
      c.read(appControllerProvider).phase,
      AppPhase.ready,
      reason: 'the password that made this container still opens it',
    );

    // And it STAYS open across a launch: the flag is back, so the next boot
    // goes to the lock screen instead of offering to make a new identity.
    final c2 = ProviderContainer();
    addTearDown(c2.dispose);
    c2.read(appControllerProvider.notifier);
    await _settle(c2);
    expect(c2.read(appControllerProvider).phase, AppPhase.locked);
  });

  test('a password that opens nothing leaves no trace of having been tried', () async {
    final c = ProviderContainer(
      overrides: [storageProvider.overrideWith((ref) => _OpensForNobody())],
    );
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    await _settle(c);
    expect(c.read(appControllerProvider).phase, AppPhase.onboarding);

    expect(await ctrl.reopenExistingContainer('not the password'), isFalse);
    expect(
      c.read(appControllerProvider).phase,
      AppPhase.onboarding,
      reason:
          'a refused attempt must leave the person on the choice, not stranded '
          'on a lock screen for a container that may not exist',
    );
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getBool('onboarded'),
      isNot(true),
      reason:
          'marking a device onboarded because someone GUESSED at it would send '
          'the next launch to a lock screen with nothing behind it',
    );
  });

  testWidgets('the choice offers the door, and it asks for a password', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [nodeControllerProvider.overrideWithValue(_NoopNode())],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: OnboardingScreen(generatePhrase: () => null),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final l = AppL10nEn();
    await tester.tap(find.text(l.actionContinue));
    await tester.pumpAndSettle();

    // Present WITHOUT any container existing. An entry that appeared only when
    // there was something to open would answer, by its presence, the one
    // question this app must never answer.
    final door = find.text(l.onboardOpenExisting);
    expect(door, findsOneWidget);
    await tester.ensureVisible(door);
    await tester.pumpAndSettle();
    await tester.tap(door);
    await tester.pumpAndSettle();

    expect(find.text(l.onboardOpenExistingBody), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
      reason: 'nothing to try until a password is typed',
    );
    await tester.enterText(find.byType(TextField), 'pw');
    await tester.pumpAndSettle();
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
  });

  test('setting up over a container that already has an identity is refused', () async {
    // The mistake this release makes likelier, and the most expensive one in
    // the app. `open` is called with createIfMissing, so the password that
    // made a container OPENS it — and the ceremony then writes a fresh
    // sovereign credential over the old one with `storeFile`. That credential
    // IS the identity: the phrase fixes only its Ed25519 half and the Falcon
    // half exists nowhere else, so replacing it renames the person to an
    // address none of their contacts hold. Silently, and with no undo.
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    await _settle(c);
    await ctrl.completeOnboarding(
      password: 'pw',
      displayName: 'Me',
      mode: StorageMode.hiddenSpace,
    );
    // A container that has actually been USED. The loopback harness boots no
    // node, so nothing writes a node config on its own — and the guard is
    // about the identity, not about the display name, so the fixture has to
    // put one there the way a real boot does.
    final storage = c.read(storageProvider);
    await storage.saveNodeConfig('[identity]\nkey = "already here"');
    final before = await storage.loadNodeConfig();
    expect(
      before,
      isNotNull,
      reason: 'the fixture has to hold an identity or this proves nothing',
    );

    await ctrl.startOver();
    await expectLater(
      ctrl.completeOnboarding(
        password: 'pw', // the same container, reached the wrong way
        displayName: 'Someone else',
        mode: StorageMode.hiddenSpace,
      ),
      throwsA(isA<ContainerAlreadyHasAnIdentity>()),
    );

    // And it is still there afterwards, reachable by the door that exists.
    expect(await ctrl.reopenExistingContainer('pw'), isTrue);
    expect(await c.read(storageProvider).loadNodeConfig(), before);
  });
}
