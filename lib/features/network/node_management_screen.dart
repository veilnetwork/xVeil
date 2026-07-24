import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/node/managed_node.dart';
import '../../data/node/node_lifecycle.dart';
import '../../l10n/app_localizations.dart';
import '../../state/managed_nodes_controller.dart';
import 'node_config_screen.dart';
import 'node_provision_screen.dart';
import 'ssh_command_dialog.dart';

class NodeManagementScreen extends ConsumerWidget {
  const NodeManagementScreen({super.key, required this.nodeId});

  final String nodeId;

  ManagedNode? _node(WidgetRef ref) {
    for (final node
        in ref.watch(managedNodesProvider).value ?? const <ManagedNode>[]) {
      if (node.id == nodeId) return node;
    }
    return null;
  }

  Future<void> _run(
    BuildContext context,
    ManagedNode node, {
    required String title,
    required String command,
    bool preview = false,
    Duration timeout = const Duration(minutes: 2),
  }) => showDialog<void>(
    context: context,
    builder: (_) => SshCommandDialog(
      node: node,
      title: title,
      command: command,
      timeout: timeout,
      showCommandPreview: preview,
    ),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final node = _node(ref);
    if (node == null) {
      return Scaffold(
        appBar: AppBar(title: Text(l.nodeManage)),
        body: Center(child: Text(l.nodesEmpty)),
      );
    }
    final endpoint = node.hasSsh
        ? '${node.sshUser}@${node.sshHost}:${node.sshPort}'
        : l.nodeSshHostLabel;
    return Scaffold(
      appBar: AppBar(title: Text(node.label)),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: Text(
              node.hasNodeId ? '${node.nodeId!.substring(0, 12)}…' : '—',
            ),
            subtitle: Text(endpoint),
          ),
          const Divider(),
          ListTile(
            enabled: node.hasSsh && node.sshUser != null,
            leading: const Icon(Icons.monitor_heart_outlined),
            title: Text(l.nodeInventory),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _run(
              context,
              node,
              title: l.nodeInventory,
              command: buildNodeInventoryScript(),
            ),
          ),
          ListTile(
            enabled: node.hasSsh && node.sshUser != null,
            leading: const Icon(Icons.system_update_alt),
            title: Text(l.nodeInstallUpdate),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => NodeProvisionScreen(node: node),
              ),
            ),
          ),
          const Divider(),
          _SectionHeader(l.nodeServices),
          for (final service in NodeManagedService.values)
            _ServiceTile(
              service: service,
              enabled: node.hasSsh && node.sshUser != null,
              onAction: (action) => _run(
                context,
                node,
                title: '${service.binary} · ${_actionLabel(l, action)}',
                command: buildNodeServiceActionScript(service, action),
              ),
            ),
          const Divider(),
          _SectionHeader(l.nodeAdvancedConfig),
          for (final target in NodeConfigTarget.values)
            ListTile(
              enabled: node.hasSsh && node.sshUser != null,
              leading: const Icon(Icons.tune),
              title: Text(_configLabel(target)),
              subtitle: Text(target.path),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => NodeConfigScreen(node: node, target: target),
                ),
              ),
            ),
          const Divider(),
          ListTile(
            enabled: node.hasSsh && node.sshUser != null,
            leading: const Icon(Icons.delete_sweep_outlined),
            title: Text(l.nodeUninstallSoftware),
            onTap: () => _chooseUninstall(context, node),
          ),
          ListTile(
            enabled: node.hasSsh && node.sshUser != null,
            leading: Icon(
              Icons.warning_amber_rounded,
              color: Theme.of(context).colorScheme.error,
            ),
            title: Text(
              l.nodeDebootstrap,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            onTap: () => _confirmDebootstrap(context, node),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Future<void> _chooseUninstall(BuildContext context, ManagedNode node) async {
    final l = AppL10n.of(context);
    final selected = <NodeManagedService>{};
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(l.nodeSelectServices),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final service in NodeManagedService.values)
                CheckboxListTile(
                  value: selected.contains(service),
                  title: Text(service.binary),
                  onChanged: (value) => setState(() {
                    if (value ?? false) {
                      selected.add(service);
                    } else {
                      selected.remove(service);
                    }
                  }),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(l.actionCancel),
            ),
            FilledButton(
              onPressed: selected.isEmpty
                  ? null
                  : () => Navigator.pop(dialogContext, true),
              child: Text(l.nodeUninstallSoftware),
            ),
          ],
        ),
      ),
    );
    if (accepted != true || !context.mounted) return;
    await _run(
      context,
      node,
      title: l.nodeUninstallSoftware,
      command: buildNodeUninstallScript(selected),
      preview: true,
    );
  }

  Future<void> _confirmDebootstrap(
    BuildContext context,
    ManagedNode node,
  ) async {
    final l = AppL10n.of(context);
    final controller = TextEditingController();
    var matches = false;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(l.nodeDebootstrap),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(l.nodeDebootstrapConfirm),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: l.nodeDebootstrapType,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (value) =>
                    setState(() => matches = value.trim() == 'DELETE'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(l.actionCancel),
            ),
            FilledButton(
              onPressed: matches
                  ? () => Navigator.pop(dialogContext, true)
                  : null,
              child: Text(l.nodeDebootstrap),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (accepted != true || !context.mounted) return;
    await _run(
      context,
      node,
      title: l.nodeDebootstrap,
      command: buildNodeDebootstrapScript(),
      preview: true,
      timeout: const Duration(minutes: 3),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
    child: Text(label, style: Theme.of(context).textTheme.titleMedium),
  );
}

class _ServiceTile extends StatelessWidget {
  const _ServiceTile({
    required this.service,
    required this.enabled,
    required this.onAction,
  });

  final NodeManagedService service;
  final bool enabled;
  final ValueChanged<NodeServiceAction> onAction;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return ListTile(
      enabled: enabled,
      leading: Icon(
        service == NodeManagedService.veil
            ? Icons.hub_outlined
            : Icons.extension_outlined,
      ),
      title: Text(service.binary),
      subtitle: Text(service.unit),
      trailing: PopupMenuButton<NodeServiceAction>(
        enabled: enabled,
        onSelected: onAction,
        itemBuilder: (_) => [
          for (final action in NodeServiceAction.values)
            PopupMenuItem(value: action, child: Text(_actionLabel(l, action))),
        ],
      ),
    );
  }
}

String _actionLabel(AppL10n l, NodeServiceAction action) => switch (action) {
  NodeServiceAction.status => l.nodeServiceStatus,
  NodeServiceAction.start => l.nodeServiceStart,
  NodeServiceAction.stop => l.nodeServiceStop,
  NodeServiceAction.restart => l.nodeServiceRestart,
  NodeServiceAction.enable => l.nodeServiceEnable,
  NodeServiceAction.disable => l.nodeServiceDisable,
};

String _configLabel(NodeConfigTarget target) => switch (target) {
  NodeConfigTarget.veil => 'veil · node.toml',
  NodeConfigTarget.ogate => 'ogate · ogate.toml',
  NodeConfigTarget.oproxyClient => 'oproxy-client · client.toml',
  NodeConfigTarget.oproxyServer => 'oproxy-server · server.toml',
};
