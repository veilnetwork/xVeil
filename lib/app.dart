import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'features/calls/call_overlay.dart';
import 'features/calls/call_lifecycle_bridge.dart';
import 'l10n/app_localizations.dart';
import 'routing/router.dart';
import 'state/group_service.dart';
import 'state/locale_controller.dart';
import 'theme/app_theme.dart';

class XVeilApp extends ConsumerWidget {
  const XVeilApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      onGenerateTitle: (context) => AppL10n.of(context).appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.dark,
      // null → follow the system locale; otherwise the user's chosen language.
      locale: ref.watch(localeProvider),
      localizationsDelegates: AppL10n.localizationsDelegates,
      supportedLocales: AppL10n.supportedLocales,
      routerConfig: router,
      // Float the call UI (incoming ring / in-call) above every route.
      builder: (context, child) => Stack(
        children: [
          ?child,
          const CallLifecycleBridge(),
          const CallOverlay(),
          // Eagerly build the group service once the identity is ready, so its
          // inbound-snapshot bridge is attached BEFORE any group frame arrives
          // (a member added on another device pushes a snapshot immediately).
          const _GroupBridge(),
        ],
      ),
    );
  }
}

/// A zero-size widget that keeps the group service alive so its inbound
/// snapshot bridge is attached as soon as the identity is ready.
class _GroupBridge extends ConsumerWidget {
  const _GroupBridge();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(groupServiceProvider);
    return const SizedBox.shrink();
  }
}
