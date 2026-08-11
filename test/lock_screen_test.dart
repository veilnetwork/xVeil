import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/features/lock/lock_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/routing/router.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/providers.dart';
import 'dart:io';
import 'package:xveil/data/whisper_model_store.dart';
import 'package:xveil/state/whisper_model_controller.dart';
import 'package:xveil/state/translation_model_controller.dart';

/// `lib/app.dart`'s own arrangement: the wipe-report host lives in
/// `MaterialApp.builder`, ABOVE whatever is being routed to, because the wipe's
/// last act unmounts the screen that asked for it.
Widget _appAround(Widget home) => MaterialApp(
  localizationsDelegates: AppL10n.localizationsDelegates,
  supportedLocales: AppL10n.supportedLocales,
  builder: (context, child) =>
      Stack(children: [child!, const WipeReportHost()]),
  home: home,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({'onboarded': true});
    // Start over and Clear all data both bring the OS tunnel down first, and
    // that stop is now unconditional — closing the platform TUN is what makes
    // it authoritative (audit XV-H2). A widget test has no VPN plugin, and an
    // unanswered platform channel leaves the teardown in flight when the
    // assertion runs — the same reason the speech store is faked below.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('network.veil.xveil/vpn'),
          (call) async => <String, Object?>{'phase': 'stopped'},
        );
  });

  testWidgets('Start over confirms then returns to onboarding', (tester) async {
    late ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        child: Consumer(
          builder: (ctx, ref, _) {
            container = ProviderScope.containerOf(ctx);
            return const MaterialApp(
              localizationsDelegates: AppL10n.localizationsDelegates,
              supportedLocales: AppL10n.supportedLocales,
              home: LockScreen(),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    final l = AppL10n.of(tester.element(find.byType(LockScreen)));

    // The lock screen's "Start over" is a TextButton; tapping it opens a
    // confirmation dialog with a FilledButton of the same label.
    await tester.tap(find.widgetWithText(TextButton, l.lockStartOver));
    await tester.pumpAndSettle();
    expect(find.text(l.lockStartOverBody), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, l.lockStartOver));
    await tester.pumpAndSettle();

    expect(container.read(appControllerProvider).phase, AppPhase.onboarding);
  });

  testWidgets('cancelling Start over keeps the lock screen', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: LockScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final l = AppL10n.of(tester.element(find.byType(LockScreen)));

    await tester.tap(find.widgetWithText(TextButton, l.lockStartOver));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.actionCancel));
    await tester.pumpAndSettle();

    // Still on the lock screen (unlock button present).
    expect(find.text(l.lockUnlock), findsOneWidget);
  });

  testWidgets('Clear all data is gated behind typing the exact phrase', (
    tester,
  ) async {
    late ProviderContainer container;
    // The wipe removes the speech model, and resolving the support directory
    // goes through path_provider — which never answers in a widget test, so
    // without this the wipe is still in flight when the assertion runs.
    final modelDir = Directory.systemTemp.createTempSync('lock_wipe_model');
    addTearDown(() {
      if (modelDir.existsSync()) modelDir.deleteSync(recursive: true);
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // Same reason the speech store is overridden here: wipeContainers
          // resolves the models directory through a platform channel, which a
          // widget test does not have. This test is about the phrase gate, not
          // about what a wipe removes.
          translationModelsRootProvider.overrideWithValue(() async => null),
          whisperModelStoreProvider.overrideWithValue(
            WhisperModelStore(supportDirectory: () async => modelDir),
          ),
        ],
        child: Consumer(
          builder: (ctx, ref, _) {
            container = ProviderScope.containerOf(ctx);
            return const MaterialApp(
              localizationsDelegates: AppL10n.localizationsDelegates,
              supportedLocales: AppL10n.supportedLocales,
              home: LockScreen(),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final l = AppL10n.of(tester.element(find.byType(LockScreen)));

    await tester.tap(find.widgetWithText(TextButton, l.lockWipe));
    await tester.pumpAndSettle();

    // The destructive confirm button is present but DISABLED until the phrase
    // is typed (so an accidental double-tap can't wipe anything).
    final confirm = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, l.lockWipeConfirm),
    );
    expect(confirm.onPressed, isNull, reason: 'disabled before the phrase');

    final dialogField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(dialogField, l.lockWipePhrase);
    await tester.pumpAndSettle();
    final confirmNow = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, l.lockWipeConfirm),
    );
    expect(confirmNow.onPressed, isNotNull, reason: 'enabled once typed');

    await tester.tap(find.widgetWithText(FilledButton, l.lockWipeConfirm));
    await tester.pumpAndSettle();
    expect(container.read(appControllerProvider).phase, AppPhase.onboarding);
  });

  testWidgets('a container the wipe could not delete is NAMED on screen', (
    tester,
  ) async {
    // The whole point of the returned list. `wipeContainers` re-stats what it
    // deleted instead of trusting `delete()`, and the screen threw that answer
    // away — so someone whose container survived saw the onboarding screen,
    // the same screen someone whose container is gone sees.
    //
    // Real chmod, not a fake, for this one: the assertion is about the answer
    // reaching the interface, and a fake that returns `['container']` on
    // command cannot show that the real path produces it. The async file work
    // this drives is confined to a temp directory and to the container's own
    // `exists`/`delete`; every platform channel the wipe touches is overridden
    // below, because THOSE are what leave a widget test hanging.
    final dir = Directory.systemTemp.createTempSync('lock_wipe_locked_');
    final store = File('${dir.path}/test.store')..writeAsStringSync('container');
    // Unwritable DIRECTORY: the file stays readable, the unlink cannot happen.
    // What a read-only volume or a backup agent holding the directory looks
    // like from here.
    expect(Process.runSync('chmod', ['a-w', dir.path]).exitCode, 0);
    addTearDown(() {
      Process.runSync('chmod', ['u+w', dir.path]);
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    final modelDir = Directory.systemTemp.createTempSync('lock_wipe_model_');
    addTearDown(() {
      if (modelDir.existsSync()) modelDir.deleteSync(recursive: true);
    });

    late ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          translationModelsRootProvider.overrideWithValue(() async => null),
          whisperModelStoreProvider.overrideWithValue(
            WhisperModelStore(supportDirectory: () async => modelDir),
          ),
          deniableBootProvider.overrideWithValue(
            DeniableBootConfig(
              runtimeDir: '${dir.path}/rt',
              listenPort: 9000,
              storePath: store.path,
            ),
          ),
        ],
        child: Consumer(
          builder: (ctx, ref, _) {
            container = ProviderScope.containerOf(ctx);
            return _appAround(const LockScreen());
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final l = AppL10n.of(tester.element(find.byType(LockScreen)));

    await tester.tap(find.widgetWithText(TextButton, l.lockWipe));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      l.lockWipePhrase,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, l.lockWipeConfirm));
    await tester.pump();
    // The wipe does REAL file work here — exists, delete, then the re-stat that
    // produces the answer — and a widget test's clock is fake, so none of those
    // futures complete under `pumpAndSettle` alone. It does not hang: it sails
    // straight past a wipe that never finished and the dialog is simply
    // absent, which looks exactly like the bug this test is about. So REAL
    // event-loop turns are alternated with pumps: one hand-off is not enough
    // either, because the wipe awaits file work several times over and each
    // completion is only picked up by the following pump. Bounded, and it
    // stops the moment the wipe has landed.
    for (var i = 0; i < 60; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
      if (container.read(appControllerProvider).phase == AppPhase.onboarding) {
        break;
      }
    }
    await tester.pumpAndSettle();

    expect(store.existsSync(), isTrue, reason: 'precondition: it survived');
    // THE assertion. It cannot pass while the screen drops the list.
    expect(
      find.text(l.lockWipeLeftContainer),
      findsOneWidget,
      reason: 'a wipe that could not delete the container must say so',
    );
    expect(find.text(l.lockWipeLeftRest), findsOneWidget);
    expect(
      find.widgetWithText(FilledButton, l.lockWipeRetry),
      findsOneWidget,
      reason: 'naming it without offering another go is only half an answer',
    );
    // GUARDS — both stay green with the fix removed, and are here to pin the
    // deliberate behaviour around it rather than to prove it:
    //   * the phase still flips (see `wipeContainers`: parking someone on a
    //     lock screen for a container that may already be gone is its own
    //     disclosure), so the dialog is raised OVER onboarding;
    //   * nothing was thrown on the way.
    expect(container.read(appControllerProvider).phase, AppPhase.onboarding);
    expect(tester.takeException(), isNull);
    // `testWidgets` takes no `testOn`, so the platform gate is a `skip`: the
    // fixture is a POSIX mode, and Windows says nothing about rights in mode
    // bits.
  }, skip: Platform.isWindows);

  testWidgets('Retry runs the wipe again; both leftovers are named at once', (
    tester,
  ) async {
    // Faked here on purpose: what is under test is that Retry CALLS again, and
    // a second call has to be counted, not inferred. The fake also produces
    // the container+files case, which no single-file fixture can.
    final ctrl = _LeftoverWipeController();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith(() => ctrl)],
        child: _appAround(const LockScreen()),
      ),
    );
    await tester.pumpAndSettle();
    final l = AppL10n.of(tester.element(find.byType(LockScreen)));

    await tester.tap(find.widgetWithText(TextButton, l.lockWipe));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      l.lockWipePhrase,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, l.lockWipeConfirm));
    await tester.pumpAndSettle();

    expect(ctrl.calls, 1);
    expect(find.text(l.lockWipeLeftBoth), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, l.lockWipeRetry));
    await tester.pumpAndSettle();
    expect(ctrl.calls, 2, reason: 'Retry that does not retry is a decoration');
    // Still failing, so it says so again rather than closing on a lie.
    expect(find.text(l.lockWipeLeftBoth), findsOneWidget);

    // The third pass succeeds: the dialog closes and does not come back.
    ctrl.leftovers = const [];
    await tester.tap(find.widgetWithText(FilledButton, l.lockWipeRetry));
    await tester.pumpAndSettle();
    expect(ctrl.calls, 3);
    expect(find.text(l.lockWipeLeftBoth), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('a surviving MODEL is named, not folded into "stopped partway"', (
    tester,
  ) async {
    // The report grew two codes when the survivor list did, and the dialog had
    // one sentence per COMBINATION of the two it knew. An unknown code fell
    // through to `lockWipeStopped` — "the deletion stopped partway through" —
    // which is the honest-about-nothing message, over a wipe that ran to the
    // end and knows exactly what is left. So the two things most likely to
    // survive would have been reported as the one thing nothing is known
    // about.
    final ctrl = _LeftoverWipeController()
      ..leftovers = const ['speech-model', 'translations'];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith(() => ctrl)],
        child: _appAround(const LockScreen()),
      ),
    );
    await tester.pumpAndSettle();
    final l = AppL10n.of(tester.element(find.byType(LockScreen)));

    await tester.tap(find.widgetWithText(TextButton, l.lockWipe));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      l.lockWipePhrase,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, l.lockWipeConfirm));
    await tester.pumpAndSettle();

    expect(find.text(l.lockWipeLeftSpeechModel), findsOneWidget);
    expect(find.text(l.lockWipeLeftTranslations), findsOneWidget);
    expect(
      find.text(l.lockWipeStopped),
      findsNothing,
      reason: 'the wipe ran to the end and knows what is left — say which',
    );
    // The container went, so the sentence about the container must not appear.
    expect(find.text(l.lockWipeLeftContainer), findsNothing);
    expect(find.text(l.lockWipeLeftRest), findsOneWidget);
  });

  testWidgets('a wipe that THROWS says so instead of vanishing', (
    tester,
  ) async {
    // `_wipe` had no catch at all, so a throw became an uncaught async error:
    // the confirm dialog closed, the screen sat there, and the person read
    // that as "nothing happened" — on the one action that cannot be undone.
    final ctrl = _ThrowingWipeController();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith(() => ctrl)],
        child: _appAround(const LockScreen()),
      ),
    );
    await tester.pumpAndSettle();
    final l = AppL10n.of(tester.element(find.byType(LockScreen)));

    await tester.tap(find.widgetWithText(TextButton, l.lockWipe));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      l.lockWipePhrase,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, l.lockWipeConfirm));
    await tester.pumpAndSettle();

    expect(find.text(l.lockWipeStopped), findsOneWidget);
    // Nothing was verified after a throw, so the dialog must NOT claim the
    // rest was destroyed.
    expect(find.text(l.lockWipeLeftRest), findsNothing);
    expect(
      tester.takeException(),
      isNull,
      reason: 'the throw must be handled, not left to the zone',
    );
  });

  testWidgets('the report survives the ROUTER taking the lock screen away', (
    tester,
  ) async {
    // The arrangement every other test in this file leaves out, and the only
    // reason the defect could sit behind a green suite: they mount
    // `MaterialApp(home: LockScreen())` with NO router, so no page is ever
    // swapped and a dialog raised over the lock screen simply stays put.
    // Production has a router. `wipeContainers` flips the phase to onboarding
    // as its LAST act — on purpose, see the comment there — the router
    // redirects on that flip, and the dialog, being a ROUTE over the `/lock`
    // page, is removed together with it. (The `mounted` guard that used to
    // stand in front of it was never the culprit and measured TRUE every time;
    // see `_runWipe`.)
    //
    // So this one puts a real `GoRouter` in front of it, gated by the SAME
    // pure function the app's router is gated by (`redirectForPhase`), with
    // the report host in `MaterialApp.builder` exactly where `app.dart` mounts
    // it. What makes it a reproduction rather than another polite fiction is
    // the `findsNothing` below: the router really did take the lock screen and
    // its page away at the moment the report is expected on screen.
    final ctrl = _LeftoverWipeController();
    final container = ProviderContainer(
      overrides: [appControllerProvider.overrideWith(() => ctrl)],
    );
    addTearDown(container.dispose);
    // The same ValueNotifier bridge `routerProvider` builds, so a phase change
    // re-runs the redirect instead of waiting for an unrelated rebuild.
    final refresh = ValueNotifier<AppPhase>(AppPhase.locked);
    addTearDown(refresh.dispose);
    container.listen(
      appControllerProvider.select((s) => s.phase),
      (_, next) => refresh.value = next,
      fireImmediately: true,
    );
    final router = GoRouter(
      initialLocation: '/lock',
      refreshListenable: refresh,
      redirect: (_, state) => redirectForPhase(
        container.read(appControllerProvider).phase,
        state.matchedLocation,
      ),
      routes: [
        GoRoute(path: '/lock', builder: (_, _) => const LockScreen()),
        GoRoute(
          path: '/onboarding',
          builder: (_, _) =>
              const Scaffold(body: Center(child: Text('first launch'))),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          routerConfig: router,
          builder: (context, child) =>
              Stack(children: [child!, const WipeReportHost()]),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byType(LockScreen),
      findsOneWidget,
      reason: 'the fixture never reached the lock screen',
    );
    final l = AppL10n.of(tester.element(find.byType(LockScreen)));

    await tester.tap(find.widgetWithText(TextButton, l.lockWipe));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      l.lockWipePhrase,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, l.lockWipeConfirm));
    await tester.pumpAndSettle();

    // The arrangement really is the one that broke it.
    expect(
      find.byType(LockScreen),
      findsNothing,
      reason:
          'the router did not unmount the lock screen, so this test proves '
          'exactly as little as the ones without a router',
    );
    expect(find.text('first launch'), findsOneWidget);

    // THE assertion. It cannot pass while the report is raised as a ROUTE over
    // the page the phase flip replaces.
    expect(
      find.text(l.lockWipeLeftBoth),
      findsOneWidget,
      reason: 'a wipe that could not delete the container must say so, and '
          'the screen it was started from is not around to say it',
    );
    expect(find.text(l.lockWipeLeftRest), findsOneWidget);
    // And it still WORKS from up there: Retry runs the wipe again with no lock
    // screen left to run it.
    expect(ctrl.calls, 1);
    await tester.tap(find.widgetWithText(FilledButton, l.lockWipeRetry));
    await tester.pumpAndSettle();
    expect(
      ctrl.calls,
      2,
      reason: 'Retry that cannot retry once its screen is gone is a decoration',
    );
    ctrl.leftovers = const [];
    await tester.tap(find.widgetWithText(FilledButton, l.lockWipeRetry));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('first launch'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('small iPhone stays scrollable above the software keyboard', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(375, 667);
    tester.view.padding = const FakeViewPadding(top: 20);
    tester.view.viewInsets = const FakeViewPadding(bottom: 291);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appControllerProvider.overrideWith(_LockedErrorController.new),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: LockScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final l = AppL10n.of(tester.element(find.byType(LockScreen)));
    expect(tester.takeException(), isNull);
    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(find.text(l.lockWrong), findsOneWidget);

    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -220),
    );
    await tester.pumpAndSettle();
    expect(find.text(l.lockWipe), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Clear all data stays disabled for the WRONG phrase', (
    tester,
  ) async {
    // The test above goes straight from empty to the exact phrase, so it is
    // satisfied by any gate that merely requires typing SOMETHING -- replacing
    // the comparison with `isNotEmpty` left the suite green. That is the whole
    // difference between "type these words to confirm" and "touch the keyboard
    // to confirm", on the one action in the app that cannot be undone.
    late ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        child: Consumer(
          builder: (ctx, ref, _) {
            container = ProviderScope.containerOf(ctx);
            return const MaterialApp(
              localizationsDelegates: AppL10n.localizationsDelegates,
              supportedLocales: AppL10n.supportedLocales,
              home: LockScreen(),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final l = AppL10n.of(tester.element(find.byType(LockScreen)));

    await tester.tap(find.widgetWithText(TextButton, l.lockWipe));
    await tester.pumpAndSettle();
    final dialogField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    bool confirmEnabled() =>
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, l.lockWipeConfirm),
            )
            .onPressed !=
        null;

    for (final typed in [
      'x',
      'yes',
      'delete',
      '${l.lockWipePhrase} ',
      '${l.lockWipePhrase}x',
      l.lockWipePhrase.substring(0, l.lockWipePhrase.length - 1),
    ]) {
      await tester.enterText(dialogField, typed);
      await tester.pumpAndSettle();
      final shouldPass = typed.trim() == l.lockWipePhrase;
      expect(
        confirmEnabled(),
        shouldPass,
        reason: 'typed "$typed" — expected enabled=$shouldPass',
      );
    }

    // Nothing above was allowed to wipe anything on the way through.
    expect(
      container.read(appControllerProvider).phase,
      isNot(AppPhase.onboarding),
    );
  });
}

class _LockedErrorController extends AppController {
  @override
  AppState build() => const AppState(AppPhase.locked, unlockError: true);
}

/// A wipe that keeps failing to delete both tiers, and counts how often it was
/// asked to try.
///
/// Extends the real controller so everything the screen does around the wipe —
/// the phase, the unlock state — behaves as production does.
class _LeftoverWipeController extends AppController {
  int calls = 0;
  List<String> leftovers = const ['container', 'files'];

  @override
  AppState build() => const AppState(AppPhase.locked);

  @override
  Future<List<String>> wipeContainers() async {
    calls++;
    // The real one flips the phase whatever happens; keeping that here means
    // the dialog is exercised over the same screen it will be raised over.
    state = const AppState(AppPhase.onboarding);
    return leftovers;
  }
}

/// A wipe that throws — a wedged platform channel, a plugin that never answers.
class _ThrowingWipeController extends AppController {
  @override
  AppState build() => const AppState(AppPhase.locked);

  @override
  Future<List<String>> wipeContainers() async {
    throw StateError('the wipe could not run');
  }
}
