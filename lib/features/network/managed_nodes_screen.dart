import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../data/node/managed_node.dart';
import '../../data/node/node_probe.dart';
import '../../l10n/app_localizations.dart';
import 'node_provision_screen.dart';
import 'ssh_check_dialog.dart';
import '../../state/managed_nodes_controller.dart';
import '../../state/proxy_routing_controller.dart';

/// "Мои узлы" — the registry of nodes the user runs (a VPS exit, a home relay).
/// Each carries the node's veil id (so it can be used as a routing exit) and
/// optional SSH reachability for status / future provisioning. The "use as
/// exit" action wires a node straight into "Маршрутизация трафика".
class ManagedNodesScreen extends ConsumerWidget {
  const ManagedNodesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final nodesAsync = ref.watch(managedNodesProvider);
    return Scaffold(
      appBar: AppBar(title: Text(l.nodesTitle)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _editSheet(context, ref, null),
        icon: const Icon(Icons.add),
        label: Text(l.nodesAdd),
      ),
      body: nodesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (nodes) {
          if (nodes.isEmpty) {
            return _Empty(message: l.nodesEmpty, hint: l.nodesEmptyHint);
          }
          return ListView(
            children: [
              for (final n in nodes) _NodeTile(node: n),
            ],
          );
        },
      ),
    );
  }
}

class _NodeTile extends ConsumerWidget {
  const _NodeTile({required this.node});
  final ManagedNode node;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sub = <String>[
      if (node.hasNodeId) '${node.nodeId!.substring(0, 8)}…',
      if (node.hasSsh) '${node.sshUser ?? ''}@${node.sshHost}:${node.sshPort}',
    ].join('  ·  ');
    return ListTile(
      leading: const Icon(Icons.dns_outlined),
      title: Text(node.label),
      subtitle: sub.isEmpty ? null : Text(sub),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _editSheet(context, ref, node),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.message, required this.hint});
  final String message;
  final String hint;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.dns_outlined, size: 48, color: scheme.outline),
            const SizedBox(height: 16),
            Text(message, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(hint,
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: scheme.outline)),
          ],
        ),
      ),
    );
  }
}

void _editSheet(BuildContext context, WidgetRef ref, ManagedNode? existing) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _NodeEditSheet(existing: existing),
  );
}

class _NodeEditSheet extends ConsumerStatefulWidget {
  const _NodeEditSheet({this.existing});
  final ManagedNode? existing;
  @override
  ConsumerState<_NodeEditSheet> createState() => _NodeEditSheetState();
}

