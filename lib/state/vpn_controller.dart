import 'dart:async';
import 'identity_scoped_prefs.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/node/proxy_routing.dart';
import '../data/vpn/vpn_backend.dart';
import '../data/vpn/linux_managed_vpn_backend.dart';
import '../data/vpn/socks5_transport_preflight.dart';
import '../data/vpn/vpn_proxy_plan.dart';
import '../data/vpn/vpn_routing_policy.dart';
import '../data/vpn/windows_managed_vpn_backend.dart';
import 'app_controller.dart';
import 'providers.dart';
import 'proxy_routing_controller.dart';

/// Profile-scoped: a decoy profile must not inherit the real profile's
/// posture, and this value is read before any container is open (audit
/// XV-10). See [identityScopedPrefKey].
String get _kVpnRoutingKey => identityScopedPrefKey('vpn_routing_policy');

class VpnState {
  const VpnState({
    this.policy = VpnRoutingPolicy.defaults,
    this.backend = const VpnBackendState(
      VpnBackendPhase.unsupported,
      detail: 'probing native packet tunnel',
    ),
    this.busy = false,
  });

  final VpnRoutingPolicy policy;
  final VpnBackendState backend;
  final bool busy;

  bool get isRunning => backend.isRunning;

  VpnState copyWith({
    VpnRoutingPolicy? policy,
    VpnBackendState? backend,
    bool? busy,
  }) => VpnState(
    policy: policy ?? this.policy,
    backend: backend ?? this.backend,
    busy: busy ?? this.busy,
  );
}

final vpnBackendProvider = Provider<VpnBackend>(
  (_) => switch (Platform.operatingSystem) {
    'linux' => LinuxManagedVpnBackend(),
    'windows' => WindowsManagedVpnBackend(),
    _ => MethodChannelVpnBackend(),
  },
);

typedef VpnTransportPreflight = Future<void> Function(String listen);

final vpnTransportPreflightProvider = Provider<VpnTransportPreflight>(
  (_) => Socks5TransportPreflight.verify,
);

class VpnController extends Notifier<VpnState> {
  bool _disposed = false;
  bool _userChanged = false;

  /// TEARDOWN GENERATION — the same idiom as `AppController._lifecycle`, for the
  /// one resource in this app that outlives the process: the OS packet tunnel
  /// (audit XV-H2).
  ///
  /// [start] publishes `running` and persists `enabled: true` only AFTER seconds
  /// of awaits — the transport activation, a SOCKS5 preflight, the native start.
  /// A lock landing in that window used to change nothing: [stop] opens with
  /// `if (state.busy || !state.isRunning) return;` and during a start BOTH are
  /// true — busy is set, and the phase is `starting`, never `running` — so the
  /// backend was never asked to stop, and the tunnel came up behind the lock
  /// screen of a device that had just said it was locked.
  ///
  /// The deterministic half of it needs no race at all. `_stopVpnTunnel` READS
  /// this provider, so in a session where nothing else touched the VPN the lock
  /// itself constructs the notifier: [build] returns the default state
  /// (`unsupported`, not running), the guard above returns on it synchronously,
  /// and the [_restoreAndProbe] that [build] scheduled then probes the native
  /// backend and ADOPTS whatever tunnel it finds — republishing `running` for
  /// the session the lock had just ended. The lock's own act of reading the
  /// provider defeated the stop it existed to perform.
  ///
  /// So every path that publishes or adopts a tunnel snapshots this counter
  /// before its first await and, if the snapshot has gone stale by the time it
  /// holds a result, takes the tunnel down instead of publishing it.
  /// [stopForTeardown] bumps the counter synchronously, before anything it
  /// awaits, so neither an in-flight start nor a just-scheduled restore can slip
  /// past it.
  int _generation = 0;

  /// The start currently in flight, so a teardown waits for it to be OVER before
  /// asking the backend to stop: a stop that overtakes the start it means to
  /// cancel is simply overwritten by it.
  Future<void>? _inFlight;

  /// True when a session-ending teardown happened since [gen] was taken.
  bool _superseded(int gen) => gen != _generation;

