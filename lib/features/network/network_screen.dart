import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:veil_flutter/veil_flutter.dart' show VeilBackground;

import '../../data/node/node_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../state/background_node_controller.dart';
import '../../state/managed_nodes_controller.dart';
import '../../state/providers.dart';
import '../../state/proxy_routing_controller.dart';

class NetworkScreen extends ConsumerWidget {
  const NetworkScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final status = ref.watch(nodeStatusProvider);
    // Non-blocking notice when the node can't come up / reach the network — so
    // the user is told the truth instead of seeing a fabricated "connected".
    ref.listen(nodeStatusProvider, (prev, next) {
      final s = next.asData?.value;
      if (s == null) return;
      final justFailed =
          s.phase == NodePhase.error || s.phase == NodePhase.offline;
      final prevPhase = prev?.asData?.value.phase;
      final changed = prevPhase != s.phase;
      if (justFailed && changed && context.mounted) {
        final headline = s.phase == NodePhase.error
            ? l.networkStatusError
            : l.networkStatusOffline;
        final detail = (s.message != null && s.message!.isNotEmpty)
            ? '\n${s.message}'
            : '';
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 6),
            content: Text('$headline$detail'),
          ));
      }
    });
    // Real peer count from the live transport (not the controller's snapshot,
    // which only carries phase). 0 until a real node is up.
    final peers = ref.watch(sessionCountProvider).asData?.value ?? 0;
    return Scaffold(
      appBar: AppBar(title: Text(l.networkTitle)),
      body: ListView(
        children: [
          status.when(
            loading: () => const _StatusCard(
              phase: NodePhase.starting,
              peers: 0,
            ),
            error: (e, _) =>
                _StatusCard(phase: NodePhase.error, peers: 0, message: '$e'),
            data: (s) => _StatusCard(
                phase: s.phase, peers: peers, message: s.message),
          ),
          const Divider(),
          // Secondary controls — proxy/VPN + node management land here in later
          // milestones, behind their own ports (oproxy/ogate, SSH provisioning).
          Consumer(builder: (context, ref, _) {
            final routing = ref.watch(proxyRoutingProvider);
            return ListTile(
              leading: Icon(Icons.vpn_lock_outlined,
                  color: routing.isActive
                      ? Theme.of(context).colorScheme.primary
                      : null),
              title: Text(l.networkRouteTitle),
              subtitle: Text(routing.isActive
                  ? l.networkRouteSubActive
                  : l.networkRouteSubIdle),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/route'),
            );
          }),
          // Background operation — Android only (a foreground service keeps the
          // node, proxy and delivery alive when backgrounded). Opt-in: it shows
          // a persistent notification, so it's off by default for deniability.
          if (Platform.isAndroid)
            Consumer(builder: (context, ref, _) {
              final on = ref.watch(backgroundNodeProvider);
              return Column(
                children: [
                  SwitchListTile(
                    secondary:
                        const Icon(Icons.battery_charging_full_outlined),
                    title: Text(l.networkBackgroundTitle),
                    subtitle: Text(l.networkBackgroundHint),
                    isThreeLine: true,
                    value: on,
                    onChanged: (v) async {
                      await ref.read(backgroundNodeProvider.notifier).set(v);
                      // Turning it ON: a foreground service alone is NOT enough
                      // on Doze + aggressive OEMs — prompt for the battery
                      // exemption the first time it isn't already granted.
                      if (v && context.mounted) {
                        await _promptBackgroundPermission(context, l);
                      }
                    },
                  ),
                  // While ON, always surface the background-permission help: a
                  // RED warning if the app is still battery-optimised (the OS
                  // will suspend us), otherwise an info nudge — because the
                  // per-OEM "Autostart" knob (MIUI/HyperOS/OneUI) is NOT visible
                  // to any Android API, so we can't know if it's set. Tap → the
                  // dialog (battery exemption + a deep-link to app settings).
                  if (on)
                    FutureBuilder<bool>(
                      future: VeilBackground.isIgnoringBatteryOptimizations(),
                      builder: (ctx, snap) {
                        final exempt = snap.data ?? true;
                        return ListTile(
                          leading: Icon(
                            exempt
                                ? Icons.info_outline
                                : Icons.warning_amber_rounded,
                            color: exempt
                                ? null
                                : Theme.of(ctx).colorScheme.error,
                          ),
                          title: Text(l.networkBackgroundAllowTitle),
                          subtitle: Text(l.networkBackgroundAllowBody),
                          isThreeLine: true,
                          onTap: () =>
                              _promptBackgroundPermission(ctx, l, force: true),
                        );
                      },
                    ),
                ],
              );
            }),
          Consumer(builder: (context, ref, _) {
            final count =
                ref.watch(managedNodesProvider).asData?.value.length ?? 0;
            return ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: Text(l.networkNodesTitle),
              subtitle: Text(count > 0
                  ? l.networkNodesSubCount(count)
                  : l.networkNodesSub),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/nodes'),
            );
          }),
          ListTile(
            leading: const Icon(Icons.extension_outlined),
            title: Text(l.networkExtTitle),
            subtitle: Text(l.networkExtSub),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _soon(context),
          ),
        ],
      ),
    );
  }

  void _soon(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppL10n.of(context).networkComingLater)),
    );
  }
}

