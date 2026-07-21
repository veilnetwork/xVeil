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

/// Which applications are eligible to use the packet tunnel.
enum VpnApplicationMode { allApplications, onlySelected }

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
    this.applicationMode = VpnApplicationMode.allApplications,
    this.applicationIds = const [],
    this.vpnOproxyNodeIds = const [],
    this.applicationOproxyNodeIds = const {},
    this.oproxyAutoFailover = true,
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
  final VpnApplicationMode applicationMode;
  final List<String> applicationIds;

  /// Ordered primary/fallback exit chain for traffic without an app override.
  /// Empty means "use ProxyRouting's default oproxy chain".
  final List<String> vpnOproxyNodeIds;

  /// Android package ID -> ordered primary/fallback exit chain.
  final Map<String, List<String>> applicationOproxyNodeIds;
  final bool oproxyAutoFailover;
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
    if (applicationMode == VpnApplicationMode.onlySelected &&
        applicationIds.isEmpty) {
      errors.add('applicationIds.empty');
    }
    if (applicationIds.length > 256 ||
        applicationIds.any((value) => !isValidApplicationId(value))) {
      errors.add('applicationIds.invalid');
    }
    if (!_isValidOproxyChain(vpnOproxyNodeIds)) {
      errors.add('vpnOproxyNodeIds.invalid');
    }
    if (applicationOproxyNodeIds.length > 256 ||
        applicationOproxyNodeIds.entries.any(
          (entry) =>
              !isValidApplicationId(entry.key) ||
              entry.value.isEmpty ||
              !_isValidOproxyChain(entry.value),
        )) {
      errors.add('applicationOproxyNodeIds.invalid');
    }
    if (applicationMode == VpnApplicationMode.onlySelected &&
        applicationOproxyNodeIds.keys.any(
          (applicationId) => !applicationIds.contains(applicationId),
        )) {
      errors.add('applicationOproxyNodeIds.notSelected');
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

  static bool isValidApplicationId(String value) {
    final input = value.trim();
    return input.length <= 255 &&
        RegExp(
          r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$',
        ).hasMatch(input);
  }

  static bool isValidOproxyNodeId(String value) =>
      RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(value);

  static bool _isValidOproxyChain(List<String> values) =>
      values.length <= 16 && values.every(isValidOproxyNodeId);

  VpnRoutingPolicy copyWith({
    bool? enabled,
    VpnRouteMode? routeMode,
    List<String>? includedCidrs,
    List<String>? excludedCidrs,
    List<String>? includedCountryCodes,
    List<String>? excludedCountryCodes,
    VpnApplicationMode? applicationMode,
    List<String>? applicationIds,
    List<String>? vpnOproxyNodeIds,
    Map<String, List<String>>? applicationOproxyNodeIds,
    bool? oproxyAutoFailover,
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
    applicationMode: applicationMode ?? this.applicationMode,
    applicationIds: applicationIds ?? this.applicationIds,
    vpnOproxyNodeIds: vpnOproxyNodeIds ?? this.vpnOproxyNodeIds,
    applicationOproxyNodeIds:
        applicationOproxyNodeIds ?? this.applicationOproxyNodeIds,
    oproxyAutoFailover: oproxyAutoFailover ?? this.oproxyAutoFailover,
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
    'applicationMode': applicationMode.name,
    'applicationIds': applicationIds,
    'vpnOproxyNodeIds': vpnOproxyNodeIds,
    'applicationOproxyNodeIds': applicationOproxyNodeIds,
    'oproxyAutoFailover': oproxyAutoFailover,
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
    final applicationModeName = json['applicationMode'] as String?;
    final applicationMode = VpnApplicationMode.values
        .where((v) => v.name == applicationModeName)
        .firstOrNull;
    return VpnRoutingPolicy(
      enabled: json['enabled'] as bool? ?? false,
      routeMode: mode ?? VpnRouteMode.allTraffic,
      includedCidrs: _strings(json['includedCidrs']),
      excludedCidrs: _strings(json['excludedCidrs']),
      includedCountryCodes: _countryCodes(json['includedCountryCodes']),
      excludedCountryCodes: _countryCodes(json['excludedCountryCodes']),
      applicationMode: applicationMode ?? VpnApplicationMode.allApplications,
      applicationIds: _applicationIds(json['applicationIds']),
      vpnOproxyNodeIds: _oproxyNodeIds(json['vpnOproxyNodeIds']),
      applicationOproxyNodeIds: _applicationOproxyNodeIds(
        json['applicationOproxyNodeIds'],
      ),
      oproxyAutoFailover: json['oproxyAutoFailover'] as bool? ?? true,
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

  static List<String> _applicationIds(Object? value) => value is List
      ? value
            .whereType<String>()
            .map((v) => v.trim())
            .where((v) => v.isNotEmpty)
            .toSet()
            .toList(growable: false)
      : const [];

  static List<String> _oproxyNodeIds(Object? value) => value is List
      ? value
            .whereType<String>()
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty)
            .toSet()
            .toList(growable: false)
      : const [];

  static Map<String, List<String>> _applicationOproxyNodeIds(Object? value) {
    if (value is! Map) return const {};
    return {
      for (final entry in value.entries)
        if (entry.key is String)
          entry.key as String: _oproxyNodeIds(entry.value),
    };
  }

  static const defaults = VpnRoutingPolicy();
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
