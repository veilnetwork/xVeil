import 'dart:io';

/// Which destinations a system VPN sends into veil.
enum VpnRouteMode {
  /// Route IPv4 and IPv6 default routes, except [VpnRoutingPolicy.excludedCidrs].
  allTraffic,

  /// Route only [VpnRoutingPolicy.includedCidrs].
  includeOnly,

  /// Route the default routes, except [VpnRoutingPolicy.excludedCidrs].
  excludeOnly,
}

/// Persisted, platform-neutral configuration for an OS-level packet tunnel.
///
/// This is deliberately separate from the SOCKS5 config. SOCKS5 is the packet
/// engine's upstream; a VPN is active only after a native backend has created a
/// TUN interface and confirmed that it is forwarding packets.
class VpnRoutingPolicy {
  const VpnRoutingPolicy({
    this.enabled = false,
    this.routeMode = VpnRouteMode.allTraffic,
    this.includedCidrs = const [],
    this.excludedCidrs = const [],
    this.includedCountryCodes = const [],
    this.excludedCountryCodes = const [],
    this.routeDns = true,
    this.dnsServers = defaultDnsServers,
    this.allowLan = true,
    this.mtu = defaultMtu,
  });

  static const defaultMtu = 1280;
  static const defaultDnsServers = ['1.1.1.1', '2606:4700:4700::1111'];

  /// Last successfully applied native-tunnel intent. It is never sufficient
  /// on its own to claim that the VPN is currently running.
  final bool enabled;
  final VpnRouteMode routeMode;
  final List<String> includedCidrs;
  final List<String> excludedCidrs;
  final List<String> includedCountryCodes;
  final List<String> excludedCountryCodes;
  final bool routeDns;
  final List<String> dnsServers;
  final bool allowLan;
  final int mtu;

  List<String> validate() {
    final errors = <String>[];
    if (mtu < 1280 || mtu > 9000) errors.add('mtu');
    if (routeMode == VpnRouteMode.includeOnly &&
        includedCidrs.isEmpty &&
        includedCountryCodes.isEmpty) {
      errors.add('includedCidrs.empty');
    }
    if (includedCidrs.any((value) => !isValidCidr(value))) {
      errors.add('includedCidrs.invalid');
    }
    if (excludedCidrs.any((value) => !isValidCidr(value))) {
      errors.add('excludedCidrs.invalid');
    }
    if (includedCountryCodes.any((value) => !isValidCountryCode(value))) {
      errors.add('includedCountryCodes.invalid');
    }
    if (excludedCountryCodes.any((value) => !isValidCountryCode(value))) {
      errors.add('excludedCountryCodes.invalid');
    }
    if (routeDns && dnsServers.isEmpty) errors.add('dnsServers.empty');
    if (dnsServers.any((value) => !isValidIp(value))) {
      errors.add('dnsServers.invalid');
    }
    return errors;
  }

  bool get isValid => validate().isEmpty;

  static bool isValidIp(String value) {
    final input = value.trim();
    if (input.isEmpty || input.contains('%') || input.contains('/')) {
      return false;
    }
    return InternetAddress.tryParse(input) != null;
  }

  static bool isValidCidr(String value) {
    final input = value.trim();
    if (input.isEmpty || input.contains('%')) return false;
    final slash = input.lastIndexOf('/');
    if (slash <= 0 || slash == input.length - 1) return false;
    final address = InternetAddress.tryParse(input.substring(0, slash));
    final prefix = int.tryParse(input.substring(slash + 1));
    if (address == null || prefix == null) return false;
    final max = address.type == InternetAddressType.IPv4 ? 32 : 128;
    return prefix >= 0 && prefix <= max;
  }

  static bool isValidCountryCode(String value) =>
      RegExp(r'^[A-Za-z]{2}$').hasMatch(value.trim());

  VpnRoutingPolicy copyWith({
    bool? enabled,
    VpnRouteMode? routeMode,
    List<String>? includedCidrs,
    List<String>? excludedCidrs,
    List<String>? includedCountryCodes,
    List<String>? excludedCountryCodes,
    bool? routeDns,
    List<String>? dnsServers,
    bool? allowLan,
    int? mtu,
  }) => VpnRoutingPolicy(
    enabled: enabled ?? this.enabled,
    routeMode: routeMode ?? this.routeMode,
    includedCidrs: includedCidrs ?? this.includedCidrs,
    excludedCidrs: excludedCidrs ?? this.excludedCidrs,
    includedCountryCodes: includedCountryCodes ?? this.includedCountryCodes,
    excludedCountryCodes: excludedCountryCodes ?? this.excludedCountryCodes,
    routeDns: routeDns ?? this.routeDns,
    dnsServers: dnsServers ?? this.dnsServers,
    allowLan: allowLan ?? this.allowLan,
    mtu: mtu ?? this.mtu,
  );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'routeMode': routeMode.name,
    'includedCidrs': includedCidrs,
    'excludedCidrs': excludedCidrs,
    'includedCountryCodes': includedCountryCodes,
    'excludedCountryCodes': excludedCountryCodes,
    'routeDns': routeDns,
    'dnsServers': dnsServers,
    'allowLan': allowLan,
    'mtu': mtu,
  };

  factory VpnRoutingPolicy.fromJson(Map<String, dynamic> json) {
    final modeName = json['routeMode'] as String?;
    final mode = VpnRouteMode.values
        .where((v) => v.name == modeName)
        .firstOrNull;
    return VpnRoutingPolicy(
      enabled: json['enabled'] as bool? ?? false,
      routeMode: mode ?? VpnRouteMode.allTraffic,
      includedCidrs: _strings(json['includedCidrs']),
      excludedCidrs: _strings(json['excludedCidrs']),
      includedCountryCodes: _countryCodes(json['includedCountryCodes']),
      excludedCountryCodes: _countryCodes(json['excludedCountryCodes']),
      routeDns: json['routeDns'] as bool? ?? true,
      dnsServers: json.containsKey('dnsServers')
          ? _strings(json['dnsServers'])
          : defaultDnsServers,
      allowLan: json['allowLan'] as bool? ?? true,
      mtu: json['mtu'] as int? ?? defaultMtu,
    );
  }

  static List<String> _strings(Object? value) => value is List
      ? value.whereType<String>().map((v) => v.trim()).toList(growable: false)
      : const [];

  static List<String> _countryCodes(Object? value) => value is List
      ? value
            .whereType<String>()
            .map((v) => v.trim().toUpperCase())
            .where((v) => v.isNotEmpty)
            .toSet()
            .toList(growable: false)
      : const [];

  static const defaults = VpnRoutingPolicy();
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
