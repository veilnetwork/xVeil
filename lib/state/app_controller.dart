import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ids.dart';
import '../data/veil_stack.dart';
import '../domain/identity.dart';
import '../domain/roster.dart';
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
  });

  final AppPhase phase;
  final Identity? identity;
  final bool unlockError;

  /// In [AppPhase.pickingIdentity], the labels of the identities the unlocked
  /// master manages (the picker's options). Empty otherwise.
  final List<String> identities;

  AppState copyWith({
    AppPhase? phase,
    Identity? identity,
    bool? unlockError,
    List<String>? identities,
  }) =>
      AppState(
        phase ?? this.phase,
        identity: identity ?? this.identity,
        unlockError: unlockError ?? false,
        identities: identities ?? this.identities,
      );
}

const _kOnboardedKey = 'onboarded';
const _kStorageModeKey = 'storage_mode';

class AppController extends Notifier<AppState> {
  /// Roster of the master unlocked this session, cached between [unlock] (which
  /// reads it then releases the master's lock) and [pickIdentity]. Holds child
  /// SpaceKeys — cleared on lock/start-over. Null in single-identity mode.
  List<RosterEntry>? _pendingRoster;

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
      await storage.close();
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
    final identity = await storage.loadIdentity() ?? _placeholderIdentity();
    await _enterSession(identity);
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
    state = AppState(AppPhase.ready, identity: effective);
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
    await _teardownRealStack();
    await ref.read(storageProvider).close();
    _pendingRoster = null; // drop cached child keys
    state = const AppState(AppPhase.locked);
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
    await _teardownRealStack();
    await ref.read(storageProvider).close();
    _pendingRoster = null;
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