  @override
  VpnState build() {
    ref.onDispose(() => _disposed = true);
    // Taken HERE, synchronously, because a teardown that reads this provider for
    // the first time constructs the notifier itself: the bump that follows in
    // the same synchronous stretch must be visible to the restore below.
    final gen = _generation;
    // Let NotifierProvider publish the build result before async code reads or
    // writes [state]. Calling it synchronously here races provider init.
    scheduleMicrotask(() => unawaited(_restoreAndProbe(gen)));
    return const VpnState();
  }

  Future<void> _restoreAndProbe(int gen) async {
    // A teardown ran between [build] and this microtask — which is the ordinary
    // case when the teardown is what built us. Adopting a tunnel now would put
    // `running` back on a session that is over.
    if (_superseded(gen)) return;
    var policy = state.policy;
    try {
      final prefs = await ref.read(prefsProvider.future);
      final raw = prefs.getString(_kVpnRoutingKey);
      if (raw != null && !_userChanged) {
        policy = VpnRoutingPolicy.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
      }
    } catch (_) {
      // Widget tests and a damaged preference stay on safe defaults.
    }
    final proxy = await ref
        .read(proxyRoutingProvider.notifier)
        .waitUntilLoaded();
    final nativeBackend = ref.read(vpnBackendProvider);
    var backend = await nativeBackend.probe();
    // The teardown that superseded us stops the tunnel itself, unconditionally,
    // so this probe result — running or not — describes a session that is over.
    if (_superseded(gen)) return;
    final activePolicy = _userChanged ? state.policy : policy;
    if (backend.isRunning) {
      try {
        final plan = VpnProxyPlan.build(routing: proxy, policy: activePolicy);
        if (!await _activateProxyPlan(plan)) {
          await nativeBackend.stop();
          backend = const VpnBackendState(
            VpnBackendPhase.error,
            detail:
                'the restored VPN transport could not be applied; the system '
                'tunnel was stopped to avoid blocking traffic',
          );
        }
      } on Object catch (error) {
        await nativeBackend.stop();
        _clearProxyPlan();
        backend = VpnBackendState(
          VpnBackendPhase.error,
          detail:
              'the saved VPN oproxy configuration is invalid: $error; the '
              'system tunnel was stopped to avoid blocking traffic',
        );
      }
    } else {
      _clearProxyPlan();
    }
    if (!_disposed && !_superseded(gen)) {
      state = VpnState(policy: activePolicy, backend: backend);
    }
  }

  Future<void> configure(VpnRoutingPolicy policy) async {
    _userChanged = true;
    // Editing never manufactures a running state and never auto-starts a
    // tunnel. An active backend must be explicitly restarted to apply changes.
    state = state.copyWith(policy: policy);
    await _persist(policy);
  }

  Future<void> start() {
    final pending = _start();
    // Recorded so a teardown can wait for this run to be OVER — not for it to
    // have succeeded. The error-swallowing copy is the teardown's; the caller
    // still gets the original future with its error intact.
    _inFlight = pending.catchError((Object _) {});
    return pending;
  }

