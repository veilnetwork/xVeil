/// User-facing traffic-routing config for the embedded veil node — the
/// "Маршрутизация трафика" feature. Maps to veil's `[proxy.socks5]` /
/// `[proxy.exit]` config sections, which the node runtime spawns as services
/// (and re-spawns on apply-config reload, so this can be toggled without a
/// native rebuild).
///
/// Two independent roles:
///  * **SOCKS5 (client routing)** — bind a local SOCKS5 listener and tunnel its
///    TCP streams through the overlay to [exitNodeId]. Point a browser / system
///    proxy at [socks5Listen] to route traffic through veil (censorship +
///    location circumvention). Requires an [exitNodeId] to route through.
///  * **Exit (serve others)** — accept proxy-connect streams from peers and
///    egress them to the clearnet. Turns THIS node into an exit others can route
///    through; more exits = a healthier censorship-resistant network.
class OproxyEndpoint {
  const OproxyEndpoint({required this.nodeId, required this.label});

  final String nodeId;
  final String label;

  Map<String, dynamic> toJson() => {'nodeId': nodeId, 'label': label};

  factory OproxyEndpoint.fromJson(Map<String, dynamic> json) => OproxyEndpoint(
    nodeId: json['nodeId'] as String? ?? '',
    label: json['label'] as String? ?? '',
  );
}

/// One local SOCKS listener backed by an ordered primary/fallback exit chain.
/// Runtime profiles are derived from VPN app rules and are never persisted in
/// [ProxyRouting]; the user-facing durable data is the endpoint catalog.
class ProxySocksProfile {
  const ProxySocksProfile({required this.listen, required this.exitNodeIds});

  final String listen;
  final List<String> exitNodeIds;
}

/// The catalog to save after a deployment finishes, or null to leave it alone.
///
/// What makes a node routable by THIS app is veil's `[proxy.exit]`: the node
/// runtime registers the well-known exit app id only when that is enabled
/// (`spawn_exit_proxy` returns `None` otherwise), and the app's connector dials
/// nothing else. So the catalog entry follows the exit, and the deployment
/// screen's exit switch is the thing that decides it.
///
/// It used to follow the `oproxy-server` COMPONENT instead. That is a separate
/// program answering a separate, derived `app_id(node_id, "oproxy", app_name)`
/// which this app never speaks -- so the old rule was wrong in both directions:
/// deploying oproxy-server with the exit switch off registered an entry nothing
/// could dial, and deploying an exit WITHOUT oproxy-server -- the default --
/// registered nothing, leaving a 64-hex node id to be typed in by hand. The
/// first live run of this flow hit the second half.
///
/// Pure, and it takes the decision rather than reading it, so both the "add"
/// and the "leave alone" branches are reachable from a plain unit test.
ProxyRouting? routingWithDeployedExit(
  ProxyRouting routing, {
  required bool isExit,
  required String? nodeId,
  required String label,
}) {
  if (!isExit) return null;
  final id = nodeId?.trim().toLowerCase();
  if (id == null || !ProxyRouting.isValidNodeId(id)) return null;
  // Against the EFFECTIVE catalog: a node already named by the default chain is
  // routable and must not be added a second time under a different label.
  if (routing.effectiveOproxies.any((e) => e.nodeId == id)) return null;
  return routing.copyWith(
    oProxies: [
      ...routing.oProxies,
      OproxyEndpoint(
        nodeId: id,
        label: label.trim().isEmpty
            ? 'oproxy ${id.substring(0, 8)}'
            : label.trim(),
      ),
    ],
  );
}

/// What the VPN is still missing before it can bring its transport up.
enum VpnTransportGap {
  /// No exit to route through: the catalog names none, and the legacy single
  /// exit is unset too.
  noExit,

  /// The local SOCKS5 listen address is not a loopback `host:port`.
  badListen,
}

class ProxyRouting {
  const ProxyRouting({
    this.socks5Enabled = false,
    this.socks5Listen = defaultListen,
    this.exitNodeId,
    this.oProxies = const [],
    this.defaultOproxyNodeIds = const [],
    this.runtimeSocksProfiles = const [],
    this.exitEnabled = false,
    this.exitAllowPrivate = false,
  });

