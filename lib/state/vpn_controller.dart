import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/vpn/vpn_backend.dart';
import '../data/vpn/linux_managed_vpn_backend.dart';
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
    final backend = await ref.read(vpnBackendProvider).probe();
    if (backend.isRunning) {
      ref.read(vpnProxyDemandProvider.notifier).state = true;
      await ref.read(appControllerProvider.notifier).reapplyProxyRouting();
    } else {
      ref.read(vpnProxyDemandProvider.notifier).state = false;
    }
    if (!_disposed) state = VpnState(policy: policy, backend: backend);
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
    if (!proxy.vpnTransportReady) {
      state = state.copyWith(
        backend: const VpnBackendState(
          VpnBackendPhase.error,
          detail: 'VPN exit is not configured',
        ),
      );
      return;
    }
    state = state.copyWith(
      busy: true,
      backend: const VpnBackendState(VpnBackendPhase.starting),
    );
    if (!await _setProxyDemand(true)) {
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
    VpnBackendState result;
    try {
      result = await ref
          .read(vpnBackendProvider)
          .start(
            policy: state.policy,
            socks5Listen: proxy.socks5Listen,
            exitNodeId: proxy.exitNodeId!,
            obfs4Psk: ref.read(deniableBootProvider)?.obfs4Psk,
          );
    } catch (error) {
      result = VpnBackendState(VpnBackendPhase.error, detail: '$error');
    }
    if (!result.isRunning && !_disposed) {
      await _setProxyDemand(false);
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
    if (_disposed) return;
    final applied = state.policy.copyWith(enabled: !stopped);
    state = VpnState(policy: applied, backend: result);
    await _persist(applied);
  }

  Future<void> refresh() async {
    if (state.busy) return;
    final result = await ref.read(vpnBackendProvider).status();
    if (_disposed) return;
    final demanded = ref.read(vpnProxyDemandProvider);
    if (demanded != result.isRunning) {
      await _setProxyDemand(result.isRunning);
    }
    if (!_disposed) state = state.copyWith(backend: result);
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
