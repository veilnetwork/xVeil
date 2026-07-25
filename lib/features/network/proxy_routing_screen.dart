import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/node/proxy_routing.dart';
import '../../data/vpn/vpn_backend.dart';
import '../../data/vpn/vpn_application_catalog.dart';
import '../../data/vpn/vpn_routing_policy.dart';
import '../../l10n/app_localizations.dart';
import '../../routing/back_affordance.dart';
import '../../state/proxy_routing_controller.dart';
import '../../state/vpn_controller.dart';
import '../../state/vpn_application_catalog.dart';

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

  @override
  void initState() {
    super.initState();
    final cfg = ref.read(proxyRoutingProvider);
    _listen = TextEditingController(text: cfg.socks5Listen);
  }

  @override
  void dispose() {
    _listen.dispose();
    super.dispose();
  }

  void _save(ProxyRouting next) =>
      ref.read(proxyRoutingProvider.notifier).set(next);

  Future<void> _editOproxy(ProxyRouting cfg, [OproxyEndpoint? existing]) async {
    final l = AppL10n.of(context);
    var label = existing?.label ?? '';
    var nodeId = existing?.nodeId ?? '';
    final result = await showDialog<OproxyEndpoint>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final id = nodeId.trim();
          final valid =
              label.trim().isNotEmpty && ProxyRouting.isValidNodeId(id);
          return AlertDialog(
            title: Text(
              existing == null ? l.oproxyAddTitle : l.oproxyEditTitle,
            ),
            content: SizedBox(
              width: 520,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    initialValue: label,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: l.oproxyName,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (value) => setDialogState(() => label = value),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    initialValue: nodeId,
                    minLines: 1,
                    maxLines: 2,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                    decoration: InputDecoration(
                      labelText: l.routeExitNodeLabel,
                      errorText:
                          id.isNotEmpty && !ProxyRouting.isValidNodeId(id)
                          ? l.routeExitNodeInvalid
                          : null,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (value) => setDialogState(() => nodeId = value),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(
                  MaterialLocalizations.of(context).cancelButtonLabel,
                ),
              ),
              FilledButton(
                onPressed: valid
                    ? () => Navigator.pop(
                        context,
                        OproxyEndpoint(
                          nodeId: id.toLowerCase(),
                          label: label.trim(),
                        ),
                      )
                    : null,
                child: Text(MaterialLocalizations.of(context).saveButtonLabel),
              ),
            ],
          );
        },
      ),
    );
    if (result == null || !mounted) return;

    final endpoints = [...cfg.effectiveOproxies];
    final oldIndex = existing == null
        ? -1
        : endpoints.indexWhere((item) => item.nodeId == existing.nodeId);
    if (oldIndex >= 0) {
      endpoints[oldIndex] = result;
    } else {
      endpoints.removeWhere((item) => item.nodeId == result.nodeId);
      endpoints.add(result);
    }
    var defaults = [...cfg.effectiveDefaultOproxyNodeIds];
    if (existing != null && existing.nodeId != result.nodeId) {
      defaults = defaults
          .map((id) => id == existing.nodeId ? result.nodeId : id)
          .toList();
    }
    if (defaults.isEmpty) defaults = [result.nodeId];
    _save(
      cfg.copyWith(
        oProxies: endpoints,
        defaultOproxyNodeIds: defaults,
        exitNodeId: defaults.first,
      ),
    );
  }

  Future<void> _configureDefaultOproxies(ProxyRouting cfg) async {
    final l = AppL10n.of(context);
    final byId = {
      for (final endpoint in cfg.effectiveOproxies) endpoint.nodeId: endpoint,
    };
    final selected = cfg.effectiveDefaultOproxyNodeIds.toSet();
    final ordered = [
      ...cfg.effectiveDefaultOproxyNodeIds
          .map((id) => byId[id])
          .whereType<OproxyEndpoint>(),
      ...byId.values.where((endpoint) => !selected.contains(endpoint.nodeId)),
    ];
    final result = await showDialog<List<String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(l.oproxyDefaultOrderTitle),
          content: SizedBox(
            width: 520,
            height: 420,
            child: ordered.isEmpty
                ? Center(child: Text(l.oproxyEmpty))
                : ReorderableListView.builder(
                    itemCount: ordered.length,
                    onReorderItem: (oldIndex, newIndex) => setDialogState(() {
                      ordered.insert(newIndex, ordered.removeAt(oldIndex));
                    }),
                    itemBuilder: (context, index) {
                      final endpoint = ordered[index];
                      return CheckboxListTile(
                        key: ValueKey(endpoint.nodeId),
                        value: selected.contains(endpoint.nodeId),
                        title: Text(endpoint.label),
                        subtitle: Text(
                          endpoint.nodeId,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontFamily: 'monospace'),
                        ),
                        secondary: ReorderableDragStartListener(
                          index: index,
                          child: const Icon(Icons.drag_handle),
                        ),
                        onChanged: (value) => setDialogState(() {
                          if (value ?? false) {
                            selected.add(endpoint.nodeId);
                          } else {
                            selected.remove(endpoint.nodeId);
                          }
                        }),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
            ),
            FilledButton(
              onPressed: selected.isEmpty
                  ? null
                  : () => Navigator.pop(
                      context,
                      ordered
                          .where((item) => selected.contains(item.nodeId))
                          .map((item) => item.nodeId)
                          .toList(growable: false),
                    ),
              child: Text(MaterialLocalizations.of(context).saveButtonLabel),
            ),
          ],
        ),
      ),
    );
    if (result == null || !mounted) return;
    _save(cfg.copyWith(defaultOproxyNodeIds: result, exitNodeId: result.first));
  }

  void _removeOproxy(ProxyRouting cfg, OproxyEndpoint endpoint) {
    final endpoints = cfg.effectiveOproxies
        .where((item) => item.nodeId != endpoint.nodeId)
        .toList(growable: false);
    final defaults = cfg.effectiveDefaultOproxyNodeIds
        .where((id) => id != endpoint.nodeId)
        .toList(growable: false);
    _save(
      cfg.copyWith(
        oProxies: endpoints,
        defaultOproxyNodeIds: defaults,
        exitNodeId: defaults.firstOrNull,
        clearExitNodeId: defaults.isEmpty,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final cfg = ref.watch(proxyRoutingProvider);
    final scheme = Theme.of(context).colorScheme;
    final listenInvalid = !ProxyRouting.isValidListen(_listen.text.trim());

    return Scaffold(
      appBar: AppBar(
        leading: const RootedBackButton(),
        title: Text(l.routeTitle),
      ),
      body: ListView(
        children: [
          const _VpnSection(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Card(
              margin: EdgeInsets.zero,
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.hub_outlined),
                    title: Text(l.oproxyCatalogTitle),
                    subtitle: Text(
                      cfg.effectiveDefaultOproxyNodeIds.isEmpty
                          ? l.oproxyNoDefault
                          : l.oproxyDefaultSummary(
                              cfg.effectiveDefaultOproxyNodeIds.length,
                            ),
                    ),
                    trailing: IconButton(
                      tooltip: l.oproxyAddTitle,
                      onPressed: () => _editOproxy(cfg),
                      icon: const Icon(Icons.add),
                    ),
                  ),
                  for (final endpoint in cfg.effectiveOproxies)
                    ListTile(
                      title: Text(endpoint.label),
                      subtitle: Text(
                        endpoint.nodeId,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                      leading:
                          cfg.effectiveDefaultOproxyNodeIds.firstOrNull ==
                              endpoint.nodeId
                          ? const Icon(Icons.star, color: Colors.amber)
                          : const Icon(Icons.dns_outlined),
                      trailing: Wrap(
                        children: [
                          IconButton(
                            tooltip: l.oproxyEditTitle,
                            onPressed: () => _editOproxy(cfg, endpoint),
                            icon: const Icon(Icons.edit_outlined),
                          ),
                          IconButton(
                            tooltip: MaterialLocalizations.of(
                              context,
                            ).deleteButtonTooltip,
                            onPressed: () => _removeOproxy(cfg, endpoint),
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ],
                      ),
                    ),
                  if (cfg.effectiveOproxies.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton.icon(
                          onPressed: () => _configureDefaultOproxies(cfg),
                          icon: const Icon(Icons.swap_vert),
                          label: Text(l.oproxyDefaultOrderAction),
                        ),
                      ),
                    ),
                ],
              ),
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
}

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
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

  Future<void> _selectApplications(VpnRoutingPolicy policy) async {
    final l = AppL10n.of(context);
    List<VpnApplication> applications;
    try {
      applications = await ref.read(vpnApplicationsProvider.future);
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.vpnApplicationLoadError(error.toString()))),
      );
      return;
    }
    if (!mounted) return;

    final byId = {
      for (final application in applications) application.id: application,
    };
    for (final id in policy.applicationIds) {
      byId.putIfAbsent(id, () => VpnApplication(id: id, label: id));
    }
    final choices = byId.values.toList(growable: false)
      ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    final selected = policy.applicationIds.toSet();
    final result = await showDialog<Set<String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(l.vpnApplicationPickerTitle),
          content: SizedBox(
            width: 420,
            height: 520,
            child: _ApplicationSearchList(
              searchFieldKey: const ValueKey('vpn-application-search'),
              applications: choices,
              emptyMessage: l.vpnApplicationPickerEmpty,
              noResultsMessage: l.vpnApplicationSearchEmpty,
              searchHint: l.searchHint,
              itemBuilder: (context, application) => CheckboxListTile(
                value: selected.contains(application.id),
                title: Text(application.label),
                subtitle: Text(
                  application.id,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
                onChanged: (value) => setDialogState(() {
                  if (value ?? false) {
                    selected.add(application.id);
                  } else {
                    selected.remove(application.id);
                  }
                }),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, selected),
              child: Text(MaterialLocalizations.of(context).okButtonLabel),
            ),
          ],
        ),
      ),
    );
    if (result != null) {
      _configure(
        policy.copyWith(applicationIds: result.toList(growable: false)),
      );
    }
  }

  Future<List<String>?> _chooseOproxyChain({
    required ProxyRouting routing,
    required List<String> current,
    required String title,
    required bool allowDefault,
  }) async {
    final l = AppL10n.of(context);
    final byId = {
      for (final endpoint in routing.effectiveOproxies)
        endpoint.nodeId: endpoint,
    };
    final selected = current.toSet();
    final ordered = [
      ...current.map((id) => byId[id]).whereType<OproxyEndpoint>(),
      ...byId.values.where((endpoint) => !selected.contains(endpoint.nodeId)),
    ];
    return showDialog<List<String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 520,
            height: 420,
            child: ordered.isEmpty
                ? Center(child: Text(l.oproxyEmpty))
                : ReorderableListView.builder(
                    itemCount: ordered.length,
                    onReorderItem: (oldIndex, newIndex) => setDialogState(() {
                      ordered.insert(newIndex, ordered.removeAt(oldIndex));
                    }),
                    itemBuilder: (context, index) {
                      final endpoint = ordered[index];
                      return CheckboxListTile(
                        key: ValueKey(endpoint.nodeId),
                        value: selected.contains(endpoint.nodeId),
                        title: Text(endpoint.label),
                        subtitle: Text(
                          index == 0 && selected.contains(endpoint.nodeId)
                              ? l.oproxyPrimary
                              : endpoint.nodeId,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        secondary: ReorderableDragStartListener(
                          index: index,
                          child: const Icon(Icons.drag_handle),
                        ),
                        onChanged: (value) => setDialogState(() {
                          if (value ?? false) {
                            selected.add(endpoint.nodeId);
                          } else {
                            selected.remove(endpoint.nodeId);
                          }
                        }),
                      );
                    },
                  ),
          ),
          actions: [
            if (allowDefault)
              TextButton(
                onPressed: () => Navigator.pop(context, const <String>[]),
                child: Text(l.oproxyUseDefault),
              ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
            ),
            FilledButton(
              onPressed: selected.isEmpty
                  ? null
                  : () => Navigator.pop(
                      context,
                      ordered
                          .where((item) => selected.contains(item.nodeId))
                          .map((item) => item.nodeId)
                          .toList(growable: false),
                    ),
              child: Text(MaterialLocalizations.of(context).saveButtonLabel),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _configureApplicationOproxies(
    VpnRoutingPolicy policy,
    ProxyRouting routing,
  ) async {
    final l = AppL10n.of(context);
    List<VpnApplication> applications;
    try {
      applications = await ref.read(vpnApplicationsProvider.future);
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.vpnApplicationLoadError(error.toString()))),
      );
      return;
    }
    if (!mounted) return;
    final visible = policy.applicationMode == VpnApplicationMode.onlySelected
        ? applications
              .where((app) => policy.applicationIds.contains(app.id))
              .toList(growable: false)
        : applications;
    final routes = {
      for (final entry in policy.applicationOproxyNodeIds.entries)
        entry.key: [...entry.value],
    };
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(l.oproxyApplicationRoutesTitle),
          content: SizedBox(
            width: 620,
            height: 520,
            child: _ApplicationSearchList(
              searchFieldKey: const ValueKey('oproxy-application-search'),
              applications: visible,
              emptyMessage: l.oproxyApplicationRoutesEmpty,
              noResultsMessage: l.vpnApplicationSearchEmpty,
              searchHint: l.searchHint,
              itemBuilder: (context, application) {
                final chain = routes[application.id] ?? const <String>[];
                final endpoint = chain.isEmpty
                    ? null
                    : routing.effectiveOproxies
                          .where((item) => item.nodeId == chain.first)
                          .firstOrNull;
                return ListTile(
                  leading: const Icon(Icons.apps),
                  title: Text(application.label),
                  subtitle: Text(
                    '${application.id}\n'
                    '${chain.isEmpty ? l.oproxyUseDefault : l.oproxyRouteSummary(endpoint?.label ?? chain.first.substring(0, 8), chain.length - 1)}',
                  ),
                  onTap: () async {
                    final selected = await _chooseOproxyChain(
                      routing: routing,
                      current: chain,
                      title: application.label,
                      allowDefault: true,
                    );
                    if (selected == null) return;
                    setDialogState(() {
                      if (selected.isEmpty) {
                        routes.remove(application.id);
                      } else {
                        routes[application.id] = selected;
                      }
                    });
                  },
                  trailing: const Icon(Icons.chevron_right),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(MaterialLocalizations.of(context).saveButtonLabel),
            ),
          ],
        ),
      ),
    );
    if (saved ?? false) {
      _configure(policy.copyWith(applicationOproxyNodeIds: routes));
    }
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
    final applicationRoutingSupported = ref
        .watch(vpnApplicationCatalogProvider)
        .isSupported;
    final vpnOproxyChain = policy.vpnOproxyNodeIds.isEmpty
        ? proxy.effectiveDefaultOproxyNodeIds
        : policy.vpnOproxyNodeIds;
    final primaryOproxy = vpnOproxyChain.isEmpty
        ? null
        : proxy.effectiveOproxies
              .where((item) => item.nodeId == vpnOproxyChain.first)
              .firstOrNull;
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
        const SizedBox(height: 12),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.route),
          title: Text(l.oproxyVpnRouteTitle),
          subtitle: Text(
            vpnOproxyChain.isEmpty
                ? l.oproxyNoDefault
                : l.oproxyRouteSummary(
                    primaryOproxy?.label ??
                        vpnOproxyChain.first.substring(0, 8),
                    vpnOproxyChain.length - 1,
                  ),
          ),
          trailing: const Icon(Icons.chevron_right),
          enabled:
              !vpn.isRunning && !vpn.busy && proxy.effectiveOproxies.isNotEmpty,
          onTap: vpn.isRunning || vpn.busy || proxy.effectiveOproxies.isEmpty
              ? null
              : () async {
                  final selected = await _chooseOproxyChain(
                    routing: proxy,
                    current: policy.vpnOproxyNodeIds,
                    title: l.oproxyVpnRouteTitle,
                    allowDefault: true,
                  );
                  if (selected != null) {
                    _configure(policy.copyWith(vpnOproxyNodeIds: selected));
                  }
                },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.swap_horiz),
          title: Text(l.oproxyAutoFailover),
          subtitle: Text(l.oproxyAutoFailoverHint),
          value: policy.oproxyAutoFailover,
          onChanged: vpn.isRunning || vpn.busy
              ? null
              : (value) =>
                    _configure(policy.copyWith(oproxyAutoFailover: value)),
        ),
        const SizedBox(height: 12),
        if (applicationRoutingSupported)
          DropdownButtonFormField<VpnApplicationMode>(
            initialValue: policy.applicationMode,
            decoration: InputDecoration(
              labelText: l.vpnApplicationRouting,
              border: const OutlineInputBorder(),
            ),
            items: [
              DropdownMenuItem(
                value: VpnApplicationMode.allApplications,
                child: Text(l.vpnApplicationAll),
              ),
              DropdownMenuItem(
                value: VpnApplicationMode.onlySelected,
                child: Text(l.vpnApplicationOnlySelected),
              ),
            ],
            onChanged: vpn.isRunning || vpn.busy
                ? null
                : (value) {
                    if (value != null) {
                      _configure(policy.copyWith(applicationMode: value));
                    }
                  },
          )
        else
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.info_outline),
            title: Text(l.vpnApplicationRouting),
            subtitle: Text(l.vpnApplicationUnsupported),
          ),
        if (applicationRoutingSupported &&
            policy.applicationMode == VpnApplicationMode.onlySelected) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(l.vpnApplicationOnlySelectedHint),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  policy.applicationIds.isEmpty
                      ? l.vpnApplicationNoneSelected
                      : l.vpnApplicationSelectedCount(
                          policy.applicationIds.length,
                        ),
                  style: policy.applicationIds.isEmpty
                      ? TextStyle(color: scheme.error)
                      : null,
                ),
              ),
              OutlinedButton.icon(
                onPressed: vpn.isRunning || vpn.busy
                    ? null
                    : () => _selectApplications(policy),
                icon: const Icon(Icons.apps),
                label: Text(l.vpnApplicationSelect),
              ),
            ],
          ),
        ],
        if (applicationRoutingSupported) ...[
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.account_tree_outlined),
            title: Text(l.oproxyApplicationRoutesTitle),
            subtitle: Text(
              l.oproxyApplicationRoutesCount(
                policy.applicationOproxyNodeIds.length,
              ),
            ),
            trailing: const Icon(Icons.chevron_right),
            enabled:
                !vpn.isRunning &&
                !vpn.busy &&
                proxy.effectiveOproxies.isNotEmpty,
            onTap: vpn.isRunning || vpn.busy || proxy.effectiveOproxies.isEmpty
                ? null
                : () => _configureApplicationOproxies(policy, proxy),
          ),
        ],
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

