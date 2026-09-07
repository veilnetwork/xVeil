import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/node/bundled_seeds.dart' show shouldOfferBundledSeeds;
import '../../data/node/node_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../state/managed_nodes_controller.dart';
import '../../state/messaging.dart' show messagingServiceProvider;
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

  /// Peers are connected, and yet nobody could start a conversation with us.
  ///
  /// No relay hosts this device's mailbox, so a contact request addressed here
  /// is dropped with nothing to see at either end. It is not the same silence
  /// as the others and it does not look like one: the app is connected, says
  /// so, and works in every direction the person tries first. The daemon has
  /// warned its operator about this state since the day the state existed.
  unreachableFirst,

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
  required bool canBeReachedFirst,
  required Duration? connectedFor,
}) {
  // CONNECTED IS NOT REACHABLE. Having peers settles every question below —
  // the node is up, there is a route, somebody answered — and answers none
  // about whether anyone can reach US.
  if (peers > 0) {
    return canBeReachedFirst
        ? NetworkReach.reachable
        : NetworkReach.unreachableFirst;
  }
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
  // AND CONNECTED IS NOT "HAS PEERS" EITHER. The guard above waits out
  // `starting`, which was the wrong phase to wait on: a node reports itself
  // connected when it is UP, and its first peer arrives seconds later —
  // measured at up to a minute on a desktop doing discovery from nothing. So
  // the strip announced "offline, no other nodes found" over a node that was
  // finding them, and took it back a moment later. Reported from a laptop, and
  // it is the same misreading of "connected" that cost the mailbox its
  // carriers.
  //
  // Only the "found nobody yet" verdict waits. The two above it do not: having
  // no way in at all is a settled fact about configuration rather than a race,
  // and a node that is not running is not going to start by being waited for.
  if (connectedFor != null && connectedFor < kNetworkFirstPeerGrace) {
    return NetworkReach.reachable;
  }
  return NetworkReach.searching;
}

/// How long a node may be connected with no peers before that is worth saying.
///
/// Not a debounce: it is the gap between "the node is up" and "the node has
/// found somebody", which on a desktop starting discovery from nothing runs to
/// the better part of a minute. A strip that fires inside that window calls an
/// ordinary start an outage.
const Duration kNetworkFirstPeerGrace = Duration(seconds: 45);

/// How long a reason must hold before it is shown.
///
/// A peer count dips to zero on a route change, a reconnect, or an identity
/// switch, and comes back within a second or two. A strip that flashes for
/// those is worse than no strip: it trains the eye to skip it, and then it is
/// not there when it matters.
const Duration kNetworkReachSettle = Duration(seconds: 6);

/// How long "nobody can reach you" must hold before it is shown.
///
/// Much longer than [kNetworkReachSettle], and for a different reason: this one
/// is not debouncing a flicker, it is waiting out a job. Registering a mailbox
/// needs a peer, then that peer's key resolved, and it retries on a backoff, so
/// the honest answer for the first half-minute of every launch is "not yet"
/// rather than "never".
const Duration kNetworkUnreachableSettle = Duration(seconds: 45);

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

  /// When the node last became connected, so the verdict can tell "up and
  /// still looking" from "up and found nobody". Null while it is not.
  DateTime? _connectedAt;

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
    _settle = Timer(
        next == NetworkReach.unreachableFirst
            ? kNetworkUnreachableSettle
            : kNetworkReachSettle, () {
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
    if (phase == NodePhase.connected) {
      _connectedAt ??= DateTime.now();
    } else {
      _connectedAt = null;
    }
    final reach = networkReach(
      phase: phase,
      peers: peers,
      useBundledSeeds: ref.watch(bundledSeedsChoiceProvider),
      ownNodeCount: ref.watch(managedNodesProvider).asData?.value.length ?? 0,
      configuredPeerCount:
          ref.watch(deniableBootProvider)?.bootstrapPeers.length ?? 0,
      // Read, not watched: registration has no stream, and the peer count
      // above ticks often enough to carry this along with it.
      canBeReachedFirst:
          ref.read(messagingServiceProvider).canBeReachedFirst,
      connectedFor: _connectedAt == null
          ? null
          : DateTime.now().difference(_connectedAt!),
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
      // Not an error either: everything the person does works. What they
      // cannot see without being told is the one direction that does not.
      NetworkReach.unreachableFirst => (
        l.reachCannotBeReached,
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
        Icons.markunread_mailbox_outlined,
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
