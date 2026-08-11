import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:veil_flutter/veil_flutter.dart' show VeilBackground;

import '../common/shown_cause.dart';
import '../../core/error_journal.dart';
import '../../data/node/bundled_seeds.dart'
    show
        setBundledSeedsAllowed,
        shouldOfferBundledSeeds,
        storedBundledSeedsAnswer;
import '../../data/node/node_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../routing/back_affordance.dart';
import '../../state/background_node_controller.dart';
import '../../state/managed_nodes_controller.dart';
import '../../state/providers.dart';
import '../../state/proxy_routing_controller.dart';

/// The part of a node failure that is safe to put on screen.
///
/// The node's message is a raw native error and can quote a store path, a
/// bind address or a peer id. Why the network is down is the useful half and
/// worth keeping — a snackbar that says only "offline" helps nobody diagnose a
/// firewall. The identifying half is not: a snackbar is on screen for anyone
/// standing nearby, and it is the kind of thing people photograph and send.
///
/// So: redact, cap short enough for a snackbar, and let the full text reach
/// the error report instead.
String nodeFailureDetail(String? message) {
  if (message == null || message.trim().isEmpty) return '';
  return '\n${ErrorJournal.redact(message, maxLength: 160)}';
}

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
        // The node's message is a raw native error: it can quote a store
        // path, a bind address or a peer id. Telling the user WHY the network
        // is down is the useful part and worth keeping — the identifying part
        // is not, and a snackbar is on screen for anyone standing nearby. So
        // redact for display and keep the original for the error report.
        final raw = s.message;
        if (raw != null && raw.isNotEmpty) {
          errorJournal.record(
            kind: 'node',
            error: raw,
            atMs: DateTime.now().millisecondsSinceEpoch,
          );
        }
        final detail = nodeFailureDetail(raw);
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 6),
              content: Text('$headline$detail'),
            ),
          );
      }
    });
    // Real peer count from the live transport (not the controller's snapshot,
    // which only carries phase). 0 until a real node is up.
    final peers = ref.watch(sessionCountProvider).asData?.value ?? 0;
    return Scaffold(
      appBar: AppBar(
        leading: const RootedBackButton(),
        title: Text(l.networkTitle),
      ),
      body: ListView(
        children: [
          status.when(
            loading: () =>
                const _StatusCard(phase: NodePhase.starting, peers: 0),
            error: (e, _) => _StatusCard(
              phase: NodePhase.error,
              peers: 0,
              message: shownCause(e, kind: 'node'),
            ),
            data: (s) =>
                _StatusCard(phase: s.phase, peers: peers, message: s.message),
          ),
          // An identity that declined the shared entry nodes and has added none
          // of its own cannot reach anything, and the status card above says
          // only "offline" — which reads as a fault. Name the actual reason and
          // the way out, on the screen someone lands on when nothing works.
          const _NoWayToTheNetworkCard(),
          const Divider(),
          // How this identity reaches the network at all — first, because every
          // control below it is about a network this one decides whether there
          // is any way into. It is also the control the onboarding step promises
          // is here.
          const SharedSeedsSwitch(),
          const Divider(),
          // Secondary controls: proxy routing (oproxy SOCKS5 client + exit) is
          // live below; node management (ogate, SSH provisioning) is still a
          // later milestone behind the Extensions stub.
          Consumer(
            builder: (context, ref, _) {
              final routing = ref.watch(proxyRoutingProvider);
              return ListTile(
                leading: Icon(
                  Icons.vpn_lock_outlined,
                  color: routing.isActive
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
                title: Text(l.networkRouteTitle),
                subtitle: Text(
                  routing.isActive
                      ? l.networkRouteSubActive
                      : l.networkRouteSubIdle,
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/route'),
              );
            },
          ),
          // Background operation — Android only (a foreground service keeps the
          // node, proxy and delivery alive when backgrounded). Opt-in: it shows
          // a persistent notification, so it's off by default for deniability.
          if (Platform.isAndroid)
            Consumer(
              builder: (context, ref, _) {
                final on = ref.watch(backgroundNodeProvider);
                return Column(
                  children: [
                    SwitchListTile(
                      secondary: const Icon(
                        Icons.battery_charging_full_outlined,
                      ),
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
                            onTap: () => _promptBackgroundPermission(
                              ctx,
                              l,
                              force: true,
                            ),
                          );
                        },
                      ),
                  ],
                );
              },
            ),
          Consumer(
            builder: (context, ref, _) {
              final count =
                  ref.watch(managedNodesProvider).asData?.value.length ?? 0;
              return ListTile(
                leading: const Icon(Icons.dns_outlined),
                title: Text(l.networkNodesTitle),
                subtitle: Text(
                  count > 0 ? l.networkNodesSubCount(count) : l.networkNodesSub,
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/nodes'),
              );
            },
          ),
          // Lua extensions are not implemented. The row was a chevron that led
          // to a "coming later" snackbar, which reads as a feature that exists
          // and is merely switched off. The strings stay in the ARB files so
          // restoring the entry is one widget, not a translation round.
        ],
      ),
    );
  }
}

