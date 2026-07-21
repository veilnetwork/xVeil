import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/proxy_routing.dart';
import 'package:xveil/data/vpn/vpn_proxy_plan.dart';
import 'package:xveil/features/network/security_center_sheet.dart';
import 'package:xveil/data/vpn/vpn_routing_policy.dart';

const _first =
    '1111111111111111111111111111111111111111111111111111111111111111';
const _second =
    '2222222222222222222222222222222222222222222222222222222222222222';
const _third =
    '3333333333333333333333333333333333333333333333333333333333333333';
const _unknown =
    '0000000000000000000000000000000000000000000000000000000000000000';

const _routing = ProxyRouting(
  oProxies: [
    OproxyEndpoint(nodeId: _first, label: 'KZ'),
    OproxyEndpoint(nodeId: _second, label: 'DE'),
    OproxyEndpoint(nodeId: _third, label: 'NL'),
  ],
  defaultOproxyNodeIds: [_first, _second],
);

void main() {
  test('security center accepts an explicit VPN chain without a default', () {
    const routing = ProxyRouting(
      oProxies: [OproxyEndpoint(nodeId: _first, label: 'Primary')],
    );
    const policy = VpnRoutingPolicy(vpnOproxyNodeIds: [_first]);

    expect(routing.vpnTransportReady, isFalse);
    expect(vpnTransportReadyForPolicy(routing, policy), isTrue);
  });

  test('allocates one listener per unique ordered exit chain', () {
    final plan = VpnProxyPlan.build(
      routing: _routing,
      policy: const VpnRoutingPolicy(
        applicationOproxyNodeIds: {
          'org.mozilla.firefox': [_third, _second],
          'com.android.chrome': [_first, _second],
        },
      ),
    );

    expect(plan.defaultListen, '127.0.0.1:1080');
    expect(plan.profiles, hasLength(2));
    expect(plan.profiles.first.exitNodeIds, [_first, _second]);
    expect(plan.applicationListens['com.android.chrome'], '127.0.0.1:1080');
    expect(plan.applicationListens['org.mozilla.firefox'], '127.0.0.1:1081');
  });

  test('disabled failover keeps only the primary candidate', () {
    final plan = VpnProxyPlan.build(
      routing: _routing,
      policy: const VpnRoutingPolicy(oproxyAutoFailover: false),
    );
    expect(plan.profiles.single.exitNodeIds, [_first]);
  });

  test('unknown saved exit fails closed', () {
    expect(
      () => VpnProxyPlan.build(
        routing: _routing,
        policy: const VpnRoutingPolicy(vpnOproxyNodeIds: [_unknown]),
      ),
      throwsA(isA<VpnProxyPlanException>()),
    );
  });

  test('manual SOCKS with another chain retains its base port', () {
    final plan = VpnProxyPlan.build(
      routing: const ProxyRouting(
        socks5Enabled: true,
        oProxies: [
          OproxyEndpoint(nodeId: _first, label: 'KZ'),
          OproxyEndpoint(nodeId: _second, label: 'DE'),
        ],
        defaultOproxyNodeIds: [_first],
      ),
      policy: const VpnRoutingPolicy(vpnOproxyNodeIds: [_second]),
    );
    expect(plan.defaultListen, '127.0.0.1:1081');
  });
}
