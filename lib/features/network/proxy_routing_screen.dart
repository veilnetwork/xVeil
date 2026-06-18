import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/node/proxy_routing.dart';
import '../../l10n/app_localizations.dart';
import '../../state/proxy_routing_controller.dart';

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

  void _save(ProxyRouting next) => ref.read(proxyRoutingProvider.notifier).set(next);

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final cfg = ref.watch(proxyRoutingProvider);
    final scheme = Theme.of(context).colorScheme;
    final exitText = _exitId.text.trim();
    final exitInvalid = exitText.isNotEmpty && !_isHex64(exitText);

    return Scaffold(
      appBar: AppBar(title: Text(l.routeTitle)),
      body: ListView(
        children: [
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
              child: TextField(
                controller: _listen,
                decoration: InputDecoration(
                  labelText: l.routeListenLabel,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (v) =>
                    _save(cfg.copyWith(socks5Listen: v.trim())),
              ),
            ),
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
                  setState(() {}); // refresh validation + status line
                  _save(cfg.copyWith(
                    exitNodeId: t.isEmpty ? null : t,
                    clearExitNodeId: t.isEmpty,
                  ));
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: cfg.socks5Active
                  ? Row(
                      children: [
                        Icon(Icons.check_circle,
                            size: 18, color: Colors.green),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(l.routeProxyAddress(cfg.socks5Listen),
                              style: TextStyle(color: scheme.primary)),
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        Icon(Icons.info_outline,
                            size: 18, color: scheme.outline),
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
                  child: Text(l.routeAppliesNextStart,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: scheme.outline)),
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
