import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/node/node_controller.dart';
import '../../data/node/proxy_routing.dart';
import '../../data/vpn/vpn_backend.dart';
import '../../data/vpn/vpn_proxy_plan.dart';
import '../../data/vpn/vpn_routing_policy.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_controller.dart';
import '../../state/providers.dart';
import '../../state/proxy_routing_controller.dart';
import '../../state/vpn_controller.dart';

/// Opens the compact, always-available security and network control surface.
///
/// It deliberately reuses the same providers and actions as Network/Account
/// settings: the peer count is live, identity switches follow the selected
/// one-active/all-online policy, and proxy changes restart the node instead of
/// merely painting an optimistic toggle.
Future<void> showSecurityCenterSheet(
  BuildContext context,
  WidgetRef ref,
) async {
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => const _SecurityCenterSheet(),
  );
}

class _SecurityCenterSheet extends ConsumerStatefulWidget {
  const _SecurityCenterSheet();

  @override
  ConsumerState<_SecurityCenterSheet> createState() =>
      _SecurityCenterSheetState();
}

class _SecurityCenterSheetState extends ConsumerState<_SecurityCenterSheet> {
  bool _busy = false;

  /// The onion setting as this sheet found it.
  ///
  /// Kept so the subtitle can tell "this is how it is set" apart from "you just
  /// changed it, and it applies when the node next starts". Choosing the hint
  /// from the current bool alone made a never-touched toggle announce a change
  /// nobody had made: on a fresh install the line read "no longer routes over
  /// onion — applies on its next start", which describes a pending restart for
  /// a setting that has always been off.
  bool? _anonymousAtOpen;

  Future<void> _switchIdentity(String label) async {
    final app = ref.read(appControllerProvider);
    if (_busy || label == app.activeIdentity) return;
    Navigator.of(context).pop();
    await ref.read(appControllerProvider.notifier).switchIdentity(label);
  }

