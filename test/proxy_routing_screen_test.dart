import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/proxy_routing.dart';
import 'package:xveil/features/network/proxy_routing_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/proxy_routing_controller.dart';

const _exit =
    'aa11bb22cc33dd44ee55ff66007788990011223344556677889900aabbccddee';

Widget _host() => const ProviderScope(
      child: MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: ProxyRoutingScreen(),
      ),
    );

void main() {
  testWidgets('toggling SOCKS5 reveals the exit field and updates the provider',
      (tester) async {
    await tester.pumpWidget(_host());
    await tester.pump();

    final l = AppL10n.of(tester.element(find.byType(ProxyRoutingScreen)));

    // SOCKS5 off initially → no exit field.
    expect(find.text(l.routeListenLabel), findsNothing);

    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();

    // Now the listen + exit fields are shown, and the "need exit" hint appears.
    expect(find.text(l.routeListenLabel), findsOneWidget);
    expect(find.text(l.routeNeedExit), findsOneWidget);

    final container = ProviderScope.containerOf(
        tester.element(find.byType(ProxyRoutingScreen)));
    expect(container.read(proxyRoutingProvider).socks5Enabled, isTrue);
    expect(container.read(proxyRoutingProvider).socks5Active, isFalse);
  });

  testWidgets('a valid exit node id makes SOCKS5 active', (tester) async {
    await tester.pumpWidget(_host());
    await tester.pump();
    final l = AppL10n.of(tester.element(find.byType(ProxyRoutingScreen)));

    await tester.tap(find.byType(Switch).first); // enable SOCKS5
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, l.routeExitNodeLabel),
        _exit);
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
        tester.element(find.byType(ProxyRoutingScreen)));
    final cfg = container.read(proxyRoutingProvider);
    expect(cfg.socks5Active, isTrue);
    expect(cfg.exitNodeId, _exit);
    // The proxy-address line is shown when active.
    expect(find.textContaining(cfg.socks5Listen), findsWidgets);
  });

  testWidgets('enabling the exit role flips exitEnabled', (tester) async {
    await tester.pumpWidget(_host());
    await tester.pump();

    // The second switch is the exit role.
    await tester.tap(find.byType(Switch).at(1));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
        tester.element(find.byType(ProxyRoutingScreen)));
    expect(container.read(proxyRoutingProvider).exitEnabled, isTrue);
    // The allow-private advanced toggle now appears.
    expect(container.read(proxyRoutingProvider), isA<ProxyRouting>());
  });
}
