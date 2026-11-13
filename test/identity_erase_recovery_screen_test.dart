import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/features/identity/identity_erase_recovery_screen.dart';
import 'package:xveil/features/settings/error_report.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/app_controller.dart';

class _RecoveryController extends AppController {
  final result = Completer<bool>();
  int retries = 0, locks = 0;
  @override
  AppState build() => const AppState(AppPhase.identityEraseRecovery);
  @override
  Future<bool> retryIdentityErasure() {
    retries++;
    return result.future;
  }

  @override
  Future<void> lock() async {
    locks++;
    state = const AppState(AppPhase.locked);
  }
}

void main() {
  testWidgets('one retry at a time; diagnostics and lock remain available', (
    tester,
  ) async {
    final controller = _RecoveryController();
    final container = ProviderContainer(
      overrides: [appControllerProvider.overrideWith(() => controller)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: const IdentityEraseRecoveryScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(CopyErrorReportTile), findsOneWidget);
    expect(
      tester
          .widget<CopyErrorReportTile>(find.byType(CopyErrorReportTile))
          .phase,
      'identityEraseRecovery',
    );
    final retry = find.byKey(const Key('identity-erase-retry'));
    final lock = find.byKey(const Key('identity-erase-lock'));
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pump();
    expect(controller.retries, 1);
    expect(tester.widget<FilledButton>(retry).onPressed, isNull);
    expect(tester.widget<OutlinedButton>(lock).onPressed, isNotNull);
    await tester.ensureVisible(lock);
    await tester.tap(lock);
    await tester.pump();
    expect(controller.locks, 1);
    controller.result.complete(false);
    await tester.pumpAndSettle();
    expect(container.read(appControllerProvider).phase, AppPhase.locked);
    expect(tester.takeException(), isNull);
  });

  for (final language in ['ru', 'en', 'es']) {
    testWidgets('recovery is readable with large text in $language', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(320, 680));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final container = ProviderContainer(
        overrides: [
          appControllerProvider.overrideWith(_RecoveryController.new),
        ],
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
            home: const IdentityEraseRecoveryScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('identity-erase-retry')));
      await tester.ensureVisible(find.byKey(const Key('identity-erase-lock')));
      expect(find.byType(CopyErrorReportTile), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