  static const defaultListen = '127.0.0.1:1080';

  /// Bind the local SOCKS5 listener and route its streams through [exitNodeId].
  final bool socks5Enabled;

  /// Local bind address for the SOCKS5 listener (host:port).
  final String socks5Listen;

  /// 64-hex node_id of the exit to route SOCKS5 streams through. Required for
  /// [socks5Enabled] to take effect (the node skips an exit-less SOCKS5).
  final String? exitNodeId;

  /// Saved exit catalog. Node IDs are stable routing identifiers; labels are
  /// local-only descriptions such as a country/provider name.
  final List<OproxyEndpoint> oProxies;

  /// Ordered default primary/fallback chain used by manual SOCKS and as the
  /// initial VPN chain. Old configs transparently fall back to [exitNodeId].
  final List<String> defaultOproxyNodeIds;

  /// Ephemeral listeners required by the currently running VPN app rules.
  /// Deliberately excluded from JSON.
  final List<ProxySocksProfile> runtimeSocksProfiles;

  /// Run an exit proxy on this node (egress peers' streams to the clearnet).
  final bool exitEnabled;

  /// Let the exit reach private/loopback/link-local ranges. OFF by default —
  /// a public exit must refuse RFC1918 / metadata endpoints (SSRF guard).
  final bool exitAllowPrivate;

  /// Whether the SOCKS5 client role is fully configured: enabled, a valid
  /// 64-hex exit, AND a safe loopback listen address. This is also the gate
  /// [EmbeddedNode.withProxy] uses before interpolating [socks5Listen] into the
  /// node's TOML — so an invalid/injection-bearing listen is never emitted
  /// (fail-closed). A SOCKS5 toggle missing any of these is inert in veil.
  bool get socks5Active => socks5Enabled && vpnTransportReady;

  List<String> get effectiveDefaultOproxyNodeIds {
    final configured = defaultOproxyNodeIds
        .where(_isHex64)
        .toSet()
        .toList(growable: false);
    if (configured.isNotEmpty) return configured;
    final legacy = exitNodeId;
    return legacy != null && _isHex64(legacy) ? [legacy] : const [];
  }

  List<OproxyEndpoint> get effectiveOproxies {
    final byNode = <String, OproxyEndpoint>{};
    for (final endpoint in oProxies) {
      if (_isHex64(endpoint.nodeId)) byNode[endpoint.nodeId] = endpoint;
    }
    for (final nodeId in effectiveDefaultOproxyNodeIds) {
      byNode.putIfAbsent(
        nodeId,
        () => OproxyEndpoint(
          nodeId: nodeId,
          label: 'oproxy ${nodeId.substring(0, 8)}',
        ),
      );
    }
    return byNode.values.toList(growable: false);
  }

  /// Whether the shared exit/listen settings are sufficient for the system
  /// VPN to provision its own local SOCKS transport. Unlike [socks5Active],
  /// this deliberately does not depend on the manual SOCKS5 toggle: that
  /// toggle controls whether the listener remains available for applications
  /// when the system VPN is off.
  bool get vpnTransportReady => vpnTransportGap == null;

  /// WHICH of the two requirements is missing, or null when neither is.
  ///
  /// [vpnTransportReady] is a conjunction of two unrelated things — an exit to
  /// route through, and a local address to listen on — and the screen used to
  /// answer both with one sentence: "choose a valid exit node". Someone whose
  /// exit chain was fine and whose listen address was not was sent to fix the
  /// wrong thing, with the VPN button greyed out and no way to tell why. It
  /// costs a reader minutes; measured on myself, hunting an exit chain that
  /// was correct while `127.0.0.1: by1080` sat in the field above it.
  VpnTransportGap? get vpnTransportGap {
    if (effectiveDefaultOproxyNodeIds.isEmpty) return VpnTransportGap.noExit;
    if (!isValidListen(socks5Listen)) return VpnTransportGap.badListen;
    return null;
  }

