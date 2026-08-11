import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/core/secure_screen.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/features/onboarding/onboarding_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/providers.dart';

import 'support/onboarding_walk.dart';

/// A node controller with no timers (FakeNodeController uses delayed/periodic
/// timers that leak past a widget test).
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

  testWidgets('create-identity wizard completes into a ready session', (
    tester,
  ) async {
    late ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [nodeControllerProvider.overrideWithValue(_NoopNode())],
        child: Consumer(
          builder: (ctx, ref, _) {
            container = ProviderScope.containerOf(ctx);
            return MaterialApp(
              localizationsDelegates: AppL10n.localizationsDelegates,
              supportedLocales: AppL10n.supportedLocales,
              home: const OnboardingScreen(),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    AppL10n l() => AppL10n.of(tester.element(find.byType(OnboardingScreen)));

    // 0 welcome -> Continue
    await tester.tap(find.text(l().actionContinue));
    await tester.pumpAndSettle();
    // No dead "import backup" affordance: recovery phrase is the only restore
    // path until a deniable export/import format actually exists.
    expect(find.byIcon(Icons.file_open_outlined), findsNothing);
    // 1 choose -> Create a new identity
    await tester.tap(find.text(l().onboardCreateIdentity));
    await tester.pumpAndSettle();
    // 2 recovery -> confirm checkbox, Continue. Both sit below word 24 in
    // the step's own scroll now, so the walk scrolls to them.
    await confirmRecoveryPhrase(tester, continueLabel: l().actionContinue);
    // 3 storage -> Continue (default hidden space)
    await tester.tap(find.text(l().actionContinue));
    await tester.pumpAndSettle();
    // 7 network entry -> Continue (default: keep the shared seed nodes)
    await tester.tap(find.text(l().actionContinue));
    await tester.pumpAndSettle();
    // 4 password -> enter + repeat + Done
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'test123');
    await tester.enterText(fields.at(1), 'test123');
    await tester.tap(find.text(l().actionDone));
    // The submit button shows a spinner and (in the real app) the router
    // navigates away on ready — here we just pump bounded frames for the
    // async completeOnboarding to finish, then assert.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(container.read(appControllerProvider).phase, AppPhase.ready);
  });

  testWidgets(
    'restore wizard gates on the validator and completes into ready',
    (tester) async {
      late ProviderContainer container;
      final validated = <String>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [nodeControllerProvider.overrideWithValue(_NoopNode())],
          child: Consumer(
            builder: (ctx, ref, _) {
              container = ProviderScope.containerOf(ctx);
              return MaterialApp(
                localizationsDelegates: AppL10n.localizationsDelegates,
                supportedLocales: AppL10n.supportedLocales,
                home: OnboardingScreen(
                  // Fake validator (the real one is FFI): any 24 words pass.
                  validatePhrase: (p) {
                    validated.add(p);
                    return p.split(' ').length == 24;
                  },
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      AppL10n l() => AppL10n.of(tester.element(find.byType(OnboardingScreen)));
      bool submitEnabled() =>
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, l().onboardRestoreSubmit),
              )
              .onPressed !=
          null;

      // 0 welcome -> Continue, 1 choose -> Restore from recovery phrase.
      await tester.tap(find.text(l().actionContinue));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l().onboardRestoreIdentity));
      await tester.pumpAndSettle();

      // 5 restore: 23 words keep the button disabled even if the validator
      // would pass; 24 words that fail validation stay disabled too.
      final field = find.byType(TextField);
      await tester.enterText(field, List.generate(23, (i) => 'w$i').join(' '));
      await tester.pumpAndSettle();
      expect(submitEnabled(), isFalse);

      // 24 normalized words (extra whitespace + case must not matter).
      await tester.enterText(
        field,
        '  ${List.generate(24, (i) => 'W$i').join('   ')} ',
      );
      await tester.pumpAndSettle();
      expect(submitEnabled(), isTrue);
      await tester.tap(find.text(l().onboardRestoreSubmit));
      await tester.pumpAndSettle();
      expect(validated, contains(List.generate(24, (i) => 'w$i').join(' ')));

      // 3 storage -> Continue, 7 network entry -> Continue, 4 password -> Done.
      await tester.tap(find.text(l().actionContinue));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l().actionContinue));
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'test123');
      await tester.enterText(fields.at(1), 'test123');
      await tester.tap(find.text(l().actionDone));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(container.read(appControllerProvider).phase, AppPhase.ready);
    },
  );

  group('linking to a device you already use', () {
    // A second device joins an existing device group. It must NOT be walked
    // through the sovereign ritual: the 24 words it would be told to write
    // down restore an identity it never owns, and the person already has the
    // real phrase on the device they are linking from. What it needs is a
    // temporary identity good enough to reach the network and be adopted.

    Future<ProviderContainer> pump(WidgetTester tester) async {
      late ProviderContainer container;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [nodeControllerProvider.overrideWithValue(_NoopNode())],
          child: Consumer(
            builder: (ctx, ref, _) {
              container = ProviderScope.containerOf(ctx);
              return MaterialApp(
                localizationsDelegates: AppL10n.localizationsDelegates,
                supportedLocales: AppL10n.supportedLocales,
                home: const OnboardingScreen(),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    AppL10n l(WidgetTester tester) =>
        AppL10n.of(tester.element(find.byType(OnboardingScreen)));

    Future<void> toChoosePath(WidgetTester tester) async {
      await tester.tap(find.text(l(tester).actionContinue));
      await tester.pumpAndSettle();
    }

    testWidgets('the link path reaches ready and asks for no phrase', (
      tester,
    ) async {
      final container = await pump(tester);
      await toChoosePath(tester);
      await tester.tap(find.text(l(tester).onboardLinkDevice));
      await tester.pumpAndSettle();

      // The explanation step, NOT the recovery step.
      expect(find.text(l(tester).onboardLinkDeviceBody), findsOneWidget);
      expect(
        find.text(l(tester).recoveryTitle),
        findsNothing,
        reason: 'a device being adopted must never be told to back up words '
            'that restore an identity it will not own',
      );
      expect(find.byType(Checkbox), findsNothing);

      await tester.tap(find.text(l(tester).actionContinue));
      await tester.pumpAndSettle(); // 3 storage
      await tester.tap(find.text(l(tester).actionContinue));
      await tester.pumpAndSettle(); // 7 network entry
      await tester.tap(find.text(l(tester).actionContinue));
      await tester.pumpAndSettle(); // 4 password
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'test123');
      await tester.enterText(fields.at(1), 'test123');
      await tester.tap(find.text(l(tester).actionDone));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(container.read(appControllerProvider).phase, AppPhase.ready);
      expect(
        container.read(pendingDeviceLinkProvider),
        isTrue,
        reason: 'the session must open on the device-link screen; without '
            'this the user lands on chats as a stranger to their own account',
      );
    });

    testWidgets('the create path does NOT arm the device-link handoff', (
      tester,
    ) async {
      // Guards the flag against firing for everyone: a create-path user
      // hijacked onto the link screen would be told to approve a device from
      // an account that does not exist yet.
      final container = await pump(tester);
      await toChoosePath(tester);
      await tester.tap(find.text(l(tester).onboardCreateIdentity));
      await tester.pumpAndSettle();
      await confirmRecoveryPhrase(
        tester,
        continueLabel: l(tester).actionContinue,
      );
      await tester.tap(find.text(l(tester).actionContinue));
      await tester.pumpAndSettle();
      // 7 network entry -> Continue (default: keep the shared seed nodes)
      await tester.tap(find.text(l(tester).actionContinue));
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'test123');
      await tester.enterText(fields.at(1), 'test123');
      await tester.tap(find.text(l(tester).actionDone));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(container.read(appControllerProvider).phase, AppPhase.ready);
      expect(container.read(pendingDeviceLinkProvider), isFalse);
    });

    testWidgets('backing out of link and creating instead clears the intent', (
      tester,
    ) async {
      // The intent is a field that outlives the step. Someone who opens the
      // link path, changes their mind, and creates an identity would otherwise
      // finish as a device sitting on the join screen waiting for an approval
      // that is never coming.
      final container = await pump(tester);
      await toChoosePath(tester);
      await tester.tap(find.text(l(tester).onboardLinkDevice));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      expect(
        find.text(l(tester).onboardCreateIdentity),
        findsOneWidget,
        reason: 'back from the link step lands on the path choice, not welcome',
      );
      await tester.tap(find.text(l(tester).onboardCreateIdentity));
      await tester.pumpAndSettle();
      await confirmRecoveryPhrase(
        tester,
        continueLabel: l(tester).actionContinue,
      );
      await tester.tap(find.text(l(tester).actionContinue));
      await tester.pumpAndSettle();
      // 7 network entry -> Continue (default: keep the shared seed nodes)
      await tester.tap(find.text(l(tester).actionContinue));
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'test123');
      await tester.enterText(fields.at(1), 'test123');
      await tester.tap(find.text(l(tester).actionDone));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(container.read(appControllerProvider).phase, AppPhase.ready);
      expect(container.read(pendingDeviceLinkProvider), isFalse);
    });
  });

  group('the password step is the last chance to get it right', () {
    // There is no recovery path for the container password: no reset, no
    // escrow, nothing to email. A password accepted here that is not the one
    // the person thinks they chose costs them everything they will ever put in
    // the app, on the very first screen. Both guards below existed and neither
    // was covered -- the whole suite passed with the confirmation check
    // deleted.

    /// Walk the create-identity wizard as far as the password step.
    Future<ProviderContainer> reachPasswordStep(WidgetTester tester) async {
      late ProviderContainer container;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [nodeControllerProvider.overrideWithValue(_NoopNode())],
          child: Consumer(
            builder: (ctx, ref, _) {
              container = ProviderScope.containerOf(ctx);
              return MaterialApp(
                localizationsDelegates: AppL10n.localizationsDelegates,
                supportedLocales: AppL10n.supportedLocales,
                home: const OnboardingScreen(),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      AppL10n l() => AppL10n.of(tester.element(find.byType(OnboardingScreen)));
      await tester.tap(find.text(l().actionContinue));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l().onboardCreateIdentity));
      await tester.pumpAndSettle();
      await confirmRecoveryPhrase(tester, continueLabel: l().actionContinue);
      await tester.tap(find.text(l().actionContinue));
      await tester.pumpAndSettle();
      // 7 network entry -> Continue (default: keep the shared seed nodes)
      await tester.tap(find.text(l().actionContinue));
      await tester.pumpAndSettle();
      return container;
    }

    Future<void> submit(WidgetTester tester, String pw, String repeat) async {
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), pw);
      await tester.enterText(fields.at(1), repeat);
      await tester.tap(
        find.text(
          AppL10n.of(tester.element(find.byType(OnboardingScreen))).actionDone,
        ),
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    testWidgets('a mistyped confirmation does NOT create the container', (
      tester,
    ) async {
      final container = await reachPasswordStep(tester);
      final l = AppL10n.of(tester.element(find.byType(OnboardingScreen)));
      await submit(tester, 'correct-horse', 'correct-hosre');

      expect(
        container.read(appControllerProvider).phase,
        isNot(AppPhase.ready),
        reason:
            'the container would be sealed with a password they never '
            'chose, and nothing can open it afterwards',
      );
      expect(find.text(l.onboardPasswordMismatch), findsOneWidget);
    });

    testWidgets('a too-short password does NOT create the container', (
      tester,
    ) async {
      final container = await reachPasswordStep(tester);
      final l = AppL10n.of(tester.element(find.byType(OnboardingScreen)));
      await submit(tester, '123', '123');

      expect(
        container.read(appControllerProvider).phase,
        isNot(AppPhase.ready),
      );
      expect(find.text(l.onboardPasswordTooShort), findsOneWidget);
    });

    testWidgets('correcting the mistake then proceeds', (tester) async {
      // Without this the pair above would also pass on a step that can never
      // succeed at all -- "it refused" has to be distinguishable from "it is
      // broken".
      final container = await reachPasswordStep(tester);
      await submit(tester, 'correct-horse', 'correct-hosre');
      expect(
        container.read(appControllerProvider).phase,
        isNot(AppPhase.ready),
      );

      await submit(tester, 'correct-horse', 'correct-horse');
      expect(container.read(appControllerProvider).phase, AppPhase.ready);
    });
  });

  testWidgets('a placeholder phrase says so; a restored one does not', (
    tester,
  ) async {
    // `veilGeneratePhrase()` returns null when the native generator is
    // unavailable (exactly this environment) SO THAT the caller can degrade
    // honestly. The screen still showed those placeholder words under the
    // ordinary "these 24 words ARE your identity, write them down" copy, while
    // the identity was minted at random — the user would have backed up 24
    // words that restore nothing.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [nodeControllerProvider.overrideWithValue(_NoopNode())],
        child: MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: OnboardingScreen(validatePhrase: (_) => true),
        ),
      ),
    );
    await tester.pumpAndSettle();
    AppL10n l() => AppL10n.of(tester.element(find.byType(OnboardingScreen)));

    await tester.tap(find.text(l().actionContinue));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l().onboardCreateIdentity));
    await tester.pumpAndSettle();
    expect(
      find.text(l().recoveryTitle),
      findsOneWidget,
      reason: 'we are on the recovery step',
    );
    expect(
      find.text(l().recoveryPlaceholderWarning),
      findsOneWidget,
      reason: 'a phrase that restores nothing must be labelled as such',
    );

  });

  testWidgets('a restored phrase carries no placeholder warning', (
    tester,
  ) async {
    // The warning must not cry wolf: a phrase the user supplied IS real, and
    // labelling it "restores nothing" would push them to discard a good one.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [nodeControllerProvider.overrideWithValue(_NoopNode())],
        child: MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: OnboardingScreen(validatePhrase: (_) => true),
        ),
      ),
    );
    await tester.pumpAndSettle();
    AppL10n l() => AppL10n.of(tester.element(find.byType(OnboardingScreen)));

    await tester.tap(find.text(l().actionContinue));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l().onboardRestoreIdentity));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      List.generate(24, (i) => 'w$i').join(' '),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(l().onboardRestoreSubmit));
    await tester.pumpAndSettle();
    expect(find.text(l().recoveryPlaceholderWarning), findsNothing);
  });

  group('the 24 words are kept off any screenshot', () {
    // The recovery step shows, in plain words, everything needed to become this
    // person — and nothing in the app had ever asked the platform not to
    // capture the screen (audit X-11). Asserted on the REAL wizard rather than
    // on the guard widget alone, because the thing that can silently regress is
    // the wiring: the guard staying behind while the step moves.

    late List<bool> secureCalls;

    setUp(() {
      secureCalls = [];
      secureScreen.debugReset();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel(SecureScreen.channelName),
            (call) async {
              if (call.method == 'setSecure') {
                secureCalls.add((call.arguments as Map)['secure'] as bool);
              }
              return null;
            },
          );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel(SecureScreen.channelName),
            null,
          );
      secureScreen.debugReset();
    });

    Future<void> pump(WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [nodeControllerProvider.overrideWithValue(_NoopNode())],
          child: MaterialApp(
            localizationsDelegates: AppL10n.localizationsDelegates,
            supportedLocales: AppL10n.supportedLocales,
            home: OnboardingScreen(validatePhrase: (_) => true),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    AppL10n l(WidgetTester tester) =>
        AppL10n.of(tester.element(find.byType(OnboardingScreen)));

    testWidgets('the phrase step secures the screen and the next one frees it', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.text(l(tester).actionContinue));
      await tester.pumpAndSettle();
      expect(
        secureCalls,
        isEmpty,
        reason: 'the welcome and path steps carry nothing worth securing — a '
            'flag held app-wide would black out this app\'s own screen share',
      );

      await tester.tap(find.text(l(tester).onboardCreateIdentity));
      await tester.pumpAndSettle();
      expect(find.text(l(tester).recoveryTitle), findsOneWidget);
      expect(secureCalls, [true], reason: 'the words are on screen unprotected');

      // Off the step -> the flag goes back, so sharing works again.
      await confirmRecoveryPhrase(
        tester,
        continueLabel: l(tester).actionContinue,
      );
      expect(find.text(l(tester).storageTitle), findsOneWidget);
      expect(secureCalls, [true, false]);
    });

    testWidgets('typing a phrase in is protected too', (tester) async {
      // Restoring puts the same 24 words on screen, in a field that is
      // deliberately not obscured.
      await pump(tester);
      await tester.tap(find.text(l(tester).actionContinue));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l(tester).onboardRestoreIdentity));
      await tester.pumpAndSettle();
      expect(secureCalls, [true]);

      await tester.enterText(
        find.byType(TextField),
        List.generate(24, (i) => 'w$i').join(' '),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(l(tester).onboardRestoreSubmit));
      await tester.pumpAndSettle();
      expect(secureCalls, [true, false]);
    });
  });

  testWidgets('the word count gates on its own, not via the validator', (
    tester,
  ) async {
    // The existing restore test hands in a validator that itself returns
    // `words == 24`, so it is satisfied whether or not the widget checks the
    // count -- deleting the widget's own check left the whole suite green.
    // Here the validator accepts ANYTHING, so the count is the only thing that
    // can still refuse. It has to: the real validator is BIP-39, which happily
    // accepts a valid 12-word phrase, while every phrase this app mints is 24.
    // Without the count check that 12-word phrase would restore silently into
    // a different identity than the person meant.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [nodeControllerProvider.overrideWithValue(_NoopNode())],
        child: MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: OnboardingScreen(validatePhrase: (_) => true),
        ),
      ),
    );
    await tester.pumpAndSettle();

    AppL10n l() => AppL10n.of(tester.element(find.byType(OnboardingScreen)));
    bool submitEnabled() =>
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, l().onboardRestoreSubmit),
            )
            .onPressed !=
        null;

    await tester.tap(find.text(l().actionContinue));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l().onboardRestoreIdentity));
    await tester.pumpAndSettle();

    final field = find.byType(TextField);
    for (final count in [1, 12, 23, 25]) {
      await tester.enterText(
        field,
        List.generate(count, (i) => 'w$i').join(' '),
      );
      await tester.pumpAndSettle();
      expect(
        submitEnabled(),
        isFalse,
        reason: '$count words must not be submittable on a 24-word screen',
      );
    }

    // ...and 24 still works, so the gate is a gate and not a wall.
    await tester.enterText(field, List.generate(24, (i) => 'w$i').join(' '));
    await tester.pumpAndSettle();
    expect(submitEnabled(), isTrue);
  });
}
