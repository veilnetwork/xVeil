import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/secure_screen.dart';
import 'features/calls/call_overlay.dart';
import 'features/calls/group_call_overlay.dart';
import 'features/calls/call_lifecycle_bridge.dart';
import 'features/lock/lock_screen.dart' show WipeReportHost;
import 'features/lock/screen_lock_overlay.dart';
import 'l10n/app_localizations.dart';
import 'routing/router.dart';
import 'state/api_server.dart';
import 'state/call_log.dart';
import 'state/cloud_capability_service.dart';
import 'state/cloud_service.dart';
import 'state/device_sync_bridge.dart';
import 'state/resume_reconnect.dart';
import 'state/group_service_providers.dart';
import 'state/group_call_service.dart';
import 'state/p2p_endpoint_service.dart';
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
      // Float the call UI (incoming ring / in-call) above every route, and put
      // the task-switcher cover above THAT: the snapshot the platform takes on
      // the way out would otherwise show whatever was last on screen, call UI
      // included (audit X-11).
      // The screen lock sits INSIDE the shield and OVER everything else: it is
      // a cover, not a route, so the home shell — and with it the notification
      // binder, the node and every service below — stays mounted and keeps
      // delivering while the screen is locked. Routing to a lock screen would
      // unmount all of it, and the point of this lock is that it costs nothing
      // in delivery.
      builder: (context, child) => TaskSwitcherShield(
        child: ScreenLockHost(
          child: Stack(
            children: [
              ?child,
              const CallLifecycleBridge(),
              const CallOverlay(),
              const GroupCallOverlay(),
              // Eagerly build the group service once the identity is ready, so
              // its inbound-snapshot bridge is attached BEFORE any group frame
              // arrives (a member added on another device pushes a snapshot
              // immediately).
              const _GroupBridge(),
              // Keep the automation-API controller alive so a persisted
              // "enabled" flag re-opens the loopback server on boot (off by
              // default).
              const _ApiBridge(),
              // What an irreversible wipe could not delete, named. It has to
              // be raised from HERE, above the router: the wipe's last act is
              // to send the app to onboarding, so the lock screen that asked
              // for it is gone before the answer arrives.
              const WipeReportHost(),
            ],
          ),
        ),
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
    // Keep ephemeral group-call signaling attached from identity-ready onward;
    // an incoming announce must not be lost merely because no call UI is open.
    ref.watch(groupCallServiceProvider);
    // Keep the P2P endpoint service attached from identity-ready onward. The
    // provider is lazy, and until something reads it the realtime
    // `onP2PEndpoints` callback stays null — every inbound endpoints frame is
    // then dropped right after the "realtime in endpoints" log line. On a
    // fresh start that silently ate the peer's call-time endpoint exchange
    // until a call (or debug hook) happened to instantiate the service, so
    // the first calls after a restart stayed on relay (live stand,
    // 2026-07-24).
    ref.watch(p2pEndpointServiceProvider);
    // Multi-device brick 4: contacts/settings/call-journal sync taps, plus the
    // journal recorder itself (calls are journaled even without a journal UI).
    ref.watch(deviceSyncBridgeProvider);
    ref.watch(resumeReconnectProvider);
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
