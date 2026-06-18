import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../data/node/managed_node.dart';
import '../../l10n/app_localizations.dart';
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
            // Provisioning over SSH is the next layer — flagged, not faked.
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Icon(Icons.info_outline,
                      size: 16, color: Theme.of(context).colorScheme.outline),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(l.nodeProvisionSoon,
                        style: Theme.of(context).textTheme.bodySmall),
                  ),
                ],
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
