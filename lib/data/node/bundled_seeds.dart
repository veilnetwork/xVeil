import '../storage/storage.dart';
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
/// In the IDENTITY'S OWN SPACE, as a container setting — this key — with a
/// per-profile PREFERENCE as the pre-unlock fallback and the migration source.
///
/// It shipped as a preference alone, and the rationale written here was wrong.
/// `identityScopedPrefKey` is the identity function; the separation it stands
/// for comes entirely from WHICH preferences file is installed, and that file
/// is installed once per process, from `main()`, per app PROFILE — which the
/// codebase itself documents as "only a directory choice", not an identity and
/// not a security boundary. So one answer was handed to every identity at once:
/// with several online, each node resolved the same stored value, two
/// identities could not disagree, and the last write won for all of them
/// immediately.
///
/// The claim that "one file per profile is what keeps a decoy from inheriting
/// the real identity's network posture" was untrue for the decoy this app
/// actually ships. A duress master ([AppController.createDecoyMaster]) is
/// another SPACE IN THE SAME CONTAINER, opened by the same process out of the
/// same profile directory — so it read the same file and inherited the real
/// identity's answer exactly. For a messenger whose purpose is deniability,
/// a decoy that dials what the real identity dials is the failure, not a
/// detail.
///
/// A container setting can carry it because of WHEN it is read: the node is
/// composed AFTER the space is open ([RealVeilStack.startDeniable] receives the
/// unlocked [Storage] and resolves the answer from it), unlike the padding
/// preset, which decides how to OPEN the container and therefore cannot live
/// inside it.
///
/// ## Why the preference half is a SEPARATE file
///
/// `bundled_seeds_prefs.dart`, and nothing here may import it. This file is on
/// the headless daemon's import path — `bin/xveil.dart` reaches it through
/// `lib/headless/headless_runtime.dart` and [RealVeilStack] — and the
/// preference store is `package:shared_preferences`, which is `package:flutter`,
/// which is `dart:ui`. One import of it here stopped `dart build cli` from
/// producing the daemon at all: every app build stayed green, and the whole of
/// doc/HEADLESS-DAEMON.md became unbuildable for as long as nobody ran that one
/// script (commit 709f3b9).
///
/// The split is not a workaround, it is the honest shape: a daemon has no app
/// profile, so there is no preference for it to read, nothing for it to migrate
/// FROM, and no onboarding screen that could have written one. It composes its
/// node from a config file, which is where its answer comes from
/// ([HeadlessConfig.useBundledSeeds]), falling back to the space and then to
/// [kBundledSeedsDefault] — see [bundledSeedsAllowedFromSpace].
///
/// Stored as `'true'`/`'false'` — an ABSENT setting is the space never having
/// answered, which is what triggers the one-time migration from the preference,
/// and is why the value is spelled out rather than encoded as presence.
const String kBundledSeedsSettingKey = 'network.bundled_seeds.v1';

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

/// What a space says about itself: its own answer, nothing yet, or nothing at
/// all because it would not answer.
///
/// The third case is not the second. Falling back to the profile preference is
/// right for a space that never answered — that is the migration — and wrong for
/// one whose read FAILED: the preference may hold a different identity's answer,
/// and adopting it would write that identity's posture into this space for good.
class BundledSeedsSpaceAnswer {
  const BundledSeedsSpaceAnswer.answered(bool this.value) : readable = true;
  const BundledSeedsSpaceAnswer.absent() : value = null, readable = true;
  const BundledSeedsSpaceAnswer.unreadable() : value = null, readable = false;

  final bool? value;
  final bool readable;
}

/// Read the setting out of one space, telling "no answer" from "no read".
Future<BundledSeedsSpaceAnswer> bundledSeedsAnswerInSpace(
  Storage storage,
) async {
  // A closed space is not an unanswered one. Nothing may be written into it,
  // and nothing may be concluded from its silence.
  if (!storage.isOpen) return const BundledSeedsSpaceAnswer.unreadable();
  try {
    final raw = await storage.getSetting(kBundledSeedsSettingKey);
    if (raw == null || raw.isEmpty) return const BundledSeedsSpaceAnswer.absent();
    return BundledSeedsSpaceAnswer.answered(raw == 'true');
  } catch (_) {
    return const BundledSeedsSpaceAnswer.unreadable();
  }
}

/// Write THIS identity's answer into its own space. **False means it was not
/// written**, including "the space is not open" — the caller has to be able to
/// say so rather than show a choice that did not stick.
///
/// The app's writer (`setBundledSeedsAllowedFor`) is the one that knows what to
/// do before any container exists; this half is only ever the space.
Future<bool> setBundledSeedsAllowedInSpace(
  Storage storage,
  bool allowed,
) async {
  if (!storage.isOpen) return false;
  try {
    await storage.putSetting(
      kBundledSeedsSettingKey,
      allowed ? 'true' : 'false',
    );
    return true;
  } catch (_) {
    return false;
  }
}

/// This identity's answer from its own space ALONE — no preference behind it.
///
/// For a process that HAS none to read: the headless daemon, and
/// [RealVeilStack.startDeniable] which the daemon boots through. There is no
/// silent default hidden in here — [ifUnanswered] is what a space that has
/// never been asked resolves to, and the caller states it, because for the app
/// that case means "migrate the preference" and for a daemon it means "the
/// config file did not say either, so behave as this app always has".
///
/// Never writes. A read that had to invent an answer must not freeze the
/// invention into the container: reading a config is not answering the
/// question, and the daemon's config can say something different tomorrow.
Future<bool> bundledSeedsAllowedFromSpace(
  Storage storage, {
  required bool ifUnanswered,
}) async => (await bundledSeedsAnswerInSpace(storage)).value ?? ifUnanswered;

/// The peers ONE identity is handed, given ITS answer. Built, never filtered —
/// see [resolveBootstrapPeers].
typedef IdentityPeers = List<BootstrapPeerCfg> Function(bool useBundledSeeds);

/// What one identity boots with: its own answer, and the peer list built from it.
///
/// Both halves travel together because both are needed and neither is enough:
/// the list decides what the app hands the node, [useBundledSeeds] decides
/// `builtin_seed_policy`, and an empty list without the policy is the exact
/// condition under which veil splices its compiled-in seeds back in.
class IdentitySeedPlan {
  const IdentitySeedPlan({
    required this.useBundledSeeds,
    required this.bootstrapPeers,
  });

  final bool useBundledSeeds;
  final List<BootstrapPeerCfg> bootstrapPeers;
}