class _NodeEditSheetState extends ConsumerState<_NodeEditSheet> {
  late final TextEditingController _label;
  late final TextEditingController _nodeId;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _user;
  String? _labelError;
  String? _nodeIdError;
  bool _probing = false;
  ProbeResult? _probeResult;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _label = TextEditingController(text: e?.label ?? '');
    _nodeId = TextEditingController(text: e?.nodeId ?? '');
    _host = TextEditingController(text: e?.sshHost ?? '');
    _port = TextEditingController(text: '${e?.sshPort ?? 22}');
    _user = TextEditingController(text: e?.sshUser ?? '');
  }

  @override
  void dispose() {
    for (final c in [_label, _nodeId, _host, _port, _user]) {
      c.dispose();
    }
    super.dispose();
  }

  bool _isHex64(String s) =>
      s.length == 64 && RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(s);

  void _save() {
    final l = AppL10n.of(context);
    final label = _label.text.trim();
    final nodeId = _nodeId.text.trim();
    setState(() {
      _labelError = label.isEmpty ? l.nodeLabelRequired : null;
      _nodeIdError =
          (nodeId.isNotEmpty && !_isHex64(nodeId)) ? l.nodeIdInvalid : null;
    });
    if (_labelError != null || _nodeIdError != null) return;

    final host = _host.text.trim();
    final node = ManagedNode(
      id: widget.existing?.id ?? const Uuid().v4(),
      label: label,
      nodeId: nodeId.isEmpty ? null : nodeId,
      sshHost: host.isEmpty ? null : host,
      sshPort: int.tryParse(_port.text.trim()) ?? 22,
      sshUser: _user.text.trim().isEmpty ? null : _user.text.trim(),
    );
    ref.read(managedNodesProvider.notifier).upsert(node);
    Navigator.of(context).pop();
  }

  Future<void> _remove() async {
    await ref.read(managedNodesProvider.notifier).remove(widget.existing!.id);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _checkReachable() async {
    final host = _host.text.trim();
    if (host.isEmpty) return;
    final port = int.tryParse(_port.text.trim()) ?? 22;
    setState(() {
      _probing = true;
      _probeResult = null;
    });
    final result = await probeTcp(host, port);
    if (mounted) {
      setState(() {
        _probing = false;
        _probeResult = result;
      });
    }
  }

  void _useAsExit() {
    final l = AppL10n.of(context);
    final id = _nodeId.text.trim();
    if (!_isHex64(id)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l.nodeNeedsNodeId)));
      return;
    }
    final cur = ref.read(proxyRoutingProvider);
    ref.read(proxyRoutingProvider.notifier).set(
          cur.copyWith(socks5Enabled: true, exitNodeId: id),
        );
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(l.nodeUseAsExitDone)));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final isEdit = widget.existing != null;
    final nodeId = _nodeId.text.trim();
    final canExit = _isHex64(nodeId);
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 0, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(isEdit ? l.nodeEdit : l.nodesAdd,
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            TextField(
              controller: _label,
              decoration: InputDecoration(
                labelText: l.nodeLabelLabel,
                errorText: _labelError,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nodeId,
              minLines: 1,
              maxLines: 2,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: l.nodeIdLabel,
                helperText: l.nodeIdHintText,
                helperMaxLines: 2,
                errorText: _nodeIdError,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _host,
              onChanged: (_) => setState(() => _probeResult = null),
              decoration: InputDecoration(
                labelText: l.nodeSshHostLabel,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _port,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: l.nodeSshPortLabel,
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _user,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: l.nodeSshUserLabel,
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Reachability probe — a dependency-free TCP connect to host:port.
            if (_host.text.trim().isNotEmpty)
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _probing ? null : _checkReachable,
                    icon: _probing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.wifi_find),
                    label: Text(_probing ? l.nodeChecking : l.nodeCheckReachable),
                  ),
                  const SizedBox(width: 12),
                  if (_probeResult != null)
                    Row(
                      children: [
                        Icon(
                          _probeResult == ProbeResult.reachable
                              ? Icons.check_circle
                              : Icons.cancel,
                          size: 18,
                          color: _probeResult == ProbeResult.reachable
                              ? Colors.green
                              : Theme.of(context).colorScheme.error,
                        ),
                        const SizedBox(width: 6),
                        Text(_probeResult == ProbeResult.reachable
                            ? l.nodeReachable
                            : l.nodeUnreachable),
                      ],
                    ),
                ],
              ),
            // SSH connect & check — needs a user. Opens a one-shot auth dialog;
            // credentials are never stored.
            if (_host.text.trim().isNotEmpty && _user.text.trim().isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => SshCheckDialog(
                      host: _host.text.trim(),
                      port: int.tryParse(_port.text.trim()) ?? 22,
                      user: _user.text.trim(),
                    ),
                  ),
                  icon: const Icon(Icons.terminal, size: 18),
                  label: Text(l.nodeSshConnect),
                ),
              ),
            const SizedBox(height: 8),
            // Provision a veil node over SSH — only for a SAVED node with SSH
            // details (so the reported node id can be stored back onto it).
            if (isEdit &&
                _host.text.trim().isNotEmpty &&
                _user.text.trim().isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () {
                    final node = widget.existing!.copyWith(
                      sshHost: _host.text.trim(),
                      sshPort: int.tryParse(_port.text.trim()) ?? 22,
                      sshUser: _user.text.trim(),
                    );
                    Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => NodeProvisionScreen(node: node),
                    ));
                  },
                  icon: const Icon(Icons.rocket_launch, size: 18),
                  label: Text(l.nodeProvision),
                ),
              ),
            const SizedBox(height: 8),
            if (canExit)
              OutlinedButton.icon(
                onPressed: _useAsExit,
                icon: const Icon(Icons.alt_route),
                label: Text(l.nodeUseAsExit),
              ),
            const SizedBox(height: 8),
            FilledButton(onPressed: _save, child: Text(l.actionSave)),
            if (isEdit) ...[
              const SizedBox(height: 4),
              TextButton.icon(
                onPressed: _remove,
                icon: Icon(Icons.delete_outline,
                    color: Theme.of(context).colorScheme.error),
                label: Text(l.nodeRemove,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
