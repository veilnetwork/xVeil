import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/node/managed_node.dart';
import '../../data/node/node_auto_update.dart';
import '../../data/node/node_lifecycle.dart';
import '../../data/node/node_provisioner.dart';
import '../../data/node/ssh_client.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_controller.dart';
import '../../state/managed_nodes_controller.dart';
import '../../state/proxy_routing_controller.dart';
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
    Future<void> Function(SshResult result)? onSuccess,
  }) => showDialog<void>(
    context: context,
    builder: (_) => SshCommandDialog(
      node: node,
      title: title,
      command: command,
      timeout: timeout,
      showCommandPreview: preview,
      onSuccess: onSuccess,
    ),
  );

  /// Keep what the inventory just reported: the node id, AND the exit, if the
  /// server turns out to be one.
  ///
  /// Both decisions live in pure functions ([nodeWithAdoptedId],
  /// [routingWithInventoriedExit]) so every branch is reachable from a unit
  /// test. The second one is why re-adding a lost server no longer means
  /// deploying over a working one: the read-only inventory is enough to make it
  /// routable again, and it rewrites nothing on the machine.
  Future<void> _adoptInventory(
    BuildContext context,
    WidgetRef ref,
    ManagedNode node,
    SshResult result,
  ) async {
    final report = parseProvisionReport(result.stdout);
    // The id is adopted only into a BLANK record (see nodeWithAdoptedId); the
    // version is refreshed every time, because that is the whole point of
    // running an inventory.
    var updated = nodeWithAdoptedId(node, result.stdout) ?? node;
    if (report.veilVersion != null) {
      updated = updated.copyWith(veilVersion: report.veilVersion);
    }
    if (updated != node) {
      await ref.read(managedNodesProvider.notifier).upsert(updated);
    }
    final routing = routingWithInventoriedExit(
      ref.read(proxyRoutingProvider),
      // The record as it stands AFTER the id was adopted, so a blank entry that
      // just learned its id is registered on the same run rather than on the
      // next one.
      node: updated,
      inventoryOutput: result.stdout,
    );
    if (routing != null) {
      await ref.read(proxyRoutingProvider.notifier).set(routing);
    }
    // An exit that admits NOBODY is the shape a server deployed before the
    // allowlist existed has: no `allowed_node_ids`, no `allow_all`. Today's
    // node ignores both and carries the traffic; the moment it is updated it
    // refuses every stream, and the only trace is one line in the node's log.
    // Said here, where the operator is looking at that server and has its
    // config in front of them.
    final self = ref.read(appControllerProvider).identity?.nodeId.hex;
    if (exitAdmitsSelf(result.stdout, self) == false && context.mounted) {
      final l = AppL10n.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l.nodeExitRefusesThisDevice),
          duration: const Duration(seconds: 8),
        ),
      );
    }
  }

  /// Install or remove the server's self-updater, and record what the server
  /// actually did.
  ///
  /// The flag is not flipped optimistically. It describes a timer on a machine,
  /// and a switch that moves when the SSH run failed would show a node keeping
  /// itself current when nothing on it does.
  Future<void> _setAutoUpdate(
    BuildContext context,
    WidgetRef ref,
    ManagedNode node,
    bool value,
  ) => _run(
    context,
    node,
    title: AppL10n.of(context).nodeAutoUpdate,
    command: buildNodeAutoUpdateScript(enabled: value),
    onSuccess: (result) async {
      if (!result.ok) return;
      await ref
          .read(managedNodesProvider.notifier)
          .upsert(node.copyWith(autoUpdate: value));
    },
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
              onSuccess: (result) =>
                  _adoptInventory(context, ref, node, result),
            ),
          ),
          // A switch that RUNS something over SSH, so it reads as an action and
          // not as a stored preference: the record only changes after the
          // server said it did.
          SwitchListTile(
            secondary: const Icon(Icons.update),
            title: Text(l.nodeAutoUpdate),
            subtitle: Text(l.nodeAutoUpdateHint),
            isThreeLine: true,
            value: node.autoUpdate,
            onChanged: node.hasSsh && node.sshUser != null
                ? (value) => _setAutoUpdate(context, ref, node, value)
                : null,
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
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => const _DebootstrapConfirmDialog(),
    );
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

/// Type-to-confirm for debootstrap, owning both its controller and its
/// enabled/disabled state.
///
/// It was a `StatefulBuilder` beside a controller the caller disposed on the
/// line after the await. `showDialog`'s future completes when `Navigator.pop`
/// runs, but the route keeps its subtree mounted through the exit transition,
/// so the `TextField` went on using a disposed controller. Same defect, same
/// shape, and the same three-error cascade it produced in cloud storage:
/// "used after being disposed", then `_dependents.isEmpty`, then a dirty
/// widget built in the wrong scope — only the last of which reaches the user.
class _DebootstrapConfirmDialog extends StatefulWidget {
  const _DebootstrapConfirmDialog();

  @override
  State<_DebootstrapConfirmDialog> createState() =>
      _DebootstrapConfirmDialogState();
}

class _DebootstrapConfirmDialogState extends State<_DebootstrapConfirmDialog> {
  final TextEditingController _typed = TextEditingController();
  bool _matches = false;

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return AlertDialog(
      title: Text(l.nodeDebootstrap),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l.nodeDebootstrapConfirm),
          const SizedBox(height: 12),
          TextField(
            controller: _typed,
            autofocus: true,
            decoration: InputDecoration(
              labelText: l.nodeDebootstrapType,
              border: const OutlineInputBorder(),
            ),
            onChanged: (value) =>
                setState(() => _matches = value.trim() == 'DELETE'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(l.actionCancel),
        ),
        FilledButton(
          onPressed: _matches ? () => Navigator.pop(context, true) : null,
          child: Text(l.nodeDebootstrap),
        ),
      ],
    );
  }
}
