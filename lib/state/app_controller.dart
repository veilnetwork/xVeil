import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ids.dart';
import '../data/node/node_controller.dart';
import '../data/veil_stack.dart';
import '../domain/identity.dart';
import '../domain/roster.dart';
import 'background_node_controller.dart';
import 'keep_all_online_controller.dart';
import 'proxy_routing_controller.dart';
import 'providers.dart';
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
  }) =>
      AppState(
        phase ?? this.phase,
        identity: identity ?? this.identity,
        unlockError: unlockError ?? false,
        identities: identities ?? this.identities,
        activeIdentity: activeIdentity ?? this.activeIdentity,
        preparingReason: preparingReason ?? PreparingReason.node,
      );
}

const _kOnboardedKey = 'onboarded';
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
    final onboarded = prefs.getBool(_kOnboardedKey) ?? false;
    state = AppState(onboarded ? AppPhase.locked : AppPhase.onboarding);
  }

  /// Finish first-launch setup: persist the new identity into a freshly
  /// created space and start the session.
  Future<void> completeOnboarding({
    required Identity identity,
    required String password,
    required StorageMode mode,
  }) async {
    // Show the "setting up" screen up front and let it paint a frame BEFORE the
    // CPU-heavy work begins — creating the container (Argon2id KDF) and
    // provisioning the node identity both block briefly, and without this the
    // onboarding window looks frozen on "Done". Only in deniable mode (the
    // loopback/test path is instant, so it would just flash).
    if (ref.read(deniableBootProvider) != null) {
      state = state.copyWith(
          phase: AppPhase.preparingNode,
          preparingReason: PreparingReason.firstRunMining);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    final storage = ref.read(storageProvider);
    await storage.open(password: password, createIfMissing: true);
    await storage.saveIdentity(identity);

    final prefs = await ref.read(prefsProvider.future);
    await prefs.setBool(_kOnboardedKey, true);
    await prefs.setString(_kStorageModeKey, mode.name);

    await _enterSession(identity);
  }

  /// Returning user: try to unlock the space with [password].
  Future<void> unlock(String password) async {
    // Show the loading screen BEFORE the heavy work: opening the real container
    // runs Argon2 (and, in keep-all-online, boots every node) on this isolate,
    // which freezes the UI. Switch to the preparing screen and yield a frame so
    // the "opening your container" message paints before the freeze — otherwise
    // the unlock button just hangs with no feedback. Only on the real deniable
    // path (the loopback/test opener is instant, so it would just flash).
    if (ref.read(deniableBootProvider) != null) {
      state = state.copyWith(
          phase: AppPhase.preparingNode,
          preparingReason: PreparingReason.unlocking);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    final storage = ref.read(storageProvider);
    bool ok;
    try {
      ok = await storage.open(password: password);
    } catch (_) {
      // Wrong password, missing or corrupt container — never let unlock throw
      // (that would freeze the lock screen's spinner). Surface as an error.
      ok = false;
    }
    if (!ok) {
      // Back to the lock screen with the error (we're on preparingNode now).
      state = const AppState(AppPhase.locked, unlockError: true);
      return;
    }
    // Master vs identity is decided AFTER unlock by inspecting contents (never
    // from disk — deniability). A roster ⇒ master: read it, then release the
    // exclusive lock (only one space open at a time) and let the user pick.
    final roster = await storage.loadRoster();
    if (roster != null && roster.isNotEmpty) {
      _pendingRoster = roster;
      // Cache the master's keys so roster edits can reopen it without a
      // password re-prompt (held in memory like the child keys above).
      _masterKeys = await storage.exportSpaceKeys();
      await storage.close(); // release the single-space lock first
      // Opt-in "all identities online": host every space + run every node at
      // once (needs the real container path). Else the one-active picker.
      final boot = ref.read(deniableBootProvider);
      if (ref.read(keepAllOnlineProvider) && boot?.storePath != null) {
        try {
          await _enterAllOnline(roster, boot!);
          return;
        } catch (e, st) {
          // All-online boot failed — never strand the user on a stuck unlock.
          // Tear down any half-built session and fall back to the one-active
          // picker (which is known-good). Surface WHY so we can fix it.
          devLog(() => 'xVeil[all-online]: boot FAILED -> picker: $e\n$st');
          await _teardownSession();
        }
      }
      state = state.copyWith(
        phase: AppPhase.pickingIdentity,
        identities: [for (final e in roster) e.label],
      );
      return;
    }
    // Single identity space — unchanged path.
    final identity = await storage.loadIdentity() ?? _placeholderIdentity();
    await _enterSession(identity);
  }

  /// All-online mode: open the container as one multi-space, boot every
  /// identity's node + messaging pipeline at once, and show the first identity.
  /// Switching later just re-points the view — no node goes offline.
  Future<void> _enterAllOnline(
      List<RosterEntry> roster, DeniableBootConfig boot) async {
    // Still part of the unlock from the user's view (opening + booting all).
    state = state.copyWith(
        phase: AppPhase.preparingNode,
        preparingReason: PreparingReason.unlocking);
    final session = ref.read(sessionBuilderProvider)(
      storePath: boot.storePath!,
      runtimeDir: boot.runtimeDir,
      listenPort: boot.listenPort,
    );
    await session.bootAll(roster);
    await ref.read(backgroundNodeProvider.notifier).applyIfNodeUp(nodeUp: true);
    ref.read(sessionProvider.notifier).state = session;
    final first = roster.first.label;
    await _activateOnline(first, [for (final e in roster) e.label]);
  }

  /// Point the providers (active storage/messaging via [activeIdentityProvider],
  /// transport/invite via [realStackProvider]) at a hosted identity and surface
  /// it. Used on entry and on every all-online switch — no teardown.
  Future<void> _activateOnline(String label, List<String> identities) async {
    final session = ref.read(sessionProvider)!;
    _activeLabel = label;
    ref.read(activeIdentityProvider.notifier).state = label;
    final stack = session.stackFor(label);
    ref.read(realStackProvider.notifier).state = stack;
    final st = session.storageFor(label);
    final identity =
        (st != null ? await st.loadIdentity() : null) ?? _placeholderIdentity();
    final effective = stack != null
        ? Identity(
            nodeId: stack.myInvite.nodeId,
            displayName: identity.displayName,
            username: identity.username)
        : identity;
    state = AppState(AppPhase.ready,
        identity: effective, identities: identities, activeIdentity: label);
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
      state = const AppState(AppPhase.locked, unlockError: true);
      return;
    }
    _activeLabel = label;
    final identity = await storage.loadIdentity() ?? _placeholderIdentity();
    await _enterSession(identity);
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
    await _teardownRealStack(); // stop the current identity's node
    await ref.read(storageProvider).close(); // release the lock
    state = state.copyWith(phase: AppPhase.preparingNode);
    final storage = ref.read(storageProvider);
    if (!await storage.openWithKeys(entry.spaceKeys)) {
      state = const AppState(AppPhase.locked, unlockError: true);
      return;
    }
    _activeLabel = label;
    final identity = await storage.loadIdentity() ?? _placeholderIdentity();
    await _enterSession(identity);
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

    // Reboot the node so the new routing takes effect. The space stays open
    // (teardown only stops the node); _enterSession re-reads the setting and
    // boots with the new anonymity, then refreshes the home state + node id.
    await _teardownRealStack();
    final identity = await storage.loadIdentity() ?? _placeholderIdentity();
    await _enterSession(identity);
    return true;
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
    final identity = await storage.loadIdentity() ?? _placeholderIdentity();
    await _enterSession(identity);
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

    final storage = ref.read(storageProvider);
    if (!await storage.openWithKeys(masterKeys)) {
      await _recoverToActive();
      return false;
    }
    // Edit the master's ON-DISK roster (source of truth), then mirror in memory.
    final onDisk = await storage.loadRoster() ?? roster;
    final updated = [
      for (final e in onDisk)
        if (e.label == label)
          RosterEntry(label: e.label, spaceKeys: e.spaceKeys, anonymous: anonymous)
        else
          e,
    ];
    await storage.saveRoster(updated);
    await storage.close();
    _pendingRoster = updated;

    // Re-enter so the change takes effect (a node's anonymity is fixed at its
    // boot, so editing the roster requires the node to re-boot under it).
    await _reEnterAfterRosterEdit(updated, prevActive, hadSession);
    return true;
  }

  /// Re-enter a master session after editing its roster (anonymity toggle,
  /// bind, unbind, delete). [updated] is the new roster; [target] is the label
  /// to return to — if it is null or no longer in [updated] (e.g. the active
  /// identity was just removed), fall back to the picker (one-active) or the
  /// first identity (all-online). Shared so every roster-edit re-enters
  /// identically. Caller must already have torn the session/stack down + saved.
  Future<void> _reEnterAfterRosterEdit(
      List<RosterEntry> updated, String? target, bool hadSession) async {
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
          devLog(() => 'xVeil[roster]: all-online re-enter FAILED -> picker: $e\n$st');
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
    _pendingRoster = updated;

    // If we just unbound the ACTIVE identity it is gone from [updated], so the
    // helper falls back to the picker; otherwise it restores the active view.
    await _reEnterAfterRosterEdit(updated, prevActive, hadSession);
    return true;
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
    _pendingRoster = updated;

    await _reEnterAfterRosterEdit(updated, prevActive, hadSession);
    return true;
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

    final storage = ref.read(storageProvider);
    // Open the identity by its OWN password (must already exist — no create).
    if (!await storage.open(password: identityPassword)) {
      await _recoverToActive();
      return false;
    }
    // Only a PLAIN identity can be bound — a space with a roster is a master.
    final isPlainIdentity = await storage.loadIdentity() != null &&
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
    if (onDisk.any((e) =>
        e.label == label || listEquals(e.spaceKeys, keys))) {
      await storage.close();
      await _recoverToActive();
      return false;
    }
    final updated = [...onDisk, RosterEntry(label: label, spaceKeys: keys)];
    await storage.saveRoster(updated);
    await storage.close();
    _pendingRoster = updated;

    await _reEnterAfterRosterEdit(updated, prevActive, hadSession);
    return true;
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
    final storage = ref.read(storageProvider);

    // Open/create the master and decide append-vs-convert from its ON-DISK
    // state — never from in-memory session state.
    if (!await storage.open(password: masterPassword, createIfMissing: true)) {
      await _recoverToActive();
      return false;
    }
    final existingRoster = await storage.loadRoster();
    final masterHasIdentity = await storage.loadIdentity() != null;
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
            anonymous: _singleAnonymous),
    ];

    // Refuse a duplicate label — two roster entries with the same label would
    // break switching (it resolves an identity by label).
    if (base.any((e) => e.label == label)) {
      await _recoverToActive();
      return false;
    }

    // Create + name the new identity space (its node config is mined lazily on
    // first boot, like onboarding). Distinct child passwords are assumed (the UI
    // instructs this; the design can't deniably dedupe passwords).
    if (!await storage.open(password: password, createIfMissing: true)) {
      await _recoverToActive();
      return false;
    }
    await storage.saveIdentity(generateIdentity(displayName: label));
    final roster = <RosterEntry>[
      ...base,
      RosterEntry(
        label: label,
        spaceKeys: await storage.exportSpaceKeys(),
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
    _masterKeys = await storage.exportSpaceKeys();
    await storage.close();

    // Enter the new identity (one-active). If the user has keep-all-online on,
    // the next unlock brings every identity — including this one — back online.
    _pendingRoster = roster;
    _activeLabel = null;
    await pickIdentity(label);
    return true;
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

    final storage = ref.read(storageProvider);
    var ok = false;
    if (await storage.open(password: duressPassword, createIfMissing: true)) {
      // Refuse to write into anything that already exists — a clash means the
      // password opened a real identity (has an identity) or an existing master
      // (has a roster); writing the decoy roster would clobber it.
      final clash = await storage.loadIdentity() != null ||
          await storage.loadRoster() != null;
      if (!clash) {
        await storage.saveRoster(decoy);
        ok = true;
      }
      await storage.close();
    }

    // Restore the user's active identity.
    if (activeLabel != null) {
      _activeLabel = null;
      await pickIdentity(activeLabel);
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

  Future<void> _enterSession(Identity identity) async {
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
      state = state.copyWith(
        phase: AppPhase.preparingNode,
        preparingReason:
            firstRun ? PreparingReason.firstRunMining : PreparingReason.node,
      );
    }
    await _ensureRealStack();
    final stack = ref.read(realStackProvider);
    if (stack == null) {
      // Loopback / legacy: kick the placeholder controller without blocking.
      ref.read(nodeControllerProvider).start();
    }
    // In real mode the user's identity IS the node's identity — show the real
    // node id (and invite) rather than the local placeholder.
    final effective = stack != null
        ? Identity(
            nodeId: stack.myInvite.nodeId,
            displayName: identity.displayName,
            username: identity.username,
          )
        : identity;
    // Carry the master roster + active identity through the session so the UI
    // can offer a switcher (empty/null in single-identity mode).
    state = AppState(
      AppPhase.ready,
      identity: effective,
      identities: [for (final e in _pendingRoster ?? const []) e.label],
      activeIdentity: _activeLabel,
    );
  }

  /// Build the in-process deniable stack post-unlock (storage is open) when the
  /// embedded boot is configured and not already running.
  Future<void> _ensureRealStack() async {
    if (ref.read(realStackProvider) != null) return;
    final boot = ref.read(deniableBootProvider);
    if (boot == null) return;
    try {
      final stack = await RealVeilStack.startDeniable(
        storage: ref.read(storageProvider),
        runtimeDir: boot.runtimeDir,
        listenPort: boot.listenPort,
        anonymous: _activeAnonymous(),
        lazyMining: _singleLazyMining,
        // Deliberately DON'T inject `[[bootstrap_peers]]` into the node config:
        // the node dials the same nodes from its compiled-in BUILTIN_SEEDS (the
        // proven-connecting path), and injecting explicit peers made
        // veil_node_apply_config fail with ENOENT on Android (a per-peer persist
        // path that doesn't exist in the ephemeral runtime dir). The seeds are
        // still used as mailbox-relay candidates — that path reads
        // boot.bootstrapPeers directly (see messaging.dart), independent of the
        // node config — so the rendezvous ad still publishes.
        bootstrapPeers: const [],
        obfs4Psk: boot.obfs4Psk,
        proxy: ref.read(proxyRoutingProvider),
      );
      ref.read(realStackProvider.notifier).state = stack;
      // Real node is up — clear any pending boot status so the UI follows the
      // real controller's live state, not a stale "connecting…".
      ref.read(nodeBootStateProvider.notifier).state = null;
      // Keep the node alive when backgrounded if the user opted in (Android FGS).
      await ref
          .read(backgroundNodeProvider.notifier)
          .applyIfNodeUp(nodeUp: true);
      devLog(() => 'xVeil[deniable]: node up, invite=${stack.myInvite.nodeId.short}');
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

  Future<void> lock() async {
    await _teardownSession(); // all-online: stop every node + release the lock
    await _teardownRealStack();
    await _stopBackgroundService();
    await _cleanRuntimeBase();
    await ref.read(storageProvider).close();
    _clearMasterSession();
    state = const AppState(AppPhase.locked);
  }

  void _clearMasterSession() {
    _pendingRoster = null; // drop cached child keys
    _masterKeys = null; // drop cached master keys
    _activeLabel = null;
  }

  /// Tear down an all-online session (all nodes + messaging + the shared lock)
  /// and clear its providers. No-op when there is no session.
  Future<void> _teardownSession() async {
    final session = ref.read(sessionProvider);
    if (session == null) return;
    ref.read(sessionProvider.notifier).state = null;
    ref.read(activeIdentityProvider.notifier).state = null;
    await session.disposeAll();
  }

  Future<void> _teardownRealStack() async {
    final stack = ref.read(realStackProvider);
    if (stack != null) {
      await stack.dispose();
      ref.read(realStackProvider.notifier).state = null;
    }
  }

  /// Deniability: remove the ephemeral runtime-dir BASE (the parent that holds
  /// each identity's sockets + the public obfs4 PSK). Each stack already deletes
  /// its own subdir on dispose; this clears the now-empty base and any straggler
  /// so NO trace that nodes ran is left in temp after lock/wipe. Best-effort.
  /// Stop the background foreground service on teardown — no node is running
  /// once locked, so nothing should keep the process (or its notification) alive.
  Future<void> _stopBackgroundService() async {
    await ref.read(backgroundNodeProvider.notifier).applyIfNodeUp(nodeUp: false);
  }

  Future<void> _cleanRuntimeBase() async {
    final base = ref.read(deniableBootProvider)?.runtimeDir;
    if (base == null) return;
    try {
      final d = Directory(base);
      if (d.existsSync()) await d.delete(recursive: true);
    } catch (_) {/* leftover sockets are not worth failing teardown on */}
  }

  /// Escape hatch from the lock screen: forget the onboarded flag and return to
  /// onboarding (e.g. forgotten password, or a moved/missing container). The
  /// existing container file is left untouched on disk — deniability means we
  /// can't and shouldn't prove it exists; the user simply sets up anew.
  Future<void> startOver() async {
    await _teardownSession();
    await _teardownRealStack();
    await _stopBackgroundService();
    await _cleanRuntimeBase();
    await ref.read(storageProvider).close();
    _clearMasterSession();
    final prefs = await ref.read(prefsProvider.future);
    await prefs.remove(_kOnboardedKey);
    await prefs.remove(_kStorageModeKey);
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
  Future<void> wipeContainers() async {
    await _teardownSession();
    await _teardownRealStack();
    await _stopBackgroundService();
    await _cleanRuntimeBase();
    await ref.read(storageProvider).close();
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
    }

    final prefs = await ref.read(prefsProvider.future);
    await prefs.remove(_kOnboardedKey);
    await prefs.remove(_kStorageModeKey);
    state = const AppState(AppPhase.onboarding);
  }

  /// Generates a fresh sovereign identity. The real implementation derives a
  /// 24-word BIP-39 phrase + node id via veil_flutter; here we mint a random
  /// node id so the rest of the flow is exercisable.
  static Identity generateIdentity({String? displayName}) {
    final rnd = Random.secure();
    final bytes = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      bytes[i] = rnd.nextInt(256);
    }
    return Identity(nodeId: NodeId(bytes), displayName: displayName);
  }

  Identity _placeholderIdentity() => generateIdentity();
}

final appControllerProvider =
    NotifierProvider<AppController, AppState>(AppController.new);
