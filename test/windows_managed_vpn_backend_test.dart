import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/vpn/vpn_backend.dart';
import 'package:xveil/data/vpn/vpn_routing_policy.dart';
import 'package:xveil/data/vpn/windows_managed_vpn_backend.dart';

void main() {
  test('Windows helper request exposes only the closed privileged schema', () {
    final request = buildWindowsVpnHelperRequest(
      hostPid: 77,
      token: 'ab' * 32,
      socks5Listen: '127.0.0.1:1080',
      expandedPolicy: <String, dynamic>{
        'enabled': true,
        'routeMode': 'excludeOnly',
        'includedCidrs': <String>[],
        'excludedCidrs': <String>['10.0.0.0/8'],
        'routeDns': false,
        'dnsServers': <String>['1.1.1.1'],
        'allowLan': true,
        'mtu': 1400,
        'includedCountryCodes': <String>['KZ'],
        'excludedCountryCodes': <String>['RU'],
      },
    );

    expect(request.keys, ['hostPid', 'token', 'socks5Listen', 'policy']);
    final policy = request['policy']! as Map<String, Object?>;
    expect(policy.keys, [
      'routeMode',
      'includedCidrs',
      'excludedCidrs',
      'routeDns',
      'dnsServers',
      'allowLan',
      'mtu',
    ]);
    expect(policy, isNot(contains('enabled')));
    expect(policy, isNot(contains('includedCountryCodes')));
    expect(policy, isNot(contains('excludedCountryCodes')));
  });

  test('PowerShell elevation quotes paths without interpolation', () {
    final script = buildWindowsVpnElevationScript(
      r"C:\Program Files\x'veil\xveil.exe",
      r'C:\Users\A Name\Temp\request.json',
    );

    expect(script, contains(r"$exe = 'C:\Program Files\x''veil\xveil.exe'"));
    expect(script, contains(r"$request = 'C:\Users\A Name\Temp\request.json'"));
    expect(
      script,
      contains(r'''$arguments = '--xveil-vpn-helper "' + $request + '"';'''),
    );
  });

  test(
    'Windows rejects application filtering instead of routing every app',
    () async {
      final result = await WindowsManagedVpnBackend().start(
        policy: const VpnRoutingPolicy(
          applicationMode: VpnApplicationMode.onlySelected,
          applicationIds: ['org.mozilla.firefox'],
        ),
        socks5Listen: '127.0.0.1:1080',
        exitNodeId: '00' * 32,
        exitNodeIds: ['00' * 32],
      );
      expect(result.phase, VpnBackendPhase.error);
      expect(result.detail, contains('not supported'));
    },
  );
}
