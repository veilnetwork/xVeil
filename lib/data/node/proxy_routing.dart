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
class ProxyRouting {
  const ProxyRouting({
    this.socks5Enabled = false,
    this.socks5Listen = defaultListen,
    this.exitNodeId,
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
  bool get socks5Active =>
      socks5Enabled &&
      exitNodeId != null &&
      _isHex64(exitNodeId!) &&
      isValidListen(socks5Listen);

  /// Whether anything routing-related is on (drives the config injection + the
  /// network-screen "active" badge).
  bool get isActive => socks5Active || exitEnabled;

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
    bool? exitEnabled,
    bool? exitAllowPrivate,
  }) =>
      ProxyRouting(
        socks5Enabled: socks5Enabled ?? this.socks5Enabled,
        socks5Listen: socks5Listen ?? this.socks5Listen,
        exitNodeId: clearExitNodeId ? null : (exitNodeId ?? this.exitNodeId),
        exitEnabled: exitEnabled ?? this.exitEnabled,
        exitAllowPrivate: exitAllowPrivate ?? this.exitAllowPrivate,
      );

  Map<String, dynamic> toJson() => {
        'socks5Enabled': socks5Enabled,
        'socks5Listen': socks5Listen,
        if (exitNodeId != null) 'exitNodeId': exitNodeId,
        'exitEnabled': exitEnabled,
        'exitAllowPrivate': exitAllowPrivate,
      };

  factory ProxyRouting.fromJson(Map<String, dynamic> json) => ProxyRouting(
        socks5Enabled: json['socks5Enabled'] as bool? ?? false,
        socks5Listen: json['socks5Listen'] as String? ?? defaultListen,
        exitNodeId: json['exitNodeId'] as String?,
        exitEnabled: json['exitEnabled'] as bool? ?? false,
        exitAllowPrivate: json['exitAllowPrivate'] as bool? ?? false,
      );

  static const disabled = ProxyRouting();
}
