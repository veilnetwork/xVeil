import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../core/error_journal.dart';
import '../core/secret_wipe.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;

import '../data/native_libs.dart';

import '../data/node/bundled_seeds.dart' show IdentitySeedPlan;
import '../data/node/bundled_seeds_prefs.dart' show planIdentitySeeds;
import '../data/node/embedded_node.dart';
import '../data/node/node_controller.dart';
import '../data/node/proxy_routing.dart';
import '../data/storage/kv_log_store.dart' show SlotUtilization;
import '../data/storage/on_disk_blob_store.dart';
import '../data/storage/storage.dart';
import '../data/veil_stack.dart';
import '../data/vpn/vpn_backend.dart' show VpnBackendPhase;
import '../data/whisper_model_store.dart' show WhisperModelStore;
import '../domain/storage_compaction_policy.dart';
import '../domain/identity.dart';
import '../domain/p2p_policy.dart';
import '../domain/roster.dart';
import 'background_node_controller.dart';
import 'keep_all_online_controller.dart';
import 'proxy_routing_controller.dart';
import 'identity_scoped_prefs.dart';
import 'notifications.dart';
import 'providers.dart';
import 'screen_lock_controller.dart';
import 'storage_preferences.dart';
import 'vpn_controller.dart';
import 'translation_model_controller.dart';
import 'whisper_model_controller.dart';
import 'package:xveil/core/log.dart';

/// Top-level lifecycle of the app, used by the router to gate screens.
enum AppPhase {
  /// Reading prefs / deciding where to send the user.
  bootstrapping,

  /// No identity set up yet — run the first-launch wizard.
  onboarding,

  /// An identity exists; the space is locked and needs a password.
  locked,

  /// The unlocked space is a MASTER managing several identities — let the user
  /// pick which one to act as (master mode). Single-identity spaces skip this.
  pickingIdentity,

  /// Space unlocked; the in-process node is being provisioned/booted (mining the
  /// identity on first run can take a few seconds) — show a "setting up" screen.
  preparingNode,

  /// The space opened, but the identity record inside it is DAMAGED (audit
  /// XV-13). Not the same as a space with no identity: something is stored and
  /// it will not parse. Dead end on purpose — the only ways out are locking or
  /// the destructive actions on the lock screen, and nothing on the path here
  /// writes to the space, so whatever is left of the record stays intact for a
  /// later recovery tool.
  identityDamaged,

  /// Space unlocked, node starting/connected — show the messenger.
  ready,
}

/// Why the [AppPhase.preparingNode] screen is showing — drives its message so a
/// long wait reads honestly (opening the encrypted container vs the one-time
/// identity proof-of-work vs a generic node boot) instead of always "preparing".
enum PreparingReason { node, unlocking, firstRunMining }

class AppState {
  const AppState(
    this.phase, {
    this.identity,
    this.unlockError = false,
    this.identities = const [],
    this.activeIdentity,
    this.preparingReason = PreparingReason.node,
  });

  final AppPhase phase;
  final Identity? identity;
  final bool unlockError;

  /// Why the preparing screen is up (opening container / first-run mining /
  /// generic). Transient; reset to [PreparingReason.node] on the next state.
  final PreparingReason preparingReason;

  /// The labels of the identities the unlocked master manages — populated
  /// throughout a master session (the picker's options, and the switcher's).
  /// Empty in single-identity mode.
  final List<String> identities;

  /// In a master session, the label of the currently active identity; null in
  /// single-identity mode.
  final String? activeIdentity;

  /// True when the unlocked space is a master managing several identities.
  bool get isMaster => identities.isNotEmpty;

  AppState copyWith({
    AppPhase? phase,
    Identity? identity,
    bool? unlockError,
    List<String>? identities,
    String? activeIdentity,
    PreparingReason? preparingReason,
  }) => AppState(
    phase ?? this.phase,
    identity: identity ?? this.identity,
    unlockError: unlockError ?? false,
    identities: identities ?? this.identities,
    activeIdentity: activeIdentity ?? this.activeIdentity,
    preparingReason: preparingReason ?? PreparingReason.node,
  );
}

/// Whether this install has been through first-launch setup — a fact about ONE
/// profile, not the installation. It used to be global, so a brand-new profile
/// started at the lock screen with no container to unlock and could never be
/// opened at all. Separation now comes from the per-profile preference file
/// rather than from the key name (audit XV-16); see [identityScopedPrefKey].
String _onboardedKey() => identityScopedPrefKey('onboarded');
const _kStorageModeKey = 'storage_mode';

class AppController extends Notifier<AppState> {
  /// Roster of the master unlocked this session — cached for the whole master
  /// session so identity switching needs no re-prompt. Holds child SpaceKeys;
  /// cleared on lock/start-over. Null in single-identity mode.
  List<RosterEntry>? _pendingRoster;

  /// The MASTER space's own SpaceKeys, cached at unlock so roster edits (e.g.
  /// toggling an identity's anonymity) can reopen the master by keys without
  /// re-prompting for the master password. Cleared on lock/start-over.
  Uint8List? _masterKeys;

  /// Label of the identity currently active in a master session (null in
  /// single-identity mode).
  String? _activeLabel;

  /// One-active listen-port offset, alternated on every real-stack teardown:
  /// rebinding the port a just-stopped node held stalls the next boot for up
  /// to ~90s (its teardown lingers in the kernel) — the dominant cost of a
  /// slow identity switch in one-active mode (audit #3).
  int _oneActivePortOffset = 0;

  /// A SINGLE (non-master) identity's anonymity preference, persisted per-space
  /// under the `anonymous` setting and loaded at session entry. Defaults to
  /// FALSE: a plain identity routes directly (no onion overhead) unless the user
  /// turns anonymity on. In master mode the per-identity roster flag governs
  /// instead (see [_activeAnonymous]).
  bool _singleAnonymous = false;

  /// Storage key for [_singleAnonymous].
  static const _kAnonymousSetting = 'anonymous';

  /// A SINGLE (non-master) identity's lazy-mining preference, persisted per-space
  /// under the `lazy_mining` setting and loaded at session entry. Defaults to
  /// FALSE: lazy mining is a CPU-heavy background PoW grind that raises the
  /// identity's anti-sybil difficulty but is NOT needed to use the node and
  /// competes with the latency-critical runtime (it starved IPC → app hangs).
  /// Opt-in only. Like anonymity, it is fixed at node boot, so toggling reboots.
  bool _singleLazyMining = false;

  /// Storage key for [_singleLazyMining].
  static const _kLazyMiningSetting = 'lazy_mining';

  @override
  AppState build() {
    _bootstrap();
    return const AppState(AppPhase.bootstrapping);
  }

  Future<void> _bootstrap() async {
    final prefs = await ref.read(prefsProvider.future);
    // Reading preferences is an async gap, and the controller can be disposed
    // inside it — a window closed during launch, an identity switch that
    // rebuilds the provider. Assigning state afterwards throws out of a future
    // nobody awaits, which surfaces as an unhandled error rather than as
    // anything a person could act on.
    if (!ref.mounted) return;
    final onboarded = prefs.getBool(_onboardedKey()) ?? false;
    state = AppState(onboarded ? AppPhase.locked : AppPhase.onboarding);
  }

  /// Finish first-launch setup: persist the new identity into a freshly
  /// created space and start the session.
  /// Held ONLY between completeOnboarding and the first node boot, then
  /// dropped (P2): the master phrase the user just wrote down, from which the
  /// node identity is derived. Never persisted anywhere.
  String? _pendingIdentityPhrase;

  /// Read the pending phrase AND clear it, in one step.
  ///
  /// There is deliberately no way to read it without spending it. The bug this
  /// closes was a read whose matching clear sat after an `await` that could
  /// throw: on a failed node boot the phrase stayed in the controller, and the
  /// next unlock — of a different legacy or decoy identity with no node config
  /// of its own — consumed it and derived the SAME node identity, binding two
  /// storage spaces that must not know about each other to one identity on the
  /// wire. Separating read from clear is what made that possible, so they are
  /// not separable any more.
  @visibleForTesting
  String? takePendingIdentityPhrase() {
    final phrase = _pendingIdentityPhrase;
    _pendingIdentityPhrase = null;
    return phrase;
  }

  /// Whether the pending phrase is a RESTORE. Travels beside the phrase and is
  /// taken with it: the boot needs both together, and a flag that outlived its
  /// phrase would mint a device key for an identity nobody is restoring.
  bool _pendingRestoringIdentity = false;

  bool takePendingRestoringIdentity() {
    final restoring = _pendingRestoringIdentity;
    _pendingRestoringIdentity = false;
    return restoring;
  }

