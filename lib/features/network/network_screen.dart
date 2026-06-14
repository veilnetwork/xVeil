import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/node/node_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../state/providers.dart';

class NetworkScreen extends ConsumerWidget {
  const NetworkScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final status = ref.watch(nodeStatusProvider);
    return Scaffold(
      appBar: AppBar(title: Text(l.networkTitle)),
      body: ListView(
        children: [
          status.when(
            loading: () => const _StatusCard(
              phase: NodePhase.starting,
              peers: 0,
            ),
            error: (e, _) =>
                const _StatusCard(phase: NodePhase.error, peers: 0),
            data: (s) => _StatusCard(phase: s.phase, peers: s.peerCount),
          ),
          const Divider(),
          // Secondary controls — proxy/VPN + node management land here in later
          // milestones, behind their own ports (oproxy/ogate, SSH provisioning).
          ListTile(
            leading: const Icon(Icons.vpn_lock_outlined),
            title: const Text('Route traffic (Proxy / VPN)'),
            subtitle: const Text('oproxy / ogate — coming soon'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _soon(context),
          ),
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: const Text('My nodes'),
            subtitle: const Text('Add a node over SSH, run ogate/oproxy'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _soon(context),
          ),
          ListTile(
            leading: const Icon(Icons.extension_outlined),
            title: const Text('Extensions (Lua)'),
            subtitle: const Text('Load sandboxed add-ons'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _soon(context),
          ),
        ],
      ),
    );
  }

  void _soon(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Coming in a later milestone')),
    );
  }
}

class _StatusCard extends ConsumerWidget {
  const _StatusCard({required this.phase, required this.peers});
  final NodePhase phase;
  final int peers;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final (label, color, icon) = switch (phase) {
      NodePhase.connected => (l.networkStatusConnected, Colors.green, Icons.check_circle),
      NodePhase.starting => (l.networkStatusConnecting, scheme.tertiary, Icons.sync),
      NodePhase.offline => (l.networkStatusOffline, scheme.outline, Icons.cloud_off),
      NodePhase.error => ('Error', scheme.error, Icons.error_outline),
      NodePhase.stopped => (l.networkStatusOffline, scheme.outline, Icons.power_settings_new),
    };
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Icon(icon, color: color, size: 36),
              const SizedBox(width: 16),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 4),
                  Text(
                    phase == NodePhase.connected ? l.networkPeers(peers) : '—',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
