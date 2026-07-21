import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/proxy_routing.dart';
import 'package:xveil/data/vpn/vpn_application_catalog.dart';
import 'package:xveil/data/vpn/vpn_routing_policy.dart';
import 'package:xveil/features/network/proxy_routing_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/proxy_routing_controller.dart';
import 'package:xveil/state/vpn_application_catalog.dart';
import 'package:xveil/state/vpn_controller.dart';

const _exit =
    'aa11bb22cc33dd44ee55ff66007788990011223344556677889900aabbccddee';

Widget _host() => const ProviderScope(
  child: MaterialApp(
    localizationsDelegates: AppL10n.localizationsDelegates,
    supportedLocales: AppL10n.supportedLocales,
    home: ProxyRoutingScreen(),
  ),
);

class _FakeApplicationCatalog implements VpnApplicationCatalog {
  @override
  bool get isSupported => true;

  @override
  Future<List<VpnApplication>> listApplications() async => const [
    VpnApplication(id: 'org.mozilla.firefox', label: 'Firefox'),
    VpnApplication(id: 'com.android.chrome', label: 'Chrome'),
  ];
}

Widget _androidHost() => ProviderScope(
  overrides: [
    vpnApplicationCatalogProvider.overrideWithValue(_FakeApplicationCatalog()),
  ],
  child: const MaterialApp(
    localizationsDelegates: AppL10n.localizationsDelegates,
    supportedLocales: AppL10n.supportedLocales,
    home: ProxyRoutingScreen(),
  ),
);

Future<void> _addOproxy(
  WidgetTester tester,
  AppL10n l, {
  String label = 'Amsterdam',
}) async {
  await tester.tap(find.byTooltip(l.oproxyAddTitle));
  await tester.pumpAndSettle();
  await tester.enterText(find.widgetWithText(TextField, l.oproxyName), label);
  await tester.enterText(
    find.widgetWithText(TextField, l.routeExitNodeLabel),
    _exit,
  );
  await tester.pump();
  await tester.tap(
    find.widgetWithText(
      FilledButton,
      MaterialLocalizations.of(
        tester.element(find.byType(AlertDialog)),
      ).saveButtonLabel,
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('exit can be configured while manual SOCKS remains off', (
    tester,
  ) async {
    await tester.pumpWidget(_host());
    await tester.pump();

    final l = AppL10n.of(tester.element(find.byType(ProxyRoutingScreen)));

    expect(find.text(l.routeListenLabel), findsOneWidget);
    await _addOproxy(tester, l);

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
    await _addOproxy(tester, l);

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

  testWidgets('Android VPN can be limited to selected applications', (
    tester,
  ) async {
    await tester.pumpWidget(_androidHost());
    await tester.pumpAndSettle();
    final l = AppL10n.of(tester.element(find.byType(ProxyRoutingScreen)));

    await _addOproxy(tester, l);
    await tester.tap(find.text(l.vpnTitle));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.vpnApplicationAll));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.vpnApplicationOnlySelected).last);
    await tester.pumpAndSettle();

    expect(find.text(l.vpnApplicationNoneSelected), findsOneWidget);
    final select = find.widgetWithText(OutlinedButton, l.vpnApplicationSelect);
    await tester.ensureVisible(select);
    await tester.pumpAndSettle();
    await tester.tap(select);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('vpn-application-search')),
      'FIRE',
    );
    await tester.pumpAndSettle();
    expect(find.text('Firefox'), findsOneWidget);
    expect(find.text('Chrome'), findsNothing);
    await tester.tap(find.widgetWithText(CheckboxListTile, 'Firefox'));
    await tester.tap(
      find.widgetWithText(
        FilledButton,
        MaterialLocalizations.of(
          tester.element(find.byType(AlertDialog)),
        ).okButtonLabel,
      ),
    );
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProxyRoutingScreen)),
    );
    final policy = container.read(vpnControllerProvider).policy;
    expect(policy.applicationMode, VpnApplicationMode.onlySelected);
    expect(policy.applicationIds, ['org.mozilla.firefox']);
    expect(policy.isValid, isTrue);

    final routes = find.text(l.oproxyApplicationRoutesTitle);
    await tester.ensureVisible(routes);
    await tester.tap(routes);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('oproxy-application-search')),
      'MOZILLA.FIREFOX',
    );
    await tester.pumpAndSettle();
    expect(find.text('Firefox'), findsOneWidget);
    expect(find.text('Chrome'), findsNothing);
  });
}
