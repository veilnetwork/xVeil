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

  testWidgets('shows the identity of the ready session', (tester) async {
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
    await container.read(appControllerProvider.notifier).completeOnboarding(
          displayName: 'Nat',
          password: 'pw',
          mode: StorageMode.hiddenSpace,
        );
    await tester.pump();
    await tester.pump();

    expect(find.text('Nat'), findsOneWidget);
    // The node id on screen is the transport's, not one onboarding invented
    // (audit XV-06).
    final nodeId = await container.read(veilTransportProvider).nodeId();
    expect(find.text(nodeId.short), findsWidgets);

    // "Lock now" moved to the navigation drawer (see folder_panel_test) — the
    // settings screen must NOT offer it anymore.
    expect(find.text('Lock now'), findsNothing);
  });
}
