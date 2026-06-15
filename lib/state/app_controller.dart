import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ids.dart';
import '../data/veil_stack.dart';
import '../domain/identity.dart';
import '../domain/roster.dart';
import 'keep_all_online_controller.dart';
import 'providers.dart';

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

class AppState {
  const AppState(
    this.phase, {
    this.identity,
    this.unlockError = false,
    this.identities = const [],
    this.activeIdentity,
  });

  final AppPhase phase;
  final Identity? identity;
  final bool unlockError;

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
  }) =>
      AppState(
        phase ?? this.phase,
        identity: identity ?? this.identity,
        unlockError: unlockError ?? false,
        identities: identities ?? this.identities,
        activeIdentity: activeIdentity ?? this.activeIdentity,
      );
}

const _kOnboardedKey = 'onboarded';
const _kStorageModeKey = 'storage_mode';

class AppController extends Notifier<AppState> {
  /// Roster of the master unlocked this session — cached for the whole master
  /// session so identity switching needs no re-prompt. Holds child SpaceKeys;
  /// cleared on lock/start-over. Null in single-identity mode.
  List<RosterEntry>? _pendingRoster;

  /// Label of the identity currently active in a master session (null in
  /// single-identity mode).
  String? _activeLabel;

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
      state = state.copyWith(phase: AppPhase.preparingNode);
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
      state = state.copyWith(unlockError: true);
      return;
    }
    // Master vs identity is decided AFTER unlock by inspecting contents (never
    // from disk — deniability). A roster ⇒ master: read it, then release the
    // exclusive lock (only one space open at a time) and let the user pick.
    final roster = await storage.loadRoster();
    if (roster != null && roster.isNotEmpty) {
      _pendingRoster = roster;
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
          debugPrint('xVeil[all-online]: boot FAILED -> picker: $e\n$st');
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
    state = state.copyWith(phase: AppPhase.preparingNode);
    final session = ref.read(sessionBuilderProvider)(
      storePath: boot.storePath!,
      runtimeDir: boot.runtimeDir,
      listenPort: boot.listenPort,
    );
    await session.bootAll(roster);
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
    final label = _activeLabel;
    if (label == null || _pendingRoster == null) return false;
    for (final e in _pendingRoster!) {
      if (e.label == label) return e.anonymous;
    }
    return false;
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
      if (active.isOpen) currentKeys = active.exportSpaceKeys();
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

    // Base roster: an EXISTING master → its OWN on-disk roster (append to it); a
    // fresh master → wrap the current single identity as the first child.
    final base = <RosterEntry>[
      if (existingRoster != null)
        ...existingRoster
      else if (currentKeys != null)
        RosterEntry(label: existingLabel, spaceKeys: currentKeys),
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
        spaceKeys: storage.exportSpaceKeys(),
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
    // Deniable path: now that the space is open, boot the in-process node from
    // the in-space identity (mining it on first run). Best-effort — never block
    // entering the session if the node fails. Show a "setting up" screen while
    // it provisions (the mining runs off the UI isolate; see startDeniable).
    if (ref.read(deniableBootProvider) != null &&
        ref.read(realStackProvider) == null) {
      state = state.copyWith(phase: AppPhase.preparingNode);
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
      );
      ref.read(realStackProvider.notifier).state = stack;
      debugPrint('xVeil[deniable]: node up, invite=${stack.myInvite.nodeId.short}');
    } catch (e, st) {
      // Stay on loopback — a node-boot failure must not trap the user — but
      // surface WHY so we can fix it (the stack trace points at the failing step).
      debugPrint('xVeil[deniable]: boot FAILED -> loopback: $e\n$st');
    }
  }

  Future<void> lock() async {
    await _teardownSession(); // all-online: stop every node + release the lock
    await _teardownRealStack();
    await ref.read(storageProvider).close();
    _clearMasterSession();
    state = const AppState(AppPhase.locked);
  }

  void _clearMasterSession() {
    _pendingRoster = null; // drop cached child keys
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

  /// Escape hatch from the lock screen: forget the onboarded flag and return to
  /// onboarding (e.g. forgotten password, or a moved/missing container). The
  /// existing container file is left untouched on disk — deniability means we
  /// can't and shouldn't prove it exists; the user simply sets up anew.
  Future<void> startOver() async {
    await _teardownSession();
    await _teardownRealStack();
    await ref.read(storageProvider).close();
    _clearMasterSession();
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
