import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/features/bootstrap/profile_erasure_recovery_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/app_controller.dart';

class _Controller extends AppController {
  final gate = Completer<void>();
  int calls = 0;
  @override
  AppState build() => const AppState(AppPhase.profileErasureRecovery);
  @override
  Future<List<String>> wipeContainers() async {
    calls++;
    state = const AppState(AppPhase.profileErasureRecovery, erasureBusy: true);
    await gate.future;
    state = const AppState(AppPhase.onboarding);
    return [];
  }
}

void main() {
  for (final locale in AppL10n.supportedLocales) {
    testWidgets(
      'live erasure retry is localized and cannot run twice (${locale.languageCode})',
      (tester) async {
        final controller = _Controller();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [appControllerProvider.overrideWith(() => controller)],
            child: MaterialApp(
              locale: locale,
              localizationsDelegates: AppL10n.localizationsDelegates,
              supportedLocales: AppL10n.supportedLocales,
              home: const ProfileErasureRecoveryScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final l = AppL10n.of(tester.element(find.byType(Scaffold)));
        expect(find.text(l.profileErasurePendingTitle), findsOneWidget);
        await tester.tap(find.text(l.lockWipeRetry));
        await tester.pump();
        expect(controller.calls, 1);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(find.byType(FilledButton), findsNothing);
        controller.gate.complete();
        await tester.pumpAndSettle();
        expect(controller.calls, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