  Future<void> _start() async {
    if (state.busy || state.isRunning) return;
    if (state.backend.phase == VpnBackendPhase.unsupported) return;
    // Taken before the first await — see [_generation].
    final gen = _generation;
    final proxy = ref.read(proxyRoutingProvider);
    if (!state.policy.isValid) {
      state = state.copyWith(
        backend: const VpnBackendState(
          VpnBackendPhase.error,
          detail: 'invalid VPN routing policy',
        ),
      );
      return;
    }
    late final VpnProxyPlan proxyPlan;
    try {
      proxyPlan = VpnProxyPlan.build(routing: proxy, policy: state.policy);
    } on Object catch (error) {
      state = state.copyWith(
        backend: VpnBackendState(
          VpnBackendPhase.error,
          detail: 'VPN oproxy configuration is invalid: $error',
        ),
      );
      return;
    }
    state = state.copyWith(
      busy: true,
      backend: const VpnBackendState(VpnBackendPhase.starting),
    );
    if (!await _activateProxyPlan(proxyPlan)) {
      if (!_disposed) {
        state = state.copyWith(
          busy: false,
          backend: const VpnBackendState(
            VpnBackendPhase.error,
            detail: 'could not start the VPN transport',
          ),
        );
      }
      return;
    }
    try {
      await ref.read(vpnTransportPreflightProvider)(proxyPlan.defaultListen);
    } catch (error) {
      await _setProxyDemand(false);
      _clearProxyPlan();
      if (!_disposed) {
        state = state.copyWith(
          busy: false,
          backend: VpnBackendState(
            VpnBackendPhase.error,
            detail:
                'VPN exit is unreachable: $error. '
                'The system tunnel was not enabled.',
          ),
        );
      }
      return;
    }
    // Held across the await: after it, a teardown may have disposed the
    // container, and the handle to the thing that must be stopped would be gone
    // with it.
    final nativeBackend = ref.read(vpnBackendProvider);
    VpnBackendState result;
    try {
      result = await nativeBackend.start(
        policy: state.policy,
        socks5Listen: proxyPlan.defaultListen,
        exitNodeId: proxyPlan.profiles.first.exitNodeIds.first,
        exitNodeIds: proxyPlan.profiles.first.exitNodeIds,
        applicationProxyListens: proxyPlan.applicationListens,
        obfs4Psk: ref.read(deniableBootProvider)?.obfs4Psk,
      );
    } catch (error) {
      result = VpnBackendState(VpnBackendPhase.error, detail: '$error');
    }
    if (_superseded(gen)) {
      // The session ended while the tunnel was coming up. The tunnel lives in
      // the operating system, so the session ending does not take it with it:
      // hand it straight back, drop the transport, and above all do NOT persist
      // `enabled: true` — that flag is what the next launch restores from.
      try {
        await nativeBackend.stop();
      } catch (_) {
        // Best effort. [stopForTeardown] waited for this run and asks again.
      }
      if (_disposed) return;
      _clearProxyPlan();
      state = VpnState(
        policy: state.policy,
        backend: const VpnBackendState(
          VpnBackendPhase.stopped,
          detail: 'the session ended while the VPN tunnel was starting',
        ),
      );
      return;
    }
    if (!result.isRunning && !_disposed) {
      await _setProxyDemand(false);
      _clearProxyPlan();
    }
    if (_disposed) return;
    final applied = state.policy.copyWith(enabled: result.isRunning);
    state = VpnState(policy: applied, backend: result);
    await _persist(applied);
  }

  Future<void> stop() async {
    if (state.busy || !state.isRunning) return;
    state = state.copyWith(
      busy: true,
      backend: const VpnBackendState(VpnBackendPhase.stopping),
    );
    final result = await ref.read(vpnBackendProvider).stop();
    if (_disposed) return;
    final stopped = result.phase == VpnBackendPhase.stopped;
    if (stopped) await _setProxyDemand(false);
    if (stopped) _clearProxyPlan();
    if (_disposed) return;
    final applied = state.policy.copyWith(enabled: !stopped);
    state = VpnState(policy: applied, backend: result);
    await _persist(applied);
  }

  /// Bring the OS tunnel down because the SESSION IS ENDING — lock, start over,
  /// wipe — and report the phase the backend finished in (audit XV-H2).
  ///
  /// Deliberately not [stop]. That one is the UI button, and its opening guard
  /// (`busy || !isRunning`) is right for a button and wrong for a teardown: a
  /// teardown must not be talked out of stopping by a tunnel that is mid-start,
  /// nor by the default state of a controller the teardown itself has just
  /// built. So the backend is asked unconditionally, and the caller is told what
  /// it answered instead of the answer being dropped on the floor.
  ///
  /// Nothing is persisted here. A lock is not the user turning the VPN off, and
  /// the policy key is profile-scoped: writing it while the identity underneath
  /// is being torn down would file this session's posture under whichever scope
  /// the write happened to resolve to.
  Future<VpnBackendPhase> stopForTeardown() async {
    // FIRST, before any await: nothing built under the previous generation may
    // publish or adopt a tunnel any more. Even if the wait below outlives the
    // caller's timeout, this bump has already landed and the in-flight start
    // tears its own tunnel down when it returns.
    _generation++;
    // Read now, while the container is certainly alive.
    final nativeBackend = ref.read(vpnBackendProvider);
    // A start past its guards owns the backend until it returns; it now knows it
    // is superseded and stops what it started. Stopping underneath it would only
    // be undone by it.
    await _inFlight;
    final result = await nativeBackend.stop();
    if (!_disposed) {
      // A tunnel that did NOT stop still needs its local transport, exactly as
      // in [stop]: pulling it out from under a live tunnel blackholes traffic.
      if (result.phase == VpnBackendPhase.stopped) _clearProxyPlan();
      state = VpnState(policy: state.policy, backend: result);
    }
    return result.phase;
  }

