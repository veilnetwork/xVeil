import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/vpn/linux_managed_vpn_backend.dart';
import 'package:xveil/data/vpn/vpn_backend.dart';
import 'package:xveil/data/vpn/vpn_routing_policy.dart';

void main() {
  test('Linux helper request exposes only the closed privileged schema', () {
    final request = buildLinuxVpnHelperRequest(
      hostPid: 42,
      socks5Listen: '127.0.0.1:1080',
      expandedPolicy: <String, dynamic>{
        'enabled': true,
        'routeMode': 'excludeOnly',
        'includedCidrs': <String>[],
        'excludedCidrs': <String>['203.0.113.0/24'],
        'includedCountryCodes': <String>[],
        'excludedCountryCodes': <String>['KZ'],
        'geoIpGeneratedAt': '2026-07-20',
        'routeDns': false,
        'dnsServers': <String>['1.1.1.1'],
        'allowLan': true,
        'mtu': 1280,
      },
    );

    expect(request['hostPid'], 42);
    expect(request['socks5Listen'], '127.0.0.1:1080');
    final policy = request['policy']! as Map<String, Object?>;
    expect(policy.keys, <String>{
      'routeMode',
      'includedCidrs',
      'excludedCidrs',
      'routeDns',
      'dnsServers',
      'allowLan',
      'mtu',
    });
    expect(policy['excludedCidrs'], <String>['203.0.113.0/24']);
    expect(policy['routeDns'], isFalse);
    expect(policy, isNot(contains('enabled')));
    expect(policy, isNot(contains('geoIpGeneratedAt')));
  });

  test(
    'Linux rejects application filtering instead of routing every app',
    () async {
      final result = await LinuxManagedVpnBackend().start(
        policy: const VpnRoutingPolicy(
          applicationMode: VpnApplicationMode.onlySelected,
          applicationIds: ['org.mozilla.firefox'],
        ),
        socks5Listen: '127.0.0.1:1080',
        exitNodeId: '00' * 32,
      );
      expect(result.phase, VpnBackendPhase.error);
      expect(result.detail, contains('not supported'));
    },
  );
}