typedef _ApplicationItemBuilder =
    Widget Function(BuildContext context, VpnApplication application);

class _ApplicationSearchList extends StatefulWidget {
  const _ApplicationSearchList({
    required this.searchFieldKey,
    required this.applications,
    required this.emptyMessage,
    required this.noResultsMessage,
    required this.searchHint,
    required this.itemBuilder,
  });

  final Key searchFieldKey;
  final List<VpnApplication> applications;
  final String emptyMessage;
  final String noResultsMessage;
  final String searchHint;
  final _ApplicationItemBuilder itemBuilder;

  @override
  State<_ApplicationSearchList> createState() => _ApplicationSearchListState();
}

class _ApplicationSearchListState extends State<_ApplicationSearchList> {
  late final TextEditingController _search;
  var _query = '';

  @override
  void initState() {
    super.initState();
    _search = TextEditingController();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final normalized = _query.trim().toLowerCase();
    final filtered = normalized.isEmpty
        ? widget.applications
        : widget.applications
              .where(
                (application) =>
                    application.label.toLowerCase().contains(normalized) ||
                    application.id.toLowerCase().contains(normalized),
              )
              .toList(growable: false);
    return Column(
      children: [
        TextField(
          key: widget.searchFieldKey,
          controller: _search,
          autofocus: widget.applications.isNotEmpty,
          decoration: InputDecoration(
            hintText: widget.searchHint,
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _query.isEmpty
                ? null
                : IconButton(
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).deleteButtonTooltip,
                    onPressed: () {
                      _search.clear();
                      setState(() => _query = '');
                    },
                    icon: const Icon(Icons.clear),
                  ),
            border: const OutlineInputBorder(),
          ),
          onChanged: (value) => setState(() => _query = value),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: widget.applications.isEmpty
              ? Center(child: Text(widget.emptyMessage))
              : filtered.isEmpty
              ? Center(child: Text(widget.noResultsMessage))
              : ListView.builder(
                  itemCount: filtered.length,
                  itemBuilder: (context, index) =>
                      widget.itemBuilder(context, filtered[index]),
                ),
        ),
      ],
    );
  }
}
