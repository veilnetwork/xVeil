import 'package:flutter/services.dart';

import 'vpn_routing_policy.dart';

enum VpnBackendPhase {
  unsupported,
  stopped,
  starting,
  running,
  stopping,
  error,
}

class VpnBackendState {
  const VpnBackendState(this.phase, {this.detail});

  final VpnBackendPhase phase;
  final String? detail;

  bool get isRunning => phase == VpnBackendPhase.running;

  factory VpnBackendState.fromMap(Object? value) {
    if (value is! Map) {
      return const VpnBackendState(
        VpnBackendPhase.error,
        detail: 'invalid native VPN response',
      );
    }
    final rawPhase = value['phase'] as String?;
    final phase = VpnBackendPhase.values
        .where((candidate) => candidate.name == rawPhase)
        .firstOrNull;
    return VpnBackendState(
      phase ?? VpnBackendPhase.error,
      detail: value['detail'] as String?,
    );
  }
}

abstract interface class VpnBackend {
  Future<VpnBackendState> probe();

  Future<VpnBackendState> status();

  Future<VpnBackendState> start({
    required VpnRoutingPolicy policy,
    required String socks5Listen,
  });

  Future<VpnBackendState> stop();
}

/// Native boundary shared by Android, Apple, Windows and Linux runners.
///
/// Missing platform code is reported as unsupported. In particular, a missing
/// plugin never becomes an optimistic `running` state.
class MethodChannelVpnBackend implements VpnBackend {
  const MethodChannelVpnBackend();

  static const _channel = MethodChannel('network.veil.xveil/vpn');

  @override
  Future<VpnBackendState> probe() => _invoke('probe');

  @override
  Future<VpnBackendState> status() => _invoke('status');

  @override
  Future<VpnBackendState> start({
    required VpnRoutingPolicy policy,
    required String socks5Listen,
  }) => _invoke('start', {
    'policy': policy.toJson(),
    'socks5Listen': socks5Listen,
  });

  @override
  Future<VpnBackendState> stop() => _invoke('stop');

  Future<VpnBackendState> _invoke(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    try {
      return VpnBackendState.fromMap(
        await _channel.invokeMethod<Object?>(method, arguments),
      );
    } on MissingPluginException {
      return const VpnBackendState(
        VpnBackendPhase.unsupported,
        detail: 'native packet tunnel is not installed',
      );
    } on PlatformException catch (error) {
      return VpnBackendState(
        VpnBackendPhase.error,
        detail: error.message ?? error.code,
      );
    }
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