/// The shared-seed question, after onboarding — the control the onboarding step
/// promises is here ("You can change this later in Network settings").
///
/// That sentence shipped with nothing behind it. `setBundledSeedsAllowed` had
/// exactly two call sites: the onboarding step, which asks once, and the
/// startup re-offer, which can only ever write `true`. So an identity that
/// ACCEPTED could never decline, and one that declined and then ticked "don't
/// show this again" had no route back at all — the app promised a control it
/// did not have.
///
/// ## Why both halves are written here
///
/// Exactly the reasoning onboarding is built on, and it is not optional:
///
///   * the PREFERENCE is what `RealVeilStack.startDeniable` resolves when it
///     composes the node config, and therefore what decides
///     `builtin_seed_policy` (see [EmbeddedNode.withBuiltinSeedPolicy]);
///   * [bundledSeedsChoiceProvider] is what [deniableBootProvider] rebuilds its
///     bootstrap peer list from, so it decides whether the bundled descriptors
///     from `assets/prod/seeds.json` are handed to the node at all.
///
/// Writing only the preference would leave the boot config still holding those
/// addresses; setting only the provider would leave the node splicing in its
/// own compile-time seeds. Either alone is the theatre the choice exists to
/// prevent.
///
/// ## What happens to a node that is already running
///
/// Nothing, until it next starts — which is what the note under the switch
/// says, in the same words the proxy-routing screen uses for the same reason.
/// Both halves are consumed while a node config is being COMPOSED: the policy
/// line at `startDeniable`, the peer list when the messaging stack is built
/// around a fresh node. A running node keeps the posture it booted with, and
/// flipping this switch neither tears down a connection it already has nor
/// dials anything new. The switch deliberately does not restart the node on its
/// own: that drops every live session, and doing it silently under a settings
/// toggle is worse than saying when the change lands.
///
/// Profile-scoped, like the original answer — the preference store is one file
/// per profile, so a decoy neither inherits nor discloses the real identity's
/// network posture.
class SharedSeedsSwitch extends ConsumerStatefulWidget {
  const SharedSeedsSwitch({super.key});

  @override
  ConsumerState<SharedSeedsSwitch> createState() => _SharedSeedsSwitchState();
}

