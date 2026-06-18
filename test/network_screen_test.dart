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

  testWidgets('renders the secondary controls (proxy / nodes / extensions)',
      (tester) async {
    await tester.pumpWidget(
        _host(const NodeStatus(phase: NodePhase.connected, peerCount: 1)));
    await tester.pump();
    expect(find.byIcon(Icons.vpn_lock_outlined), findsOneWidget);
    expect(find.byIcon(Icons.dns_outlined), findsOneWidget);
    expect(find.byIcon(Icons.extension_outlined), findsOneWidget);
  });
}
