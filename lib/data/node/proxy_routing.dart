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

  /// Whether the SOCKS5 client role is fully configured (enabled + a valid
  /// 64-hex exit). A SOCKS5 toggle without an exit is inert in veil, so the UI
  /// treats it as not-yet-active.
  bool get socks5Active =>
      socks5Enabled &&
      exitNodeId != null &&
      _isHex64(exitNodeId!);

  /// Whether anything routing-related is on (drives the config injection + the
  /// network-screen "active" badge).
  bool get isActive => socks5Active || exitEnabled;

  static bool _isHex64(String s) =>
      s.length == 64 && RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(s);

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