class _StatusCard extends ConsumerWidget {
  const _StatusCard({required this.phase, required this.peers, this.message});
  final NodePhase phase;
  final int peers;
  final String? message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final (label, color, icon) = switch (phase) {
      NodePhase.connected => (l.networkStatusConnected, Colors.green, Icons.check_circle),
      NodePhase.starting => (l.networkStatusConnecting, scheme.tertiary, Icons.sync),
      NodePhase.offline => (l.networkStatusOffline, scheme.outline, Icons.cloud_off),
      NodePhase.error => (l.networkStatusError, scheme.error, Icons.error_outline),
      NodePhase.stopped => (l.networkStatusOffline, scheme.outline, Icons.power_settings_new),
    };
    // Sub-line: real peer count when connected; the failure detail when the node
    // couldn't come up; a dash otherwise. Never a fabricated count.
    final sub = phase == NodePhase.connected
        ? l.networkPeers(peers)
        : ((message != null && message!.isNotEmpty) ? message! : '—');
    // The peer count drills into the per-peer list. Only meaningful with a real
    // node up (connected) — disabled otherwise, so the dev/loopback "0" isn't a
    // dead tap into an empty screen.
    final tappable = phase == NodePhase.connected;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: tappable ? () => context.push('/peers') : null,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Icon(icon, color: color, size: 36),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label,
                          style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 4),
                      Text(
                        sub,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
                if (tappable) const Icon(Icons.chevron_right),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Prompt the user to exempt the app from battery optimisation, so the keep-alive
/// foreground service is actually allowed to keep the node receiving in the
/// background (Doze + aggressive OEMs suspend it otherwise). No-op if already
/// granted. Also offers the app-settings deep-link, where MIUI/HyperOS/OneUI hide
/// the per-app "Autostart" knob a foreground service still needs.
Future<void> _promptBackgroundPermission(BuildContext context, AppL10n l,
    {bool force = false}) async {
  // From the toggle we only nag when the exemption is missing; from the help
  // tile ([force]) we always show it — the dialog also deep-links to the OEM
  // "Autostart" screen, which no API can confirm is set.
  if (!force && await VeilBackground.isIgnoringBatteryOptimizations()) return;
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(l.networkBackgroundAllowTitle),
      content: Text(l.networkBackgroundAllowBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(l.networkBackgroundLater),
        ),
        TextButton(
          onPressed: () {
            Navigator.pop(ctx);
            VeilBackground.openBackgroundSettings();
          },
          child: Text(l.networkBackgroundOpenSettings),
        ),
        FilledButton(
          onPressed: () {
            Navigator.pop(ctx);
            VeilBackground.requestIgnoreBatteryOptimizations();
          },
          child: Text(l.networkBackgroundAllowGrant),
        ),
      ],
    ),
  );
}
