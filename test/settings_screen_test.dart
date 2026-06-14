import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/features/settings/settings_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/providers.dart';

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

  testWidgets('shows the identity and locks via "Lock now"', (tester) async {
    late ProviderContainer container;
    await tester.pumpWidget(ProviderScope(
      overrides: [nodeControllerProvider.overrideWithValue(_NoopNode())],
      child: Consumer(builder: (ctx, ref, _) {
        container = ProviderScope.containerOf(ctx);
        return const MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: SettingsScreen(),
        );
      }),
    ));
    await tester.pumpAndSettle();

    // Enter a ready session with a known identity.
    final id = AppController.generateIdentity(displayName: 'Nat');
    await container.read(appControllerProvider.notifier).completeOnboarding(
          identity: id,
          password: 'pw',
          mode: StorageMode.hiddenSpace,
        );
    await tester.pump();
    await tester.pump();

    expect(find.text('Nat'), findsOneWidget);
    expect(find.text(id.nodeId.short), findsWidgets);

    // "Lock now" locks the session.
    await tester.tap(find.text('Lock now'));
    await tester.pump();
    expect(container.read(appControllerProvider).phase, AppPhase.locked);
  });
}
