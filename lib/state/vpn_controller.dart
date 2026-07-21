import 'dart:async';
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

const _kVpnRoutingKey = 'vpn_routing_policy';

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

  @override
  VpnState build() {
    ref.onDispose(() => _disposed = true);
    // Let NotifierProvider publish the build result before async code reads or
    // writes [state]. Calling it synchronously here races provider init.
    scheduleMicrotask(() => unawaited(_restoreAndProbe()));
    return const VpnState();
  }

  Future<void> _restoreAndProbe() async {
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
    if (!_disposed) state = VpnState(policy: activePolicy, backend: backend);
  }

  Future<void> configure(VpnRoutingPolicy policy) async {
    _userChanged = true;
    // Editing never manufactures a running state and never auto-starts a
    // tunnel. An active backend must be explicitly restarted to apply changes.
    state = state.copyWith(policy: policy);
    await _persist(policy);
  }

  Future<void> start() async {
    if (state.busy || state.isRunning) return;
    if (state.backend.phase == VpnBackendPhase.unsupported) return;
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
    VpnBackendState result;
    try {
      result = await ref
          .read(vpnBackendProvider)
          .start(
            policy: state.policy,
            socks5Listen: proxyPlan.defaultListen,
            exitNodeId: proxyPlan.profiles.first.exitNodeIds.first,
            applicationProxyListens: proxyPlan.applicationListens,
            obfs4Psk: ref.read(deniableBootProvider)?.obfs4Psk,
          );
    } catch (error) {
      result = VpnBackendState(VpnBackendPhase.error, detail: '$error');
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
