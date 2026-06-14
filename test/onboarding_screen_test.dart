import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/features/onboarding/onboarding_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/providers.dart';

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

  testWidgets('create-identity wizard completes into a ready session',
      (tester) async {
    late ProviderContainer container;
    await tester.pumpWidget(ProviderScope(
      overrides: [nodeControllerProvider.overrideWithValue(_NoopNode())],
      child: Consumer(builder: (ctx, ref, _) {
        container = ProviderScope.containerOf(ctx);
        return MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: const OnboardingScreen(),
        );
      }),
    ));
    await tester.pumpAndSettle();

    AppL10n l() => AppL10n.of(tester.element(find.byType(OnboardingScreen)));

    // 0 welcome -> Continue
    await tester.tap(find.text(l().actionContinue));
    await tester.pumpAndSettle();
    // 1 choose -> Create a new identity
    await tester.tap(find.text(l().onboardCreateIdentity));
    await tester.pumpAndSettle();
    // 2 recovery -> confirm checkbox, Continue
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l().actionContinue));
    await tester.pumpAndSettle();
    // 3 storage -> Continue (default hidden space)
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
}