class _SharedSeedsSwitchState extends ConsumerState<SharedSeedsSwitch> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _syncFromStore();
  }

  /// Re-read the identity's own answer from the store.
  ///
  /// [bundledSeedsChoiceProvider] is seeded ONCE, by `main()`, from whichever
  /// profile the process started on. Switching identity swaps the preference
  /// file underneath it without touching the provider, so a control rendered
  /// from the provider alone would show — and write from — the PREVIOUS
  /// identity's answer. Reading the store when the control is opened makes that
  /// self-correcting, the same shape as the cached node identity.
  ///
  /// [storedBundledSeedsAnswer] rather than `bundledSeedsAllowed` because a
  /// store that will not answer must move nothing: the latter reports `true` on
  /// a failed read, which is the right default when a node config has to be
  /// composed regardless, and exactly the wrong one here — it would put an
  /// identity that refused the shared seeds back on them without anyone asking.
  Future<void> _syncFromStore() async {
    final stored = await storedBundledSeedsAnswer();
    if (!mounted || stored == null) return;
    if (ref.read(bundledSeedsChoiceProvider) != stored) {
      ref.read(bundledSeedsChoiceProvider.notifier).state = stored;
    }
  }

  Future<void> _set(bool allowed) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      // Persist FIRST, and treat a refused write as "nothing happened". The
      // onboarding step can afford the opposite — there the node has not booted
      // yet and the session that follows really does run on the answer just
      // given — but here the node config is composed from the STORE at the next
      // boot. Moving the switch over a failed write would show an answer no
      // node will ever read, which is the exact shape of promise this control
      // exists to stop making.
      final saved = await setBundledSeedsAllowed(allowed);
      if (!mounted) return;
      if (!saved) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(content: Text(AppL10n.of(context).seedsSwitchSaveFailed)),
          );
        return;
      }
      ref.read(bundledSeedsChoiceProvider.notifier).state = allowed;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final on = ref.watch(bundledSeedsChoiceProvider);
    return Column(
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.public),
          title: Text(l.seedsSwitchTitle),
          // Both answers stated with what they cost, as on the onboarding step:
          // a switch labelled only "shared entry nodes" would make the private
          // answer look free and the shared one look like nothing at all.
          subtitle: Text(on ? l.seedsSwitchOnSub : l.seedsSwitchOffSub),
          isThreeLine: true,
          value: on,
          onChanged: _busy ? null : _set,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Row(
            children: [
              Icon(Icons.refresh, size: 18, color: scheme.outline),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  // The same sentence the routing screen shows for the same
                  // fact: a running node keeps the config it booted with.
                  l.routeAppliesNextStart,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: scheme.outline),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Why this identity is offline, when the reason is that it was told to be.
///
/// Shown on exactly the state [shouldOfferBundledSeeds] describes — declined
/// and nothing to connect through — minus the suppression, which silences the
/// startup PROMPT and is not a request to be lied to on the network screen. The
/// difference between a choice and a trap is whether the app says what to do
/// next; a person who ticked "don't show this again" still deserves the answer
/// when they come looking for it.
class _NoWayToTheNetworkCard extends ConsumerWidget {
  const _NoWayToTheNetworkCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(bundledSeedsChoiceProvider)) return const SizedBox.shrink();
    // Here — unlike the startup prompt — the LIVE peer count is worth watching
    // too: this screen is looked at over time, not sampled once at boot, so a
    // node that has since connected to something should stop being told it
    // cannot reach anything.
    final livePeers = ref.watch(peersProvider).asData?.value.length ?? 0;
    if (!shouldOfferBundledSeeds(
      useBundledSeeds: false,
      // The card answers "why is nothing working", which a silenced prompt does
      // not stop being a fair question — so suppression is not consulted.
      reofferSuppressed: false,
      ownNodeCount: ref.watch(managedNodesProvider).asData?.value.length ?? 0,
      configuredPeerCount:
          (ref.watch(deniableBootProvider)?.bootstrapPeers.length ?? 0) +
          livePeers,
    )) {
      return const SizedBox.shrink();
    }
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.link_off, color: scheme.onErrorContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l.seedsNoNodeTitle,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: scheme.onErrorContainer,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              l.seedsNoNodeBody,
              style: TextStyle(color: scheme.onErrorContainer),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                icon: const Icon(Icons.add),
                label: Text(l.seedsNoNodeAction),
                onPressed: () => context.push('/nodes'),
              ),
            ),
          ],
        ),
      ),
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
      NodePhase.connected => (
        l.networkStatusConnected,
        Colors.green,
        Icons.check_circle,
      ),
      NodePhase.starting => (
        l.networkStatusConnecting,
        scheme.tertiary,
        Icons.sync,
      ),
      NodePhase.offline => (
        l.networkStatusOffline,
        scheme.outline,
        Icons.cloud_off,
      ),
      NodePhase.error => (
        l.networkStatusError,
        scheme.error,
        Icons.error_outline,
      ),
      NodePhase.stopped => (
        l.networkStatusOffline,
        scheme.outline,
        Icons.power_settings_new,
      ),
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
                      Text(
                        label,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 4),
                      Text(sub, style: Theme.of(context).textTheme.bodyMedium),
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
Future<void> _promptBackgroundPermission(
  BuildContext context,
  AppL10n l, {
  bool force = false,
}) async {
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
