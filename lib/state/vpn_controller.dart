import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/vpn/vpn_backend.dart';
import '../data/vpn/vpn_routing_policy.dart';
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
  (_) => const MethodChannelVpnBackend(),
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
    if (!proxy.socks5Active) {
      state = state.copyWith(
        backend: const VpnBackendState(
          VpnBackendPhase.error,
          detail: 'SOCKS5 exit is not active',
        ),
      );
      return;
    }
    state = state.copyWith(
      busy: true,
      backend: const VpnBackendState(VpnBackendPhase.starting),
    );
    final result = await ref
        .read(vpnBackendProvider)
        .start(policy: state.policy, socks5Listen: proxy.socks5Listen);
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
    final applied = state.policy.copyWith(enabled: !stopped);
    state = VpnState(policy: applied, backend: result);
    await _persist(applied);
  }

  Future<void> refresh() async {
    if (state.busy) return;
    final result = await ref.read(vpnBackendProvider).status();
    if (!_disposed) state = state.copyWith(backend: result);
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