  /// Whether anything routing-related is on (drives the config injection + the
  /// network-screen "active" badge).
  bool get isActive =>
      socks5Active || runtimeSocksProfiles.isNotEmpty || exitEnabled;

  static bool isValidNodeId(String s) => _isHex64(s);

  static bool _isHex64(String s) =>
      s.length == 64 && RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(s);

  /// A SOCKS5 listen address is valid only as `host:port` where the host is
  /// LOOPBACK and the port is 1–65535. Two reasons, both security:
  ///  * it forbids TOML-breaking characters (`" \n \r \\`), so the value can be
  ///    interpolated into the node config without injection;
  ///  * it forbids non-loopback hosts (e.g. `0.0.0.0`), so the proxy can't be
  ///    accidentally exposed as an OPEN proxy on the LAN/internet.
  static bool isValidListen(String listen) {
    if (listen.contains(RegExp(r'["\n\r\\\t]'))) return false;
    final i = listen.lastIndexOf(':');
    if (i <= 0 || i >= listen.length - 1) return false;
    final host = listen.substring(0, i);
    final port = int.tryParse(listen.substring(i + 1));
    if (port == null || port < 1 || port > 65535) return false;
    const loopback = {'127.0.0.1', 'localhost', '::1', '[::1]'};
    return loopback.contains(host);
  }

  ProxyRouting copyWith({
    bool? socks5Enabled,
    String? socks5Listen,
    String? exitNodeId,
    bool clearExitNodeId = false,
    List<OproxyEndpoint>? oProxies,
    List<String>? defaultOproxyNodeIds,
    List<ProxySocksProfile>? runtimeSocksProfiles,
    bool? exitEnabled,
    bool? exitAllowPrivate,
  }) => ProxyRouting(
    socks5Enabled: socks5Enabled ?? this.socks5Enabled,
    socks5Listen: socks5Listen ?? this.socks5Listen,
    exitNodeId: clearExitNodeId ? null : (exitNodeId ?? this.exitNodeId),
    oProxies: oProxies ?? this.oProxies,
    defaultOproxyNodeIds: defaultOproxyNodeIds ?? this.defaultOproxyNodeIds,
    runtimeSocksProfiles: runtimeSocksProfiles ?? this.runtimeSocksProfiles,
    exitEnabled: exitEnabled ?? this.exitEnabled,
    exitAllowPrivate: exitAllowPrivate ?? this.exitAllowPrivate,
  );

  Map<String, dynamic> toJson() => {
    'socks5Enabled': socks5Enabled,
    'socks5Listen': socks5Listen,
    if (exitNodeId != null) 'exitNodeId': exitNodeId,
    'oproxies': oProxies.map((value) => value.toJson()).toList(),
    'defaultOproxyNodeIds': defaultOproxyNodeIds,
    'exitEnabled': exitEnabled,
    'exitAllowPrivate': exitAllowPrivate,
  };

  factory ProxyRouting.fromJson(Map<String, dynamic> json) => ProxyRouting(
    socks5Enabled: json['socks5Enabled'] as bool? ?? false,
    socks5Listen: json['socks5Listen'] as String? ?? defaultListen,
    exitNodeId: json['exitNodeId'] as String?,
    oProxies: _oproxies(json['oproxies']),
    defaultOproxyNodeIds: _strings(json['defaultOproxyNodeIds']),
    exitEnabled: json['exitEnabled'] as bool? ?? false,
    exitAllowPrivate: json['exitAllowPrivate'] as bool? ?? false,
  );

  static List<String> _strings(Object? value) => value is List
      ? value.whereType<String>().toSet().toList(growable: false)
      : const [];

  static List<OproxyEndpoint> _oproxies(Object? value) => value is List
      ? value
            .whereType<Map>()
            .map(
              (item) =>
                  OproxyEndpoint.fromJson(Map<String, dynamic>.from(item)),
            )
            .where(
              (item) => _isHex64(item.nodeId) && item.label.trim().isNotEmpty,
            )
            .toList(growable: false)
      : const [];

  static const disabled = ProxyRouting();
}
