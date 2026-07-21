import '../node/proxy_routing.dart';
import 'vpn_routing_policy.dart';

class VpnProxyPlanException implements Exception {
  const VpnProxyPlanException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Materialized local SOCKS listeners for one VPN start.
///
/// Each unique ordered exit chain gets one listener. Android's flow selector
/// maps package UIDs to these listeners; Linux/Windows/Apple use
/// [defaultListen] and reject per-app overrides until they have an equivalent
/// process-aware selector.
class VpnProxyPlan {
  static const maxProfiles = 32;

  const VpnProxyPlan({
    required this.defaultListen,
    required this.profiles,
    required this.applicationListens,
  });

  final String defaultListen;
  final List<ProxySocksProfile> profiles;
  final Map<String, String> applicationListens;

  static VpnProxyPlan build({
    required ProxyRouting routing,
    required VpnRoutingPolicy policy,
  }) {
    if (!ProxyRouting.isValidListen(routing.socks5Listen)) {
      throw const VpnProxyPlanException('invalid local SOCKS5 listen address');
    }
    final known = routing.effectiveOproxies
        .map((endpoint) => endpoint.nodeId)
        .toSet();
    final configuredDefault = policy.vpnOproxyNodeIds.isEmpty
        ? routing.effectiveDefaultOproxyNodeIds
        : policy.vpnOproxyNodeIds;
    final defaultChain = _normalizeChain(
      configuredDefault,
      known: known,
      autoFailover: policy.oproxyAutoFailover,
      description: 'default VPN',
    );

    final chainToListen = <String, String>{};
    final profiles = <ProxySocksProfile>[];
    var nextPort = _port(routing.socks5Listen);
    final manualChain = routing.socks5Active
        ? routing.effectiveDefaultOproxyNodeIds
        : const <String>[];

    String allocate(List<String> chain) {
      final key = chain.join(':');
      final existing = chainToListen[key];
      if (existing != null) return existing;
      final useBasePort =
          profiles.isEmpty &&
          (manualChain.isEmpty || _sameChain(chain, manualChain));
      if (!useBasePort) nextPort += 1;
      if (nextPort > 65535) {
        throw const VpnProxyPlanException('not enough local SOCKS5 ports');
      }
      if (profiles.length >= maxProfiles) {
        throw const VpnProxyPlanException(
          'too many distinct application oproxy chains (maximum 32)',
        );
      }
      final listen = _withPort(routing.socks5Listen, nextPort);
      chainToListen[key] = listen;
      profiles.add(ProxySocksProfile(listen: listen, exitNodeIds: chain));
      return listen;
    }

    final defaultListen = allocate(defaultChain);
    final applicationListens = <String, String>{};
    for (final entry in policy.applicationOproxyNodeIds.entries) {
      final chain = _normalizeChain(
        entry.value,
        known: known,
        autoFailover: policy.oproxyAutoFailover,
        description: entry.key,
      );
      applicationListens[entry.key] = allocate(chain);
    }
    return VpnProxyPlan(
      defaultListen: defaultListen,
      profiles: profiles,
      applicationListens: applicationListens,
    );
  }

  static List<String> _normalizeChain(
    List<String> values, {
    required Set<String> known,
    required bool autoFailover,
    required String description,
  }) {
    final chain = values.toSet().toList(growable: false);
    if (chain.isEmpty) {
      throw VpnProxyPlanException('$description oproxy chain is empty');
    }
    final missing = chain.where((nodeId) => !known.contains(nodeId)).toList();
    if (missing.isNotEmpty) {
      throw VpnProxyPlanException(
        '$description references an unknown oproxy ${missing.first}',
      );
    }
    return autoFailover ? chain : [chain.first];
  }

  static int _port(String listen) =>
      int.parse(listen.substring(listen.lastIndexOf(':') + 1));

  static String _withPort(String listen, int port) =>
      '${listen.substring(0, listen.lastIndexOf(':') + 1)}$port';

  static bool _sameChain(List<String> left, List<String> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }
}
