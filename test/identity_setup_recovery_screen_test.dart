import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/features/identity/identity_setup_recovery_screen.dart';
import 'package:xveil/features/settings/error_report.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/app_controller.dart';

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
}