  /// Finish first-launch setup.
  ///
  /// Takes what the person actually chose, not a fabricated identity. It used
  /// to take an [Identity] whose node id the caller had just minted at RANDOM,
  /// which is where audit XV-06 starts: that id went into the space, the node
  /// then derived or mined its own, and nothing ever reconciled them. There is
  /// nothing to reconcile now — the node id is never authored here.
  Future<void> completeOnboarding({
    required String password,
    required StorageMode mode,
    String? displayName,
    // The REAL master phrase shown on the recovery step (null on the
    // loopback/test path where the native generator is unavailable).
    String? identityPhrase,
    // The phrase names an identity that ALREADY EXISTS. The first device of an
    // identity takes the phrase's own keypair as its node key; every later one
    // must mint its own, or two devices restored from one phrase are literally
    // one node — which is what made linking answer "self device".
    bool restoringIdentity = false,
    // The user picked "link to a device you already use": this device only has
    // to reach the network so an existing one can approve it, and the session
    // this opens should land on the device-link screen instead of chats.
    bool joinExisting = false,
  }) async {
    _pendingIdentityPhrase = identityPhrase;
    _pendingRestoringIdentity = restoringIdentity;
    // Set BEFORE the session opens: _enterSession flips the phase to ready, and
    // the router consumes the flag on that transition. Setting it afterwards
    // would race the redirect and drop the user on chats.
    ref.read(pendingDeviceLinkProvider.notifier).state = joinExisting;
    // Show the "setting up" screen up front and let it paint a frame BEFORE the
    // CPU-heavy work begins — creating the container (Argon2id KDF) and
    // provisioning the node identity both block briefly, and without this the
    // onboarding window looks frozen on "Done". Only in deniable mode (the
    // loopback/test path is instant, so it would just flash).
    if (ref.read(deniableBootProvider) != null) {
      state = state.copyWith(
        phase: AppPhase.preparingNode,
        preparingReason: PreparingReason.firstRunMining,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    final storage = ref.read(storageProvider);
    // `open` ANSWERS whether it unlocked anything (audit X-15). The result was
    // dropped and the profile write ran anyway, against a storage that was not
    // open — so a failure here surfaced later, somewhere else, as a confusing
    // error against half-written onboarding state. Roll the phase back and say
    // what happened while the cause is still on the stack.
    final opened = await storage.open(
      password: password,
      createIfMissing: true,
    );
    if (!opened) {
      await _abandonOnboarding();
      throw StateError(
        'storage.open refused the onboarding password; nothing was written',
      );
    }
    // From here the container is OPEN, and every remaining step can fail. The
    // rollback used to cover only the step above — the one that had not opened
    // anything yet — so a profile write, a preference write or a node boot that
    // threw left the container OPEN, its exclusive flock held, the screen lock
    // primed with the password, and the phase parked on "setting up" with no
    // way forward and no way back (audit report8).
    try {
      // The container just answered to this password — the same one moment
      // [unlock] uses, and the only one onboarding gets. Without this the very
      // first session had nothing to check a typed password against, so the
      // screen lock could not engage at all until the app was restarted
      // (IF-01): `_lock` refuses to put up a prompt nobody can answer.
      ref.read(screenLockProvider.notifier).rememberPassword(password);
      final profile = UserProfile(displayName: displayName);
      await storage.saveProfile(profile);

      final prefs = await ref.read(prefsProvider.future);
      // `setBool`/`setString` ANSWER whether the write landed, and both answers
      // were dropped. A preference store that refuses (the in-memory fallback
      // main() installs when the profile store cannot be created, a full disk)
      // left this install marked "onboarded" only in RAM: the next launch shows
      // first-run setup again, over a container that already exists, and the
      // storage mode the user chose is gone with it.
      if (!await prefs.setBool(_onboardedKey(), true)) {
        throw StateError('preference store refused the onboarding marker');
      }
      if (!await prefs.setString(_kStorageModeKey, mode.name)) {
        throw StateError('preference store refused the storage mode');
      }

      await _enterSession(profile);
    } catch (e, st) {
      devLog(() => 'xVeil[onboarding]: FAILED, rolling back: $e\n$st');
      errorJournal.record(
        kind: 'onboarding',
        error: e,
        stack: st,
        atMs: DateTime.now().millisecondsSinceEpoch,
      );
      await _abandonOnboarding(closeStorage: true);
      rethrow;
    }
  }

  /// Undo a first-launch setup that did not finish.
  ///
  /// The container FILE is deliberately left alone — it may already hold other
  /// deniable spaces, and this app cannot prove otherwise; the same reasoning
  /// as [startOver]. What goes is everything this attempt put in memory or in
  /// preferences: the open handle and its exclusive lock, the screen lock's
  /// password recogniser, the master phrase, the device-link intent, and the
  /// two preference keys that would otherwise send the next launch to a lock
  /// screen for an identity that was never finished.
  Future<void> _abandonOnboarding({bool closeStorage = false}) async {
    if (closeStorage) {
      try {
        await ref.read(storageProvider).close();
      } catch (e) {
        devLog(() => 'xVeil[onboarding]: rollback close failed: $e');
      }
      // Primed with a password for a session that will not exist.
      ref.read(screenLockProvider.notifier).forgetSession();
      try {
        final prefs = await ref.read(prefsProvider.future);
        await prefs.remove(_onboardedKey());
        await prefs.remove(_kStorageModeKey);
      } catch (e) {
        devLog(() => 'xVeil[onboarding]: rollback prefs failed: $e');
      }
    }
    ref.read(pendingDeviceLinkProvider.notifier).state = false;
    takePendingIdentityPhrase();
    state = state.copyWith(phase: AppPhase.onboarding, preparingReason: null);
  }

  /// Guards [unlock] against overlapping runs (UI double-submit racing the
  /// debug hook's /unlock): two concurrent opens of the same container make the
  /// second fail `Busy` and the interleaved state writes can end on `locked`
  /// while the container is actually open — a stuck "wrong password" until
  /// restart. One unlock at a time; latecomers are dropped (the in-flight run
  /// ends in ready/locked either way).
  bool _unlockInFlight = false;

  /// LIFECYCLE GENERATION — what makes "is the session I am building still the
  /// one the user wants?" a question with an answer (audit H-06).
  ///
  /// Every boot in this file creates a live resource — a node, a hosted session
  /// owning every identity's node and the container's shared lock — and
  /// publishes it into a provider AFTER an await. [lock] runs in that window as
  /// a matter of course: it is reachable from the tray and from the API, and the
  /// window is the WHOLE node boot, first-run mining included. A lock that
  /// landed inside it read the providers, found them empty (nothing was
  /// published yet), tore down nothing and returned — and then the boot it never
  /// saw finished and published a LIVE node and an OPEN container into a session
  /// the user had already ended, with the lock screen up in front of it. The
  /// phase even walked back to `ready`. That is a deniability failure, not an
  /// inconvenience: the machine stays on the network after a visible "locked".
  ///
  /// The guard that existed covered only two unlocks overlapping
  /// ([_unlockInFlight]); nothing here knew about lock at all.
  ///
  /// Every transition that ENDS a session ([lock], [startOver],
  /// [wipeContainers]) bumps this BEFORE it tears anything down. Everything that
  /// builds a live resource takes a snapshot before its awaits and, if the
  /// snapshot has gone stale by the time it holds the result, ROLLS BACK what it
  /// built instead of publishing it. There is no await between the check and the
  /// publish, so a lock either sees the published resource and tears it down, or
  /// is seen by the check — never neither.
  int _lifecycle = 0;

  /// Ends the current lifecycle: nothing built under the previous generation may
  /// be published any more. Called at the TOP of every teardown-to-locked path,
  /// before the first await, so an in-flight boot cannot slip past it.
  void _endLifecycle() => _lifecycle++;

  /// True when a session-ending transition happened since [gen] was taken.
  bool _supersededSince(int gen) => gen != _lifecycle;

  /// Test seam for the one dependency of [_ensureRealStack] a unit test cannot
  /// provide: the static [RealVeilStack.startDeniable], which boots a real
  /// in-process node. Substituting it is what makes the lock-during-boot window
  /// drivable at all — against the real boot the race is decided by a
  /// multi-second mine nothing in a test can hold open.
  ///
  /// Null in production, where the real boot runs with the composed config.
  ///
  /// Takes the [IdentitySeedPlan] the boot resolved for the identity being
  /// started — the answer read out of ITS space and the peer list built from it.
  /// Handed over rather than hidden behind the seam so a test can assert what a
  /// given identity's node would actually have been composed with; the seam used
  /// to swallow it, which is how a shared list reached every node unnoticed.
  @visibleForTesting
  Future<RealVeilStack> Function(IdentitySeedPlan plan)?
  debugDeniableStackStarter;

  /// Returning user: try to unlock the space with [password].
  Future<void> unlock(String password) async {
    if (_unlockInFlight) {
      devLog(() => 'xVeil[unlock]: ignored — an unlock is already in flight');
      return;
    }
    _unlockInFlight = true;
    try {
      await _unlockInner(password);
    } finally {
      _unlockInFlight = false;
    }
  }

  Future<void> _unlockInner(String password) async {
    final t0 = DateTime.now();
    // Taken before the first await: everything this unlock publishes is only
    // valid while the lifecycle it started in is still current.
    final gen = _lifecycle;
    int ms() => DateTime.now().difference(t0).inMilliseconds;
    devLog(() => 'xVeil[unlock]: begin (phase=${state.phase.name})');
    // Show the loading screen BEFORE the heavy work: opening the real container
    // runs Argon2 (and, in keep-all-online, boots every node) on this isolate,
    // which freezes the UI. Switch to the preparing screen and yield a frame so
    // the "opening your container" message paints before the freeze — otherwise
    // the unlock button just hangs with no feedback. Only on the real deniable
    // path (the loopback/test opener is instant, so it would just flash).
    if (ref.read(deniableBootProvider) != null) {
      state = state.copyWith(
        phase: AppPhase.preparingNode,
        preparingReason: PreparingReason.unlocking,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    final storage = ref.read(storageProvider);
    bool ok;
    try {
      ok = await storage.open(password: password);
      devLog(() => 'xVeil[unlock]: container open -> $ok (+${ms()}ms)');
    } catch (e) {
      // Missing or corrupt container, a Busy flock, an FFI/worker fault — never
      // let unlock throw (that would freeze the lock screen's spinner). Surface
      // as an error, but LOG THE REAL CAUSE: a swallowed detail here is exactly
      // how "container won't unlock with the correct password" stays
      // undiagnosable in the field. (A genuine wrong password is ok=false, not
      // a throw.)
      devLog(() => 'xVeil[unlock]: container open THREW (+${ms()}ms): $e');
      // Recorded, unlike a plain wrong password (that is ok=false, not a
      // throw): "the correct password does not open it" is the report worth
      // sending, a count of someone's typos is not.
      errorJournal.record(
        kind: 'unlock',
        error: e,
        atMs: DateTime.now().millisecondsSinceEpoch,
      );
      ok = false;
    }
    if (!ok) {
      // Back to the lock screen with the error (we're on preparingNode now).
      state = const AppState(AppPhase.locked, unlockError: true);
      return;
    }
    // The container just answered to this password, so this is the one moment
    // the screen lock can learn to recognise it. Only a recogniser is kept —
    // never the password, and never anything that reaches disk.
    ref.read(screenLockProvider.notifier).rememberPassword(password);
    // Master vs identity is decided AFTER unlock by inspecting contents (never
    // from disk — deniability). A roster ⇒ master: read it, then release the
    // exclusive lock (only one space open at a time) and let the user pick.
    //
    // Wrap the whole post-open classification so a throwing FFI op
    // (exportSpaceKeys, _enterSession's node-config read) can't leave the
    // unlock spinner frozen with the container half-open — bounce back to the
    // lock screen so the user retries cleanly.
    try {
      final roster = await storage.loadRoster();
      devLog(
        () =>
            'xVeil[unlock]: classified as '
            '${roster == null || roster.isEmpty ? 'single identity' : 'master (${roster.length} identities)'} '
            '(+${ms()}ms)',
      );
      if (roster != null && roster.isNotEmpty) {
        _setPendingRoster(roster);
        // Cache the master's keys so roster edits can reopen it without a
        // password re-prompt (held in memory like the child keys above).
        _setMasterKeys(await storage.exportSpaceKeys());
        await storage.close(); // release the single-space lock first
        // "All identities online" (the NORM since 2026-07-11): host every
        // space + run every node at once (needs the real container path).
        // Else the one-active picker. AWAIT the persisted value — the lazily
        // created provider's sync state can still be the default while the
        // prefs load is in flight, which must not override an explicit
        // one-active opt-out.
        final boot = ref.read(deniableBootProvider);
        final allOnline = await ref
            .read(keepAllOnlineProvider.notifier)
            .resolved();
        if (allOnline && boot?.storePath != null) {
          try {
            await _enterAllOnline(roster, boot!);
            return;
          } catch (e, st) {
            // All-online boot failed — never strand the user on a stuck
            // unlock. Tear down any half-built session and fall back to the
            // one-active picker (known-good). Surface WHY so we can fix it.
            devLog(() => 'xVeil[all-online]: boot FAILED -> picker: $e\n$st');
            await _teardownSession();
          }
        }
        if (_supersededSince(gen)) {
          // Locked while we were classifying. The picker is a SESSION screen —
          // putting it up now would walk the phase back off the lock screen.
          devLog(() => 'xVeil[unlock]: locked mid-unlock — not showing picker');
          return;
        }
        state = state.copyWith(
          phase: AppPhase.pickingIdentity,
          identities: [for (final e in roster) e.label],
        );
        return;
      }
      // Single identity space — unchanged path.
      await _maybeAutoCompactBeforeSession(password);
      final profile = await _loadProfileOrHalt(storage);
      if (profile == null) return; // damaged record — parked, nothing written
      await _enterSession(profile);
      devLog(
        () => 'xVeil[unlock]: done, phase=${state.phase.name} (+${ms()}ms)',
      );
    } catch (e, st) {
      devLog(
        () =>
            'xVeil[unlock]: post-open classification failed -> lock '
            '(+${ms()}ms): $e\n$st',
      );
      errorJournal.record(
        kind: 'unlock',
        error: e,
        stack: st,
        atMs: DateTime.now().millisecondsSinceEpoch,
      );
      try {
        await ref.read(storageProvider).close();
      } catch (_) {}
      state = const AppState(AppPhase.locked, unlockError: true);
    }
  }

  /// Current on-disk size of the deniable container in bytes, or null on the
  /// loopback/test path (no real container) — for the storage-maintenance UI.
  Future<int?> containerSizeBytes() async {
    final path = ref.read(deniableBootProvider)?.storePath;
    if (path == null) return null;
    try {
      return await File(path).length();
    } catch (_) {
      return null;
    }
  }

  /// Whether storage compaction is available: only for a SINGLE identity.
  /// `compact_known` keeps ONLY the space whose password is supplied and DROPS
  /// every other (decoy) space, so it must never run on a master/multi-identity
  /// container with just one password. `_masterKeys` is set only when a roster
  /// was found, so its absence means a lone space.
  bool get canCompactStorage =>
      _masterKeys == null && ref.read(deniableBootProvider)?.storePath != null;

  /// Compact the deniable container in place to reclaim dead padding (the
  /// log-structured store never shrinks on its own; only a repack does). The
  /// node + open store hold a `LOCK_EX`, so we tear the session down, compact
  /// off-isolate, then re-open via [unlock]. Reopened even on failure (the
  /// rewrite is atomic — the container is untouched on error), so the user is
  /// never stranded locked out. Returns the on-disk size before/after in bytes.
  Future<({int before, int after})> compactStorage(String password) async {
    if (!canCompactStorage) {
      throw StateError('compaction is single-identity only');
    }
    return _compactKeeping(
      passwords: [Uint8List.fromList(utf8.encode(password))],
      reopenWith: password,
    );
  }

  /// Compact a container that holds SEVERAL identities, keeping every one on
  /// the roster.
  ///
  /// `compact_known` keeps exactly the spaces whose passwords it is given and
  /// drops the rest, which is why [compactStorage] refuses to run with one
  /// password on a multi-identity container: it would be a deletion wearing the
  /// name of maintenance. Give it every password and the same call becomes
  /// safe — so the restriction was never about compaction, only about how many
  /// passwords the screen had collected.
  ///
  /// The roster deduplicates: an identity reachable through two masters is
  /// listed once, and one master password that opens several subordinates is
  /// passed once. [reopenWith] is the password this device unlocks with
  /// afterwards, which is the one the person is already using.
  Future<({int before, int after})> compactStorageKeeping({
    required CompactionRoster roster,
    required String reopenWith,
  }) async {
    if (roster.length == 0) {
      throw StateError(
        'compaction with an empty roster would delete every '
        'identity in the container',
      );
    }
    return _compactKeeping(
      passwords: [
        for (final bytes in roster.passwords()) Uint8List.fromList(bytes),
      ],
      reopenWith: reopenWith,
    );
  }

  /// Put the app into the state where passwords can be checked: session down,
  /// node stopped, container closed. Answers whether the container really let
  /// go of its lock.
  ///
  /// The screen that collects passwords cannot do this itself and must not try
  /// to work around it: a live session holds `LOCK_EX`, so every probe would
  /// answer "wrong password". One teardown, many probes, one compaction.
  ///
  /// Whoever calls this OWNS reopening. Cancel, an error, a closed dialog — all
  /// of them have to reach [cancelCompactionCollection], or the app sits torn
  /// down with no session and no explanation.
  Future<bool> beginCompactionCollection() async {
    state = state.copyWith(
      phase: AppPhase.preparingNode,
      preparingReason: PreparingReason.unlocking,
    );
    await _boundedTeardown('session teardown', _teardownSession);
    await _boundedTeardown('node teardown', _teardownRealStack);
    return _boundedTeardown(
      'store close',
      () => ref.read(storageProvider).close(),
    );
  }

  /// Undo [beginCompactionCollection] without compacting.
  ///
  /// The one path this exists for is the person changing their mind, which is
  /// the most likely outcome of a dialog that asks for several passwords. It
  /// must leave them exactly where they were.
  Future<void> cancelCompactionCollection(String reopenWith) =>
      unlock(reopenWith);

  /// What a password opens in this container — for the screen that collects
  /// them before a compaction.
  ///
  /// MUST be called with the store CLOSED. A live session holds the container
  /// under `LOCK_EX`, so this cannot verify a password while the app is running
  /// normally; the offer tears the session down once and probes inside that
  /// window. Called with the store open it answers `opened: false`, which reads
  /// as "wrong password" and would be a lie — so the caller owns the teardown
  /// and this says so rather than guessing.
  ///
  /// Returns what the container ACTUALLY knows. A node id is deliberately not
  /// among it: a space does not carry one (see [CompactionRoster]). What is
  /// here is what a person can recognise their identity by — the name it shows,
  /// and, for a master, the labels of everything that would come with it.
  Future<
    ({
      bool opened,
      bool isMaster,
      String? displayName,
      String? username,
      List<String> subordinates,
    })
  >
  probeCompactionIdentity(String password) async {
    const closed = (
      opened: false,
      isMaster: false,
      displayName: null,
      username: null,
      subordinates: <String>[],
    );
    final storage = ref.read(storageProvider);
    if (!await storage.open(password: password)) return closed;
    try {
      // A roster-bearing space is a master: unlocking it brings everything it
      // lists, which is the whole reason one password can cover several
      // identities.
      final roster = await storage.loadRoster();
      final profile = await storage.loadProfile();
      return (
        opened: true,
        isMaster: roster != null,
        displayName: profile?.displayName,
        username: profile?.username,
        subordinates: <String>[
          for (final e in roster ?? const <RosterEntry>[]) e.label,
        ],
      );
    } catch (_) {
      // A damaged record is not an identity we may claim to have found. Audit
      // XV-13: reading this as "not a master" once let a bind proceed on a
      // space nobody could read.
      return closed;
    } finally {
      await storage.close();
    }
  }

  Future<({int before, int after})> _compactKeeping({
    required List<Uint8List> passwords,
    required String reopenWith,
  }) async {
    final path = ref.read(deniableBootProvider)!.storePath!;
    final before = await File(path).length();
    state = state.copyWith(
      phase: AppPhase.preparingNode,
      preparingReason: PreparingReason.unlocking,
    );
    await _boundedTeardown('session teardown', _teardownSession);
    await _boundedTeardown('node teardown', _teardownRealStack);
    // release the LOCK_EX
    final released = await _boundedTeardown(
      'store close',
      () => ref.read(storageProvider).close(),
    );
    try {
      // `compact_known` opens the container under LOCK_EX and BLOCKS for it.
      // Starting it while our own handle is still open means waiting on a lock
      // only we could release — no progress, no CPU, no temp file, and a screen
      // that says "opening the store" until the app is killed. That is exactly
      // what a device reported. Refuse instead, and say why.
      if (!released) {
        throw StateError(
          'the container did not close in ${_teardownBudget.inSeconds}s, so '
          'compaction would wait forever on a lock we still hold',
        );
      }
      await hv.compactKnownAsync(path, passwords, dylibPath: _hvDylibPath());
    } finally {
      await unlock(reopenWith); // always reopen
    }
    final after = await File(path).length();
    // Remember the post-compaction size: the auto-compact trigger compares the
    // current size against it (bloat = mostly-dead padding grows the file a
    // multiple past the last-known-live size). Best-effort.
    try {
      await ref.read(storageProvider).putSetting(_lastCompactSizeKey, '$after');
    } catch (_) {}
    return (before: before, after: after);
  }

  /// How long any single teardown step gets before compaction stops waiting on
  /// it. Generous: these are real shutdowns, not formalities.
  static const Duration _teardownBudget = Duration(seconds: 15);

  /// Run a teardown step under a deadline; report whether it FINISHED.
  ///
  /// Every step here waits on something that can stop answering — messaging
  /// teardown quiesces its lanes and flushes the ratchet over IPC, the node
  /// stop crosses FFI, the store close waits on its worker. None of them had a
  /// bound, so one wedged step held the whole chain, and the caller with it.
  /// The result is reported rather than swallowed because for the store close
  /// it decides whether compaction may start at all.
  Future<bool> _boundedTeardown(
    String what,
    Future<void> Function() step,
  ) async {
    try {
      await step().timeout(_teardownBudget);
      return true;
    } on TimeoutException {
      devLog(
        () =>
            'xVeil[compact]: $what did not finish in '
            '${_teardownBudget.inSeconds}s — abandoned',
      );
      return false;
    } catch (e) {
      devLog(() => 'xVeil[compact]: $what failed: $e');
      return false;
    }
  }

  /// What the storage-maintenance UI needs in order to tell the user whether
  /// compacting is worth doing — the container's size, how much of it is dead
  /// padding, and whether that is enough to be worth mentioning unprompted.
  ///
  /// Null when there is nothing honest to say: no real container, compaction
  /// unavailable (multi-identity — see [canCompactStorage]), or a backing that
  /// cannot report slot occupancy. The UI must then show the size alone, NOT a
  /// reclaimable figure of zero.
  Future<StorageReclaim?> storageReclaim() async {
    // Same gate as the compact button: on a multi-identity container the ratio
    // both understates (sibling spaces' chunks are not "owned" by this one)
    // and describes something the user cannot act on anyway.
    if (!canCompactStorage) return null;
    final size = await containerSizeBytes();
    if (size == null) return null;
    final SlotUtilization? utilization;
    try {
      utilization = await ref.read(storageProvider).containerUtilization();
    } catch (_) {
      return null;
    }
    if (utilization == null) return null;
    return estimateStorageReclaim(
      sizeBytes: size,
      utilization: utilization,
      autoCompactEnabled: await autoCompactEnabled(),
    );
  }

  /// The container's kept hardening warning, or null when there is none.
  ///
  /// Reading it is also what KEEPS it: the container forgets at close, so the
  /// first read of a fresh record is what writes the durable copy. See
  /// `Storage.retainHardeningWarning`.
  Future<String?> containerHardeningWarning() async {
    try {
      return await ref.read(storageProvider).retainHardeningWarning();
    } catch (_) {
      // A readout, not a gate: a store that will not answer must not take the
      // settings screen down with it.
      return null;
    }
  }

  /// "I have shown this to the person" — clears both copies, or neither.
  ///
  /// Returns null on success and the failure text otherwise. It used to
  /// swallow everything, which turned a refused acknowledgement into a silent
  /// one: the caller believed the warning was dismissed and hid it, while the
  /// container still held the record nobody had accepted.
  Future<String?> acknowledgeHardeningWarning() async {
    try {
      await ref.read(storageProvider).acknowledgeHardeningWarning();
      return null;
    } catch (e) {
      return '$e';
    }
  }

  /// Turn a size + slot occupancy into the maintenance readout, and decide
  /// whether it deserves an unprompted nudge.
  ///
  /// Pure and static so the decision is testable on its own and there is ONE
  /// place that makes it — the screen renders [StorageReclaim.worthCompacting],
  /// it does not re-derive the rule from thresholds of its own.
  ///
  /// The thresholds are the ones auto-compaction ALREADY uses, deliberately:
  ///  * [_autoCompactMinBytes] — below it the padding is noise either way;
  ///  * [_autoCompactGrowthFactor] — auto-compaction fires once the file has
  ///    grown to N× its post-compaction (i.e. live) size, and a file that is
  ///    N× its live data is `1 - 1/N` dead. Measuring the dead share directly
  ///    is strictly better than comparing against a remembered size, and it
  ///    needs no bookkeeping to survive.
  ///
  /// [autoCompactEnabled] SUPPRESSES the nudge: with the opt-in on, the next
  /// unlock compacts by itself and there is nothing to ask the user for. The
  /// nudge exists for the default configuration — auto-compaction off, one
  /// identity, nobody watching the file grow.
  static StorageReclaim estimateStorageReclaim({
    required int sizeBytes,
    required SlotUtilization utilization,
    required bool autoCompactEnabled,
  }) {
    final dead = utilization.deadFraction;
    final reclaimable = (sizeBytes * dead).floor();
    final deadEnough = dead >= 1.0 - (1.0 / _autoCompactGrowthFactor);
    return StorageReclaim(
      sizeBytes: sizeBytes,
      reclaimableBytes: reclaimable < 0 ? 0 : reclaimable,
      deadFraction: dead,
      worthCompacting:
          !autoCompactEnabled &&
          sizeBytes >= _autoCompactMinBytes &&
          deadEnough,
    );
  }

  static const String _autoCompactKey = 'storage.autocompact.v1';
  static const String _lastCompactSizeKey = 'storage.lastcompactsize.v1';

  /// Auto-compaction floor: below this on-disk size the padding overhead is
  /// noise — never worth an unlock-time repack.
  static const int _autoCompactMinBytes = 16 << 20;

  /// Trigger factor: compact when the container has grown this many times past
  /// the size it had right after the previous compaction (dead padding
  /// dominates long before 3× in practice — live data per commit is ≤ a few KB
  /// while every commit pads to a full 256 KiB bucket).
  static const int _autoCompactGrowthFactor = 3;

  bool _autoCompactRunning = false;

  /// Whether unlock-time auto-compaction is enabled (opt-in, default OFF).
  ///
  /// OFF by default DELIBERATELY: `compact_known` keeps only the spaces whose
  /// passwords are supplied, and a sibling deniable space added by password
  /// (no roster — [canCompactStorage] cannot see it BY DESIGN) would be
  /// silently destroyed. Enabling this is the user's attestation that no other
  /// hidden identity lives in this container — same contract as the manual
  /// compact button, made durable.
  Future<bool> autoCompactEnabled() async {
    try {
      return await ref.read(storageProvider).getSetting(_autoCompactKey) == '1';
    } catch (_) {
      return false;
    }
  }

  Future<void> setAutoCompactEnabled(bool enabled) async {
    await ref
        .read(storageProvider)
        .putSetting(_autoCompactKey, enabled ? '1' : '0');
  }

  // ── The compaction OFFER: when to interrupt, and how much is worth it ──────
  //
  // Distinct from auto-compaction above. Auto-compaction acts without asking
  // and therefore may only run where nothing can be lost; the offer asks, so it
  // can be the default. Its two knobs and its "don't ask again yet" mark live
  // in the container beside everything else the identity owns.

  static const String _offerEnabledKey = 'storage.compact.offer.enabled.v1';
  static const String _offerPeriodDaysKey = 'storage.compact.offer.days.v1';
  static const String _offerThresholdKey = 'storage.compact.offer.bytes.v1';
  static const String _offerLastShownKey = 'storage.compact.offer.shown.v1';

  /// The person's two knobs, with the defaults they asked for: every 3 days,
  /// and only when a gigabyte or more would come back.
  Future<CompactionOfferSettings> compactionOfferSettings() async {
    try {
      final storage = ref.read(storageProvider);
      final enabled = await storage.getSetting(_offerEnabledKey);
      final days = int.tryParse(
        await storage.getSetting(_offerPeriodDaysKey) ?? '',
      );
      final bytes = int.tryParse(
        await storage.getSetting(_offerThresholdKey) ?? '',
      );
      return CompactionOfferSettings(
        // Absent means default-on: the offer exists for the person who never
        // opens these settings at all.
        enabled: enabled != '0',
        period: days != null && days > 0
            ? Duration(days: days)
            : CompactionOfferSettings.defaultPeriod,
        thresholdBytes: bytes != null && bytes > 0
            ? bytes
            : CompactionOfferSettings.defaultThresholdBytes,
      );
    } catch (_) {
      // Store not open yet — the defaults are the honest answer, not silence.
      return const CompactionOfferSettings();
    }
  }

  Future<void> setCompactionOfferSettings(
    CompactionOfferSettings settings,
  ) async {
    final storage = ref.read(storageProvider);
    await storage.putSetting(_offerEnabledKey, settings.enabled ? '1' : '0');
    await storage.putSetting(
      _offerPeriodDaysKey,
      '${settings.period.inDays < 1 ? 1 : settings.period.inDays}',
    );
    await storage.putSetting(_offerThresholdKey, '${settings.thresholdBytes}');
  }

  /// Remember that the offer was SHOWN — not that compaction ran.
  ///
  /// Declining is an answer. Timing the next offer from the moment of asking is
  /// what makes the period mean "don't pester me", which is what it is for.
  Future<void> noteCompactionOffered({DateTime? at}) async {
    try {
      await ref
          .read(storageProvider)
          .putSetting(
            _offerLastShownKey,
            '${(at ?? DateTime.now()).millisecondsSinceEpoch}',
          );
    } catch (_) {
      /* an unrecorded offer asks again sooner; it never asks less */
    }
  }

  /// Whether to offer compaction now, and the figures the offer may quote.
  ///
  /// Unlike [storageReclaim], this does NOT go silent on a container holding
  /// several identities. Silence was right for the old readout — it could only
  /// overstate there, and the button it belonged to was unavailable anyway —
  /// but the offer exists precisely to gather every identity's password, so
  /// refusing to speak until there is only one would refuse the case it is for.
  ///
  /// The honesty lives in the estimate instead: it carries how many identities
  /// it counted against how many the container is known to hold, and answers
  /// `isExact` only when they match. A screen may quote a number when it has
  /// one and say "at least" when it does not.
  ///
  /// Live bytes come from the slot RATIO rather than a chunk count, so nothing
  /// here has to know the container's chunk size — a constant that lives in
  /// Rust and would drift the day it changed.
  Future<({CompactionOfferVerdict verdict, CompactionEstimate estimate})?>
  compactionOffer({DateTime? now}) async {
    final size = await containerSizeBytes();
    if (size == null) return null;
    final SlotUtilization? utilization;
    try {
      utilization = await ref.read(storageProvider).containerUtilization();
    } catch (_) {
      return null;
    }
    if (utilization == null) return null;
    final estimate = CompactionEstimate(
      fileBytes: size,
      liveBytes: (size * utilization.liveFraction).round(),
      identitiesCounted: 1,
      // A lone space is one identity and we have just counted it. Under a
      // master the roster says how many there are; without it the count is
      // unknown, which `isExact` reports as "not exact" rather than guessing.
      identitiesKnown: _masterKeys == null ? 1 : (_pendingRoster?.length ?? 0),
    );
    return (
      verdict: compactionOfferVerdict(
        estimate: estimate,
        settings: await compactionOfferSettings(),
        now: now ?? DateTime.now(),
        lastOfferedAt: await lastCompactionOfferAt(),
      ),
      estimate: estimate,
    );
  }

  Future<DateTime?> lastCompactionOfferAt() async {
    try {
      final raw = await ref
          .read(storageProvider)
          .getSetting(_offerLastShownKey);
      final ms = int.tryParse(raw ?? '');
      return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
    } catch (_) {
      return null;
    }
  }

  Future<bool> leanStoragePaddingEnabled() async {
    try {
      final prefs = await ref.read(prefsProvider.future);
      return prefs.getBool(kStorageLeanPaddingPref) ??
          kStorageLeanPaddingDefault;
    } catch (_) {
      return kStorageLeanPaddingDefault;
    }
  }

  Future<void> setLeanStoragePaddingEnabled(bool enabled) async {
    final prefs = await ref.read(prefsProvider.future);
    await prefs.setBool(kStorageLeanPaddingPref, enabled);
  }

  /// Same trigger as [_maybeAutoCompact], but it runs before booting the node.
  /// This matters for badly bloated containers: boot reads node/messaging state
  /// and can spend minutes in [AppPhase.preparingNode], so a post-ready compact
  /// never gets a chance to fire. Only runs for single-identity spaces with the
  /// existing opt-in setting enabled.
  Future<void> _maybeAutoCompactBeforeSession(String password) async {
    if (_autoCompactRunning || !canCompactStorage) return;
    final storage = ref.read(storageProvider);
    final path = ref.read(deniableBootProvider)?.storePath;
    if (path == null) return;
    try {
      if (!await autoCompactEnabled()) return;
      final size = await File(path).length();
      if (size < _autoCompactMinBytes) return;
      final lastRaw = await storage.getSetting(_lastCompactSizeKey);
      final last = int.tryParse(lastRaw ?? '') ?? 0;
      if (last > 0 && size < last * _autoCompactGrowthFactor) return;
      _autoCompactRunning = true;
      devLog(
        () =>
            'xVeil[storage]: pre-session auto-compact triggered '
            '(size=$size, lastCompacted=$last)',
      );
      await storage.close(); // release LOCK_EX before compact_known.
      await hv.compactKnownAsync(path, [
        Uint8List.fromList(utf8.encode(password)),
      ], dylibPath: _hvDylibPath());
      final reopened = await storage.open(password: password);
      if (!reopened) {
        throw StateError('container did not reopen after compaction');
      }
      final after = await File(path).length();
      await storage.putSetting(_lastCompactSizeKey, '$after');
      devLog(
        () => 'xVeil[storage]: pre-session auto-compact done $size -> $after',
      );
    } catch (e) {
      devLog(() => 'xVeil[storage]: pre-session auto-compact failed: $e');
      if (!storage.isOpen) {
        try {
          await storage.open(password: password);
        } catch (_) {}
      }
    } finally {
      _autoCompactRunning = false;
    }
  }

  /// Path the compaction worker isolate dlopens the hidden-volume native lib
  /// from (a fresh isolate doesn't inherit the main isolate's loaded image). By
  /// soname on Android; the first existing bundle candidate on desktop.
  String? _hvDylibPath() {
    if (Platform.isAndroid) return nativeLibFileName('hidden_volume_ffi');
    for (final p in nativeLibCandidates('hidden_volume_ffi')) {
      if (File(p).existsSync()) return p;
    }
    return null;
  }

  /// All-online mode: open the container as one multi-space, boot every
  /// identity's node + messaging pipeline at once, and show the first identity.
  /// Switching later just re-points the view — no node goes offline.
  Future<void> _enterAllOnline(
    List<RosterEntry> roster,
    DeniableBootConfig boot,
  ) async {
    // Taken before the first await — see [_lifecycle].
    final gen = _lifecycle;
    // Still part of the unlock from the user's view (opening + booting all).
    state = state.copyWith(
      phase: AppPhase.preparingNode,
      preparingReason: PreparingReason.unlocking,
    );
    final leanPadding = await leanStoragePaddingEnabled();
    final session = ref.read(sessionBuilderProvider)(
      storePath: boot.storePath!,
      runtimeDir: boot.runtimeDir,
      listenPort: boot.listenPort,
      // A BUILDER, not the finished list. Each identity in the session resolves
      // its own answer from its own space and gets its own list built from it;
      // handing one list down was what made two identities in one container
      // unable to disagree.
      peersFor: boot.peersFor,
      // Boot every always-online node with the SAME network/routing config the
      // single-identity path uses — otherwise these nodes start with no obfs4
      // PSK (cannot join the production network), no lazy-mining setting, and no
      // traffic routing.
      obfs4Psk: boot.obfs4Psk,
      udpReflectors: boot.udpReflectors,
      lazyMining: _singleLazyMining,
      proxy: ref.read(effectiveProxyRoutingProvider),
      paddingPreset: leanPadding
          ? hv.PaddingPreset.none
          : hv.PaddingPreset.bucket256KiB,
    );
    // The session OWNS every node it boots and the container's shared lock, and
    // nothing else can reach it until it is published. So everything between
    // "constructed" and "published" has to hand it back on failure (audit
    // XV-06): a throw in `bootAll` or in the foreground-service call used to
    // leave booted nodes running and the lock held, with the only reference to
    // them going out of scope — unreachable for cleanup, and the next unlock
    // then failed on the lock it could no longer release.
    try {
      await session.bootAll(roster);
      await ref
          .read(backgroundNodeProvider.notifier)
          .applyIfNodeUp(nodeUp: true);
    } catch (_) {
      // Best-effort: a teardown failure must not mask the original error, and
      // the original is what the caller needs to see.
      try {
        await session.disposeAll();
      } catch (_) {}
      rethrow;
    }
    // ...and only once it is still WANTED. A lock during `bootAll` — the window
    // is every identity's node coming up — read an empty [sessionProvider],
    // found nothing to dispose and returned; publishing here would then hand a
    // locked app a session with every node running and the container's shared
    // lock held, unreachable for cleanup until the process dies (audit H-06).
    if (_supersededSince(gen)) {
      devLog(
        () =>
            'xVeil[all-online]: locked while booting — disposing the session '
            'instead of publishing it',
      );
      try {
        await session.disposeAll();
      } catch (e) {
        devLog(() => 'xVeil[all-online]: rollback disposeAll failed: $e');
      }
      return;
    }
    // Published only once it is whole. From here `disposeAll` is reachable
    // through the provider, so lock/teardown can find it.
    ref.read(sessionProvider.notifier).state = session;
    final first = roster.first.label;
    await _activateOnline(first, [for (final e in roster) e.label]);
  }

  /// Point the providers (active storage/messaging via [activeIdentityProvider],
  /// transport/invite via [realStackProvider]) at a hosted identity and surface
  /// it. Used on entry and on every all-online switch — no teardown.
  /// Drop every posted alert and everything that attributes one.
  ///
  /// A notification outlives the session that posted it: the OS shade is
  /// shared, the alert stays until somebody dismisses it, and its inline reply
  /// is live the whole time. Lock has cleared the shade all along; a SWITCH
  /// did not, so alerts posted by the identity being left behind stayed on
  /// screen — and the owner map that decides who may reply to them survived
  /// too, in a class whose `clear` production never called
  /// (report17 XV17-M12).
  ///
  /// The order is deliberate: cancel the alerts FIRST, then drop what resolves
  /// them. A token dropped while its alert is still on screen makes that alert
  /// unroutable rather than absent.
  Future<void> _dropPostedNotifications() async {
    try {
      await ref.read(notificationServiceProvider).cancelAll();
    } catch (_) {
      // A notification backend that is not up cannot be holding anything.
    }
    ref.read(opaqueNotificationPayloadsProvider).clear();
    ref.read(notificationOwnersProvider).clear();
  }

  Future<void> _activateOnline(String label, List<String> identities) async {
    // BEFORE the view is re-pointed: from here on, this identity is the one a
    // reply would be sent from, and no alert from the one being left behind
    // may still be on screen offering to send it.
    await _dropPostedNotifications();
    final gen = _lifecycle;
    final session = ref.read(sessionProvider)!;
    _activeLabel = label;
    ref.read(activeIdentityProvider.notifier).state = label;
    final stack = session.stackFor(label);
    ref.read(realStackProvider.notifier).state = stack;
    // Follow the identity being shown. Its node was booted with ITS answer; a
    // screen still rendering the previously active identity's would report the
    // wrong posture for this one and write over it if touched.
    final seedsAnswer = session.usesBundledSeeds(label);
    if (seedsAnswer != null &&
        ref.read(bundledSeedsChoiceProvider) != seedsAnswer) {
      ref.read(bundledSeedsChoiceProvider.notifier).state = seedsAnswer;
    }
    final st = session.storageFor(label);
    // Same damaged-vs-absent split as the one-active path (audit XV-13), with
    // one honest difference: all-online has ALREADY booted every node by the
    // time we get here, so — unlike [_loadProfileOrHalt] on unlock — this
    // cannot promise the space was never written to. It promises the smaller
    // thing that still matters: no session opens on top of a damaged record.
    final UserProfile? loaded;
    try {
      loaded = st != null ? await st.loadProfile() : null;
    } on CorruptIdentityRecord catch (e, stk) {
      await _haltOnDamagedIdentity(e, stk);
      return;
    }
    final profile = loaded ?? _profileOfSpaceWithNoRecord();
    final nodeId = stack != null
        ? stack.myInvite.nodeId
        : await ref.read(veilTransportProvider).nodeId();
    if (_supersededSince(gen)) {
      // Locked while the profile / node id was being read. `ready` here would
      // put the messenger back over a lock screen the user just raised.
      devLog(() => 'xVeil[all-online]: locked mid-activate — staying locked');
      return;
    }
    state = AppState(
      AppPhase.ready,
      identity: Identity(
        nodeId: nodeId,
        displayName: profile.displayName,
        username: profile.username,
      ),
      identities: identities,
      activeIdentity: label,
    );
  }

  /// Master mode: open the chosen identity (by its stored keys) and enter its
  /// session. The active identity is the single open space; switching later is
  /// close-this-then-open-next (the exclusive lock allows only one at a time).
  Future<void> pickIdentity(String label) async {
    RosterEntry? entry;
    for (final e in _pendingRoster ?? const <RosterEntry>[]) {
      if (e.label == label) {
        entry = e;
        break;
      }
    }
    if (entry == null) return;
    final storage = ref.read(storageProvider);
    if (!await storage.openWithKeys(entry.spaceKeys)) {
      // The child keys no longer open a space — bounce back to locked.
      errorJournal.record(
        kind: 'identity',
        error: 'stored keys no longer open this space',
        atMs: DateTime.now().millisecondsSinceEpoch,
      );
      state = const AppState(AppPhase.locked, unlockError: true);
      return;
    }
    _activeLabel = label;
    final profile = await _loadProfileOrHalt(storage);
    if (profile == null) return; // damaged record — parked, nothing written
    await _enterSession(profile);
  }

  /// Switch to another identity in the same master session: stop the current
  /// node, close the active space (the exclusive lock allows only one open at a
  /// time), open the chosen child by its cached keys, and boot its node. No
  /// password — the roster is already in memory from unlock. No-op outside a
  /// master session or when already active.
  Future<void> switchIdentity(String label) async {
    // All-online: every node is already up — just re-point the view, no
    // teardown/reboot. Fast switch.
    final session = ref.read(sessionProvider);
    if (session != null) {
      if (label == _activeLabel || session.storageFor(label) == null) return;
      await _activateOnline(label, state.identities);
      return;
    }
    if (_pendingRoster == null || label == _activeLabel) return;
    RosterEntry? entry;
    for (final e in _pendingRoster!) {
      if (e.label == label) {
        entry = e;
        break;
      }
    }
    if (entry == null) return;
    // Same barrier as the all-online path above, for the same reason: the
    // identity that posted the alerts on screen is about to go away.
    await _dropPostedNotifications();
    // Timestamped phases (like _unlockInner/lock): a switch that takes seconds
    // names the step that stalled — teardown, lock release, space open, or the
    // node boot inside _enterSession (whose own laps are in veil_stack).
    final sw = Stopwatch()..start();
    int lap0 = 0;
    int lap() {
      final t = sw.elapsedMilliseconds;
      final d = t - lap0;
      lap0 = t;
      return d;
    }

    await _teardownRealStack(); // stop the current identity's node
    final tTeardown = lap();
    await ref.read(storageProvider).close(); // release the lock
    final tClose = lap();
    state = state.copyWith(phase: AppPhase.preparingNode);
    try {
      final storage = ref.read(storageProvider);
      if (!await storage.openWithKeys(entry.spaceKeys)) {
        errorJournal.record(
          kind: 'identity',
          error: 'stored keys no longer open this space',
          atMs: DateTime.now().millisecondsSinceEpoch,
        );
        state = const AppState(AppPhase.locked, unlockError: true);
        return;
      }
      final tOpen = lap();
      _activeLabel = label;
      final profile = await _loadProfileOrHalt(storage);
      if (profile == null) return; // damaged record — parked, nothing written
      await _enterSession(profile);
      devLog(
        () =>
            'xVeil[identity]: switch done in ${sw.elapsedMilliseconds}ms '
            '(teardown ${tTeardown}ms, close ${tClose}ms, open ${tOpen}ms, '
            'session ${lap()}ms)',
      );
    } catch (e) {
      // A throw here (FFI fault on close/open, corrupt identity blob) after the
      // session was torn down would leave the UI wedged on the preparing
      // screen. Bounce to the lock screen so the user re-unlocks into a clean
      // session instead of a half-torn-down dead end.
      devLog(() => 'xVeil[identity]: switchIdentity failed -> lock: $e');
      errorJournal.record(
        kind: 'identity',
        error: e,
        atMs: DateTime.now().millisecondsSinceEpoch,
      );
      try {
        await ref.read(storageProvider).close();
      } catch (_) {}
      state = const AppState(AppPhase.locked, unlockError: true);
    }
  }

  /// The identity currently active in a master session, or null in single mode.
  String? get activeIdentity => _activeLabel;

  /// Whether the active identity is configured for anonymous (onion) routing.
  /// False in single-identity mode (no roster) and for non-anonymous children.
  bool _activeAnonymous() {
    // A SINGLE identity follows its persisted [_singleAnonymous] preference
    // (default OFF: direct routing, no onion overhead). Turning it on boots the
    // node over the onion rendezvous (receive_anonymous + onion_service) so it
    // can RECEIVE an onion introduce and is reachable by node_id without
    // revealing its location — paired with anonymous sends for live,
    // NAT-traversing delivery instead of the 30s mailbox poll. In MASTER mode
    // each identity's own roster `anonymous` flag governs instead.
    final label = _activeLabel;
    if (label == null || _pendingRoster == null) return _singleAnonymous;
    for (final e in _pendingRoster!) {
      if (e.label == label) return e.anonymous;
    }
    return _singleAnonymous;
  }

  /// Whether the CURRENTLY ACTIVE identity routes anonymously (onion) — for the
  /// home-screen indicator. Reflects the debug force-flag too. Read at rebuild
  /// after watching [AppState.activeIdentity] (which changes on identity switch).
  bool get activeIsAnonymous => _activeAnonymous();

  /// Whether [label]'s identity is currently set to route anonymously (onion).
  bool isIdentityAnonymous(String label) {
    for (final e in _pendingRoster ?? const <RosterEntry>[]) {
      if (e.label == label) return e.anonymous;
    }
    return false;
  }

  /// Whether the current SINGLE (non-master) identity routes anonymously — for
  /// the single-mode settings toggle. Meaningless in master mode (use the
  /// per-identity [isIdentityAnonymous] there).
  bool get singleIdentityAnonymous => _singleAnonymous;

  /// Tell the UI these flags moved. They live on the notifier rather than in
  /// [AppState] — and the toggle reboots the node WITHOUT changing the watched
  /// fields (phase returns to `ready`, the active label is the same), so a
  /// screen that only watches [AppState] keeps drawing the pre-toggle value.
  /// Call after EVERY change to the roster's `anonymous` or [_singleAnonymous].
  void _bumpAnonymityRevision() {
    ref.read(anonymityRevisionProvider.notifier).state++;
  }

  /// Toggle anonymity for a SINGLE (non-master) identity: persist the preference
  /// into the open space and reboot the node under it (anonymity is fixed at
  /// boot). No-op in master mode (that path is [setIdentityAnonymous]) or when
  /// the space isn't open. Returns false on those guards.
  Future<bool> setSingleIdentityAnonymous(bool anonymous) async {
    if (_pendingRoster != null) return false; // master mode has its own path
    final storage = ref.read(storageProvider);
    if (!storage.isOpen) return false;
    if (_singleAnonymous == anonymous) return true;

    await storage.putSetting(_kAnonymousSetting, anonymous ? 'true' : 'false');
    _singleAnonymous = anonymous;
    _bumpAnonymityRevision();

    // Reboot the node so the new routing takes effect. The space stays open
    // (teardown only stops the node); _enterSession re-reads the setting and
    // boots with the new anonymity, then refreshes the home state + node id.
    await _teardownRealStack();
    final profile = await _loadProfileOrHalt(storage);
    if (profile == null) return false; // damaged record — parked
    await _enterSession(profile);
    return true;
  }

  /// Persist traffic-routing changes and reboot the currently hosted node(s),
  /// so a quick proxy toggle takes effect now rather than at the next app run.
  /// All-online mode rebuilds the whole hosted session because every identity
  /// shares this device-level routing policy; one-active mode only restarts the
  /// active node and keeps the already-open deniable space intact.
  Future<bool> applyProxyRouting(ProxyRouting routing) async {
    await ref.read(proxyRoutingProvider.notifier).set(routing);
    return reapplyProxyRouting();
  }

  /// Reboot the hosted node(s) with the current effective routing config
  /// without changing the user's persisted manual-SOCKS preference. The VPN
  /// controller uses this when it acquires/releases its internal SOCKS
  /// transport.
  Future<bool> reapplyProxyRouting() => rebootHostedNodes();

  /// Reboot the hosted node(s) so a setting that is armed AT NODE BOOT takes
  /// effect NOW rather than at the next app start.
  ///
  /// The one mechanism, and deliberately so: anonymity
  /// ([setSingleIdentityAnonymous]), lazy mining ([setSingleLazyMining]) and
  /// traffic routing ([reapplyProxyRouting]) are all boot-time facts, and each
  /// used to spell out the same three steps — stop the node, re-read the
  /// profile, enter the session again — which is three places for the
  /// all-online branch to be forgotten in. Callers persist their setting FIRST;
  /// the boot that follows re-reads the store, so what is written is what the
  /// new node is composed from.
  ///
  /// Both session shapes:
  ///
  ///   * ALL-ONLINE rebuilds the whole session, because a hosted identity's
  ///     node cannot be restarted alone; every identity re-reads its own space
  ///     on the way back up ([planIdentitySeeds]), so a per-identity setting
  ///     still lands on the identity that owns it;
  ///   * ONE-ACTIVE restarts just the active node and keeps the already-open
  ///     deniable space intact — no password, no re-unlock.
  ///
  /// `true` when there is a live node again (or there was never one to reboot:
  /// no embedded boot configured, or no session yet — nothing was promised and
  /// nothing was broken). `false` says the node did NOT come back, which is the
  /// caller's cue to say so rather than report a change that did not land.
  ///
  /// Every live session this identity holds goes down with the node. That is
  /// why this is not wired to a plain settings switch — see [SharedSeedsSwitch]
  /// — and why the callers that do use it either have nothing live to lose or
  /// are changing the very thing the connections run over.
  Future<bool> rebootHostedNodes() async {
    if (state.phase != AppPhase.ready ||
        ref.read(deniableBootProvider) == null) {
      return true;
    }

    final roster = _pendingRoster;
    final active = _activeLabel;
    final hadSession = ref.read(sessionProvider) != null;
    try {
      if (hadSession && roster != null) {
        state = state.copyWith(
          phase: AppPhase.preparingNode,
          preparingReason: PreparingReason.node,
        );
        await _teardownSession();
        await _reEnterAfterRosterEdit(roster, active, true);
        return state.phase == AppPhase.ready;
      }

      await _teardownRealStack();
      final storage = ref.read(storageProvider);
      if (!storage.isOpen) return false;
      final profile = await _loadProfileOrHalt(storage);
      if (profile == null) return false; // damaged record — parked
      await _enterSession(profile);
      return true;
    } catch (e, st) {
      devLog(() => 'xVeil[reboot]: hosted node reboot failed: $e\n$st');
      return false;
    }
  }

  /// Whether the ACTIVE single identity is opted into lazy mining (UI reads this
  /// for the settings toggle). Always false in master mode (no roster field).
  bool get activeLazyMining => _singleLazyMining;

  /// Toggle lazy mining for a SINGLE (non-master) identity: persist the
  /// preference into the open space and reboot the node under it (lazy mining is
  /// fixed at boot, like anonymity). No-op in master mode or when the space isn't
  /// open. Returns false on those guards. Default OFF — enabling it raises the
  /// identity's anti-sybil difficulty at the cost of a CPU-heavy background grind.
  Future<bool> setSingleLazyMining(bool enabled) async {
    if (_pendingRoster != null) return false; // master mode unsupported for now
    final storage = ref.read(storageProvider);
    if (!storage.isOpen) return false;
    if (_singleLazyMining == enabled) return true;

    await storage.putSetting(_kLazyMiningSetting, enabled ? 'true' : 'false');
    _singleLazyMining = enabled;

    // Reboot so the [Identity].lazy_mining change takes effect (_enterSession
    // re-reads the setting and composes the boot config with it).
    await _teardownRealStack();
    final profile = await _loadProfileOrHalt(storage);
    if (profile == null) return false; // damaged record — parked
    await _enterSession(profile);
    return true;
  }

  /// Toggle whether [label]'s identity routes anonymously (onion). Master-mode
  /// only. Persists the change into the master roster (reopened by its cached
  /// keys — no password re-prompt) and updates the in-memory roster. Anonymity
  /// is armed at NODE BOOT, so the change takes effect the next time that
  /// identity's node starts: if it is the ACTIVE identity, we reboot it now
  /// (one-active) or re-point it (all-online) so it applies immediately; an
  /// inactive identity picks it up on its next boot. Returns false outside a
  /// master session or if the master could not be reopened.
  Future<bool> setIdentityAnonymous(String label, bool anonymous) async {
    final roster = _pendingRoster;
    final masterKeys = _masterKeys;
    if (roster == null || masterKeys == null) return false;
    if (!roster.any((e) => e.label == label)) return false;
    // No-op if already in the requested state.
    if (isIdentityAnonymous(label) == anonymous) return true;

    final prevActive = _activeLabel;
    final hadSession = ref.read(sessionProvider) != null;

    // Release any live session/node so we can open the master directly.
    await _teardownSession();
    await _teardownRealStack();
    await ref.read(storageProvider).close();

    try {
      final storage = ref.read(storageProvider);
      if (!await storage.openWithKeys(masterKeys)) {
        await _recoverToActive();
        return false;
      }
      // Edit the master's ON-DISK roster (source of truth), then mirror it.
      final onDisk = await storage.loadRoster() ?? roster;
      final updated = [
        for (final e in onDisk)
          if (e.label == label)
            RosterEntry(
              label: e.label,
              spaceKeys: e.spaceKeys,
              anonymous: anonymous,
            )
          else
            e,
      ];
      await storage.saveRoster(updated);
      await storage.close();
      _setPendingRoster(updated);
      _bumpAnonymityRevision();

      // Re-enter so the change takes effect (a node's anonymity is fixed at
      // its boot, so editing the roster requires the node to re-boot under it).
      await _reEnterAfterRosterEdit(updated, prevActive, hadSession);
      return true;
    } catch (e) {
      // A throwing FFI op (loadRoster on a corrupt blob, saveRoster HvException)
      // after teardown must not strand the app session-less: recover to the
      // active identity (picker) or the lock screen.
      devLog(
        () => 'xVeil[identity]: setIdentityAnonymous failed -> recover: $e',
      );
      await _recoverToActive();
      return false;
    }
  }

  /// Re-enter a master session after editing its roster (anonymity toggle,
  /// bind, unbind, delete). [updated] is the new roster; [target] is the label
  /// to return to — if it is null or no longer in [updated] (e.g. the active
  /// identity was just removed), fall back to the picker (one-active) or the
  /// first identity (all-online). Shared so every roster-edit re-enters
  /// identically. Caller must already have torn the session/stack down + saved.
  Future<void> _reEnterAfterRosterEdit(
    List<RosterEntry> updated,
    String? target,
    bool hadSession,
  ) async {
    final valid = target != null && updated.any((e) => e.label == target);
    if (hadSession) {
      // All-online: rebuild the whole session (every node re-boots), then
      // restore the view to [target] if it still exists (else the first).
      final boot = ref.read(deniableBootProvider);
      if (boot?.storePath != null) {
        try {
          await _enterAllOnline(updated, boot!);
          if (valid) await switchIdentity(target);
          return;
        } catch (e, st) {
          devLog(
            () =>
                'xVeil[roster]: all-online re-enter FAILED -> picker: $e\n$st',
          );
          await _teardownSession();
        }
      }
      _activeLabel = null;
      state = state.copyWith(
        phase: AppPhase.pickingIdentity,
        identities: [for (final e in updated) e.label],
      );
      return;
    }
    // One-active: re-open [target] (rebooting its node), or show the picker when
    // it is gone so the user re-selects.
    if (valid) {
      _activeLabel = null;
      await pickIdentity(target);
    } else {
      _activeLabel = null;
      state = state.copyWith(
        phase: AppPhase.pickingIdentity,
        identities: [for (final e in updated) e.label],
      );
    }
  }

  /// Unbind [label] from THIS master — remove it from the master's roster only.
  /// The identity's space is UNTOUCHED: it still opens by its own password and
  /// from any other master that lists it. Master-mode only; refuses to unbind
  /// the last identity (an empty-roster master is indistinguishable from a plain
  /// identity space at unlock). Returns false on those guards or a reopen fail.
  Future<bool> unbindIdentity(String label) async {
    final roster = _pendingRoster;
    final masterKeys = _masterKeys;
    if (roster == null || masterKeys == null) return false;
    if (!roster.any((e) => e.label == label)) return false;
    if (roster.length <= 1) return false; // keep >= 1 identity in a master

    final prevActive = _activeLabel;
    final hadSession = ref.read(sessionProvider) != null;

    await _teardownSession();
    await _teardownRealStack();
    await ref.read(storageProvider).close();

    try {
      final storage = ref.read(storageProvider);
      if (!await storage.openWithKeys(masterKeys)) {
        await _recoverToActive();
        return false;
      }
      final onDisk = await storage.loadRoster() ?? roster;
      final updated = [
        for (final e in onDisk)
          if (e.label != label) e,
      ];
      await storage.saveRoster(updated);
      await storage.close();
      _setPendingRoster(updated);

      // If we just unbound the ACTIVE identity it is gone from [updated], so
      // the helper falls back to the picker; otherwise restores the view.
      await _reEnterAfterRosterEdit(updated, prevActive, hadSession);
      return true;
    } catch (e) {
      devLog(() => 'xVeil[identity]: unbindIdentity failed -> recover: $e');
      await _recoverToActive();
      return false;
    }
  }

  /// PERMANENTLY delete [label]'s identity: forensically erase its space (its
  /// keypair, contacts, messages, file blobs — [Storage.eraseSpace]) AND remove
  /// it from this master's roster. Irreversible — distinct from [unbindIdentity],
  /// which only removes the roster link and leaves the space openable. Refuses
  /// the last identity (use the lock-screen wipe to remove everything). NOTE: if
  /// the same identity is bound in OTHER masters, those rosters keep a now-stale
  /// entry (the space they point at is erased). Returns false on the guards.
  Future<bool> deleteIdentity(String label) async {
    final roster = _pendingRoster;
    final masterKeys = _masterKeys;
    if (roster == null || masterKeys == null) return false;
    RosterEntry? entry;
    for (final e in roster) {
      if (e.label == label) {
        entry = e;
        break;
      }
    }
    if (entry == null) return false;
    if (roster.length <= 1) return false; // keep >= 1; use wipe for everything

    final prevActive = _activeLabel;
    final hadSession = ref.read(sessionProvider) != null;

    await _teardownSession();
    await _teardownRealStack();
    await ref.read(storageProvider).close();

    try {
      final storage = ref.read(storageProvider);
      // Erase the identity's space (forensic) — open by its stored keys, wipe
      // every namespace, scrub. If the keys are stale we still drop the roster
      // entry below so the master view is consistent.
      if (await storage.openWithKeys(entry.spaceKeys)) {
        await storage.eraseSpace();
        await storage.close();
      }

      if (!await storage.openWithKeys(masterKeys)) {
        await _recoverToActive();
        return false;
      }
      final onDisk = await storage.loadRoster() ?? roster;
      final updated = [
        for (final e in onDisk)
          if (e.label != label) e,
      ];
      await storage.saveRoster(updated);
      await storage.close();
      _setPendingRoster(updated);

      await _reEnterAfterRosterEdit(updated, prevActive, hadSession);
      return true;
    } catch (e) {
      // A mid-erase / mid-save FFI throw must still re-enter a usable session
      // instead of stranding the user behind the manage-screen busy overlay.
      devLog(() => 'xVeil[identity]: deleteIdentity failed -> recover: $e');
      await _recoverToActive();
      return false;
    }
  }

  /// Bind an EXISTING identity (proven by [identityPassword]) into this master
  /// under [label]. Opens the identity by its own password to read its keys,
  /// then appends them to the master's roster — so the SAME identity space can
  /// now be reached from this master too. Returns false if: not in a master
  /// session; the password opens nothing or opens a MASTER (only a plain
  /// identity can be bound); [label] is already used here; or that identity is
  /// already bound (by its keys). The bound space is shared, not copied.
  Future<bool> bindExistingIdentity({
    required String identityPassword,
    required String label,
  }) async {
    final roster = _pendingRoster;
    final masterKeys = _masterKeys;
    if (roster == null || masterKeys == null) return false;
    if (roster.any((e) => e.label == label)) return false;

    final prevActive = _activeLabel;
    final hadSession = ref.read(sessionProvider) != null;

    await _teardownSession();
    await _teardownRealStack();
    await ref.read(storageProvider).close();

    try {
      final storage = ref.read(storageProvider);
      // Open the identity by its OWN password (must already exist — no create).
      if (!await storage.open(password: identityPassword)) {
        await _recoverToActive();
        return false;
      }
      // Only a PLAIN identity can be bound — a roster-bearing space is a master.
      // A DAMAGED identity record throws out of here into the catch below, which
      // aborts with no side effects (audit XV-13). That is the point: it used to
      // read as `null`, i.e. "not an identity space", and binding proceeded on a
      // space nobody could read.
      final isPlainIdentity =
          await storage.loadProfile() != null &&
          await storage.loadRoster() == null;
      final keys = isPlainIdentity ? await storage.exportSpaceKeys() : null;
      await storage.close();
      if (keys == null) {
        await _recoverToActive();
        return false;
      }

      // Append to the master's ON-DISK roster, re-checking label + keys there.
      if (!await storage.openWithKeys(masterKeys)) {
        await _recoverToActive();
        return false;
      }
      final onDisk = await storage.loadRoster() ?? roster;
      if (onDisk.any(
        (e) => e.label == label || listEquals(e.spaceKeys, keys),
      )) {
        await storage.close();
        await _recoverToActive();
        return false;
      }
      final updated = [...onDisk, RosterEntry(label: label, spaceKeys: keys)];
      await storage.saveRoster(updated);
      await storage.close();
      _setPendingRoster(updated);

      await _reEnterAfterRosterEdit(updated, prevActive, hadSession);
      return true;
    } catch (e) {
      devLog(
        () => 'xVeil[identity]: bindExistingIdentity failed -> recover: $e',
      );
      await _recoverToActive();
      return false;
    }
  }

  /// Add a new identity. On the FIRST add this converts the current single
  /// identity into a master managed by [masterPassword] (the existing identity
  /// becomes a child labelled [existingLabel]); thereafter it APPENDS to the
  /// EXISTING master — adding to it, never creating a second master. [label]/
  /// [password] name the new identity. On success switches to the new identity
  /// and returns true; returns false on failure — notably if [masterPassword]
  /// collides with an identity's own password (which would corrupt that space),
  /// or if [label] already names an identity in the master, so the UI can ask
  /// for a different value.
  ///
  /// The roster to persist is read from the MASTER'S OWN ON-DISK STATE and the
  /// new child appended — it is never rebuilt from in-memory session state. An
  /// earlier version trusted the in-memory `_pendingRoster`; when that was stale
  /// or null (after an all-online session, or a relaunch), `saveRoster`
  /// OVERWROTE the master and silently dropped the other identities — a
  /// lockout/data-loss bug. See test/native/repro_existing_master_add_test.dart.
  ///
  /// Serialized under the exclusive lock: tear down any live session (it holds
  /// the container lock) → snapshot the active identity's keys → open/create the
  /// master + read its on-disk roster → create the child → append → save roster
  /// → open the new identity.
  Future<bool> addIdentity({
    required String masterPassword,
    required String label,
    required String password,
    String existingLabel = 'Identity 1',
    bool anonymous = false,
  }) async {
    // Snapshot the active identity's keys BEFORE any teardown — needed only for
    // the first conversion, where the active single identity becomes the first
    // child of the brand-new master.
    final active = ref.read(storageProvider);
    Uint8List? currentKeys;
    try {
      if (active.isOpen) currentKeys = await active.exportSpaceKeys();
    } catch (_) {
      // No open active space (e.g. between states) — only matters for the first
      // conversion, which can't happen without an active identity anyway.
    }

    // Release EVERYTHING that holds the container: an all-online session keeps
    // the exclusive lock via its multi-space backing, and the active node keeps
    // a handle. Without this the direct open() below would hit a locked file (or
    // the session's no-op opener) and fail. After teardown, storageProvider
    // resolves to the single-space opener that can open the container directly.
    await _teardownSession();
    await _teardownRealStack();
    await active.close();
    try {
      final storage = ref.read(storageProvider);

      // Open/create the master and decide append-vs-convert from its ON-DISK
      // state — never from in-memory session state.
      if (!await storage.open(
        password: masterPassword,
        createIfMissing: true,
      )) {
        await _recoverToActive();
        return false;
      }
      final existingRoster = await storage.loadRoster();
      // "Does this space already hold an identity?" — the guard that stops a
      // roster being written over a real identity space. A DAMAGED record throws
      // into the catch below and aborts the whole conversion (audit XV-13);
      // before, it answered `false`, the clash check at [masterHasIdentity]
      // below never fired, and `saveRoster` went straight over the damaged
      // identity — turning "unreadable" into "gone".
      final masterHasIdentity = await storage.loadProfile() != null;
      // Capture the master's own derived keys while it is open — the collision
      // check below needs them, and re-opening just to read them would be a
      // second password derivation for nothing.
      final masterKeys = await storage.exportSpaceKeys();
      await storage.close();

      // Clash: the master password opened a real IDENTITY space (has an identity,
      // no roster). Writing a roster into it would clobber that identity — abort
      // with no side effects so the UI can ask for a different master password.
      if (masterHasIdentity && existingRoster == null) {
        await _recoverToActive();
        return false;
      }

      // First conversion (no existing master roster) needs the current identity's
      // keys to wrap it as the first child. Without them (the active space wasn't
      // open when we started) we'd write a roster of ONLY the new identity and
      // ORPHAN the existing one — abort instead of losing it.
      if (existingRoster == null && currentKeys == null) {
        await _recoverToActive();
        return false;
      }

      // Base roster: an EXISTING master → its OWN on-disk roster (append to it); a
      // fresh master → wrap the current single identity as the first child.
      final base = <RosterEntry>[
        if (existingRoster != null)
          ...existingRoster
        else if (currentKeys != null)
          // Preserve the single identity's CURRENT anonymity when wrapping it as
          // the first child, so converting to a master never silently flips its
          // routing (the bug where the "anonymous routing" banner appeared/vanished
          // on convert). Mirrors the per-space [_singleAnonymous] preference.
          RosterEntry(
            label: existingLabel,
            spaceKeys: currentKeys,
            anonymous: _singleAnonymous,
          ),
      ];

      // Refuse a duplicate label — two roster entries with the same label would
      // break switching (it resolves an identity by label).
      if (base.any((e) => e.label == label)) {
        await _recoverToActive();
        return false;
      }

      // Create + name the new identity space (its node config is mined lazily on
      // first boot, like onboarding).
      if (!await storage.open(password: password, createIfMissing: true)) {
        await _recoverToActive();
        return false;
      }

      // Derive the candidate's storage keys BEFORE the first write.
      //
      // `createIfMissing` does not create anything when the password already
      // has a space — it OPENS that space. The old order wrote an Identity
      // into whatever it opened and only then exported the keys, so re-using an
      // existing child's password overwrote that child (leaving two roster
      // entries pointing at one space), and re-using the MASTER's password
      // overwrote the master with child data — after which deleting that
      // "child" deleted the master's storage.
      //
      // Deniability boundary: this compares ONLY against the master we just
      // unlocked and the entries in its own roster — things this session
      // already legitimately sees. It must never grow to "is this password used
      // anywhere in the container", which would be a password oracle against
      // hidden identities. A collision returns the same plain `false` a
      // duplicate label already returned, so the caller learns nothing new
      // either. The comment this replaces said the design "can't deniably
      // dedupe passwords" — it can, within the roster it is editing.
      final candidateKeys = await storage.exportSpaceKeys();
      if (identitySpaceCollides(
        masterKeys: masterKeys,
        roster: base,
        candidateKeys: candidateKeys,
      )) {
        await storage.close();
        await _recoverToActive();
        return false;
      }

      await storage.saveProfile(UserProfile(displayName: label));
      final roster = <RosterEntry>[
        ...base,
        RosterEntry(
          label: label,
          spaceKeys: candidateKeys,
          anonymous: anonymous,
        ),
      ];
      await storage.close();

      // Persist the appended roster into the (now-existing) master.
      if (!await storage.open(password: masterPassword)) {
        await _recoverToActive();
        return false;
      }
      await storage.saveRoster(roster);
      // Cache the master's keys so a later roster edit (e.g. toggling anonymity)
      // works without re-unlocking — same as the unlock path does.
      _setMasterKeys(await storage.exportSpaceKeys());
      await storage.close();

      // Enter the new identity (one-active). If the user has keep-all-online on,
      // the next unlock brings every identity — including this one — back online.
      _setPendingRoster(roster);
      _activeLabel = null;
      await pickIdentity(label);
      return true;
    } catch (e) {
      devLog(() => 'xVeil[identity]: addIdentity failed -> recover: $e');
      await _recoverToActive();
      return false;
    }
  }

  /// Create a **decoy (duress) master** under [duressPassword], whose roster
  /// lists ONLY the chosen existing identities ([includeLabels]). Under coercion
  /// the user gives the duress password → it opens this decoy, showing a
  /// believable set while the real master and any sensitive identity stay
  /// hidden. SHARE ONLY GENUINELY INNOCUOUS IDENTITIES — opening the decoy
  /// exposes the full content of every identity it lists.
  ///
  /// Master-mode only (there must be identities to share). Returns false if the
  /// duress password collides with an existing identity OR an existing master
  /// (it must never overwrite either). Does not change the active session.
  Future<bool> createDecoyMaster({
    required String duressPassword,
    required List<String> includeLabels,
  }) async {
    final roster = _pendingRoster;
    if (roster == null) return false; // need a master session to share from
    final decoy = [
      for (final e in roster)
        if (includeLabels.contains(e.label)) e,
    ];
    if (decoy.isEmpty) return false;
    // FAIL-CLOSED: never write a decoy roster that references an identity the
    // user did not explicitly include — under duress, one leaked real identity
    // is catastrophic. If the filter is ever widened (roster-model change), bail
    // rather than create a decoy that exposes a hidden identity.
    final included = includeLabels.toSet();
    if (!decoy.every((e) => included.contains(e.label))) return false;

    // Only one space open at a time: close the active identity, write the decoy
    // master, then restore the active identity.
    final activeLabel = _activeLabel;
    await _teardownRealStack();
    await ref.read(storageProvider).close();

    var ok = false;
    try {
      final storage = ref.read(storageProvider);
      if (await storage.open(password: duressPassword, createIfMissing: true)) {
        // Refuse to write into anything that already exists — a clash means the
        // password opened a real identity (has an identity) or an existing
        // master (has a roster); the decoy roster would clobber it.
        //
        // An UNREADABLE identity record counts as "something is there": it
        // throws into the catch below, which leaves `ok` false and writes
        // nothing (audit XV-13). It used to read as `null` — no clash — so the
        // decoy roster was written over a damaged but possibly recoverable
        // identity space.
        final clash =
            await storage.loadProfile() != null ||
            await storage.loadRoster() != null;
        if (!clash) {
          await storage.saveRoster(decoy);
          ok = true;
        }
        await storage.close();
      }
    } catch (e) {
      devLog(() => 'xVeil[identity]: createDecoyMaster write failed: $e');
      ok = false;
      // The `close()` above is inside the try, so a throw between open and it
      // would leave the duress space OPEN and holding the container's exclusive
      // lock — and the restore below would then fail to reopen the user's own
      // identity. Release it here.
      try {
        await ref.read(storageProvider).close();
      } catch (_) {}
    }

    // Restore the user's active identity — ALWAYS, even if the decoy write
    // threw, so a fault never leaves the user session-less behind a closed
    // container.
    try {
      if (activeLabel != null) {
        _activeLabel = null;
        await pickIdentity(activeLabel);
      }
    } catch (e) {
      devLog(
        () =>
            'xVeil[identity]: createDecoyMaster restore failed -> recover: $e',
      );
      await _recoverToActive();
    }
    return ok;
  }

  /// Reopen whatever identity was active before a failed [addIdentity] so the
  /// user is not stranded on a closed space.
  Future<void> _recoverToActive() async {
    final label = _activeLabel;
    if (_pendingRoster != null && label != null) {
      _activeLabel = null;
      await pickIdentity(label);
    } else {
      // Single-identity mode: bounce to the lock screen to re-unlock cleanly.
      await ref.read(storageProvider).close();
      state = const AppState(AppPhase.locked, unlockError: true);
    }
  }

  Future<void> _enterSession(UserProfile profile) async {
    // Taken before the first await — see [_lifecycle]. Every caller of this
    // (unlock, pick, switch, anonymity/lazy-mining reboot, proxy re-apply) can
    // be locked out from under, and all of them end here at `ready`.
    final gen = _lifecycle;
    // The container has answered by the time anything reaches here, which makes
    // this the only place the screen lock can learn what this space chose. Its
    // own build ran from the app's first frame — before the unlock screen — and
    // read a shut container; on the single-identity path nothing would ever
    // rebuild it, so the saved timeout stayed `off` for the whole run (IF-01).
    // Best-effort by construction: the read is swallowed on failure.
    await ref.read(screenLockProvider.notifier).reloadTimeout();
    // Single-identity mode: load this space's persisted anonymity preference
    // BEFORE booting the node, since anonymity is fixed at boot. Master mode
    // reads the roster flag instead, so skip (the roster is authoritative).
    if (_pendingRoster == null) {
      final storage = ref.read(storageProvider);
      final v = await storage.getSetting(_kAnonymousSetting);
      _singleAnonymous = v == 'true';
      // Lazy mining is also fixed at boot; default OFF (opt-in).
      _singleLazyMining =
          (await storage.getSetting(_kLazyMiningSetting)) == 'true';
    }
    // Deniable path: now that the space is open, boot the in-process node from
    // the in-space identity (mining it on first run). Best-effort — never block
    // entering the session if the node fails. Show a "setting up" screen while
    // it provisions (the mining runs off the UI isolate; see startDeniable).
    if (ref.read(deniableBootProvider) != null &&
        ref.read(realStackProvider) == null) {
      // First run for THIS identity = no stored node config yet → startDeniable
      // will mine the identity (the slow, one-time 24-bit PoW). Flag it so the
      // screen says "creating identity" rather than the generic "preparing".
      final firstRun = await ref.read(storageProvider).loadNodeConfig() == null;
      devLog(
        () =>
            'xVeil[unlock]: preparingNode '
            '(${firstRun ? 'first-run mining' : 'node boot'})',
      );
      state = state.copyWith(
        phase: AppPhase.preparingNode,
        preparingReason: firstRun
            ? PreparingReason.firstRunMining
            : PreparingReason.node,
      );
    }
    await _ensureRealStack();
    if (_supersededSince(gen)) {
      // The node boot is the longest await the app has (first-run mining), and
      // a lock inside it has already torn down / refused whatever came up.
      // Reaching `ready` from here would leave the messenger on screen with no
      // session behind it (audit H-06).
      devLog(() => 'xVeil[session]: locked while coming up — not entering');
      return;
    }
    final stack = ref.read(realStackProvider);
    if (stack == null) {
      // Loopback / legacy: kick the placeholder controller without blocking.
      ref.read(nodeControllerProvider).start();
    }
    // ONE source for the node id, always the transport's (audit XV-06): the
    // running node's when a real stack came up, and the stand-in transport's
    // otherwise — loopback's 0xA0 in dev, fail-closed's 0xFF in a shipped build
    // with no node. Both of those are visibly not real ids, which is the point:
    // a session with no node should look like one, not wear a leftover id read
    // out of storage.
    final nodeId = stack != null
        ? stack.myInvite.nodeId
        : await ref.read(veilTransportProvider).nodeId();
    // Carry the master roster + active identity through the session so the UI
    // can offer a switcher (empty/null in single-identity mode).
    state = AppState(
      AppPhase.ready,
      identity: Identity(
        nodeId: nodeId,
        displayName: profile.displayName,
        username: profile.username,
      ),
      identities: [for (final e in _pendingRoster ?? const []) e.label],
      activeIdentity: _activeLabel,
    );
  }

  /// P2P direct-session epic: whether the node's listener may bind on all
  /// interfaces (LAN-dialable) instead of loopback. Never for an anonymous
  /// posture (P2P is hard-forbidden there — an open LAN port is a linkable
  /// beacon), and never when the stored global P2P policy is `denied`. Storage
  /// is open at `_ensureRealStack` time, so the policy setting is readable.
  Future<bool> _p2pLanListenAllowed() async {
    if (_activeAnonymous()) return false;
    String? raw;
    try {
      raw = await ref
          .read(storageProvider)
          .getSetting(kP2PGlobalPolicySettingKey);
    } catch (_) {
      return lanListenAllowed(storedPolicy: null, readFailed: true);
    }
    return lanListenAllowed(storedPolicy: raw, readFailed: false);
  }

  /// Whether the node's listener may bind beyond loopback, given what the
  /// stored global P2P policy says.
  ///
  /// Separates the two ways the setting can be missing, which the old code
  /// collapsed:
  ///
  ///  * ABSENT (`storedPolicy == null`, `readFailed == false`) — never set, so
  ///    the default applies. Denying here would break every fresh install.
  ///  * UNREADABLE (`readFailed == true`) — a transient storage error. The old
  ///    `catch` fell back to the same default, which is permissive, so a failed
  ///    read bound a LAN listener for a user who had explicitly denied P2P.
  ///    The setting exists precisely to stop that; an open LAN port is not
  ///    something to grant on a guess.
  @visibleForTesting
  static bool lanListenAllowed({
    required String? storedPolicy,
    required bool readFailed,
  }) {
    if (readFailed) return false;
    if (storedPolicy == null) {
      return kDefaultP2PGlobalPolicy != P2PGlobalPolicy.denied;
    }
    return p2pGlobalPolicyFromName(storedPolicy) != P2PGlobalPolicy.denied;
  }

  /// Build the in-process deniable stack post-unlock (storage is open) when the
  /// embedded boot is configured and not already running.
  Future<void> _ensureRealStack() async {
    if (ref.read(realStackProvider) != null) return;
    final boot = ref.read(deniableBootProvider);
    if (boot == null) return;
    // One shot, taken BEFORE the await rather than cleared after it.
    //
    // Clearing on success only meant a failed boot left the phrase sitting in
    // the controller, where the next unlock — of a DIFFERENT legacy or decoy
    // identity with no node config of its own — would consume it and derive
    // the SAME node identity. That binds two storage spaces which are supposed
    // not to know about each other to one identity on the wire, which is the
    // one thing deniable separation cannot survive. It also kept the secret in
    // the Dart heap across a lock.
    final identityPhrase = takePendingIdentityPhrase();
    final restoringIdentity = takePendingRestoringIdentity();
    // Taken before the boot — the longest await in the app (see [_lifecycle]).
    final gen = _lifecycle;
    // THIS identity's answer, out of the space this boot is about to run on —
    // and the peer list built from it. Resolved once, here, so the addresses the
    // app hands the node over IPC and the `builtin_seed_policy` the node is
    // composed with can never come from two different answers. It used to be a
    // profile preference resolved inside `startDeniable`, i.e. one answer for
    // every identity in the process, decoy masters included.
    final storage = ref.read(storageProvider);
    final seeds = await planIdentitySeeds(
      storage: storage,
      peersFor: boot.peersFor,
    );
    if (ref.read(bundledSeedsChoiceProvider) != seeds.useBundledSeeds) {
      // The screens read the live value; leaving it on the previous identity's
      // answer is the same lie in a different place.
      ref.read(bundledSeedsChoiceProvider.notifier).state =
          seeds.useBundledSeeds;
    }
    Future<RealVeilStack> startStack() async {
      final starter = debugDeniableStackStarter;
      if (starter != null) return starter(seeds);
      return RealVeilStack.startDeniable(
        storage: storage,
        runtimeDirBase: boot.runtimeDir,
        // Offset alternates after every teardown (see _teardownRealStack) so
        // a switch/relock never rebinds the just-freed port.
        listenPort: boot.listenPort + _oneActivePortOffset,
        // No offset: unlike the listener this is not rebound after a teardown,
        // and a stand sets it explicitly to keep two instances apart.
        debugMetricsPort: boot.debugMetricsPort,
        lanListen: await _p2pLanListenAllowed(),
        anonymous: _activeAnonymous(),
        lazyMining: _singleLazyMining,
        // Deliberately DON'T inject `[[bootstrap_peers]]` into the node config:
        // the node dials the same nodes from its compiled-in BUILTIN_SEEDS (the
        // proven-connecting path), and injecting explicit peers made
        // veil_node_apply_config fail with ENOENT on Android (a per-peer persist
        // path that doesn't exist in the ephemeral runtime dir). Register the
        // app-supplied set through IPC after the node is connected instead;
        // this starts connectors for bundle-only seeds without the reload bug.
        bootstrapPeers: const [],
        runtimeBootstrapPeers: seeds.bootstrapPeers,
        udpReflectors: boot.udpReflectors,
        obfs4Psk: boot.obfs4Psk,
        proxy: ref.read(effectiveProxyRoutingProvider),
        identityPhrase: identityPhrase,
        restoringIdentity: restoringIdentity,
        useBundledSeeds: seeds.useBundledSeeds,
      );
    }

    try {
      final stack = await startStack();
      if (_supersededSince(gen)) {
        // A lock landed while the node was coming up. It looked in
        // [realStackProvider], found nothing — because nothing was published
        // yet — and finished, reporting the app locked. Publishing here would
        // put a LIVE node and the open container behind the lock screen, and
        // [_enterSession] would walk the phase back to `ready` (audit H-06).
        // Roll the node back instead; NOTHING is published under a generation
        // that has ended.
        devLog(
          () =>
              'xVeil[deniable]: node came up after a lock — tearing it down '
              'instead of publishing it',
        );
        try {
          await stack.dispose();
        } catch (e) {
          devLog(() => 'xVeil[deniable]: rollback dispose failed: $e');
        }
        // Same reason as [_teardownRealStack]: the port this boot bound is now
        // in lingering teardown and the next one must not rebind it.
        _oneActivePortOffset = _oneActivePortOffset == 0 ? 64 : 0;
        return;
      }
      ref.read(realStackProvider.notifier).state = stack;
      // Real node is up — clear any pending boot status so the UI follows the
      // real controller's live state, not a stale "connecting…".
      ref.read(nodeBootStateProvider.notifier).state = null;
      // Keep the node alive when backgrounded if the user opted in (Android FGS).
      await ref
          .read(backgroundNodeProvider.notifier)
          .applyIfNodeUp(nodeUp: true);
      devLog(
        () => 'xVeil[deniable]: node up, invite=${stack.myInvite.nodeId.short}',
      );
    } catch (e, st) {
      // A node-boot failure must not trap the user — but it must NOT be hidden
      // behind a fake "connected" either: surface it honestly (the network
      // screen shows this state + a non-blocking notice) and in the log.
      ref.read(nodeBootStateProvider.notifier).state = NodeStatus(
        phase: NodePhase.error,
        message: 'node failed to start: $e',
      );
      devLog(() => 'xVeil[deniable]: boot FAILED: $e\n$st');
    }
  }

  /// Bring down the OS-level VPN tunnel.
  ///
  /// The tunnel lives in the operating system, not in this process, so it
  /// survives a lock and a wipe on its own. Leaving it up after either is the
  /// opposite of what the user asked for: traffic keeps flowing through the
  /// configured exit, and on a locked device the tunnel itself is a visible
  /// statement that this machine is running xVeil (audit XV-15).
  ///
  /// Best-effort and always before the node teardown — a tunnel pointed at a
  /// node that has just gone away is worse than one shut down cleanly.
  ///
  /// [VpnController.stopForTeardown], not the UI's `stop`: this call READS the
  /// VPN provider, so in a session where nothing else touched it the lock builds
  /// the controller itself — and `stop` would then return on that fresh default
  /// state without asking the backend anything, while the restore the build just
  /// scheduled went on to adopt the very tunnel we came to kill (audit XV-H2).
  ///
  /// Returns true only when the OS said the tunnel is DOWN. A false has already
  /// been journalled, so a caller is free to ignore it; the point of returning
  /// it is that a caller which can tell the person something — the wipe's
  /// survivor list is the obvious one — no longer has to ask a second time.
  ///
  /// JOURNALLED, not logged. Both failure paths here used to be [devLog] alone,
  /// and `devLog` is compiled out of a release build (see `core/log.dart`): in
  /// a shipped app an OS tunnel that survived a lock or a wipe left NO trace
  /// anywhere. The node half of the same teardown records `node-stop-abandoned`
  /// for exactly this situation, and of the two halves this is the one that
  /// keeps routing the person's traffic while the app says it is locked. The
  /// journal is in RAM and never exports the message, so recording it costs
  /// nothing a deniable app cares about.
  /// Legs of the CURRENT teardown that did not confirm they finished. Each
  /// teardown entry point clears it first; [lastTeardown] is what it became.
  final List<String> _incomplete = [];

  /// The verdict of the last [lock], [startOver] or [wipeContainers].
  ///
  /// Read by the API's lock handler, which otherwise answers `locked: true`
  /// for a boundary that is not closed (report17 XV17-M14).
  TeardownOutcome get lastTeardown => _lastTeardown;
  TeardownOutcome _lastTeardown = TeardownOutcome.clean;

  /// Stop the tunnel and RECORD it when it would not stop.
  Future<void> _stopVpnTunnelRecorded() async {
    if (!await _stopVpnTunnel()) _incomplete.add('vpn');
  }

  Future<bool> _stopVpnTunnel() async {
    // What went wrong, phrased for the journal. Null means the OS confirmed it.
    String? incomplete;
    try {
      final phase = await ref
          .read(vpnControllerProvider.notifier)
          .stopForTeardown()
          // Bounded: the tunnel lives behind a platform channel, and a wipe
          // that hangs because the VPN plugin is unresponsive is worse than
          // one that leaves the tunnel up — the user asked for their data
          // gone, and that part does not depend on the OS answering.
          .timeout(const Duration(seconds: 3));
      // A backend can report `error` without throwing, and that used to pass
      // unnoticed: the tunnel stays up and nothing in the log says so.
      if (phase != VpnBackendPhase.stopped) {
        incomplete = 'the backend answered ${phase.name}';
      }
    } catch (e) {
      // The timeout above lands here too, and it is the case that matters
      // most: a VPN plugin that never answers is precisely the arrangement in
      // which the tunnel is still up. Both are the same outcome to the person.
      incomplete = 'the stop did not return: $e';
    }
    if (incomplete == null) return true;
    devLog(
      () => 'xVeil[vpn]: tunnel did not stop during lock/wipe — $incomplete',
    );
    // The consequence FIRST, the cause after it: the journal truncates a long
    // message from the end, and what a reader must not lose is what this means
    // for the person rather than which exception said so.
    errorJournal.record(
      kind: 'vpn-stop-incomplete',
      error: StateError(
        'traffic may still be routed through the configured exit while the app '
        'presents itself as locked: $incomplete',
      ),
      atMs: DateTime.now().millisecondsSinceEpoch,
    );
    return false;
  }

  Future<void> lock() async {
    // FIRST, before any await and before anything is torn down: end the
    // lifecycle. What this teardown cannot see — a node or a hosted session
    // still mid-boot, published only after the await it is sitting in — now
    // refuses to publish itself and rolls back on its own (audit H-06).
    _endLifecycle();
    // Timestamped phases: a lock that takes seconds points at whichever step
    // stalled (a busy storage worker on close is the prime suspect for the
    // "won't unlock until restart" report — see WorkerKvLogStore.close).
    final t0 = DateTime.now();
    int ms() => DateTime.now().difference(t0).inMilliseconds;
    devLog(() => 'xVeil[lock]: begin');
    // Answer deliberately NOT folded into `firstError` below. A surviving
    // tunnel is REPORTED — `_stopVpnTunnel` journals what it means for the
    // person, and the screen says so — but it does not fail the lock: parking
    // someone on an unlocked-looking screen because the OS would not answer is
    // its own failure, and in a deniable app the wrong screen is a disclosure.
    // The decision is pinned by `a backend that reports it did not stop is
    // journalled`; audit report12 X-H2 asks for the opposite and is answered
    // here rather than followed.
    _incomplete.clear();
    await _stopVpnTunnelRecorded();
    // A phrase that never reached a node boot (the user finished onboarding
    // and locked before the stack came up) must not outlive the session that
    // produced it — the next unlock may be a different identity entirely.
    takePendingIdentityPhrase();
    // Posted alerts and their payloads outlive a lock otherwise (audit XV-03):
    // `cancelAll` only ran on RESUME, so locking left the shade holding
    // notifications for a session that is over — and, before the opaque-token
    // change, their conversation ids with them. Cancel first, then drop the
    // token map: a token that resolved after lock would point at a chat this
    // process can no longer open.
    try {
      await ref.read(notificationServiceProvider).cancelAll();
    } catch (_) {
      // A notification backend that is not up cannot be holding anything.
    }
    ref.read(opaqueNotificationPayloadsProvider).clear();
    // And what attributes an alert to an identity. Kept in memory only and by
    // design — a restart leaves every earlier notification unattributable,
    // which is the safe direction — but until this call the map was never
    // cleared by anything in production (report17 XV17-M12).
    ref.read(notificationOwnersProvider).clear();
    // The session is over, so the screen lock has nothing left to cover — and
    // must not carry this session's password recogniser into the next one,
    // which may well be a different identity entirely.
    ref.read(screenLockProvider.notifier).forgetSession();
    // EVERY LEG RUNS (audit XV-08). These were a plain `await` chain, so the
    // first failure skipped all of it: a session that would not stop left the
    // node running, the runtime dir populated, the container OPEN and the
    // master keys in memory — while the UI moved to `locked`. A lock that
    // reports success with the container still open is the one failure this
    // screen exists to prevent.
    //
    // Independent legs, errors collected. The first error is rethrown after
    // everything has been attempted, so the caller still learns something went
    // wrong — it just no longer decides how much cleanup happened.
    Object? firstError;
    StackTrace? firstStack;
    Future<void> leg(String name, Future<void> Function() run) async {
      try {
        await run();
      } catch (e, st) {
        devLog(() => 'xVeil[lock]: $name FAILED: $e');
        _incomplete.add('leg:$name');
        firstError ??= e;
        firstStack ??= st;
      }
    }

    // all-online: stop every node + release the lock
    await leg('teardownSession', _teardownSession);
    await leg('teardownRealStack', _teardownRealStack);
    devLog(() => 'xVeil[lock]: node/session torn down (+${ms()}ms)');
    await leg('stopBackgroundService', _stopBackgroundService);
    await leg('cleanRuntimeBase', _cleanRuntimeBase);
    await leg('closeStorage', () => ref.read(storageProvider).close());
    devLog(() => 'xVeil[lock]: storage closed (+${ms()}ms)');
    // Sensitive references go regardless of what failed above: keys held after
    // a partial lock are the worst outcome of all, and dropping them costs
    // nothing even when the container is somehow still open.
    _clearMasterSession();
    _lastTeardown = TeardownOutcome(List.unmodifiable(_incomplete));
    state = const AppState(AppPhase.locked);
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStack ?? StackTrace.current);
    }
  }

  /// Drop the cached SpaceKeys — after overwriting them (audit XV-22).
  ///
  /// These are the real thing: each one opens a space without a password. They
  /// used to be dropped by reference alone, which hands the bytes to the
  /// collector intact and leaves them readable in the heap until something
  /// happens to reuse that memory. On a LOCK — which is a person saying "I am
  /// done, protect this" — that is the wrong default.
  ///
  /// This is best-effort and the honest bound is in lib/core/secret_wipe.dart:
  /// a moving collector may already have copied these buffers, and this cannot
  /// reach the copies. It removes the copy we hold, which is the one we can.
  ///
  /// Safe here because every caller has already torn the session down, so
  /// nothing is still reading through these buffers.
  void _clearMasterSession() {
    _setPendingRoster(null); // drop cached child keys
    _setMasterKeys(null); // drop cached master keys
    _activeLabel = null;
  }

  /// Every key buffer this controller currently holds.
  ///
  /// Consulted AFTER a swap, so a buffer the new value adopted from the old
  /// one shows up as live and is left alone.
  Iterable<Uint8List> get _liveKeyBuffers sync* {
    final master = _masterKeys;
    if (master != null) yield master;
    for (final entry in _pendingRoster ?? const <RosterEntry>[]) {
      yield entry.spaceKeys;
    }
  }

  /// Zero the key buffers in [candidates] that nothing still holds.
  ///
  /// Compared by IDENTITY, never by content (audit report10 X-04). A roster
  /// edit builds new [RosterEntry] objects around the SAME `spaceKeys` buffers,
  /// so entry-level comparison would miss the aliasing entirely — and content
  /// equality is worse than useless here: the old and new buffers hold the same
  /// key bytes, so an equality check would find every buffer "still live" and
  /// wipe nothing, while looking exactly like a working fix.
  void _releaseKeys(Iterable<Uint8List?> candidates) {
    final live = _liveKeyBuffers.toList();
    for (final candidate in candidates) {
      if (candidate == null) continue;
      if (live.any((held) => identical(held, candidate))) continue;
      wipeSecretBytes(candidate);
    }
  }

  /// Replace the cached roster, wiping whatever the old one held alone.
  ///
  /// The single owner of that field. It used to be a plain assignment in six
  /// places, and `loadRoster` hands back FRESH buffers every call — so every
  /// anonymity toggle, bind, unbind, delete and addIdentity abandoned a whole
  /// set of child space keys intact in the heap. Only the buffers still
  /// referenced at lock time were ever zeroed, which meant a session with a few
  /// roster edits left several full sets readable after the container closed.
  ///
  /// Assign first, release second: the live set is read after the swap, so an
  /// adopted buffer is skipped without the caller having to say which.
  void _setPendingRoster(List<RosterEntry>? next) {
    final previous = _pendingRoster;
    _pendingRoster = next;
    if (previous == null) return;
    _releaseKeys([for (final entry in previous) entry.spaceKeys]);
  }

  /// Replace the cached master keys, wiping the old buffer unless it was
  /// adopted. Same rule as [_setPendingRoster].
  void _setMasterKeys(Uint8List? next) {
    final previous = _masterKeys;
    _masterKeys = next;
    if (previous == null) return;
    _releaseKeys([previous]);
  }

  /// The cached master SpaceKeys, for tests that check they are ZEROED — not
  /// merely dropped — by [lock] and the wipe paths. Hands back the live buffer
  /// on purpose: a copy would prove nothing about the original.
  @visibleForTesting
  Uint8List? get debugMasterKeys => _masterKeys;

  /// The cached child SpaceKeys, same purpose as [debugMasterKeys].
  @visibleForTesting
  List<RosterEntry>? get debugRoster => _pendingRoster;

  /// Tear down an all-online session (all nodes + messaging + the shared lock)
  /// and clear its providers. No-op when there is no session.
  Future<void> _teardownSession() async {
    final session = ref.read(sessionProvider);
    if (session == null) return;
    ref.read(sessionProvider.notifier).state = null;
    ref.read(activeIdentityProvider.notifier).state = null;
    await session.disposeAll();
    // "Locked" is a claim about the network, not only about the screen. A
    // teardown step that ran out of its budget was abandoned so the container
    // lock could still be released — the right trade — but the node it was
    // stopping keeps its sockets and its network identity, and its handle is
    // gone from the session, so nothing can ask it to stop again. That has to
    // be recorded rather than left to a debug log nobody reads.
    if (!session.containerLockReleased) {
      // The container is still locked by this process. Whoever is about to say
      // "locked" or "wiped" has to carry that: it is the fact behind every
      // later "correct password but won't unlock".
      _incomplete.add('container-lock-unknown');
    }
    final abandoned = session.abandonedTeardowns;
    if (abandoned.isNotEmpty) {
      _incomplete.add('session');
      devLog(
        () =>
            'xVeil[lock]: ${abandoned.length} teardown step(s) abandoned; a '
            'node may still hold its sockets: ${abandoned.join(", ")}',
      );
      errorJournal.record(
        kind: 'teardown-abandoned',
        error: StateError(
          'teardown abandoned after its budget: ${abandoned.join(", ")} — the '
          'session is gone from the app while a node may still be running',
        ),
        atMs: DateTime.now().millisecondsSinceEpoch,
      );
    }
  }

  Future<void> _teardownRealStack() async {
    final stack = ref.read(realStackProvider);
    if (stack != null) {
      // Both of these happen BEFORE the dispose, and the order is the fix.
      //
      // `dispose` can be abandoned — `_boundedTeardown` gives it fifteen
      // seconds — and everything after the await used to be skipped when it
      // was. That left the provider holding a dying stack, and
      // `_ensureRealStack` returns early on a non-null provider: the app then
      // ran with no node while believing it had one. Worse, when the abandoned
      // dispose finally returned it cleared the provider — by then possibly a
      // NEW session's stack (report9 X-16).
      //
      // Clearing first also means the port offset must flip first, or a reboot
      // during a hung dispose picks the port the dying node still holds and
      // stalls ~90s on the bind. The port this node held is in lingering
      // teardown; alternate between two ports well clear of the all-online
      // range. The listen address is composed fresh per boot and exchanged
      // in-band, so nothing persisted goes stale.
      ref.read(realStackProvider.notifier).state = null;
      _oneActivePortOffset = _oneActivePortOffset == 0 ? 64 : 0;
      await stack.dispose();
      // Did the node actually stop, or was the wait abandoned?
      //
      // The native stop is bounded now and detaches the thread when its budget
      // runs out (report9 X-17). Nothing can retry it — the handle is consumed
      // either way — so the only thing left to do with the answer is refuse to
      // claim a lock the app does not have. A node that outlived its stop
      // still holds its sockets and its network identity until the process
      // exits, and the person is being told "locked".
      //
      // Type-checked rather than put on `NodeController`: that interface has
      // eight implementers, five of them test doubles, and none of the others
      // can abandon anything — for them the honest answer is a constant.
      final controller = stack.controller;
      if (controller is EmbeddedNodeController &&
          controller.lastStopWasAbandoned) {
        _incomplete.add('node');
        devLog(
          () =>
              'xVeil[lock]: the node did not stop within its budget — it may '
              'still hold its sockets and its network identity',
        );
        errorJournal.record(
          kind: 'node-stop-abandoned',
          error: StateError(
            'the node stop ran out of its budget and the thread was detached '
            '— the app is presenting itself as locked while a node may still '
            'be running',
          ),
          atMs: DateTime.now().millisecondsSinceEpoch,
        );
      }
    }
  }

  /// Deniability: remove the ephemeral runtime-dir BASE (the parent that holds
  /// each identity's sockets + the public obfs4 PSK). Each stack already deletes
  /// its own subdir on dispose; this clears the now-empty base and any straggler
  /// so NO trace that nodes ran is left in temp after lock/wipe. Best-effort.
  /// Stop the background foreground service on teardown — nothing should keep
  /// the process (or its notification) alive once locked.
  ///
  /// This used to say "no node is running once locked". That is what the
  /// teardown intends and not what it guarantees: a dispose that runs out of
  /// its budget is abandoned so the container lock can still be released, and
  /// the node it was stopping keeps running. [_teardownSession] records when
  /// that happens.
  Future<void> _stopBackgroundService() async {
    await ref
        .read(backgroundNodeProvider.notifier)
        .applyIfNodeUp(nodeUp: false);
  }

  Future<void> _cleanRuntimeBase() async {
    final base = ref.read(deniableBootProvider)?.runtimeDir;
    if (base == null) return;
    // Only a directory WE marked (audit X-12). The path can come from
    // `XVEIL_RUNTIME_DIR`, and this is a recursive delete — a wrong launcher
    // entry, or the variable set by anything else in the session, otherwise
    // made lock/wipe erase whatever it pointed at. Leaving a few sockets
    // behind is a rounding error next to that.
    if (!runtimeDirIsOurs(base)) {
      devLog(
        () =>
            'xVeil[deniable]: refusing to remove $base — no $kRuntimeDirMarker '
            'marker, so this directory is not one we created',
      );
      return;
    }
    try {
      final d = Directory(base);
      if (d.existsSync()) await d.delete(recursive: true);
    } catch (_) {
      /* leftover sockets are not worth failing teardown on */
    }
  }

  /// Escape hatch from the lock screen: forget the onboarded flag and return to
  /// onboarding (e.g. forgotten password, or a moved/missing container). The
  /// existing container file is left untouched on disk — deniability means we
  /// can't and shouldn't prove it exists; the user simply sets up anew.
  Future<void> startOver() async {
    _endLifecycle(); // same window as [lock] — see [_lifecycle]
    _incomplete.clear();
    await _stopVpnTunnelRecorded();
    await _teardownSession();
    await _teardownRealStack();
    await _stopBackgroundService();
    await _cleanRuntimeBase();
    await ref.read(storageProvider).close();
    _clearMasterSession();
    final prefs = await ref.read(prefsProvider.future);
    await prefs.remove(_onboardedKey());
    await prefs.remove(_kStorageModeKey);
    // The NETWORK POSTURE goes too (audit XV-15). A wipe that leaves the proxy
    // exit, the VPN app list, CIDR and DNS, the preview mode and the
    // always-online choice behind is not the wipe the confirmation promised:
    // someone who wiped because they had to would still have all of it on
    // disk, in plaintext, readable without opening anything.
    for (final key in kIdentityPosturePrefKeys) {
      await prefs.remove(identityScopedPrefKey(key));
    }
    _lastTeardown = TeardownOutcome(List.unmodifiable(_incomplete));
    state = const AppState(AppPhase.onboarding);
  }

  /// IRREVERSIBLE WIPE: delete the on-disk container, destroying EVERY identity
  /// it holds — including any hidden/decoy master — then return to onboarding.
  ///
  /// Unlike [startOver], which only forgets that this device set up a container
  /// (the encrypted file is left intact, so the same password still opens it
  /// later), this scrubs the file itself. There is NO recovery: by design the
  /// spaces are unrecoverable without the container. The UI must gate this
  /// behind an explicit, clearly-worded confirmation.
  /// Destroy everything, and say what survived (audit report11 XV-H3).
  ///
  /// Every step here is best-effort by design — a wipe that aborts halfway
  /// because one directory was locked would leave MORE behind than one that
  /// carries on. What was wrong was not the tolerance, it was the silence: the
  /// phase flipped to onboarding unconditionally, the function returned
  /// nothing, and a person whose container was still on disk was shown the
  /// same screen as one whose container was gone.
  ///
  /// The returned list names what is still there, checked by looking rather
  /// than by trusting the delete call. Empty means empty.
  Future<List<String>> wipeContainers() async {
    _endLifecycle(); // same window as [lock] — see [_lifecycle]
    _incomplete.clear();
    await _stopVpnTunnelRecorded();
    await _teardownSession();
    await _teardownRealStack();
    await _stopBackgroundService();
    await _cleanRuntimeBase();
    // Guarded, unlike everything after it used to be. A wedged storage worker
    // threw here and took the whole rest of the wipe with it — including the
    // container delete on the very next lines. The one step whose failure
    // could skip the deletion was the one step with no handler.
    try {
      await ref.read(storageProvider).close();
    } catch (e) {
      devLog(() => 'xVeil[wipe]: storage close failed, deleting anyway: $e');
    }
    _clearMasterSession();

    // Delete the container file when we know its path (native/deniable build).
    // On the in-memory/loopback path there is no file — startOver semantics.
    final path = ref.read(deniableBootProvider)?.storePath;
    if (path != null) {
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (e) {
        devLog(() => 'xVeil[wipe]: failed to delete container at $path: $e');
      }
      // The large-file tier lives BESIDE the container, not inside it, so
      // deleting the container left the whole blob directory standing (audit
      // XV-11). The ciphertext is unreadable once the keys go with the volume,
      // but "unreadable" is not "absent": the file count, the sizes and the
      // directory's very existence still say that this machine ran xVeil and
      // roughly how much was stored. A wipe that leaves a shaped artifact
      // behind is not the wipe the confirmation dialog promised.
      final blobRoot = blobRootFor(path);
      try {
        if (await blobRoot.exists()) await blobRoot.delete(recursive: true);
      } catch (e) {
        devLog(
          () => 'xVeil[wipe]: failed to delete blobs at ${blobRoot.path}: $e',
        );
      }
    }

    final prefs = await ref.read(prefsProvider.future);
    await prefs.remove(_onboardedKey());
    await prefs.remove(_kStorageModeKey);
    // The NETWORK POSTURE goes too (audit XV-15). A wipe that leaves the proxy
    // exit, the VPN app list, CIDR and DNS, the preview mode and the
    // always-online choice behind is not the wipe the confirmation promised:
    // someone who wiped because they had to would still have all of it on
    // disk, in plaintext, readable without opening anything.
    for (final key in kIdentityPosturePrefKeys) {
      await prefs.remove(identityScopedPrefKey(key));
    }
    // The speech model too, on THIS path only. It is ~57 MiB fetched from a
    // public CDN, so its presence on disk says the user enabled voice
    // transcription and roughly when — a fact about how they used the app that
    // survives a wipe of everything the app itself stored. Re-downloadable, so
    // nothing is lost that cannot be got back.
    //
    // NOT removed by `startOver`: that is the forgot-my-password escape hatch,
    // which deliberately leaves the container in place, and taking a 57 MiB
    // download away from someone who mistyped a password would be a surprise
    // rather than a wipe.
    //
    // The model's own directory is resolved and KEPT, because the re-stat at
    // the end has to look at the place the delete aimed at. Asking the platform
    // channel a second time down there would be a second answer to the same
    // question — and the case worth reporting is precisely the one where that
    // channel has already misbehaved.
    Directory? speechRoot;
    // Whether we never learned where to look, as opposed to looking and
    // finding nothing. The re-stat below is skipped when the root is null, so
    // without this a platform channel that failed reported as a clean wipe —
    // and the comment on that resolve already says the case worth reporting is
    // precisely the one where the channel has misbehaved.
    var speechUnknown = false;
    try {
      // Bounded for the same reason as the tunnel: resolving the support
      // directory goes through a platform channel, and a wipe that hangs on an
      // unresponsive plugin is worse than one that leaves a re-downloadable
      // file behind.
      final store = ref.read(whisperModelStoreProvider);
      speechRoot = await store.modelDirectory().timeout(
        const Duration(seconds: 3),
      );
      await store.remove().timeout(const Duration(seconds: 3));
    } catch (e) {
      // Only when the PATH is still unknown. A resolve that succeeded and a
      // remove that then failed is the ordinary case the re-stat handles.
      speechUnknown = speechRoot == null;
      devLog(() => 'xVeil[wipe]: failed to remove the speech model: $e');
    }
    // The translation models too, and for a STRONGER reason than the speech
    // one. Whisper's model is a single generic file: its presence says the
    // person enabled transcription. A translation model is one directory per
    // DIRECTION, named `ru-en`, so what survives a wipe is a list of the
    // languages they read — a fact about the person, not just about their use
    // of the app, sitting in plaintext directory names that need nothing
    // unlocked to read.
    //
    // Same bound and the same best-effort handling: resolving the support
    // directory goes through a platform channel, and a wipe that hangs on an
    // unresponsive plugin is worse than one that leaves a re-downloadable
    // file behind.
    Directory? translationRoot;
    var translationsUnknown = false;
    try {
      translationRoot = await ref
          .read(translationModelsRootProvider)()
          .timeout(const Duration(seconds: 3));
      if (translationRoot != null && translationRoot.existsSync()) {
        translationRoot.deleteSync(recursive: true);
      }
    } catch (e) {
      // A null root RETURNED is a platform that has no such directory, which
      // is nothing to report. A throw before we had one means we do not know.
      translationsUnknown = translationRoot == null;
      devLog(() => 'xVeil[wipe]: failed to remove translation models: $e');
    }
    // Look, do not assume. `delete()` returning without throwing is not the
    // same as the file being gone: a partial recursive delete leaves children,
    // and a platform can report success on a handle it has only unlinked.
    final remaining = <String>[];
    if (path != null && File(path).existsSync()) remaining.add('container');
    if (path != null && blobRootFor(path).existsSync()) {
      remaining.add('files');
    }
    // The two model deletes belong here as much as the container does, and for
    // a while they were the only steps of the wipe that could NOT be reported.
    // They are also the likeliest to fail: each goes through a platform
    // channel, each is bounded by a timeout, and each catch swallows
    // everything. So the one arrangement in which a wipe most plausibly leaves
    // something behind was the one arrangement it told the person nothing
    // about — "everything went" over a directory that is still there.
    //
    // The `.part` file counts too. An interrupted download says the same thing
    // about this person as a finished one does, and `remove()` deletes both.
    if (speechRoot != null) {
      final model = '${speechRoot.path}/${WhisperModelStore.fileName}';
      if (File(model).existsSync() || File('$model.part').existsSync()) {
        remaining.add('speech-model');
      }
    }
    // Named apart from the speech model because what survives is different in
    // kind. Whisper's file is generic: its presence says transcription was
    // enabled. A translation model is one directory per DIRECTION, `ru-en`, so
    // what is left is the list of languages this person reads — in plaintext
    // directory names that need nothing unlocked to read.
    if (translationRoot != null && translationRoot.existsSync()) {
      remaining.add('translations');
    }
    // Unknown is its own answer, and the one this re-stat used to lose. Both
    // model deletes go through a platform channel and both catches swallow
    // everything, so a channel that failed left the root null, the check
    // skipped, and the person told the wipe was complete over a directory
    // nobody had looked at.
    if (speechUnknown) remaining.add('speech-model-unknown');
    if (translationsUnknown) remaining.add('translations-unknown');
    // A survivor that is not on disk. The wipe reported only what it could
    // re-stat, so a tunnel that would not stop, a node that outlived its
    // budget or a container whose lock was never released showed the same
    // screen as a clean wipe — while the network side of this person was
    // still up (report17 XV17-M14).
    _lastTeardown = TeardownOutcome(List.unmodifiable(_incomplete));
    if (_incomplete.isNotEmpty) remaining.add('network');
    if (remaining.isNotEmpty) {
      errorJournal.record(
        kind: 'wipe-incomplete',
        error: StateError('still on disk after wipe: ${remaining.join(', ')}'),
        atMs: DateTime.now().millisecondsSinceEpoch,
      );
    }

    // The phase still flips. Parking someone on a lock screen for a container
    // that may already be gone is its own failure, and in a deniable app the
    // wrong screen is a disclosure.
    state = const AppState(AppPhase.onboarding);
    return remaining;
  }

  /// What to show for a space that opened but holds NO profile record.
  ///
  /// An anomaly, not a normal state: the space unlocked, so the keys were
  /// right, and every space this app creates gets a record written at creation.
  /// So an absent one means something removed it, and the clash guards — which
  /// read this record's presence to decide whether a space is free to write a
  /// roster into — will read that space as empty.
  ///
  /// It is now an EMPTY profile, not a minted identity. This used to hand back
  /// a fresh random node id (audit XV-18), so the UI presented a
  /// plausible-looking identity, a DIFFERENT one on every call — "my node id
  /// keeps changing" was people describing exactly this. There is no id to
  /// invent any more: the session takes it from the transport either way, and
  /// all that is missing here is a display name.
  ///
  /// Recorded every time, because the guards' reading of it is the part that
  /// can still cost data.
  UserProfile _profileOfSpaceWithNoRecord() {
    devLog(
      () =>
          'xVeil[identity]: space opened but holds NO profile record. The '
          'container unlocked, so this is a missing record, not a wrong '
          'password.',
    );
    errorJournal.record(
      kind: 'identity',
      error: StateError('space has no profile record'),
      stack: StackTrace.current,
      atMs: DateTime.now().millisecondsSinceEpoch,
    );
    return const UserProfile();
  }

  /// Read the profile of an OPEN space for a session about to start.
  ///
  /// Returns null when the record is damaged — the caller must then return
  /// immediately, because this has already parked the app on
  /// [AppPhase.identityDamaged] and closed the space. Absent (the fresh/erased
  /// case) yields an empty profile, which costs a display name.
  ///
  /// The split exists because the two states want opposite handling and the old
  /// `loadIdentity() ?? _placeholderIdentity()` gave them the same one: a
  /// damaged record produced a random ready identity, the user saw a normal
  /// empty app, and the session then went on to write into the very space whose
  /// contents could not be read (audit XV-13).
  Future<UserProfile?> _loadProfileOrHalt(Storage storage) async {
    try {
      return await storage.loadProfile() ?? _profileOfSpaceWithNoRecord();
    } on CorruptIdentityRecord catch (e, st) {
      await _haltOnDamagedIdentity(e, st);
      return null;
    }
  }

  /// Stop everything and park on [AppPhase.identityDamaged] WITHOUT writing.
  ///
  /// Order matters: the node never boots (booting mines and STORES a node
  /// config into this space), the space is closed, and only then does the phase
  /// change. Nothing between the failed read and here touches storage, so the
  /// damaged bytes are exactly as they were found.
  Future<void> _haltOnDamagedIdentity(
    CorruptIdentityRecord e,
    StackTrace st,
  ) async {
    devLog(
      () =>
          'xVeil[identity]: DAMAGED identity record — refusing to open a '
          'session over it: $e',
    );
    errorJournal.record(
      kind: 'identity',
      error: e,
      stack: st,
      atMs: DateTime.now().millisecondsSinceEpoch,
    );
    try {
      await _teardownSession();
    } catch (_) {}
    try {
      await _teardownRealStack();
    } catch (_) {}
    try {
      await ref.read(storageProvider).close();
    } catch (_) {}
    _clearMasterSession();
    state = const AppState(AppPhase.identityDamaged);
  }
}

/// The storage-maintenance readout: what the container costs on disk, what
/// compacting it would give back, and whether that is worth saying unprompted.
///
/// Built ONLY by [AppController.estimateStorageReclaim] so the "is this worth
/// mentioning" rule has a single home.
final class StorageReclaim {
  const StorageReclaim({
    required this.sizeBytes,
    required this.reclaimableBytes,
    required this.deadFraction,
    required this.worthCompacting,
  });

  /// Current on-disk size of the container.
  final int sizeBytes;

  /// Roughly what a compaction would return to the filesystem. An estimate:
  /// dead slots are counted, not measured, and the rewrite also drops the
  /// commit history — so the real result tends to be a little better.
  final int reclaimableBytes;

  /// Share of the file that is dead padding, in `[0, 1]`.
  final double deadFraction;

  /// Whether the app should point this out on its own.
  ///
  /// It is a DISK-SPACE remark and nothing more: the container is healthy, the
  /// data is intact, and the padding is the deniability design working as
  /// intended. Nothing here may be dressed up as a warning, and nothing here
  /// starts a compaction — that needs the password and tears the session down,
  /// so it stays the user's explicit act.
  final bool worthCompacting;
}

final appControllerProvider = NotifierProvider<AppController, AppState>(
  AppController.new,
);

/// What a teardown could not confirm it finished.
///
/// "Locked" is a claim about the network, not about the screen: the tunnel is
/// down, the node has stopped, the session is disposed and the container's
/// lock is released. Each leg already knew when it had failed — and each one
/// wrote that into a journal nobody reads and then returned as if it had
/// worked, so `lock`, `startOver` and the API's `/v1/account/lock` all
/// reported a closed privacy boundary over a tunnel that might still be
/// carrying traffic (report17 XV17-M14).
///
/// Codes, not sentences, for the same reason [WipeReport] uses them: the
/// sentence has to be a translated one, and this list also crosses the API.
@immutable
class TeardownOutcome {
  const TeardownOutcome(this.incomplete);

  /// Empty means every critical leg was CONFIRMED finished. Anything in here
  /// is a leg that failed, timed out, or was abandoned — `vpn`, `session`,
  /// `node`, `container-lock-unknown`, or `leg:<name>` for a step of [lock]
  /// that threw.
  final List<String> incomplete;

  bool get complete => incomplete.isEmpty;

  static const clean = TeardownOutcome([]);
}

/// What a wipe could not delete, as a fact about the app rather than about a
/// screen.
///
/// See [WipeReportController] for why it has to be one.
@immutable
class WipeReport {
  const WipeReport({required this.remaining, required this.stopped});

  /// The codes [AppController.wipeContainers] returns for what it re-stat'd and
  /// found still present (`container`, `files`, `speech-model`,
  /// `translations`), plus what it could not re-stat at all
  /// (`speech-model-unknown`, `translations-unknown` — the platform channel
  /// that resolves those roots failed, so nothing looked). Codes rather than
  /// sentences, precisely so the sentence can be a translated one.
  final List<String> remaining;

  /// The wipe threw instead of returning. Nothing was verified, so a report
  /// with this set cannot claim the rest was destroyed.
  final bool stopped;
}

/// Runs the irreversible wipe and holds its verdict until something has shown
/// it.
///
/// This exists because the screen that ASKS for a wipe cannot be the screen
/// that reports it. [AppController.wipeContainers] flips the phase to
/// `onboarding` as its last act — deliberately, and for a reason recorded
/// there: parking someone on a lock screen for a container that may already be
/// gone is its own disclosure. The lock screen used to raise the dialog itself,
/// and nobody ever saw it: the router redirects on that flip, and the dialog is
/// a ROUTE over the page the redirect removes, so the navigator took it away
/// again in the same frame it appeared. See `_LockScreenState._runWipe` for the
/// measurement, including which suspect turned out to be innocent.
///
/// What made it invisible is that every test mounted the lock screen with no
/// router at all: nothing ever swapped a page, the dialog stayed, and the suite
/// was green over an app that never showed it.
///
/// A provider is what outlives the flip. It is not disposed by a route change,
/// so the verdict is written from here, after the phase has already moved, and
/// a host above the router paints it over wherever the flip landed.
class WipeReportController extends Notifier<WipeReport?> {
  @override
  WipeReport? build() => null;

  /// Guards Retry against a second press while the first is still running —
  /// the dialog stays up for the whole wipe, so the button is live throughout.
  bool _running = false;

  /// Run the wipe and publish what survived. Never throws: a wipe that failed
  /// to report is the defect this whole class is about, and an exception
  /// escaping into an unawaited future would be exactly that again.
  Future<void> runWipe() async {
    if (_running) return;
    _running = true;
    try {
      final remaining = await ref
          .read(appControllerProvider.notifier)
          .wipeContainers();
      if (!ref.mounted) return;
      state = remaining.isEmpty
          ? null
          : WipeReport(remaining: remaining, stopped: false);
    } catch (error, stack) {
      // A throw became an uncaught async error, the confirmation closed and the
      // screen sat there — which reads as "nothing happened" for the one action
      // that cannot be undone.
      errorJournal.record(
        kind: 'wipe',
        error: error,
        stack: stack,
        atMs: DateTime.now().millisecondsSinceEpoch,
      );
      if (!ref.mounted) return;
      state = const WipeReport(remaining: [], stopped: true);
    } finally {
      _running = false;
    }
  }

  /// The person has read it.
  void dismiss() => state = null;
}

final wipeReportProvider = NotifierProvider<WipeReportController, WipeReport?>(
  WipeReportController.new,
);
