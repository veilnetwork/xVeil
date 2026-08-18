import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/features/network/network_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/providers.dart';

Widget _host(NodeStatus status, {int? sessions}) => ProviderScope(
      overrides: [
        nodeStatusProvider.overrideWith((ref) => Stream.value(status)),
        // The card reads the real peer count from sessionCountProvider (not the
        // status snapshot), so the test drives it explicitly.
        if (sessions != null)
          sessionCountProvider.overrideWith((ref) => Stream.value(sessions)),
      ],
      child: MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: const NetworkScreen(),
      ),
    );

void main() {
  testWidgets('shows Connected + peer count when connected', (tester) async {
    await tester.pumpWidget(_host(
        const NodeStatus(phase: NodePhase.connected, peerCount: 3),
        sessions: 3));
    await tester.pump();

    final l = AppL10n.of(tester.element(find.byType(NetworkScreen)));
    expect(find.text(l.networkStatusConnected), findsOneWidget);
    expect(find.text(l.networkPeers(3)), findsOneWidget);
  });

  testWidgets('shows Connecting while starting', (tester) async {
    await tester
        .pumpWidget(_host(const NodeStatus(phase: NodePhase.starting)));
    await tester.pump();

    final l = AppL10n.of(tester.element(find.byType(NetworkScreen)));
    expect(find.text(l.networkStatusConnecting), findsOneWidget);
  });

  testWidgets('renders the secondary controls (proxy / nodes)', (tester) async {
    await tester.pumpWidget(
        _host(const NodeStatus(phase: NodePhase.connected, peerCount: 1)));
    await tester.pump();
    // Scrolled to, not merely pumped: the list is lazy and these rows sit
    // below the fold on the test surface. They moved further down when the
    // serve-the-network switch was added above them, and a `findsOneWidget`
    // on an unbuilt row fails for a reason that has nothing to do with the
    // row.
    final list = find.byType(Scrollable).first;
    for (final icon in [Icons.vpn_lock_outlined, Icons.dns_outlined]) {
      await tester.scrollUntilVisible(find.byIcon(icon), 200, scrollable: list);
      expect(find.byIcon(icon), findsOneWidget);
    }
    // Lua extensions are not implemented. The row was a chevron leading to a
    // "coming later" snackbar, which reads as a feature that exists and is
    // merely switched off — so it is gone until there is something behind it.
    expect(find.byIcon(Icons.extension_outlined), findsNothing);
  });
}