  Future<void> _setAnonymous(bool enabled) async {
    if (_busy) return;
    final app = ref.read(appControllerProvider);
    final ctrl = ref.read(appControllerProvider.notifier);
    // This one does NOT pop first, unlike the proxy and VPN toggles. Popping
    // before the await is what made the pending state unobservable: the single
    // moment at which the person has changed the setting and not yet seen it
    // take effect is the moment this surface used to disappear, so the subtitle
    // could only ever describe a state nobody had just changed — and it
    // described every such state as a pending restart.
    setState(() => _busy = true);
    try {
      if (app.isMaster && app.activeIdentity != null) {
        await ctrl.setIdentityAnonymous(app.activeIdentity!, enabled);
      } else if (!app.isMaster) {
        await ctrl.setSingleIdentityAnonymous(enabled);
      }
    } finally {
      // The reboot flips the phase, the router redirects, and this sheet is a
      // route over the page the redirect removes — so it may well be gone by
      // now. A disposed StateSetter throws, and that is the whole reason for
      // the guard.
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setProxy(bool enabled) async {
    if (_busy) return;
    final routing = ref.read(proxyRoutingProvider);
    if (enabled && routing.effectiveDefaultOproxyNodeIds.isEmpty) {
      Navigator.of(context).pop();
      if (context.mounted) context.push('/route');
      return;
    }
    setState(() => _busy = true);
    final next = routing.copyWith(socks5Enabled: enabled);
    Navigator.of(context).pop();
    await ref.read(appControllerProvider.notifier).applyProxyRouting(next);
  }

  Future<void> _setVpn(bool enabled) async {
    if (_busy) return;
    final routing = ref.read(proxyRoutingProvider);
    final policy = ref.read(vpnControllerProvider).policy;
    if (enabled && !vpnTransportReadyForPolicy(routing, policy)) {
      Navigator.of(context).pop();
      if (context.mounted) context.push('/route');
      return;
    }
    setState(() => _busy = true);
    Navigator.of(context).pop();
    final controller = ref.read(vpnControllerProvider.notifier);
    if (enabled) {
      await controller.start();
    } else {
      await controller.stop();
    }
  }

  void _open(String route) {
    Navigator.of(context).pop();
    if (context.mounted) context.push(route);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final app = ref.watch(appControllerProvider);
    final appCtrl = ref.read(appControllerProvider.notifier);
    final node = ref.watch(nodeStatusProvider).asData?.value;
    final peers = ref.watch(sessionCountProvider).asData?.value ?? 0;
    final routing = ref.watch(proxyRoutingProvider);
    final vpn = ref.watch(vpnControllerProvider);
    final vpnTransportReady = vpnTransportReadyForPolicy(routing, vpn.policy);
    // The flags live on the NOTIFIER, not in AppState, and the toggle reboots
    // the node without changing any watched field — so without this the sheet
    // would keep drawing the pre-toggle value and nothing here could ever be
    // pending. Same watch the account screen keeps, for the same reason.
    ref.watch(anonymityRevisionProvider);
    final anonymous = app.isMaster
        ? (app.activeIdentity != null &&
              appCtrl.isIdentityAnonymous(app.activeIdentity!))
        : appCtrl.singleIdentityAnonymous;
    _anonymousAtOpen ??= anonymous;
    final anonymityPending = _anonymousAtOpen != anonymous;
    final connected = node?.phase == NodePhase.connected;
    final nodeLabel = switch (node?.phase) {
      NodePhase.connected => l.networkStatusConnected,
      NodePhase.starting => l.networkStatusConnecting,
      NodePhase.error => l.networkStatusError,
      NodePhase.offline || NodePhase.stopped || null => l.networkStatusOffline,
    };

    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: 12),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
            child: Text(
              l.securityCenterTitle,
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          ListTile(
            leading: Icon(
              connected ? Icons.shield : Icons.shield_outlined,
              color: connected ? Colors.green : scheme.outline,
            ),
            title: Text(nodeLabel),
            subtitle: Text(l.networkPeers(peers)),
            trailing: const Icon(Icons.chevron_right),
            onTap: connected ? () => _open('/peers') : () => _open('/network'),
          ),
          const Divider(),
          if (app.isMaster) ...[
            ListTile(
              leading: const Icon(Icons.switch_account_outlined),
              title: Text(l.settingsSwitchIdentity),
              subtitle: app.activeIdentity == null
                  ? null
                  : Text(app.activeIdentity!),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final label in app.identities)
                    ChoiceChip(
                      label: Text(label),
                      selected: label == app.activeIdentity,
                      onSelected: _busy ? null : (_) => _switchIdentity(label),
                    ),
                ],
              ),
            ),
          ] else
            ListTile(
              leading: const Icon(Icons.person_outline),
              // The subtitle says what the row LEADS TO. It used to repeat
              // `settingsCatAccount`, which is also the title's fallback — so
              // for every identity without a display name, which is every
              // fresh one, the row read "Identities & account" twice over and
              // said nothing at all. The string written for this second line
              // was sitting unused two files away.
              title: Text(app.identity?.displayName ?? l.settingsCatAccount),
              subtitle: Text(l.settingsCatAccountHint),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _open('/settings/account'),
            ),
          const Divider(),
          SwitchListTile(
            secondary: Icon(
              vpn.isRunning ? Icons.vpn_lock : Icons.vpn_lock_outlined,
            ),
            title: Text(l.vpnTitle),
            subtitle: Text(switch (vpn.backend.phase) {
              VpnBackendPhase.running => l.vpnStatusRunning,
              VpnBackendPhase.starting => l.vpnStatusStarting,
              VpnBackendPhase.stopping => l.vpnStatusStopping,
              VpnBackendPhase.error => vpn.backend.detail ?? l.vpnStatusError,
              VpnBackendPhase.unsupported => l.vpnStatusUnsupported,
              VpnBackendPhase.stopped =>
                vpnTransportReady ? l.vpnStatusStopped : l.vpnNeedsProxy,
            }),
            value: vpn.isRunning,
            onChanged:
                _busy ||
                    vpn.busy ||
                    vpn.backend.phase == VpnBackendPhase.unsupported
                ? null
                : _setVpn,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.vpn_lock_outlined),
            title: Text(l.routeSocks5Title),
            subtitle: Text(
              routing.effectiveDefaultOproxyNodeIds.isEmpty
                  ? l.routeNeedExit
                  : (routing.socks5Active
                        ? l.networkRouteSubActive
                        : l.networkRouteSubIdle),
            ),
            value: routing.socks5Enabled,
            onChanged: _busy ? null : _setProxy,
          ),
          SwitchListTile(
            secondary: Icon(
              anonymous ? Icons.shield_moon : Icons.shield_moon_outlined,
            ),
            title: Text(l.settingsAnonymousRouting),
            // Two different sentences for two different facts. Unchanged, this
            // states what the setting IS; changed, it states what was just
            // asked for and when it lands. The pending wording on its own was
            // a claim about an act, and printing it for a toggle nobody had
            // touched told a fresh install that a restart was outstanding.
            subtitle: Text(
              anonymityPending
                  ? (anonymous
                        ? l.settingsAnonymousEnabledHint
                        : l.settingsAnonymousDisabledHint)
                  : (anonymous
                        ? l.securityCenterAnonymousOn
                        : l.securityCenterAnonymousOff),
            ),
            value: anonymous,
            onChanged: _busy ? null : _setAnonymous,
          ),
          ListTile(
            leading: const Icon(Icons.tune),
            title: Text(l.routeTitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _open('/route'),
          ),
        ],
      ),
    );
  }
}

/// The VPN may have an explicit main oproxy chain even when the manual SOCKS
/// default is intentionally unset, so readiness must be evaluated against the
/// complete routing policy rather than [ProxyRouting.vpnTransportReady].
bool vpnTransportReadyForPolicy(ProxyRouting routing, VpnRoutingPolicy policy) {
  try {
    VpnProxyPlan.build(routing: routing, policy: policy);
    return true;
  } on VpnProxyPlanException {
    return false;
  }
}
