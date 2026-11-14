import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/features/identity/identity_setup_recovery_screen.dart';
import 'package:xveil/features/settings/error_report.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/domain/storage_protection.dart';

class _SetupController extends AppController {
  _SetupController(this.blank);
  final bool blank;
  int resumes = 0, locks = 0;
  @override
  AppState build() => const AppState(AppPhase.identitySetupRecovery);
  @override
  bool get canResumeIdentitySetup => blank;
  @override
  bool beginIdentitySetupRecovery() {
    resumes++;
    state = const AppState(AppPhase.onboarding);
    return true;
  }

  @override
  Future<void> lock() async {
    locks++;
    state = const AppState(AppPhase.locked);
  }
}

class _ReplayController extends _SetupController {
  _ReplayController(this.protection) : super(false);
  final StorageProtection protection;
  final result = Completer<bool>();
  final passwords = <String>[];
  @override
  bool get canReplayIdentitySetup => true;
  @override
  StorageProtection? get setupRecoveryProtection => protection;
  @override
  Future<bool> replayIdentitySetup(String password) {
    passwords.add(password);
    return result.future;
  }
}

Widget _view(
  ProviderContainer container, {
  String language = 'en',
  double scale = 1,
}) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(
    locale: Locale(language),
    localizationsDelegates: AppL10n.localizationsDelegates,
    supportedLocales: AppL10n.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: const IdentitySetupRecoveryScreen(),
  ),
);

void main() {
  for (final blank in [true, false]) {
    for (final language in ['ru', 'en', 'es']) {
      testWidgets('setup recovery blank=$blank is readable in $language', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(const Size(320, 680));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final controller = _SetupController(blank);
        final container = ProviderContainer(
          overrides: [appControllerProvider.overrideWith(() => controller)],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              locale: Locale(language),
              localizationsDelegates: AppL10n.localizationsDelegates,
              supportedLocales: AppL10n.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(2.5)),
                child: child!,
              ),
              home: const IdentitySetupRecoveryScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final resume = find.byKey(const Key('identity-setup-resume'));
        expect(resume, blank ? findsOneWidget : findsNothing);
        expect(controller.resumes, 0);
        if (blank) {
          final details = find.byType(ExpansionTile);
          await tester.ensureVisible(details);
          await tester.tap(details);
          await tester.pumpAndSettle();
          await tester.ensureVisible(resume);
          await tester.tap(resume);
          expect(controller.resumes, 1);
          expect(
            container.read(appControllerProvider).phase,
            AppPhase.onboarding,
          );
        }
        final report = tester.widget<CopyErrorReportTile>(
          find.byType(CopyErrorReportTile),
        );
        expect(report.phase, 'identitySetupRecovery');
        final lock = find.byKey(const Key('identity-setup-lock'));
        await tester.ensureVisible(lock);
        await tester.tap(lock);
        await tester.pumpAndSettle();
        expect(controller.locks, 1);
        expect(container.read(appControllerProvider).phase, AppPhase.locked);
        expect(tester.takeException(), isNull);
      });
    }
  }
  for (final protection in [
    StorageProtection.encrypted,
    StorageProtection.unencrypted,
  ]) {
    testWidgets(
      'replay ${protection.name} has one attempt at a time and lock stays available',
      (tester) async {
        final ctrl = _ReplayController(protection);
        final container = ProviderContainer(
          overrides: [appControllerProvider.overrideWith(() => ctrl)],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(_view(container));
        await tester.pumpAndSettle();
        final field = find.byKey(const Key('identity-setup-password'));
        expect(
          field,
          protection == StorageProtection.unencrypted
              ? findsNothing
              : findsOneWidget,
        );
        if (protection != StorageProtection.unencrypted) {
          await tester.enterText(field, 'synthetic password');
        }
        final submit = find.byKey(const Key('identity-setup-replay'));
        expect(find.byKey(const Key('identity-setup-resume')), findsNothing);
        await tester.ensureVisible(submit);
        await tester.tap(submit);
        await tester.pump();
        expect(ctrl.passwords, [
          protection == StorageProtection.unencrypted
              ? ''
              : 'synthetic password',
        ]);
        expect(tester.widget<FilledButton>(submit).onPressed, isNull);
        final lock = find.byKey(const Key('identity-setup-lock'));
        await tester.ensureVisible(lock);
        await tester.tap(lock);
        await tester.pump();
        expect(ctrl.locks, 1);
        expect(container.read(appControllerProvider).phase, AppPhase.locked);
        ctrl.result.complete(false);
        await tester.pumpAndSettle();
        expect(container.read(appControllerProvider).phase, AppPhase.locked);
        if (protection != StorageProtection.unencrypted) {
          expect(tester.widget<TextField>(field).controller!.text, isEmpty);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final language in ['ru', 'en', 'es']) {
    testWidgets(
      'replay password/actions remain reachable with large $language text',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(320, 680));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final ctrl = _ReplayController(StorageProtection.hidden);
        final container = ProviderContainer(
          overrides: [appControllerProvider.overrideWith(() => ctrl)],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          _view(container, language: language, scale: 2.5),
        );
        await tester.pumpAndSettle();
        final field = find.byKey(const Key('identity-setup-password'));
        await tester.ensureVisible(field);
        await tester.enterText(field, 'synthetic password');
        final action = find.byKey(const Key('identity-setup-replay'));
        await tester.ensureVisible(action);
        await tester.tap(action);
        await tester.pump();
        ctrl.result.complete(false);
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(field).controller!.text, isEmpty);
        expect(tester.widget<FilledButton>(action).onPressed, isNotNull);
        expect(
          find.text(
            AppL10n.of(tester.element(action)).identitySetupReplayError,
          ),
          findsOneWidget,
        );
        await tester.ensureVisible(
          find.byKey(const Key('identity-setup-lock')),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
