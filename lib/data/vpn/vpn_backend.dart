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

/// Why the packet engine refused to start, when it said so in a way the app
/// can name.
///
/// The engine answers with distinct codes — already running, bad argument,
/// closed — and the app used to test only `!= 0` and then ask
/// `veil_packet_tunnel_last_error()`, which is null for every failure that
/// happens BEFORE the tunnel object exists. So a specific reason, already in
/// hand as the return value, was thrown away and replaced with "could not
/// start packet tunnel".
///
/// That mattered: a tunnel whose previous instance had not finished tearing
/// down answers "already running", and the person is told the engine failed
/// with no way to know that waiting is the fix.
enum VpnStartFailure {
  /// A tunnel is still up, or its worker has not finished. Starting again is
  /// the whole of the fix.
  alreadyRunning,

  /// The engine rejected one of the values it was handed — the tun descriptor,
  /// the SOCKS5 address, the DNS server or the MTU.
  invalidArgument,

  /// The engine was already shut down.
  closed,

  /// It refused without saying which of the above.
  refused,

  /// The engine started and then died before the app could confirm it. Its own
  /// account of why is in [VpnBackendState.detail].
  stoppedDuringStartup,

  /// Per-application routing was asked for and Android did not hand back the
  /// flow selector it needs.
  selectorMissing,

  /// The packet engine is not in this build at all.
  engineMissing,
}

class VpnBackendState {
  const VpnBackendState(this.phase, {this.detail, this.failure});

  final VpnBackendPhase phase;
  final String? detail;

  /// Set when the packet engine named a reason. [detail] stays whatever the
  /// engine or the platform said, for a log; this is what a person is shown.
  final VpnStartFailure? failure;

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
    List<String> exitNodeIds = const [],
    Map<String, String> applicationProxyListens = const {},
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
          failure: VpnStartFailure.engineMissing,
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
    List<String> exitNodeIds = const [],
    Map<String, String> applicationProxyListens = const {},
    String? obfs4Psk,
  }) async {
    final packetTunnel = _packetTunnel;
    if (packetTunnel == null) return probe();
    if ((policy.applicationMode != VpnApplicationMode.allApplications ||
            applicationProxyListens.isNotEmpty) &&
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
      // survives host suspension. Only public exit identifiers cross the
      // provider boundary; the messaging identity never does.
      'exitNodeId': exitNodeId,
      'exitNodeIds': exitNodeIds.isEmpty ? [exitNodeId] : exitNodeIds,
      'applicationProxyListens': applicationProxyListens,
      if (obfs4Psk != null && obfs4Psk.isNotEmpty) 'obfs4Psk': obfs4Psk,
    });
    final tunFd = response['tunFd'];
    if (tunFd is! int) return VpnBackendState.fromMap(response);
    final selectorListen = response['selectorListen'] as String?;
    final selectorToken = response['selectorToken'] as String?;
    if (applicationProxyListens.isNotEmpty &&
        (selectorListen == null || selectorToken == null)) {
      await _invokeRaw('abort');
      return const VpnBackendState(
        VpnBackendPhase.error,
        detail: 'Android did not create the per-application flow selector',
        failure: VpnStartFailure.selectorMissing,
      );
    }

    final result = packetTunnel.start(
      tunFd: tunFd,
      socks5Listen: socks5Listen,
      dnsIp: policy.dnsServers.firstOrNull ?? '1.1.1.1',
      mtu: policy.mtu,
      // Android's VpnService descriptors contain raw IP packets. Apple
      // packet-flow adapters add their own family metadata when needed.
      packetInformation: false,
      routeDns: policy.routeDns,
      selectorListen: selectorListen,
      selectorToken: selectorToken,
    );
    if (result != 0) {
      await _invokeRaw('abort');
      // The CODE is the reason. `lastError()` reads a slot that only exists
      // once the tunnel object does, so every pre-construction refusal reads
      // back null — which is exactly when the code is all there is.
      return VpnBackendState(
        VpnBackendPhase.error,
        detail:
            packetTunnel.lastError() ??
            'packet engine refused to start (code $result)',
        failure: PacketTunnelFfi.failureFor(result),
      );
    }

    // Catch startup failures before allowing Android to advertise a live VPN.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (packetTunnel.status() != PacketTunnelFfi.running) {
      // Its own words when it left any: the worker records why it failed and
      // the slot is still readable here, before `stop()` takes the object
      // away. The named reason is a floor, not a replacement.
      final detail = packetTunnel.lastError();
      packetTunnel.stop();
      await _invokeRaw('abort');
      return VpnBackendState(
        VpnBackendPhase.error,
        detail: detail,
        failure: VpnStartFailure.stoppedDuringStartup,
      );
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
