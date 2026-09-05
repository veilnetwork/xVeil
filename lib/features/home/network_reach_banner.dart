import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/node/bundled_seeds.dart' show shouldOfferBundledSeeds;
import '../../data/node/node_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../state/managed_nodes_controller.dart';
import '../../state/providers.dart';

/// Why the app has nobody to talk to, when it has nobody to talk to.
enum NetworkReach {
  /// Peers are connected. Nothing to say.
  reachable,

  /// The node is up and looking, and has found no one yet.
  ///
  /// This is the ordinary "offline" the person means: the app works, their
  /// messages queue, and nothing is broken — there is simply no other node in
  /// reach right now.
  searching,

  /// The node is not running, or failed to come up.
  down,

  /// There is no route to look through at all.
  ///
  /// The shared entry nodes were declined, no node of their own was added, and
  /// no peer was configured. Saying "network not found" here would be a lie
  /// dressed as a fault: nothing is broken, the way in was switched off, and
  /// the person is the only one who can switch it back on.
  noRoute,
}

/// The banner's verdict, as a function of what the app knows.
///
/// Pure on purpose. The interesting part of this feature is not the widget —
/// it is telling four different silences apart, and getting that wrong means
/// either crying fault at a deliberate choice or reporting "searching" for a
/// node that never started.
NetworkReach networkReach({
  required NodePhase phase,
  required int peers,
  required bool useBundledSeeds,
  required int ownNodeCount,
  required int configuredPeerCount,
}) {
  if (peers > 0) return NetworkReach.reachable;
  if (phase == NodePhase.error ||
      phase == NodePhase.offline ||
      phase == NodePhase.stopped) {
    return NetworkReach.down;
  }
  // STILL COMING UP is not the same as found nothing. A node reports zero
  // peers for the first seconds of every launch, and a banner that appears in
  // that window and vanishes again teaches people to ignore it.
  if (phase == NodePhase.starting) return NetworkReach.reachable;
  // The same question the network screen's card asks, asked here: is there any
  // way in at all? Answering it the same way keeps the two from disagreeing on
  // screen at the same moment.
  if (shouldOfferBundledSeeds(
    useBundledSeeds: useBundledSeeds,
    reofferSuppressed: false,
    ownNodeCount: ownNodeCount,
    configuredPeerCount: configuredPeerCount,
  )) {
    return NetworkReach.noRoute;
  }
  return NetworkReach.searching;
}

/// How long a reason must hold before it is shown.
///
/// A peer count dips to zero on a route change, a reconnect, or an identity
/// switch, and comes back within a second or two. A strip that flashes for
/// those is worse than no strip: it trains the eye to skip it, and then it is
/// not there when it matters.
const Duration kNetworkReachSettle = Duration(seconds: 6);

/// The strip under the app bar that says the app has nobody to talk to.
class NetworkReachBanner extends ConsumerStatefulWidget {
  const NetworkReachBanner({super.key});

  /// Its height when shown, for [PreferredSize].
  static const double height = 26;

  @override
  ConsumerState<NetworkReachBanner> createState() => _NetworkReachBannerState();
}

class _NetworkReachBannerState extends ConsumerState<NetworkReachBanner> {
  NetworkReach _shown = NetworkReach.reachable;
  NetworkReach? _pending;
  Timer? _settle;

  @override
  void dispose() {
    _settle?.cancel();
    super.dispose();
  }

  /// Adopt [next] after it has held for [kNetworkReachSettle].
  ///
  /// Going BACK to reachable is immediate: a banner that outlives the problem
  /// it describes is its own defect, and there is nothing to debounce about
  /// good news.
  void _observe(NetworkReach next) {
    if (next == _shown) {
      _settle?.cancel();
      _pending = null;
      return;
    }
    if (next == NetworkReach.reachable) {
      _settle?.cancel();
      _pending = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _shown = next);
      });
      return;
    }
    if (_pending == next) return;
    _pending = next;
    _settle?.cancel();
    _settle = Timer(kNetworkReachSettle, () {
      if (!mounted) return;
      setState(() {
        _shown = next;
        _pending = null;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final phase =
        ref.watch(nodeStatusProvider).asData?.value.phase ?? NodePhase.starting;
    final peers = ref.watch(sessionCountProvider).asData?.value ?? 0;
    final reach = networkReach(
      phase: phase,
      peers: peers,
      useBundledSeeds: ref.watch(bundledSeedsChoiceProvider),
      ownNodeCount: ref.watch(managedNodesProvider).asData?.value.length ?? 0,
      configuredPeerCount:
          ref.watch(deniableBootProvider)?.bootstrapPeers.length ?? 0,
    );
    _observe(reach);
    if (_shown == NetworkReach.reachable) return const SizedBox.shrink();

    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final (text, background, foreground, icon) = switch (_shown) {
      NetworkReach.noRoute => (
        l.reachNoRoute,
        scheme.errorContainer,
        scheme.onErrorContainer,
        Icons.link_off,
      ),
      NetworkReach.down => (
        l.reachNodeDown,
        scheme.errorContainer,
        scheme.onErrorContainer,
        Icons.cloud_off,
      ),
      // Not an error colour: nothing is broken. The app works, the messages
      // wait, and the only news is that nobody else is in reach.
      NetworkReach.searching => (
        l.reachOffline,
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
        Icons.wifi_tethering_off,
      ),
      NetworkReach.reachable => ('', scheme.surface, scheme.onSurface, Icons.check),
    };
    return Semantics(
      liveRegion: true,
      child: Material(
        color: background,
        child: InkWell(
          // The strip says what is wrong; the screen that can fix it is one tap
          // away. Saying "no route" without a way to the switch is half a
          // message.
          onTap: () => context.push('/network'),
          child: SizedBox(
            height: NetworkReachBanner.height,
            width: double.infinity,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 14, color: foreground),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    text,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: foreground),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
