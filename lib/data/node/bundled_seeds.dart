import 'package:shared_preferences/shared_preferences.dart';

import '../../state/identity_scoped_prefs.dart';
import 'embedded_node.dart' show BootstrapPeerCfg, mergeBootstrapPeers;

/// Whether this identity reaches the network through the SHARED seed nodes.
///
/// ## What the shared seeds are, and what they cost
///
/// Two separate mechanisms hand the same operator-run nodes to a fresh install,
/// and the choice offered to the user has to switch off BOTH or it switches off
/// nothing:
///
///   * the descriptors bundled at `assets/prod/seeds.json`, merged into
///     [DeniableBootConfig.bootstrapPeers] by `main()` and registered through
///     IPC once the node is connected (they are the mailbox-RELAY candidates,
///     so without them a NAT'd node is unreachable by node id);
///   * veil's own compile-time `builtin_seeds()`, which the node splices in by
///     itself under `builtin_seed_policy = "auto"` whenever the config names
///     neither `[[bootstrap_peers]]` nor `peers`. The app's deniable boot
///     deliberately passes `bootstrapPeers: const []` (an Android
///     apply-config ENOENT), so for a stock install that condition is ALWAYS
///     true and the compiled-in seeds are always what the node actually dials.
///
/// Emptying the first list alone would therefore be theatre: the node would
/// dial exactly the same hosts a moment later, from inside the runtime, and the
/// person who declined would be connected to the shared seeds anyway. Declining
/// sets `builtin_seed_policy = "never"` in the composed config, which is the
/// only thing that answers the question at the point where the config is BUILT
/// rather than after the node has already been handed the addresses.
///
/// The cost of each answer, which is what the wording on screen has to say:
/// keeping the seeds means the app finds the network with nothing to configure,
/// and those operator-run nodes learn that a node of yours exists and dials
/// them. Declining means NOTHING works until a node is added by hand.
///
/// ## Where the choice lives
///
/// A profile-scoped preference, which is this codebase's identity function for
/// posture that CONFIGURES THE NODE — the same store and the same reasoning as
/// `proxy_routing`, `vpn_routing_policy` and `storage.lean_padding.v1` (see
/// [identityScopedPrefKey]). It cannot live inside the container: it decides
/// how the node that boots alongside the container is composed, and one file
/// per profile is what keeps a decoy from inheriting the real identity's
/// network posture.
String get kBundledSeedsPrefKey =>
    identityScopedPrefKey('network.bundled_seeds.v1');

/// Whether the startup re-offer has been silenced for good ("don't show this
/// again"). Separate from the decision itself: a person who declines and later
/// changes their mind must not have their answer overwritten by the act of
/// dismissing a prompt, and a person who suppressed the prompt has not thereby
/// agreed to anything.
String get kBundledSeedsReofferSuppressedPrefKey =>
    identityScopedPrefKey('network.bundled_seeds.reoffer_suppressed.v1');

/// Absent means YES. Every install that predates the choice was already using
/// the seeds, and a missing preference must not silently take a working app off
/// the network. Only an explicit `false` — someone who was asked and said no —
/// changes anything.
const bool kBundledSeedsDefault = true;

/// The bootstrap peers a node is handed, BUILT from the decision.
///
/// Deliberately not a filter over a finished list. When the seeds are declined
/// they are never merged in, so no layer downstream ever holds them and no
/// later code path can decide to "fall back" to something it can still see.
/// [operatorPeers] — the `XVEIL_BOOTSTRAP_PEERS` file, or anything else the
/// user named themselves — survives either answer: declining the SHARED seeds
/// is not declining your own node.
List<BootstrapPeerCfg> resolveBootstrapPeers({
  required List<BootstrapPeerCfg> operatorPeers,
  required List<BootstrapPeerCfg> bundledSeeds,
  required bool useBundledSeeds,
}) => mergeBootstrapPeers(
  operatorPeers,
  useBundledSeeds ? bundledSeeds : const <BootstrapPeerCfg>[],
);

/// Whether to put the choice in front of someone again at startup.
///
/// Three states, and only the first one says anything:
///
///   * declined AND nothing to connect to ⇒ OFFER. The app cannot work in this
///     state, and saying nothing would leave a person staring at a messenger
///     that never connects with no hint that they had turned that off;
///   * declined AND something to connect to ⇒ SILENT. They meant it and they
///     followed through; asking again would be nagging;
///   * suppressed by the checkbox ⇒ SILENT, permanently. And note the order:
///     suppression is checked before the peer count, so someone who ticked the
///     box is never asked again even while they have nothing — that is what the
///     box promised.
///
/// ## What counts as having a peer
///
/// Deliberately NOT the running node's peer table. That number is zero at
/// startup for everybody — the node has just bound its socket and dialled
/// nothing yet — so a prompt keyed on it would fire for the healthy and the
/// stranded alike, and asking the transport to answer before it can costs a
/// wedged provider the entire prompt.
///
/// What survives a restart, and is therefore the honest answer to "have you
/// given this app any way in", is two things:
///
///   * [ownNodeCount] — the identity's own node registry (`managed_nodes`),
///     kept inside the container, which is what the "add my node" flow writes;
///   * [configuredPeerCount] — the peers the boot config actually handed the
///     node. For an identity that declined, the bundled seeds are not in that
///     list by construction, so anything left is an entry point the operator
///     named themselves (`XVEIL_BOOTSTRAP_PEERS`).
///
/// A peer redeemed from an invite is deliberately not counted: `addContact`
/// reaches the LIVE node over IPC and nothing writes it down, and the runtime
/// directory it lives in is destroyed with the process — so on the next launch
/// that peer is gone and the identity is stranded again, which is exactly the
/// state worth speaking up about.
bool shouldOfferBundledSeeds({
  required bool useBundledSeeds,
  required bool reofferSuppressed,
  required int ownNodeCount,
  required int configuredPeerCount,
}) {
  if (useBundledSeeds) return false;
  if (reofferSuppressed) return false;
  return ownNodeCount == 0 && configuredPeerCount == 0;
}

/// Read the decision for the profile this launch runs on.
///
/// A free async read rather than a provider because the node config is composed
/// in the data layer, below Riverpod — the same shape, for the same reason, as
/// `leanStoragePaddingEnabled`. Every path that builds a node config resolves it
/// here, so no caller can forget to pass it and quietly reinstate the seeds.
Future<bool> bundledSeedsAllowed() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(kBundledSeedsPrefKey) ?? kBundledSeedsDefault;
  } catch (_) {
    // An unreadable preference store must not take a working app off the
    // network: fall back to the historical behaviour, never to the opt-out.
    return kBundledSeedsDefault;
  }
}

/// Record the decision. **False means it was not written** — the caller has to
/// be able to say so rather than show a choice that did not stick.
Future<bool> setBundledSeedsAllowed(bool allowed) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    return await prefs.setBool(kBundledSeedsPrefKey, allowed);
  } catch (_) {
    return false;
  }
}

/// Whether the startup re-offer has been silenced for this profile.
Future<bool> bundledSeedsReofferSuppressed() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(kBundledSeedsReofferSuppressedPrefKey) ?? false;
  } catch (_) {
    return false;
  }
}

/// Silence (or un-silence) the startup re-offer for this profile.
Future<bool> setBundledSeedsReofferSuppressed(bool suppressed) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    return await prefs.setBool(
      kBundledSeedsReofferSuppressedPrefKey,
      suppressed,
    );
  } catch (_) {
    return false;
  }
}
