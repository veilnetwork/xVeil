import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'vpn_routing_policy.dart';

/// Expands ISO-style country codes into the bundled IPv4/IPv6 CIDR snapshot.
///
/// Expansion happens before the native VPN interface is created, so a missing
/// or damaged database fails closed instead of silently routing a country via
/// the wrong path.
class GeoIpCountryRoutes {
  static const assetPath = 'assets/geoip/country_routes.json.gz';
  static const maxExpandedRoutes = 12000;
  static Future<_GeoIpData>? _cached;

  static Future<Map<String, dynamic>> expandPolicy(
    VpnRoutingPolicy policy,
  ) async {
    final includedCodes = _normalized(policy.includedCountryCodes);
    final excludedCodes = _normalized(policy.excludedCountryCodes);
    if (includedCodes.isEmpty && excludedCodes.isEmpty) {
      return policy.toJson();
    }

    final data = await (_cached ??= _load());
    final included = <String>{...policy.includedCidrs};
    final excluded = <String>{...policy.excludedCidrs};
    _append(data, includedCodes, included);
    _append(data, excludedCodes, excluded);
    if (included.length + excluded.length > maxExpandedRoutes) {
      throw const FormatException(
        'GeoIP selection expands to too many platform routes',
      );
    }
    return <String, dynamic>{
      ...policy.toJson(),
      'includedCidrs': included.toList(growable: false),
      'excludedCidrs': excluded.toList(growable: false),
      'geoIpGeneratedAt': data.generatedAt,
    };
  }

  static Set<String> _normalized(List<String> values) => values
      .map((value) => value.trim().toUpperCase())
      .where((value) => value.isNotEmpty)
      .toSet();

  static void _append(
    _GeoIpData data,
    Set<String> codes,
    Set<String> destination,
  ) {
    for (final code in codes) {
      final routes = data.countries[code];
      if (routes == null || routes.isEmpty) {
        throw FormatException('GeoIP country code is unavailable: $code');
      }
      destination.addAll(routes);
    }
  }

  static Future<_GeoIpData> _load() async {
    final compressed = await rootBundle.load(assetPath);
    final decoded = GZipCodec().decode(
      compressed.buffer.asUint8List(
        compressed.offsetInBytes,
        compressed.lengthInBytes,
      ),
    );
    final root = jsonDecode(utf8.decode(decoded));
    if (root is! Map<String, dynamic> || root['schema'] != 1) {
      throw const FormatException('unsupported GeoIP route database');
    }
    final rawCountries = root['countries'];
    if (rawCountries is! Map) {
      throw const FormatException('damaged GeoIP route database');
    }
    final countries = <String, List<String>>{};
    for (final entry in rawCountries.entries) {
      if (entry.key is! String || entry.value is! List) continue;
      final routes = (entry.value as List).whereType<String>().toList(
        growable: false,
      );
      if (routes.any((route) => !VpnRoutingPolicy.isValidCidr(route))) {
        throw FormatException('invalid GeoIP routes for ${entry.key}');
      }
      countries[entry.key as String] = routes;
    }
    if (countries.isEmpty) {
      throw const FormatException('empty GeoIP route database');
    }
    return _GeoIpData(
      generatedAt: root['generatedAt'] as String? ?? 'unknown',
      countries: countries,
    );
  }
}

class _GeoIpData {
  const _GeoIpData({required this.generatedAt, required this.countries});

  final String generatedAt;
  final Map<String, List<String>> countries;
}
