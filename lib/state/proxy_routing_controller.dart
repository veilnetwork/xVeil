import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/node/proxy_routing.dart';
import 'providers.dart';

const _kProxyRoutingKey = 'proxy_routing';

/// Persisted traffic-routing config ("Маршрутизация трафика"). Stored in
/// `shared_preferences` as JSON; default = everything off.
///
/// This is OPERATIONAL config (a SOCKS5 listen port, an exit node_id, an
/// exit-proxy toggle) — public network identifiers, not container secrets — so
/// it lives alongside the other app settings rather than inside the encrypted
/// container. It is read at node boot ([RealVeilStack.startDeniable]); changing
/// it takes effect on the next node start (the node pins the proxy services from
/// the config it boots/applies).
class ProxyRoutingController extends Notifier<ProxyRouting> {
  bool _userSet = false;

  @override
  ProxyRouting build() {
    _load();
    return ProxyRouting.disabled;
  }

  Future<void> _load() async {
    try {
      final prefs = await ref.read(prefsProvider.future);
      final raw = prefs.getString(_kProxyRoutingKey);
      if (raw != null && !_userSet) {
        state = ProxyRouting.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      }
    } catch (_) {
      // No prefs (widget tests) — stay on the safe default (all off).
    }
  }

  Future<void> set(ProxyRouting value) async {
    _userSet = true;
    state = value;
    try {
      final prefs = await ref.read(prefsProvider.future);
      await prefs.setString(_kProxyRoutingKey, jsonEncode(value.toJson()));
    } catch (_) {
      // Persist best-effort; the in-memory state still drives the next boot.
    }
  }
}

final proxyRoutingProvider =
    NotifierProvider<ProxyRoutingController, ProxyRouting>(
      ProxyRoutingController.new,
    );

/// Runtime ownership of the local SOCKS transport by the system VPN.
///
/// This is intentionally not persisted as part of [ProxyRouting]: the native
/// VPN backend is the durable authority for whether a tunnel is running, while
/// [ProxyRouting.socks5Enabled] remains the user's independent manual-proxy
/// preference.
final vpnProxyDemandProvider = StateProvider<bool>((ref) => false);

/// Node configuration after combining the manual SOCKS preference with the
/// system VPN's runtime requirement. UI and preferences continue to use
/// [proxyRoutingProvider]; only node boot/reload paths consume this provider.
final effectiveProxyRoutingProvider = Provider<ProxyRouting>((ref) {
  final configured = ref.watch(proxyRoutingProvider);
  if (!ref.watch(vpnProxyDemandProvider)) return configured;
  return configured.copyWith(socks5Enabled: true);
});
