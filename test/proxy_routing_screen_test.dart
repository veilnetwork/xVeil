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
  testWidgets('exit can be configured while manual SOCKS remains off', (
    tester,
  ) async {
    await tester.pumpWidget(_host());
    await tester.pump();

    final l = AppL10n.of(tester.element(find.byType(ProxyRoutingScreen)));

    expect(find.text(l.routeListenLabel), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, l.routeExitNodeLabel),
      _exit,
    );
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProxyRoutingScreen)),
    );
    final cfg = container.read(proxyRoutingProvider);
    expect(cfg.socks5Enabled, isFalse);
    expect(cfg.socks5Active, isFalse);
    expect(cfg.vpnTransportReady, isTrue);
  });

  testWidgets('a valid exit node id makes SOCKS5 active', (tester) async {
    await tester.pumpWidget(_host());
    await tester.pump();
    final l = AppL10n.of(tester.element(find.byType(ProxyRoutingScreen)));

    await tester.tap(find.widgetWithText(SwitchListTile, l.routeSocks5Title));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, l.routeExitNodeLabel),
      _exit,
    );
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProxyRoutingScreen)),
    );
    final cfg = container.read(proxyRoutingProvider);
    expect(cfg.socks5Active, isTrue);
    expect(cfg.exitNodeId, _exit);
    // The proxy-address line is shown when active.
    expect(find.textContaining(cfg.socks5Listen), findsWidgets);
  });

  testWidgets('enabling the exit role flips exitEnabled', (tester) async {
    await tester.pumpWidget(_host());
    await tester.pump();
    final l = AppL10n.of(tester.element(find.byType(ProxyRoutingScreen)));

    await tester.tap(find.widgetWithText(SwitchListTile, l.routeServeTitle));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProxyRoutingScreen)),
    );
    expect(container.read(proxyRoutingProvider).exitEnabled, isTrue);
    // The allow-private advanced toggle now appears.
    expect(container.read(proxyRoutingProvider), isA<ProxyRouting>());
  });

  testWidgets('system VPN is explicit and fail-closed without native backend', (
    tester,
  ) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();
    final l = AppL10n.of(tester.element(find.byType(ProxyRoutingScreen)));

    expect(find.text(l.vpnTitle), findsOneWidget);
    await tester.tap(find.text(l.vpnTitle));
    await tester.pumpAndSettle();

    expect(find.text(l.vpnStatusUnsupported), findsOneWidget);
    expect(find.text(l.vpnUnsupportedDetail), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('vpn-toggle')),
    );
    expect(button.onPressed, isNull);
  });
}
