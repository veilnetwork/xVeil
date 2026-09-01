import 'package:shared_preferences/shared_preferences.dart';

import '../../core/log.dart';
import '../../state/identity_scoped_prefs.dart';
import '../storage/storage.dart';
import 'bundled_seeds.dart';

/// The PROFILE-level half of the shared-seeds choice — the part that needs a
/// preference store, and therefore Flutter.
///
/// Split out of `bundled_seeds.dart` on purpose, and the split is load-bearing:
/// that file sits on the headless daemon's import path
/// (`bin/xveil.dart` → `lib/headless/headless_runtime.dart` →
/// `lib/data/veil_stack.dart`), and `package:shared_preferences` reaches
/// `package:flutter` and so `dart:ui`, which an AOT `dart build cli` cannot
/// have. One import cost the daemon its entire build while every app build
/// stayed green (commit 709f3b9). Nothing under `lib/headless/`,
/// `lib/data/veil_stack.dart` or `lib/data/node/bundled_seeds.dart` may import
/// this file; `test/headless_is_flutter_free_test.dart` is what says so.
///
/// The preference keeps two jobs, and only those two:
///
///   * pre-unlock, where there is no space to ask — onboarding records the
///     first answer before any container exists;
///   * migration: a space with no answer of its own adopts the preference once,
///     on the first read, and owns it from then on. An upgrade must not put an
///     identity that declined back on the shared seeds, and only the preference
///     remembers that it declined.
///
/// Everything else about the decision — what the shared seeds are, why an empty
/// peer list is not enough, and why the answer belongs in the identity's own
/// space — is documented at [kBundledSeedsSettingKey].
///
/// Same string as the container setting deliberately: one name for one
/// decision, so a grep finds both halves.
String get kBundledSeedsPrefKey =>
    identityScopedPrefKey('network.bundled_seeds.v1');

/// Whether the startup re-offer has been silenced for good ("don't show this
/// again"). Separate from the decision itself: a person who declines and later
/// changes their mind must not have their answer overwritten by the act of
/// dismissing a prompt, and a person who suppressed the prompt has not thereby
/// agreed to anything.
String get kBundledSeedsReofferSuppressedPrefKey =>
    identityScopedPrefKey('network.bundled_seeds.reoffer_suppressed.v1');

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

/// This IDENTITY's answer, from its own space — the value an app boot acts on.
///
/// A space that has never answered adopts the profile preference once and owns
/// it from then on, so an upgrade keeps a refusal that only the preference
/// remembers, and the two stop tracking each other immediately afterwards. The
/// adoption is best-effort: a space that cannot be written to still boots on the
/// value it would have stored, it simply migrates again next time.
///
/// Three states, not two, and the third is the one that used to be wrong: an
/// OPEN space that would not answer resolves to `false` and never migrates —
/// see the branch below. "Never asked" is unchanged and still resolves to
/// [kBundledSeedsDefault]; a first run cannot bootstrap otherwise.
///
/// The daemon does not come through here and must not: it has no preference to
/// inherit from — see [bundledSeedsAllowedFromSpace].
Future<bool> bundledSeedsAllowedFor(Storage storage) async {
  final own = await bundledSeedsAnswerInSpace(storage);
  final value = own.value;
  if (value != null) return value;
  if (!own.readable && storage.isOpen) {
    // An OPEN space that would not answer, which is NOT "never asked" — that
    // one is `readable` with no value, and still takes the preference and the
    // first-run default below.
    //
    // Falling back here was fail-open by construction. Since the answer moved
    // into the space, the app deliberately leaves the profile preference EMPTY
    // for every identity that ever answered (the decoy test asserts exactly
    // that: `prefs.getBool(kBundledSeedsPrefKey)` is null), so for a refusing
    // identity the fallback is not a fallback at all — it is
    // [kBundledSeedsDefault] with a costume on. One failed `getSetting` and an
    // identity that had said no was composed onto the shared seeds, with
    // `builtin_seed_policy = "auto"`, and nobody asked it anything.
    //
    // Which of the two it is cannot be recovered from here, and the only place
    // that could hold a second copy is the preference file — plaintext, outside
    // every container, where a forensic tool reads it. Writing "this profile
    // declined" there to keep a refusal readable would leak the very decision
    // the refusal is about. So the unknown resolves to the answer that cannot
    // undo a privacy decision, and the person is told: this is precisely the
    // state [shouldOfferBundledSeeds] describes, so an identity with nothing
    // else to dial gets the re-offer rather than a silent reconnection.
    devLog(
      () =>
          'xVeil[seeds]: the identity space would not answer — composing '
          'WITHOUT the shared seeds rather than undoing a refusal that only '
          'the space remembers',
    );
    return false;
  }
  final inherited = await bundledSeedsAllowed();
  if (own.readable) {
    // Only when the space really has no answer — see
    // [BundledSeedsSpaceAnswer]. Best-effort: `setBundledSeedsAllowedInSpace`
    // swallows a failed write, and this boots on `inherited` either way.
    await setBundledSeedsAllowedInSpace(storage, inherited);
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
  final own = await bundledSeedsAnswerInSpace(storage);
  if (own.value != null) return own.value;
  // No space open (onboarding, or a locked app): the profile answer is the only
  // one there is. An OPEN space that would not answer stays null — see above.
  if (!own.readable && storage.isOpen) return null;
  return storedBundledSeedsAnswer();
}

/// Record THIS identity's answer, in its own space. **False means it was not
/// written.**
///
/// Deliberately does not touch the preference for an open space. That file is
/// per profile, so writing an identity's answer there would both leave it in
/// plaintext outside every container and hand it to every space that has not
/// answered yet.
Future<bool> setBundledSeedsAllowedFor(Storage storage, bool allowed) async {
  // Before any container exists — the onboarding step — the preference IS the
  // answer, and the space that gets created adopts it on its first read.
  if (!storage.isOpen) return setBundledSeedsAllowed(allowed);
  return setBundledSeedsAllowedInSpace(storage, allowed);
}

/// Resolve one identity's answer from its own space and build its peer list.
///
/// The single seam both app boot paths go through — the one-active boot and
/// every identity of an all-online session — so "which identity is this for" is
/// asked in one place and cannot be forgotten in the other. It is also the only
/// place the one-time migration off the profile preference happens, which is
/// why an app boot resolves the answer HERE and hands it down rather than
/// letting [RealVeilStack.startDeniable] read the space by itself.
Future<IdentitySeedPlan> planIdentitySeeds({
  required Storage storage,
  required IdentityPeers peersFor,
}) async {
  final allowed = await bundledSeedsAllowedFor(storage);
  return IdentitySeedPlan(
    useBundledSeeds: allowed,
    bootstrapPeers: peersFor(allowed),
    // Read from the SAME space as the answer above, in the same place, so a
    // second identity on one device cannot inherit the first one's choice.
    meetingPoints: await meetingPointsInSpace(storage),
    meetingPolicy: await meetingPolicyInSpace(storage),
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
