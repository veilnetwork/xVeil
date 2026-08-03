import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import '../data/storage/app_profile.dart';
import '../core/error_journal.dart';
import '../main.dart' show activeProfile;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;

import '../data/native_libs.dart';

import '../core/ids.dart';
import '../data/node/node_controller.dart';
import '../data/node/proxy_routing.dart';
import '../data/storage/on_disk_blob_store.dart';
import '../data/storage/storage.dart';
import '../data/veil_stack.dart';
import '../domain/identity.dart';
import '../domain/p2p_policy.dart';
import '../domain/roster.dart';
import 'background_node_controller.dart';
import 'keep_all_online_controller.dart';
import 'proxy_routing_controller.dart';
import 'identity_scoped_prefs.dart';
import 'notifications.dart';
import 'providers.dart';
import 'storage_preferences.dart';
import 'vpn_controller.dart';
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

/// Whether this install has been through first-launch setup, scoped to the
/// ACTIVE PROFILE — see [AppProfiles.scopedPrefKey] for why a global flag made
/// a new profile unopenable.
String _onboardedKey() => AppProfiles.scopedPrefKey('onboarded', activeProfile);
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

  Future<void> completeOnboarding({
    required Identity identity,
    required String password,
    required StorageMode mode,
    // The REAL master phrase shown on the recovery step (null on the
    // loopback/test path where the native generator is unavailable).
    String? identityPhrase,
    // The user picked "link to a device you already use": [identity] is a
    // temporary one that only has to reach the network, and the session this
    // opens should land on the device-link screen instead of chats.
    bool joinExisting = false,
  }) async {
    _pendingIdentityPhrase = identityPhrase;
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
    // dropped and `saveIdentity` ran anyway, against a storage that was not
    // open — so a failure here surfaced later, somewhere else, as a confusing
    // error against half-written onboarding state. Roll the phase back and say
    // what happened while the cause is still on the stack.
    final opened = await storage.open(password: password, createIfMissing: true);
    if (!opened) {
      state = state.copyWith(phase: AppPhase.onboarding, preparingReason: null);
      ref.read(pendingDeviceLinkProvider.notifier).state = false;
      takePendingIdentityPhrase();
      throw StateError(
        'storage.open refused the onboarding password; nothing was written',
      );
    }
    await storage.saveIdentity(identity);

    final prefs = await ref.read(prefsProvider.future);
    await prefs.setBool(_onboardedKey(), true);
    await prefs.setString(_kStorageModeKey, mode.name);

    await _enterSession(identity);
  }

  /// Guards [unlock] against overlapping runs (UI double-submit racing the
  /// debug hook's /unlock): two concurrent opens of the same container make the
  /// second fail `Busy` and the interleaved state writes can end on `locked`
  /// while the container is actually open — a stuck "wrong password" until
  /// restart. One unlock at a time; latecomers are dropped (the in-flight run
  /// ends in ready/locked either way).
  bool _unlockInFlight = false;

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
        _pendingRoster = roster;
        // Cache the master's keys so roster edits can reopen it without a
        // password re-prompt (held in memory like the child keys above).
        _masterKeys = await storage.exportSpaceKeys();
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
        state = state.copyWith(
          phase: AppPhase.pickingIdentity,
          identities: [for (final e in roster) e.label],
        );
        return;
      }
      // Single identity space — unchanged path.
      await _maybeAutoCompactBeforeSession(password);
      final identity = await _loadIdentityOrHalt(storage);
      if (identity == null) return; // damaged record — parked, nothing written
      await _enterSession(identity);
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
    final path = ref.read(deniableBootProvider)!.storePath!;
    final before = await File(path).length();
    state = state.copyWith(
      phase: AppPhase.preparingNode,
      preparingReason: PreparingReason.unlocking,
    );
    await _teardownSession();
    await _teardownRealStack();
    await ref.read(storageProvider).close(); // release the LOCK_EX
    try {
      await hv.compactKnownAsync(path, [
        Uint8List.fromList(utf8.encode(password)),
      ], dylibPath: _hvDylibPath());
    } finally {
      await unlock(password); // always reopen
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
      bootstrapPeers: boot.bootstrapPeers,
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
      await ref.read(backgroundNodeProvider.notifier).applyIfNodeUp(nodeUp: true);
    } catch (_) {
      // Best-effort: a teardown failure must not mask the original error, and
      // the original is what the caller needs to see.
      try {
        await session.disposeAll();
      } catch (_) {}
      rethrow;
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
  Future<void> _activateOnline(String label, List<String> identities) async {
    final session = ref.read(sessionProvider)!;
    _activeLabel = label;
    ref.read(activeIdentityProvider.notifier).state = label;
    final stack = session.stackFor(label);
    ref.read(realStackProvider.notifier).state = stack;
    final st = session.storageFor(label);
    // Same damaged-vs-absent split as the one-active path (audit XV-13), with
    // one honest difference: all-online has ALREADY booted every node by the
    // time we get here, so — unlike [_loadIdentityOrHalt] on unlock — this
    // cannot promise the space was never written to. It promises the smaller
    // thing that still matters: no session opens on top of a damaged record,
    // and no random identity is presented as if it were the user's.
    final Identity? loaded;
    try {
      loaded = st != null ? await st.loadIdentity() : null;
    } on CorruptIdentityRecord catch (e, stk) {
      await _haltOnDamagedIdentity(e, stk);
      return;
    }
    final identity = loaded ?? _placeholderIdentity();
    final effective = stack != null
        ? Identity(
            nodeId: stack.myInvite.nodeId,
            displayName: identity.displayName,
            username: identity.username,
          )
        : identity;
    state = AppState(
      AppPhase.ready,
      identity: effective,
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
    final identity = await _loadIdentityOrHalt(storage);
    if (identity == null) return; // damaged record — parked, nothing written
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
      final identity = await _loadIdentityOrHalt(storage);
      if (identity == null) return; // damaged record — parked, nothing written
      await _enterSession(identity);
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
    final identity = await _loadIdentityOrHalt(storage);
    if (identity == null) return false; // damaged record — parked
    await _enterSession(identity);
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
  Future<bool> reapplyProxyRouting() async {
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
      final identity = await _loadIdentityOrHalt(storage);
      if (identity == null) return false; // damaged record — parked
      await _enterSession(identity);
      return true;
    } catch (e, st) {
      devLog(() => 'xVeil[proxy]: apply/reboot failed: $e\n$st');
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
    final identity = await _loadIdentityOrHalt(storage);
    if (identity == null) return false; // damaged record — parked
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
      _pendingRoster = updated;

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
      _pendingRoster = updated;

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
      _pendingRoster = updated;

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
          await storage.loadIdentity() != null &&
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
      _pendingRoster = updated;

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
      final masterHasIdentity = await storage.loadIdentity() != null;
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

      await storage.saveIdentity(generateIdentity(displayName: label));
      final roster = <RosterEntry>[
        ...base,
        RosterEntry(label: label, spaceKeys: candidateKeys, anonymous: anonymous),
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
            await storage.loadIdentity() != null ||
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
    try {
      final stack = await RealVeilStack.startDeniable(
        storage: ref.read(storageProvider),
        runtimeDir: boot.runtimeDir,
        // Offset alternates after every teardown (see _teardownRealStack) so
        // a switch/relock never rebinds the just-freed port.
        listenPort: boot.listenPort + _oneActivePortOffset,
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
        runtimeBootstrapPeers: boot.bootstrapPeers,
        udpReflectors: boot.udpReflectors,
        obfs4Psk: boot.obfs4Psk,
        proxy: ref.read(effectiveProxyRoutingProvider),
        identityPhrase: identityPhrase,
      );
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
  Future<void> _stopVpnTunnel() async {
    try {
      await ref
          .read(vpnControllerProvider.notifier)
          .stop()
          // Bounded: the tunnel lives behind a platform channel, and a wipe
          // that hangs because the VPN plugin is unresponsive is worse than
          // one that leaves the tunnel up — the user asked for their data
          // gone, and that part does not depend on the OS answering.
          .timeout(const Duration(seconds: 3));
    } catch (e) {
      devLog(() => 'xVeil[vpn]: stop during lock/wipe failed: $e');
    }
  }

  Future<void> lock() async {
    // Timestamped phases: a lock that takes seconds points at whichever step
    // stalled (a busy storage worker on close is the prime suspect for the
    // "won't unlock until restart" report — see WorkerKvLogStore.close).
    final t0 = DateTime.now();
    int ms() => DateTime.now().difference(t0).inMilliseconds;
    devLog(() => 'xVeil[lock]: begin');
    await _stopVpnTunnel();
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
    state = const AppState(AppPhase.locked);
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStack ?? StackTrace.current);
    }
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
      // The port this node held is now in lingering teardown — the NEXT boot
      // must not rebind it or it can stall for ~90s (the same trap all-online
      // avoids with its +1+i offsets). Alternate between two ports well clear
      // of the all-online range. The listen address is composed fresh per
      // boot and exchanged in-band, so nothing persisted goes stale.
      _oneActivePortOffset = _oneActivePortOffset == 0 ? 64 : 0;
    }
  }

  /// Deniability: remove the ephemeral runtime-dir BASE (the parent that holds
  /// each identity's sockets + the public obfs4 PSK). Each stack already deletes
  /// its own subdir on dispose; this clears the now-empty base and any straggler
  /// so NO trace that nodes ran is left in temp after lock/wipe. Best-effort.
  /// Stop the background foreground service on teardown — no node is running
  /// once locked, so nothing should keep the process (or its notification) alive.
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
    await _stopVpnTunnel();
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
    await _stopVpnTunnel();
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
        devLog(() => 'xVeil[wipe]: failed to delete blobs at ${blobRoot.path}: $e');
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
    try {
      // Bounded for the same reason as the tunnel: resolving the support
      // directory goes through a platform channel, and a wipe that hangs on an
      // unresponsive plugin is worse than one that leaves a re-downloadable
      // file behind.
      await ref
          .read(whisperModelStoreProvider)
          .remove()
          .timeout(const Duration(seconds: 3));
    } catch (e) {
      devLog(() => 'xVeil[wipe]: failed to remove the speech model: $e');
    }
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

  /// A stand-in shown when a space opened but holds NO identity record.
  ///
  /// This is an anomaly, not a normal state: the space unlocked, so the keys
  /// were right, but there is nothing where the identity should be. It used to
  /// be minted silently (audit XV-18), so the UI presented a plausible-looking
  /// identity — a DIFFERENT one on every call, since the id is random — and the
  /// anomaly left no trace anywhere. Someone reporting "my node id keeps
  /// changing" was describing this, and nothing in the logs would have said why.
  ///
  /// Recorded now, every time. The random id is kept deliberately: an all-zero
  /// or fixed id would flow into maps, comparisons and the wire as a REAL id
  /// shared by every affected install, which trades a display bug for a
  /// correctness one.
  ///
  /// ⛔ ONLY for an ABSENT record. A record that exists but will not parse no
  /// longer reaches here at all — [_loadIdentityOrHalt] takes that branch to
  /// [AppPhase.identityDamaged] instead (audit XV-13). A placeholder over
  /// damaged data is what made a lost identity look like a working app.
  Identity _placeholderIdentity() {
    devLog(
      () =>
          'xVeil[identity]: space opened but holds NO identity record — '
          'showing a placeholder. The container unlocked, so this is a missing '
          'identity record, not a wrong password.',
    );
    errorJournal.record(
      kind: 'identity',
      error: StateError('space has no identity record; placeholder shown'),
      stack: StackTrace.current,
      atMs: DateTime.now().millisecondsSinceEpoch,
    );
    return generateIdentity();
  }

  /// Read the identity of an OPEN space for a session about to start.
  ///
  /// Returns null when the record is damaged — the caller must then return
  /// immediately, because this has already parked the app on
  /// [AppPhase.identityDamaged] and closed the space. Absent (the fresh/erased
  /// case) still yields a placeholder, which is a display concern only.
  ///
  /// The split exists because the two states want opposite handling and the old
  /// `loadIdentity() ?? _placeholderIdentity()` gave them the same one: a
  /// damaged record produced a random ready identity, the user saw a normal
  /// empty app, and the session then went on to write into the very space whose
  /// contents could not be read (audit XV-13).
  Future<Identity?> _loadIdentityOrHalt(Storage storage) async {
    try {
      return await storage.loadIdentity() ?? _placeholderIdentity();
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

final appControllerProvider = NotifierProvider<AppController, AppState>(
  AppController.new,
);
