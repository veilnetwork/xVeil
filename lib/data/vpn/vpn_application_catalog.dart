import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class VpnApplication {
  const VpnApplication({required this.id, required this.label});

  final String id;
  final String label;

  factory VpnApplication.fromMap(Map<Object?, Object?> value) => VpnApplication(
    id: value['id'] as String? ?? '',
    label: value['label'] as String? ?? '',
  );
}

abstract interface class VpnApplicationCatalog {
  bool get isSupported;

  Future<List<VpnApplication>> listApplications();
}

class MethodChannelVpnApplicationCatalog implements VpnApplicationCatalog {
  const MethodChannelVpnApplicationCatalog();

  static const _channel = MethodChannel('network.veil.xveil/vpn');

  @override
  bool get isSupported => defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<List<VpnApplication>> listApplications() async {
    if (!isSupported) return const [];
    final raw = await _channel.invokeListMethod<Object?>('listApplications');
    return (raw ?? const [])
        .whereType<Map>()
        .map(
          (value) => VpnApplication.fromMap(Map<Object?, Object?>.from(value)),
        )
        .where((value) => value.id.isNotEmpty && value.label.isNotEmpty)
        .toList(growable: false);
  }
}
