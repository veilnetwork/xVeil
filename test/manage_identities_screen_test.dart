import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/features/identity/manage_identities_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/providers.dart';

import 'support/fake_hv_container.dart';

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
  testWidgets('lists the master identities and offers the bind action',
      (tester) async {
    SharedPreferences.setMockInitialValues({'onboarded': true});
    final container = FakeHvContainer();
    final roster = <RosterEntry>[];
    for (final (label, pw) in [('alice', 'pw-a'), ('bob', 'pw-b')]) {
      final ch = container.storage();
      await ch.open(password: pw, createIfMissing: true);
      await ch.saveIdentity(AppController.generateIdentity(displayName: label));
      roster.add(RosterEntry(label: label, spaceKeys: ch.exportSpaceKeys()));
      await ch.close();
    }
    final master = container.storage();
    await master.open(password: 'masterpw', createIfMissing: true);
    await master.saveRoster(roster);
    await master.close();

    late ProviderContainer c;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        storageProvider.overrideWith((ref) => container.storage()),
        nodeControllerProvider.overrideWithValue(_NoopNode()),
      ],
      child: Consumer(builder: (ctx, ref, _) {
        c = ProviderScope.containerOf(ctx);
        return const MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: ManageIdentitiesScreen(),
        );
      }),
    ));
    await tester.pumpAndSettle();

    // Drive into a master session so the screen has a roster to show.
    await c.read(appControllerProvider.notifier).unlock('masterpw');
    await c.read(appControllerProvider.notifier).pickIdentity('alice');
    await tester.pumpAndSettle();

    final l = AppL10n.of(tester.element(find.byType(ManageIdentitiesScreen)));
    expect(find.text('alice'), findsOneWidget);
    expect(find.text('bob'), findsOneWidget);
    expect(find.text(l.manageActive), findsOneWidget); // alice is active
    expect(find.text(l.manageBind), findsWidgets); // the bind tile
  });
}
