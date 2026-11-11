import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../data/node/managed_node.dart';
import '../../data/node/node_connect.dart';
import '../../data/node/node_lifecycle.dart';
import '../../data/node/node_provisioner.dart';
import '../../data/transport/bootstrap_invite.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_controller.dart' show IdentityLease;
import '../../state/identity_guard.dart';
import '../../state/managed_nodes_controller.dart';
import '../../state/node_connect.dart';
import '../../state/providers.dart';
import '../../state/proxy_routing_controller.dart';
import '../contacts/qr_scan_screen.dart';
import 'node_management_screen.dart';
import 'node_provision_screen.dart';

String nodeConnectError(AppL10n l, NodeConnectException error) =>
    error.failure == NodeConnectFailure.expired
    ? l.nodeConnectExpired
    : l.nodeConnectError;

class NodeConnectScreen extends ConsumerStatefulWidget {
  const NodeConnectScreen({super.key, this.existing});
  final ManagedNode? existing;
  @override
  ConsumerState<NodeConnectScreen> createState() => _NodeConnectScreenState();
}

class _NodeConnectScreenState extends ConsumerState<NodeConnectScreen> {
  final _code = TextEditingController();
  final _label = TextEditingController();
  late final IdentityLease _lease;
  NodeConnectClient? _client;
  bool _busy = false;
  String? _error;
  bool get _current => mounted && ref.holdsIdentity(_lease);

  @override
  void initState() {
    super.initState();
    _lease = ref.leaseIdentity();
  }

  @override
  void dispose() {
    _client?.close();
    _code.dispose();
    _label.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const QrScanScreen(nodeConnect: true)),
    );
    if (_current && result != null) setState(() => _code.text = result);
  }

  Future<void> _pair() async {
    if (!_current) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final invite = NodeConnectInvite.parse(_code.text);
      final repository = ref.read(nodeConnectRepositoryProvider);
      final client = _client = ref.read(nodeConnectClientFactoryProvider)(
        endpoint: invite.endpoint,
        pin: invite.pin,
        isCurrent: () => _current,
      );
      final session = await client.claim(invite);
      final info = await client.info(session);
      if (!_current) return;
      if (info['host_os'] != 'linux') {
        throw const NodeConnectException(NodeConnectFailure.protocol);
      }
      final inventory = await client.run(session, buildNodeInventoryScript());
      if (!_current) return;
      if (!inventory.ok || inventory.truncated) {
        throw const NodeConnectException(NodeConnectFailure.rejected);
      }
      final report = parseProvisionReport(
        inventory.stdout,
        reachableHost: invite.endpoint.host,
      );
      final existing = widget.existing;
      if (existing?.hasNodeId == true && existing!.nodeId != report.nodeId) {
        throw const NodeConnectException(NodeConnectFailure.rejected);
      }
      final node = ManagedNode(
        id: existing?.id ?? const Uuid().v4(),
        label: _label.text.trim().isNotEmpty
            ? _label.text.trim()
            : existing?.label ?? invite.endpoint.host,
        nodeId: report.nodeId,
        connectEndpoint: session.endpoint.toString(),
        veilVersion: report.veilVersion,
        autoUpdate: existing?.autoUpdate ?? false,
      );
      await repository.save(node.id, session);
      if (!_current) return;
      final failed = await ref.read(managedNodesProvider.notifier).upsert(node);
      if (!_current) return;
      if (failed != null) {
        throw const NodeConnectException(NodeConnectFailure.rejected);
      }
      final routing = routingWithInventoriedExit(
        ref.read(proxyRoutingProvider),
        node: node,
        inventoryOutput: inventory.stdout,
      );
      if (routing != null) {
        await ref.read(proxyRoutingProvider.notifier).set(routing);
        if (!_current) return;
      }
      if (report.invite != null) {
        await ref
            .read(realStackProvider)
            ?.addContact(BootstrapInvite.parse(report.invite!));
        if (!_current) return;
      }
      // The same reviewed installer/management screens as SSH, with a new
      // pinned transport. A fresh server has no Veil identity until installed.
      if (!mounted || !_current) return;
      client.close();
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => report.nodeId == null
              ? NodeProvisionScreen(node: node)
              : NodeManagementScreen(nodeId: node.id),
        ),
      );
    } on NodeConnectException catch (error) {
      if (mounted && _current) {
        setState(() => _error = nodeConnectError(AppL10n.of(context), error));
      }
    } catch (_) {
      if (mounted && _current) {
        setState(() => _error = AppL10n.of(context).nodeConnectError);
      }
    } finally {
      _client?.close();
      _client = null;
      if (_current) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l.nodeConnectTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(l.nodeConnectHint),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _busy ? null : _scan,
            icon: const Icon(Icons.qr_code_scanner),
            label: Text(l.nodeConnectTitle),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _label,
            enabled: !_busy,
            decoration: InputDecoration(labelText: l.nodeLabelLabel),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('node-connect-code'),
            controller: _code,
            enabled: !_busy,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: l.nodeConnectLink,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Text(l.nodeConnectTrust),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 16),
          FilledButton(
            key: const ValueKey('node-connect-pair'),
            onPressed: _busy ? null : _pair,
            child: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(l.nodeConnectAction),
          ),
        ],
      ),
    );
  }
}
