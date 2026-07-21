import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'geoip_country_routes.dart';
import 'packet_tunnel_ffi.dart';
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
    required String exitNodeId,
    String? obfs4Psk,
  });

  Future<VpnBackendState> stop();
}

/// Native boundary shared by Android, Apple, Windows and Linux runners.
///
/// Missing platform code is reported as unsupported. In particular, a missing
/// plugin never becomes an optimistic `running` state.
class MethodChannelVpnBackend implements VpnBackend {
  MethodChannelVpnBackend({PacketTunnelFfi? packetTunnel})
    : _packetTunnel = packetTunnel ?? PacketTunnelFfi.tryOpen();

  static const _channel = MethodChannel('network.veil.xveil/vpn');
  final PacketTunnelFfi? _packetTunnel;

  @override
  Future<VpnBackendState> probe() {
    if (_packetTunnel == null) {
      return Future.value(
        const VpnBackendState(
          VpnBackendPhase.unsupported,
          detail: 'native packet engine is not installed',
        ),
      );
    }
    return _invokeState('probe');
  }

  @override
  Future<VpnBackendState> status() async {
    final packetTunnel = _packetTunnel;
    if (packetTunnel == null) return probe();
    final enginePhase = packetTunnel.status();
    if (enginePhase == PacketTunnelFfi.running ||
        enginePhase == PacketTunnelFfi.starting) {
      return VpnBackendState(
        enginePhase == PacketTunnelFfi.running
            ? VpnBackendPhase.running
            : VpnBackendPhase.starting,
      );
    }
    if (enginePhase == PacketTunnelFfi.error) {
      return VpnBackendState(
        VpnBackendPhase.error,
        detail: packetTunnel.lastError() ?? 'packet tunnel failed',
      );
    }
    return _invokeState('status');
  }

  @override
  Future<VpnBackendState> start({
    required VpnRoutingPolicy policy,
    required String socks5Listen,
    required String exitNodeId,
    String? obfs4Psk,
  }) async {
    final packetTunnel = _packetTunnel;
    if (packetTunnel == null) return probe();
    if (policy.applicationMode != VpnApplicationMode.allApplications &&
        defaultTargetPlatform != TargetPlatform.android) {
      return const VpnBackendState(
        VpnBackendPhase.error,
        detail: 'Per-application VPN is supported only on Android',
      );
    }

    late final Map<String, dynamic> expandedPolicy;
    try {
      expandedPolicy = await GeoIpCountryRoutes.expandPolicy(policy);
    } on Object catch (error) {
      return VpnBackendState(
        VpnBackendPhase.error,
        detail: 'GeoIP routes could not be loaded: $error',
      );
    }
    final response = await _invokeRaw('start', {
      'policy': expandedPolicy,
      'socks5Listen': socks5Listen,
      // Apple Packet Tunnel owns a separate ephemeral Veil/SOCKS node so it
      // survives host suspension. Only the public exit identifier crosses the
      // provider boundary; the messaging identity never does.
      'exitNodeId': exitNodeId,
      if (obfs4Psk != null && obfs4Psk.isNotEmpty) 'obfs4Psk': obfs4Psk,
    });
    final tunFd = response['tunFd'];
    if (tunFd is! int) return VpnBackendState.fromMap(response);

    final result = packetTunnel.start(
      tunFd: tunFd,
      socks5Listen: socks5Listen,
      dnsIp: policy.dnsServers.firstOrNull ?? '1.1.1.1',
      mtu: policy.mtu,
      // Android's VpnService descriptors contain raw IP packets. Apple
      // packet-flow adapters add their own family metadata when needed.
      packetInformation: false,
      routeDns: policy.routeDns,
    );
    if (result != 0) {
      await _invokeRaw('abort');
      return VpnBackendState(
        VpnBackendPhase.error,
        detail: packetTunnel.lastError() ?? 'could not start packet tunnel',
      );
    }

    // Catch startup failures before allowing Android to advertise a live VPN.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (packetTunnel.status() != PacketTunnelFfi.running) {
      final detail =
          packetTunnel.lastError() ?? 'packet tunnel stopped during startup';
      packetTunnel.stop();
      await _invokeRaw('abort');
      return VpnBackendState(VpnBackendPhase.error, detail: detail);
    }
    return VpnBackendState.fromMap(await _invokeRaw('confirmRunning'));
  }

  @override
  Future<VpnBackendState> stop() async {
    final packetTunnel = _packetTunnel;
    String? engineError;
    if (packetTunnel != null && packetTunnel.stop() != 0) {
      engineError = packetTunnel.lastError() ?? 'packet tunnel did not stop';
    }

    // Closing the platform TUN is authoritative and must never be skipped just
    // because the Rust forwarding loop has already failed. Otherwise Android
    // keeps the system default route pointed at a dead descriptor.
    final native = VpnBackendState.fromMap(await _invokeRaw('stop'));
    if (native.phase == VpnBackendPhase.stopped) return native;
    final details = [engineError, native.detail].whereType<String>().toList();
    return VpnBackendState(
      VpnBackendPhase.error,
      detail: details.isEmpty ? 'native VPN did not stop' : details.join('; '),
    );
  }

  Future<VpnBackendState> _invokeState(
    String method, [
    Map<String, Object?>? arguments,
  ]) async => VpnBackendState.fromMap(await _invokeRaw(method, arguments));

  Future<Map<Object?, Object?>> _invokeRaw(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    try {
      final response = await _channel.invokeMethod<Object?>(method, arguments);
      return response is Map
          ? Map<Object?, Object?>.from(response)
          : <Object?, Object?>{
              'phase': 'error',
              'detail': 'invalid native VPN response',
            };
    } on MissingPluginException {
      return <Object?, Object?>{
        'phase': 'unsupported',
        'detail': 'native packet tunnel is not installed',
      };
    } on PlatformException catch (error) {
      return <Object?, Object?>{
        'phase': 'error',
        'detail': error.message ?? error.code,
      };
    }
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
