import 'package:shared_preferences/shared_preferences.dart';

import '../../state/identity_scoped_prefs.dart';
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
/// In the IDENTITY'S OWN SPACE, as a container setting
/// ([kBundledSeedsSettingKey]), with the preference below as the pre-unlock
/// fallback and the migration source.
///
/// It shipped as a preference alone, and the rationale written here was wrong.
/// [identityScopedPrefKey] is the identity function; the separation it stands
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
/// The preference keeps two jobs, and only those two:
///
///   * pre-unlock, where there is no space to ask — onboarding records the
///     first answer before any container exists;
///   * migration: a space with no answer of its own adopts the preference once,
///     on the first read, and owns it from then on. An upgrade must not put an
///     identity that declined back on the shared seeds, and only the preference
///     remembers that it declined.
String get kBundledSeedsPrefKey =>
    identityScopedPrefKey('network.bundled_seeds.v1');

/// The identity's own answer, inside its space. Same string as the preference
/// key deliberately: one name for one decision, so a grep finds both halves.
///
/// Stored as `'true'`/`'false'` — an ABSENT setting is the space never having
/// answered, which is what triggers the one-time migration, and is why the
/// value is spelled out rather than encoded as presence.
const String kBundledSeedsSettingKey = 'network.bundled_seeds.v1';

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

/// Read the PROFILE-level answer — the pre-unlock fallback, not an identity's.
///
/// A free async read rather than a provider because the node config is composed
/// in the data layer, below Riverpod — the same shape, for the same reason, as
/// `leanStoragePaddingEnabled`.
///
/// This is what `main()` seeds the live provider from, before any container is
/// open. An identity's own answer comes from [bundledSeedsAllowedFor], which
/// falls back to this one exactly once and then stops.
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

/// The stored answer, or NULL when the store would not answer.
///
/// [bundledSeedsAllowed] deliberately reports `true` for an unreadable store: a
/// node config has to be composed one way or the other, and falling back to the
/// historical behaviour rather than to the opt-out is right there. A CONTROL is
/// the opposite case. A store that will not answer is not a person changing
/// their mind, and a switch that moved on its behalf would put an identity that
/// refused the shared seeds back on them — silently, and in the live boot
/// config. So the two callers want different things from the same read, and
/// this is the one that can tell "no answer" from "no".
Future<bool?> storedBundledSeedsAnswer() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    // Absent still means yes — see [kBundledSeedsDefault]. Only an unreadable
    // store is nothing at all.
    return prefs.getBool(kBundledSeedsPrefKey) ?? kBundledSeedsDefault;
  } catch (_) {
    return null;
  }
}

/// Record the PROFILE-level answer. **False means it was not written** — the
/// caller has to be able to say so rather than show a choice that did not stick.
///
/// Only for the state where no space exists yet (onboarding). Everything with an
/// open container writes [setBundledSeedsAllowedFor] instead: writing an
/// identity's answer here would put it in plaintext outside every container AND
/// hand it to the next identity that has none, which is the defect this file
/// used to have.
Future<bool> setBundledSeedsAllowed(bool allowed) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    return await prefs.setBool(kBundledSeedsPrefKey, allowed);
  } catch (_) {
    return false;
  }
}

/// What a space says about itself: its own answer, nothing yet, or nothing at
/// all because it would not answer.
///
/// The third case is not the second. Falling back to the profile preference is
/// right for a space that never answered — that is the migration — and wrong for
/// one whose read FAILED: the preference may hold a different identity's answer,
/// and adopting it would write that identity's posture into this space for good.
class _SpaceAnswer {
  const _SpaceAnswer.answered(bool this.value) : readable = true;
  const _SpaceAnswer.absent() : value = null, readable = true;
  const _SpaceAnswer.unreadable() : value = null, readable = false;

  final bool? value;
  final bool readable;
}

Future<_SpaceAnswer> _answerInSpace(Storage storage) async {
  // A closed space is not an unanswered one. Nothing may be written into it,
  // and nothing may be concluded from its silence.
  if (!storage.isOpen) return const _SpaceAnswer.unreadable();
  try {
    final raw = await storage.getSetting(kBundledSeedsSettingKey);
    if (raw == null || raw.isEmpty) return const _SpaceAnswer.absent();
    return _SpaceAnswer.answered(raw == 'true');
  } catch (_) {
    return const _SpaceAnswer.unreadable();
  }
}

/// This IDENTITY's answer, from its own space — the value a node boot acts on.
///
/// A space that has never answered adopts the profile preference once and owns
/// it from then on, so an upgrade keeps a refusal that only the preference
/// remembers, and the two stop tracking each other immediately afterwards. The
/// adoption is best-effort: a space that cannot be written to still boots on the
/// value it would have stored, it simply migrates again next time.
Future<bool> bundledSeedsAllowedFor(Storage storage) async {
  final own = await _answerInSpace(storage);
  final value = own.value;
  if (value != null) return value;
  final inherited = await bundledSeedsAllowed();
  if (own.readable) {
    // Only when the space really has no answer — see [_SpaceAnswer].
    try {
      await storage.putSetting(
        kBundledSeedsSettingKey,
        inherited ? 'true' : 'false',
      );
    } catch (_) {
      /* boots on `inherited` either way; migrates again next launch */
    }
  }
  return inherited;
}

/// This identity's stored answer, or NULL when nothing would answer.
///
/// The control's read, and it differs from [bundledSeedsAllowedFor] exactly
/// where [storedBundledSeedsAnswer] differs from [bundledSeedsAllowed]: a node
/// config has to be composed one way or the other, a SWITCH does not, and one
/// that moved on a failed read would put an identity that refused the shared
/// seeds back on them with nobody having asked. Never migrates — reading a
/// control is not answering the question.
Future<bool?> storedBundledSeedsAnswerFor(Storage storage) async {
  final own = await _answerInSpace(storage);
  if (own.value != null) return own.value;
  // No space open (onboarding, or a locked app): the profile answer is the only
  // one there is. An OPEN space that would not answer stays null — see above.
  if (!own.readable && storage.isOpen) return null;
  return storedBundledSeedsAnswer();
}

/// Record THIS identity's answer, in its own space. **False means it was not
/// written.**
///
/// Deliberately does not touch the preference. That file is per profile, so
/// writing an identity's answer there would both leave it in plaintext outside
/// every container and hand it to every space that has not answered yet.
Future<bool> setBundledSeedsAllowedFor(Storage storage, bool allowed) async {
  // Before any container exists — the onboarding step — the preference IS the
  // answer, and the space that gets created adopts it on its first read.
  if (!storage.isOpen) return setBundledSeedsAllowed(allowed);
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

/// Resolve one identity's answer from its own space and build its peer list.
///
/// The single seam both boot paths go through — the one-active boot and every
/// identity of an all-online session — so "which identity is this for" is asked
/// in one place and cannot be forgotten in the other.
Future<IdentitySeedPlan> planIdentitySeeds({
  required Storage storage,
  required IdentityPeers peersFor,
}) async {
  final allowed = await bundledSeedsAllowedFor(storage);
  return IdentitySeedPlan(
    useBundledSeeds: allowed,
    bootstrapPeers: peersFor(allowed),
  );
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
