import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:xveil/features/home/menu_tiles_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';

Widget _host() {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (_, _) => const MenuTilesScreen()),
      GoRoute(
        path: '/calls',
        builder: (_, _) => const Scaffold(body: Text('calls-route')),
      ),
      GoRoute(
        path: '/network',
        builder: (_, _) => const Scaffold(body: Text('network-route')),
      ),
      GoRoute(
        path: '/settings',
        builder: (_, _) => const Scaffold(body: Text('settings-route')),
      ),
    ],
  );
  return ProviderScope(
    child: MaterialApp.router(
      routerConfig: router,
      localizationsDelegates: AppL10n.localizationsDelegates,
      supportedLocales: AppL10n.supportedLocales,
    ),
  );
}

void main() {
  testWidgets(
    'menu tab exposes real app actions instead of a coming-soon stub',
    (tester) async {
      await tester.pumpWidget(_host());
      await tester.pumpAndSettle();

      final l = AppL10n.of(tester.element(find.byType(MenuTilesScreen)));
      expect(find.text(l.inviteAddContact), findsOneWidget);
      expect(find.text(l.groupCreateTitle), findsOneWidget);
      expect(find.text(l.navCalls), findsOneWidget);
      expect(find.text(l.navNetwork), findsOneWidget);
      expect(find.text(l.navSettings), findsOneWidget);
      expect(find.text(l.settingsLockNow), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);

      await tester.tap(find.text(l.navCalls));
      await tester.pumpAndSettle();
      expect(find.text('calls-route'), findsOneWidget);
    },
  );
}
