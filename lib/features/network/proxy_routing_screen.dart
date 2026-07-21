import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/node/proxy_routing.dart';
import '../../data/vpn/vpn_backend.dart';
import '../../data/vpn/vpn_routing_policy.dart';
import '../../l10n/app_localizations.dart';
import '../../state/proxy_routing_controller.dart';
import '../../state/vpn_controller.dart';

/// "Маршрутизация трафика" — configure veil as a traffic proxy. Two independent
/// roles: route MY traffic out through an exit (SOCKS5 client), and/or serve as
/// an exit for others. Maps to veil's [proxy.socks5] / [proxy.exit] config; the
/// node picks the change up on its next (re)start.
class ProxyRoutingScreen extends ConsumerStatefulWidget {
  const ProxyRoutingScreen({super.key});

  @override
  ConsumerState<ProxyRoutingScreen> createState() => _ProxyRoutingScreenState();
}

class _ProxyRoutingScreenState extends ConsumerState<ProxyRoutingScreen> {
  late final TextEditingController _listen;
  late final TextEditingController _exitId;

  @override
  void initState() {
    super.initState();
    final cfg = ref.read(proxyRoutingProvider);
    _listen = TextEditingController(text: cfg.socks5Listen);
    _exitId = TextEditingController(text: cfg.exitNodeId ?? '');
  }

  @override
  void dispose() {
    _listen.dispose();
    _exitId.dispose();
    super.dispose();
  }

  void _save(ProxyRouting next) =>
      ref.read(proxyRoutingProvider.notifier).set(next);

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final cfg = ref.watch(proxyRoutingProvider);
    final scheme = Theme.of(context).colorScheme;
    final exitText = _exitId.text.trim();
    final exitInvalid = exitText.isNotEmpty && !_isHex64(exitText);
    final listenInvalid = !ProxyRouting.isValidListen(_listen.text.trim());

