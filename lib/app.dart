import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'features/calls/call_overlay.dart';
import 'features/calls/call_lifecycle_bridge.dart';
import 'l10n/app_localizations.dart';
import 'routing/router.dart';
import 'state/api_server.dart';
import 'state/call_log.dart';
import 'state/cloud_capability_service.dart';
import 'state/cloud_service.dart';
import 'state/device_sync_bridge.dart';
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
          // Keep the automation-API controller alive so a persisted "enabled"
          // flag re-opens the loopback server on boot (off by default).
          const _ApiBridge(),
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
    // Multi-device brick 4: contacts/settings/call-journal sync taps, plus the
    // journal recorder itself (calls are journaled even without a journal UI).
    ref.watch(deviceSyncBridgeProvider);
    ref.watch(cloudServiceProvider);
    ref.watch(cloudCapabilityServiceProvider);
    ref.watch(callLogRecorderProvider);
    return const SizedBox.shrink();
  }
}

/// Keeps [apiServerControllerProvider] alive so the loopback automation server
/// starts on boot when the persisted flag is on (and reconciles on toggle).
class _ApiBridge extends ConsumerWidget {
  const _ApiBridge();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(apiServerControllerProvider);
    return const SizedBox.shrink();
  }
}
