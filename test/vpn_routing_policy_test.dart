import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/vpn/vpn_backend.dart';
import 'package:xveil/data/vpn/geoip_country_routes.dart';
import 'package:xveil/data/vpn/vpn_routing_policy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VpnRoutingPolicy', () {
    test('accepts IPv4 and IPv6 CIDRs and rejects ambiguous inputs', () {
      expect(VpnRoutingPolicy.isValidCidr('0.0.0.0/0'), isTrue);
      expect(VpnRoutingPolicy.isValidCidr('10.20.0.0/16'), isTrue);
      expect(VpnRoutingPolicy.isValidCidr('::/0'), isTrue);
      expect(VpnRoutingPolicy.isValidCidr('fd00::/8'), isTrue);

      expect(VpnRoutingPolicy.isValidCidr('10.0.0.0'), isFalse);
      expect(VpnRoutingPolicy.isValidCidr('10.0.0.0/33'), isFalse);
      expect(VpnRoutingPolicy.isValidCidr('fd00::/129'), isFalse);
      expect(VpnRoutingPolicy.isValidCidr('fe80::1%en0/64'), isFalse);
      expect(VpnRoutingPolicy.isValidCidr('host.invalid/24'), isFalse);
    });

    test('DNS accepts literal IPs only', () {
      expect(VpnRoutingPolicy.isValidIp('1.1.1.1'), isTrue);
      expect(VpnRoutingPolicy.isValidIp('2606:4700:4700::1111'), isTrue);
      expect(VpnRoutingPolicy.isValidIp('resolver.example'), isFalse);
      expect(VpnRoutingPolicy.isValidIp('fe80::1%en0'), isFalse);
      expect(VpnRoutingPolicy.isValidIp('1.1.1.1/32'), isFalse);
    });

    test('include-only requires at least one subnet', () {
      const empty = VpnRoutingPolicy(routeMode: VpnRouteMode.includeOnly);
      expect(empty.isValid, isFalse);
      expect(empty.validate(), contains('includedCidrs.empty'));

      const configured = VpnRoutingPolicy(
        routeMode: VpnRouteMode.includeOnly,
        includedCidrs: ['10.0.0.0/8'],
      );
      expect(configured.isValid, isTrue);

      const geoConfigured = VpnRoutingPolicy(
        routeMode: VpnRouteMode.includeOnly,
        includedCountryCodes: ['KZ'],
      );
      expect(geoConfigured.isValid, isTrue);
    });

    test('validates MTU, routes and routed DNS as a unit', () {
      const invalid = VpnRoutingPolicy(
        mtu: 1000,
        excludedCidrs: ['bad'],
        dnsServers: [],
      );
      expect(
        invalid.validate(),
        containsAll(['mtu', 'excludedCidrs.invalid', 'dnsServers.empty']),
      );
    });

    test('round-trips all settings and tolerates an unknown enum', () {
      const policy = VpnRoutingPolicy(
        enabled: true,
        routeMode: VpnRouteMode.excludeOnly,
        includedCidrs: ['10.0.0.0/8'],
        excludedCidrs: ['192.168.0.0/16', 'fd00::/8'],
        includedCountryCodes: ['DE'],
        excludedCountryCodes: ['KZ', 'RU'],
        routeDns: false,
        dnsServers: ['9.9.9.9'],
        allowLan: false,
        mtu: 1400,
      );
      final back = VpnRoutingPolicy.fromJson(policy.toJson());
      expect(back.enabled, isTrue);
      expect(back.routeMode, VpnRouteMode.excludeOnly);
      expect(back.includedCidrs, ['10.0.0.0/8']);
      expect(back.excludedCidrs, ['192.168.0.0/16', 'fd00::/8']);
      expect(back.includedCountryCodes, ['DE']);
      expect(back.excludedCountryCodes, ['KZ', 'RU']);
      expect(back.routeDns, isFalse);
      expect(back.dnsServers, ['9.9.9.9']);
      expect(back.allowLan, isFalse);
      expect(back.mtu, 1400);

      final unknown = Map<String, dynamic>.from(policy.toJson())
        ..['routeMode'] = 'futureMode';
      expect(
        VpnRoutingPolicy.fromJson(unknown).routeMode,
        VpnRouteMode.allTraffic,
      );
    });

    test('validates country codes without pretending GeoIP is exact', () {
      expect(VpnRoutingPolicy.isValidCountryCode('KZ'), isTrue);
      expect(VpnRoutingPolicy.isValidCountryCode('kz'), isTrue);
      expect(VpnRoutingPolicy.isValidCountryCode('KAZ'), isFalse);
      expect(VpnRoutingPolicy.isValidCountryCode('1Z'), isFalse);
      expect(
        const VpnRoutingPolicy(excludedCountryCodes: ['KAZ']).isValid,
        isFalse,
      );
    });
  });

  group('GeoIpCountryRoutes', () {
    test('expands Kazakhstan into bundled IPv4 and IPv6 routes', () async {
      const policy = VpnRoutingPolicy(
        excludedCidrs: ['192.0.2.0/24'],
        excludedCountryCodes: ['kz'],
      );
      final expanded = await GeoIpCountryRoutes.expandPolicy(policy);
      final routes = (expanded['excludedCidrs'] as List).cast<String>();

      expect(routes, contains('192.0.2.0/24'));
      expect(routes.length, greaterThan(100));
      expect(routes.any((route) => route.contains(':')), isTrue);
      expect(expanded['geoIpGeneratedAt'], isNotEmpty);
    });

    test('fails closed for a country absent from the snapshot', () async {
      await expectLater(
        GeoIpCountryRoutes.expandPolicy(
          const VpnRoutingPolicy(excludedCountryCodes: ['XX']),
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('VpnBackendState', () {
    test('never treats malformed or unknown native responses as running', () {
      expect(VpnBackendState.fromMap(null).phase, VpnBackendPhase.error);
      expect(
        VpnBackendState.fromMap({'phase': 'future'}).phase,
        VpnBackendPhase.error,
      );
      expect(VpnBackendState.fromMap({'phase': 'running'}).isRunning, isTrue);
    });
  });
}