  Future<void> refresh() async {
    if (state.busy) return;
    final result = await ref.read(vpnBackendProvider).status();
    if (_disposed) return;
    if (result.isRunning && !ref.read(vpnProxyDemandProvider)) {
      try {
        final plan = VpnProxyPlan.build(
          routing: ref.read(proxyRoutingProvider),
          policy: state.policy,
        );
        if (!await _activateProxyPlan(plan)) return;
      } on Object catch (error) {
        if (!_disposed) {
          state = state.copyWith(
            backend: VpnBackendState(
              VpnBackendPhase.error,
              detail: 'VPN oproxy configuration is invalid: $error',
            ),
          );
        }
        return;
      }
    } else if (!result.isRunning && ref.read(vpnProxyDemandProvider)) {
      await _setProxyDemand(false);
      _clearProxyPlan();
    }
    if (!_disposed) state = state.copyWith(backend: result);
  }

  Future<bool> _activateProxyPlan(VpnProxyPlan plan) async {
    final previous = ref.read(vpnProxyProfilesProvider);
    final profilesChanged = !_sameProfiles(previous, plan.profiles);
    ref.read(vpnProxyProfilesProvider.notifier).state = plan.profiles;

    if (!ref.read(vpnProxyDemandProvider)) {
      if (await _setProxyDemand(true)) return true;
    } else if (!profilesChanged) {
      return true;
    } else {
      try {
        if (await ref
            .read(appControllerProvider.notifier)
            .reapplyProxyRouting()) {
          return true;
        }
      } catch (_) {
        // Restore the previous runtime plan below.
      }
    }
    ref.read(vpnProxyProfilesProvider.notifier).state = previous;
    return false;
  }

  void _clearProxyPlan() {
    ref.read(vpnProxyDemandProvider.notifier).state = false;
    ref.read(vpnProxyProfilesProvider.notifier).state = const [];
  }

  static bool _sameProfiles(
    List<ProxySocksProfile> left,
    List<ProxySocksProfile> right,
  ) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      final a = left[index];
      final b = right[index];
      if (a.listen != b.listen ||
          a.exitNodeIds.length != b.exitNodeIds.length) {
        return false;
      }
      for (var exit = 0; exit < a.exitNodeIds.length; exit++) {
        if (a.exitNodeIds[exit] != b.exitNodeIds[exit]) return false;
      }
    }
    return true;
  }

  Future<bool> _setProxyDemand(bool enabled) async {
    final demand = ref.read(vpnProxyDemandProvider);
    if (demand == enabled) return true;
    ref.read(vpnProxyDemandProvider.notifier).state = enabled;
    try {
      final applied = await ref
          .read(appControllerProvider.notifier)
          .reapplyProxyRouting();
      if (applied) return true;
    } catch (_) {
      // Fall through to rollback below. A native tunnel must never start until
      // its local transport has actually been applied to the veil node.
    }
    ref.read(vpnProxyDemandProvider.notifier).state = demand;
    return false;
  }

  Future<void> _persist(VpnRoutingPolicy policy) async {
    try {
      final prefs = await ref.read(prefsProvider.future);
      await prefs.setString(_kVpnRoutingKey, jsonEncode(policy.toJson()));
    } catch (_) {
      // Best effort: runtime state remains authoritative for this process.
    }
  }
}

final vpnControllerProvider = NotifierProvider<VpnController, VpnState>(
  VpnController.new,
);