    return Scaffold(
      appBar: AppBar(title: Text(l.routeTitle)),
      body: ListView(
        children: [
          const _VpnSection(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              controller: _exitId,
              maxLines: 2,
              minLines: 1,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: InputDecoration(
                labelText: l.routeExitNodeLabel,
                helperText: l.routeExitNodeHint,
                helperMaxLines: 3,
                errorText: exitInvalid ? l.routeExitNodeInvalid : null,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (v) {
                final t = v.trim();
                setState(() {});
                _save(
                  cfg.copyWith(
                    exitNodeId: t.isEmpty ? null : t,
                    clearExitNodeId: t.isEmpty,
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              controller: _listen,
              decoration: InputDecoration(
                labelText: l.routeListenLabel,
                helperText: l.routeListenHint,
                errorText: listenInvalid ? l.routeListenInvalid : null,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (v) {
                setState(() {});
                _save(cfg.copyWith(socks5Listen: v.trim()));
              },
            ),
          ),
          const Divider(),
          // ── SOCKS5 client role ─────────────────────────────────────────
          SwitchListTile(
            secondary: const Icon(Icons.alt_route),
            title: Text(l.routeSocks5Title),
            subtitle: Text(l.routeSocks5Hint),
            isThreeLine: true,
            value: cfg.socks5Enabled,
            onChanged: (v) => _save(cfg.copyWith(socks5Enabled: v)),
          ),
          if (cfg.socks5Enabled) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: cfg.socks5Active
                  ? Row(
                      children: [
                        Icon(Icons.check_circle, size: 18, color: Colors.green),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            l.routeProxyAddress(cfg.socks5Listen),
                            style: TextStyle(color: scheme.primary),
                          ),
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        Icon(
                          Icons.info_outline,
                          size: 18,
                          color: scheme.outline,
                        ),
                        const SizedBox(width: 8),
                        Expanded(child: Text(l.routeNeedExit)),
                      ],
                    ),
            ),
          ],
          const Divider(),
          // ── Exit (serve others) role ───────────────────────────────────
          SwitchListTile(
            secondary: const Icon(Icons.exit_to_app),
            title: Text(l.routeServeTitle),
            subtitle: Text(l.routeServeHint),
            isThreeLine: true,
            value: cfg.exitEnabled,
            onChanged: (v) => _save(cfg.copyWith(exitEnabled: v)),
          ),
          if (cfg.exitEnabled)
            SwitchListTile(
              secondary: Icon(Icons.warning_amber, color: scheme.error),
              title: Text(l.routeAllowPrivate),
              subtitle: Text(l.routeAllowPrivateHint),
              isThreeLine: true,
              value: cfg.exitAllowPrivate,
              onChanged: (v) => _save(cfg.copyWith(exitAllowPrivate: v)),
            ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(Icons.refresh, size: 18, color: scheme.outline),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l.routeAppliesNextStart,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: scheme.outline),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static bool _isHex64(String s) =>
      s.length == 64 && RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(s);
}

class _VpnSection extends ConsumerStatefulWidget {
  const _VpnSection();

  @override
  ConsumerState<_VpnSection> createState() => _VpnSectionState();
}

class _VpnSectionState extends ConsumerState<_VpnSection> {
  late final TextEditingController _included;
  late final TextEditingController _excluded;
  late final TextEditingController _includedCountries;
  late final TextEditingController _excludedCountries;
  late final TextEditingController _dns;
  late final TextEditingController _mtu;
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    final policy = ref.read(vpnControllerProvider).policy;
    _included = TextEditingController(text: policy.includedCidrs.join('\n'));
    _excluded = TextEditingController(text: policy.excludedCidrs.join('\n'));
    _includedCountries = TextEditingController(
      text: policy.includedCountryCodes.join(', '),
    );
    _excludedCountries = TextEditingController(
      text: policy.excludedCountryCodes.join(', '),
    );
    _dns = TextEditingController(text: policy.dnsServers.join('\n'));
    _mtu = TextEditingController(text: policy.mtu.toString());
  }

  @override
  void dispose() {
    _included.dispose();
    _excluded.dispose();
    _includedCountries.dispose();
    _excludedCountries.dispose();
    _dns.dispose();
    _mtu.dispose();
    super.dispose();
  }

  List<String> _lines(String raw) => raw
      .split(RegExp(r'[\s,]+'))
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toList(growable: false);

  List<String> _countryCodes(String raw) => raw
      .split(RegExp(r'[\s,;]+'))
      .map((value) => value.trim().toUpperCase())
      .where((value) => value.isNotEmpty)
      .toSet()
      .toList(growable: false);

  void _configure(VpnRoutingPolicy policy) {
    _editing = true;
    ref.read(vpnControllerProvider.notifier).configure(policy);
  }

  void _syncLoadedPolicy(VpnRoutingPolicy policy) {
    if (_editing) return;
    _included.text = policy.includedCidrs.join('\n');
    _excluded.text = policy.excludedCidrs.join('\n');
    _includedCountries.text = policy.includedCountryCodes.join(', ');
    _excludedCountries.text = policy.excludedCountryCodes.join(', ');
    _dns.text = policy.dnsServers.join('\n');
    _mtu.text = policy.mtu.toString();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(
      vpnControllerProvider.select((value) => value.policy),
      (_, next) => _syncLoadedPolicy(next),
    );
    final l = AppL10n.of(context);
    final vpn = ref.watch(vpnControllerProvider);
    final proxy = ref.watch(proxyRoutingProvider);
    final policy = vpn.policy;
    final scheme = Theme.of(context).colorScheme;
    final includedInvalid = _lines(
      _included.text,
    ).any((value) => !VpnRoutingPolicy.isValidCidr(value));
    final excludedInvalid = _lines(
      _excluded.text,
    ).any((value) => !VpnRoutingPolicy.isValidCidr(value));
    final includedCountriesInvalid = _countryCodes(
      _includedCountries.text,
    ).any((value) => !VpnRoutingPolicy.isValidCountryCode(value));
    final excludedCountriesInvalid = _countryCodes(
      _excludedCountries.text,
    ).any((value) => !VpnRoutingPolicy.isValidCountryCode(value));
    final dnsInvalid = _lines(
      _dns.text,
    ).any((value) => !VpnRoutingPolicy.isValidIp(value));
    final parsedMtu = int.tryParse(_mtu.text);
    final mtuInvalid =
        parsedMtu == null || parsedMtu < 1280 || parsedMtu > 9000;
    final supported = vpn.backend.phase != VpnBackendPhase.unsupported;
    final canStart = supported && policy.isValid && proxy.vpnTransportReady;

    return ExpansionTile(
      leading: Icon(
        vpn.isRunning ? Icons.vpn_lock : Icons.vpn_lock_outlined,
        color: vpn.isRunning ? Colors.green : scheme.outline,
      ),
      title: Text(l.vpnTitle),
      subtitle: Text(switch (vpn.backend.phase) {
        VpnBackendPhase.running => l.vpnStatusRunning,
        VpnBackendPhase.starting => l.vpnStatusStarting,
        VpnBackendPhase.stopping => l.vpnStatusStopping,
        VpnBackendPhase.error => vpn.backend.detail ?? l.vpnStatusError,
        VpnBackendPhase.unsupported => l.vpnStatusUnsupported,
        VpnBackendPhase.stopped => l.vpnStatusStopped,
      }),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        Align(alignment: Alignment.centerLeft, child: Text(l.vpnHint)),
        const SizedBox(height: 16),
        DropdownButtonFormField<VpnRouteMode>(
          initialValue: policy.routeMode,
          decoration: InputDecoration(
            labelText: l.vpnRouteMode,
            border: const OutlineInputBorder(),
          ),
          items: [
            DropdownMenuItem(
              value: VpnRouteMode.allTraffic,
              child: Text(l.vpnRouteAll),
            ),
            DropdownMenuItem(
              value: VpnRouteMode.includeOnly,
              child: Text(l.vpnRouteInclude),
            ),
            DropdownMenuItem(
              value: VpnRouteMode.excludeOnly,
              child: Text(l.vpnRouteExclude),
            ),
          ],
          onChanged: vpn.isRunning || vpn.busy
              ? null
              : (value) {
                  if (value != null) {
                    _configure(policy.copyWith(routeMode: value));
                  }
                },
        ),
        if (policy.routeMode == VpnRouteMode.includeOnly) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _included,
            enabled: !vpn.isRunning && !vpn.busy,
            minLines: 2,
            maxLines: 5,
            decoration: InputDecoration(
              labelText: l.vpnIncludedCidrs,
              helperText: l.vpnCidrsHint,
              errorText: includedInvalid ? l.vpnCidrsInvalid : null,
              border: const OutlineInputBorder(),
            ),
            onChanged: (raw) {
              setState(() {});
              _configure(policy.copyWith(includedCidrs: _lines(raw)));
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _includedCountries,
            enabled: !vpn.isRunning && !vpn.busy,
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(
              labelText: l.vpnIncludedCountries,
              helperText: l.vpnCountriesHint,
              errorText: includedCountriesInvalid
                  ? l.vpnCountriesInvalid
                  : null,
              border: const OutlineInputBorder(),
            ),
            onChanged: (raw) {
              setState(() {});
              _configure(
                policy.copyWith(includedCountryCodes: _countryCodes(raw)),
              );
            },
          ),
        ],
        if (policy.routeMode != VpnRouteMode.includeOnly) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _excluded,
            enabled: !vpn.isRunning && !vpn.busy,
            minLines: 2,
            maxLines: 5,
            decoration: InputDecoration(
              labelText: l.vpnExcludedCidrs,
              helperText: l.vpnCidrsHint,
              errorText: excludedInvalid ? l.vpnCidrsInvalid : null,
              border: const OutlineInputBorder(),
            ),
            onChanged: (raw) {
              setState(() {});
              _configure(policy.copyWith(excludedCidrs: _lines(raw)));
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _excludedCountries,
            enabled: !vpn.isRunning && !vpn.busy,
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(
              labelText: l.vpnExcludedCountries,
              helperText: l.vpnCountriesHint,
              errorText: excludedCountriesInvalid
                  ? l.vpnCountriesInvalid
                  : null,
              border: const OutlineInputBorder(),
            ),
            onChanged: (raw) {
              setState(() {});
              _configure(
                policy.copyWith(excludedCountryCodes: _countryCodes(raw)),
              );
            },
          ),
        ],
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(l.vpnRouteDns),
          subtitle: Text(l.vpnRouteDnsHint),
          value: policy.routeDns,
          onChanged: vpn.isRunning || vpn.busy
              ? null
              : (value) => _configure(policy.copyWith(routeDns: value)),
        ),
        if (policy.routeDns)
          TextField(
            controller: _dns,
            enabled: !vpn.isRunning && !vpn.busy,
            minLines: 2,
            maxLines: 4,
            decoration: InputDecoration(
              labelText: l.vpnDnsServers,
              helperText: l.vpnDnsHint,
              errorText: dnsInvalid ? l.vpnDnsInvalid : null,
              border: const OutlineInputBorder(),
            ),
            onChanged: (raw) {
              setState(() {});
              _configure(policy.copyWith(dnsServers: _lines(raw)));
            },
          ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(l.vpnAllowLan),
          subtitle: Text(l.vpnAllowLanHint),
          value: policy.allowLan,
          onChanged: vpn.isRunning || vpn.busy
              ? null
              : (value) => _configure(policy.copyWith(allowLan: value)),
        ),
        TextField(
          controller: _mtu,
          enabled: !vpn.isRunning && !vpn.busy,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: l.vpnMtu,
            helperText: l.vpnMtuHint,
            errorText: mtuInvalid ? l.vpnMtuInvalid : null,
            border: const OutlineInputBorder(),
          ),
          onChanged: (raw) {
            setState(() {});
            final value = int.tryParse(raw);
            if (value != null) _configure(policy.copyWith(mtu: value));
          },
        ),
        const SizedBox(height: 12),
        if (!proxy.vpnTransportReady)
          Align(
            alignment: Alignment.centerLeft,
            child: Text(l.vpnNeedsProxy, style: TextStyle(color: scheme.error)),
          ),
        if (!supported)
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              l.vpnUnsupportedDetail,
              style: TextStyle(color: scheme.outline),
            ),
          ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            key: const ValueKey('vpn-toggle'),
            onPressed: vpn.busy || (!vpn.isRunning && !canStart)
                ? null
                : vpn.isRunning
                ? ref.read(vpnControllerProvider.notifier).stop
                : ref.read(vpnControllerProvider.notifier).start,
            icon: Icon(vpn.isRunning ? Icons.stop : Icons.play_arrow),
            label: Text(vpn.isRunning ? l.vpnStop : l.vpnStart),
          ),
        ),
      ],
    );
  }
}
