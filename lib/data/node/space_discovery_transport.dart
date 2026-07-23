import 'dart:typed_data';

import 'package:veil_flutter/veil_ffi.dart' as veil;

import '../../core/ids.dart';
import '../../domain/space_discovery_carrier.dart';

/// Minimal network port kept outside [GroupService] so domain tests never load
/// the native library and headless/GUI hosts share the exact same DHT path.
abstract interface class SpaceDiscoveryTransport {
  Future<void> publish(Uint8List record);

  Future<List<Uint8List>> resolve(
    SpaceDiscoveryCarrierRoute route, {
    Duration timeout = const Duration(seconds: 8),
  });
}

final class NativeSpaceDiscoveryTransport implements SpaceDiscoveryTransport {
  const NativeSpaceDiscoveryTransport(this.selfId);

  final NodeId selfId;

  @override
  Future<void> publish(Uint8List record) =>
      veil.publishSpaceDiscoveryRecordAsync(
        selfNodeId: selfId.bytes,
        record: record,
      );

  @override
  Future<List<Uint8List>> resolve(
    SpaceDiscoveryCarrierRoute route, {
    Duration timeout = const Duration(seconds: 8),
  }) => veil.resolveSpaceDiscoveryRecordsAsync(
    selfNodeId: selfId.bytes,
    routeKind: switch (route.kind) {
      SpaceDiscoveryCarrierRouteKind.direct =>
        veil.SpaceDiscoveryRouteKind.direct,
      SpaceDiscoveryCarrierRouteKind.search =>
        veil.SpaceDiscoveryRouteKind.search,
    },
    routeBody: route.body,
    timeoutMs: timeout.inMilliseconds,
  );
}
