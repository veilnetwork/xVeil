import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../common/shown_cause.dart';
import '../common/async_error_view.dart';
import '../../data/node/managed_node.dart';
import '../../data/node/node_probe.dart';
import '../../data/node/proxy_routing.dart';
import '../../data/node/ssh_credentials.dart';
import '../../l10n/app_localizations.dart';
import '../../routing/back_affordance.dart';
import '../../state/app_controller.dart' show IdentityLease;
import '../../state/identity_guard.dart';
import '../../state/managed_nodes_controller.dart';
import '../../state/proxy_routing_controller.dart';
import '../../state/ssh_credentials.dart';
import 'node_fleet_update_screen.dart';
import 'node_management_screen.dart';
import 'node_provision_screen.dart';
import 'ssh_check_dialog.dart';
import 'ssh_public_key_card.dart';

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
      appBar: AppBar(
        leading: const RootedBackButton(),
        title: Text(l.nodesTitle),
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'xveil-managed-nodes-add',
        onPressed: () => _showManagedNodeCreateChooser(context),
        icon: const Icon(Icons.add),
        label: Text(l.nodesAdd),
      ),
      body: nodesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) => AsyncErrorView(error: e, stack: st, where: 'nodes'),
        data: (nodes) {
          if (nodes.isEmpty) {
            return _Empty(message: l.nodesEmpty, hint: l.nodesEmptyHint);
          }
          final withSsh = nodes.where((n) => n.hasSsh && n.sshUser != null);
          return ListView(
            children: [
              for (final n in nodes) _NodeTile(node: n),
              // One place to update the fleet, rather than one screen per
              // machine: updating them one at a time is how versions drift
              // apart. Offered whenever anything is reachable by SSH at all —
              // the screen itself asks the nodes before it offers anything.
              if (withSsh.isNotEmpty) ...[
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.system_update_alt),
                  title: Text(l.fleetUpdateTitle),
                  subtitle: Text(l.fleetUpdateNotChecked),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const NodeFleetUpdateScreen(),
                    ),
                  ),
                ),
              ],
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
      trailing: IconButton(
        tooltip: AppL10n.of(context).nodeEdit,
        icon: const Icon(Icons.edit_outlined),
        onPressed: () => _showManagedNodeEditor(context, node),
      ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => NodeManagementScreen(nodeId: node.id),
        ),
      ),
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
            Text(
              hint,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: scheme.outline),
            ),
          ],
        ),
      ),
    );
  }
}

enum _NodeCreateMode { existing, bootstrap }

Future<void> _showManagedNodeCreateChooser(BuildContext context) async {
  final l = AppL10n.of(context);
  final mode = await showModalBottomSheet<_NodeCreateMode>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
            child: Text(
              l.nodesAddChoiceTitle,
              style: Theme.of(sheetContext).textTheme.titleLarge,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: Text(l.nodesAddExisting),
            subtitle: Text(l.nodesAddExistingHint),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.pop(sheetContext, _NodeCreateMode.existing),
          ),
          ListTile(
            leading: const Icon(Icons.rocket_launch_outlined),
            title: Text(l.nodesBootstrapNew),
            subtitle: Text(l.nodesBootstrapNewHint),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.pop(sheetContext, _NodeCreateMode.bootstrap),
          ),
          const SizedBox(height: 12),
        ],
      ),
    ),
  );
  if (mode == null || !context.mounted) return;
  await _showManagedNodeEditor(context, null, createMode: mode);
}

Future<void> _showManagedNodeEditor(
  BuildContext context,
  ManagedNode? existing, {
  _NodeCreateMode createMode = _NodeCreateMode.existing,
}) async {
  final saved = await showModalBottomSheet<ManagedNode>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => _NodeEditSheet(existing: existing, createMode: createMode),
  );
  if (saved == null ||
      existing != null ||
      createMode != _NodeCreateMode.bootstrap ||
      !context.mounted) {
    return;
  }
  await Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => NodeProvisionScreen(node: saved)),
  );
}

class _NodeEditSheet extends ConsumerStatefulWidget {
  const _NodeEditSheet({this.existing, required this.createMode});
  final ManagedNode? existing;
  final _NodeCreateMode createMode;
  @override
  ConsumerState<_NodeEditSheet> createState() => _NodeEditSheetState();
}

class _NodeEditSheetState extends ConsumerState<_NodeEditSheet> {
  late final TextEditingController _label;
  late final TextEditingController _nodeId;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _user;
  late final TextEditingController _password;
  String? _privateKeyPem;
  String? _publicKeyOpenSsh;
  String? _labelError;
  String? _nodeIdError;
  String? _hostError;
  String? _userError;
  bool _probing = false;
  bool _credentialsLoaded = false;
  bool _generatingKey = false;
  bool _saving = false;
  bool _endpointClearNotified = false;
  ProbeResult? _probeResult;

  /// The identity that OPENED this editor.
  ///
  /// An all-online switch does not close a bottom sheet. Without this, the
  /// load showed A's SSH password and private key under B, and the save read
  /// the providers again and wrote A's endpoint and secrets into B's
  /// encrypted storage.
  late final IdentityLease _lease = ref.leaseIdentity();

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _label = TextEditingController(text: e?.label ?? '');
    _nodeId = TextEditingController(text: e?.nodeId ?? '');
    _host = TextEditingController(text: e?.sshHost ?? '');
    _port = TextEditingController(text: '${e?.sshPort ?? 22}');
    _user = TextEditingController(text: e?.sshUser ?? '');
    _password = TextEditingController();
    _credentialsLoaded = e == null;
    if (e != null) unawaited(_loadCredentials(e.id));
  }

  Future<void> _loadCredentials(String nodeId) async {
    final credentials = await ref
        .read(sshCredentialsRepositoryProvider)
        .load(nodeId);
    if (!mounted) return;
    // Showing these under a different identity is the leak, before any write.
    if (!ref.holdsIdentity(_lease)) return;
    _password.text = credentials.password ?? '';
    setState(() {
      _privateKeyPem = credentials.privateKeyPem;
      _publicKeyOpenSsh = credentials.publicKeyOpenSsh;
      _credentialsLoaded = true;
    });
  }

  @override
  void dispose() {
    for (final c in [_label, _nodeId, _host, _port, _user, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  bool _isHex64(String s) =>
      s.length == 64 && RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(s);

  bool get _isBootstrapNew =>
      widget.existing == null && widget.createMode == _NodeCreateMode.bootstrap;

  bool get _isExistingNew =>
      widget.existing == null && widget.createMode == _NodeCreateMode.existing;

  SavedSshCredentials get _credentials => SavedSshCredentials(
    password: _password.text.isEmpty ? null : _password.text,
    privateKeyPem: _privateKeyPem,
    publicKeyOpenSsh: _publicKeyOpenSsh,
  );

  void _onEndpointChanged() {
    final existing = widget.existing;
    if (existing == null || !_credentialsLoaded) return;
    final changed =
        existing.sshHost !=
            (_host.text.trim().isEmpty ? null : _host.text.trim()) ||
        existing.sshPort != (int.tryParse(_port.text.trim()) ?? 22) ||
        existing.sshUser !=
            (_user.text.trim().isEmpty ? null : _user.text.trim());
    if (!changed || _credentials.isEmpty) return;
    setState(() {
      _password.clear();
      _privateKeyPem = null;
      _publicKeyOpenSsh = null;
    });
    if (_endpointClearNotified) return;
    _endpointClearNotified = true;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppL10n.of(context).sshCredentialsEndpointCleared),
      ),
    );
  }

  Future<void> _generateKey() async {
    setState(() => _generatingKey = true);
    try {
      final pair = await generateSshEd25519KeyPair(
        comment: _label.text.trim().isEmpty
            ? 'xveil'
            : 'xveil-${_label.text.trim()}',
      );
      if (!mounted) return;
      setState(() {
        _privateKeyPem = pair.privateKeyPem;
        _publicKeyOpenSsh = pair.publicKeyOpenSsh;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppL10n.of(context).sshKeyGenerationFailed(shownCause(e)),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _generatingKey = false);
    }
  }

  Future<void> _save() async {
    if (!_credentialsLoaded || _saving) return;
    final l = AppL10n.of(context);
    final label = _label.text.trim();
    final nodeId = _nodeId.text.trim();
    final host = _host.text.trim();
    final user = _user.text.trim();
    setState(() {
      _labelError = label.isEmpty ? l.nodeLabelRequired : null;
      _nodeIdError = _isExistingNew && nodeId.isEmpty
          ? l.nodeIdRequired
          : (nodeId.isNotEmpty && !_isHex64(nodeId))
          ? l.nodeIdInvalid
          : null;
      _hostError = _isBootstrapNew && host.isEmpty
          ? l.nodeSshHostRequired
          : null;
      _userError = _isBootstrapNew && user.isEmpty
          ? l.nodeSshUserRequired
          : null;
    });
    if (_labelError != null ||
        _nodeIdError != null ||
        _hostError != null ||
        _userError != null) {
      return;
    }

    final port = int.tryParse(_port.text.trim()) ?? 22;
    final sshUser = user.isEmpty ? null : user;
    final sshHost = host.isEmpty ? null : host;

    // Carry the pinned SSH host key across an edit — but ONLY when the SSH
    // endpoint is unchanged. Rebuilding the node from the form (the old code)
    // dropped sshHostFingerprint, silently downgrading a pinned node back to
    // trust-on-first-use on the next connect (a MITM could then re-pin itself).
    // Read the CURRENT persisted node, not the possibly-stale widget.existing
    // (a connect-and-check may have just pinned it). Editing host/port/user
    // points at a different server, so the old pin must NOT carry over.
    final existingId = widget.existing?.id;
    String? pin;
    ManagedNode? current;
    if (existingId != null) {
      final nodes =
          ref.read(managedNodesProvider).value ?? const <ManagedNode>[];
      for (final n in nodes) {
        if (n.id == existingId) {
          current = n;
          break;
        }
      }
    }
    // Everything this form does NOT ask about belongs to the machine at the
    // other end, and survives an edit of the label. It used to be rebuilt from
    // the form alone, so renaming a server silently set `autoUpdate` back to
    // false while a root timer kept updating it on a schedule — and the screen
    // then said unattended updates were off.
    final sameEndpoint =
        current != null &&
        current.sshHost == sshHost &&
        current.sshPort == port &&
        current.sshUser == sshUser;
    if (sameEndpoint) pin = current.sshHostFingerprint;

    final node = ManagedNode(
      id: existingId ?? const Uuid().v4(),
      label: label,
      nodeId: nodeId.isEmpty ? null : nodeId,
      sshHost: sshHost,
      sshPort: port,
      sshUser: sshUser,
      sshHostFingerprint: pin,
      // Pointed at a different machine, these describe the previous one: the
      // host key, the version it reported, the timer somebody enabled there.
      // Carrying them over would claim things about a server nobody has asked
      // anything yet.
      autoUpdate: sameEndpoint && current.autoUpdate,
      veilVersion: sameEndpoint ? current.veilVersion : null,
    );
    // The sheet outlived the identity that opened it, so these secrets and
    // this endpoint belong to a container that is no longer current.
    if (!ref.holdsIdentity(_lease)) return;
    setState(() => _saving = true);
    try {
      // The registry write reports rather than throws, so it has to be
      // CHECKED: this dialog used to pop with the node as if it were saved
      // while the commit had failed, and the user found out at the next
      // launch (report9 X-05).
      final registryError = await ref
          .read(managedNodesProvider.notifier)
          .upsert(node);
      if (registryError != null) {
        if (!mounted) return;
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l.nodeRegistrySaveFailed(registryError))),
        );
        return;
      }
      // Re-checked: the registry write above is awaited, and the secrets are
      // the half that must not land in the wrong container.
      if (!ref.holdsIdentity(_lease)) return;
      await ref
          .read(sshCredentialsRepositoryProvider)
          .save(node.id, _credentials);
      if (mounted) Navigator.of(context).pop(node);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.sshCredentialsSaveFailed(shownCause(e)))),
      );
    }
  }

  /// TOFU-pin the host key the connect-and-check dialog observed onto the SAVED
  /// node — only when it has no pin yet and the checked endpoint still matches
  /// the saved one (the form wasn't edited away from it). A CHANGED key never
  /// reaches here: sshRun throws on a pin mismatch before this fires.
  Future<void> _maybePinCheckedHost(String fingerprint) async {
    final ex = widget.existing;
    if (ex == null || ex.sshHostFingerprint != null || fingerprint.isEmpty) {
      return;
    }
    final host = _host.text.trim();
    if (ex.sshHost != (host.isEmpty ? null : host) ||
        ex.sshPort != (int.tryParse(_port.text.trim()) ?? 22) ||
        ex.sshUser != (_user.text.trim().isEmpty ? null : _user.text.trim())) {
      return; // endpoint edited since save — don't pin onto a mismatched node
    }
    final failed = await ref
        .read(managedNodesProvider.notifier)
        .upsert(ex.copyWith(sshHostFingerprint: fingerprint));
    if (failed != null && mounted) {
      // Same reason as the two dialogs: a pin nobody saved is a first contact
      // nobody expects.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppL10n.of(context).nodeHostKeyNotRemembered(failed)),
        ),
      );
    }
  }

  Future<void> _remove() async {
    // This drops the node AND its saved SSH password or key, and it used to
    // happen on a single tap — no question asked, nothing to undo. The
    // sentence that should have been asked was already written and translated;
    // it simply had no dialog to live in.
    final l = AppL10n.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.nodeRemove),
        content: Text(l.nodeRemoveConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l.actionCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l.nodeRemove),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref.read(sshCredentialsRepositoryProvider).clear(widget.existing!.id);
    final registryError = await ref
        .read(managedNodesProvider.notifier)
        .remove(widget.existing!.id);
    if (!mounted) return;
    if (registryError != null) {
      // Closing here would say the node is gone while it is still on disk and
      // will be back at the next launch — with its credentials cleared.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.nodeRegistrySaveFailed(registryError))),
      );
      return;
    }
    Navigator.of(context).pop();
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

  Future<void> _openProvision() async {
    final existing = widget.existing!;
    try {
      await ref
          .read(sshCredentialsRepositoryProvider)
          .save(existing.id, _credentials);
      if (!mounted) return;
      final node = existing.copyWith(
        sshHost: _host.text.trim(),
        sshPort: int.tryParse(_port.text.trim()) ?? 22,
        sshUser: _user.text.trim(),
      );
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              NodeProvisionScreen(node: node, initialCredentials: _credentials),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppL10n.of(context).sshCredentialsSaveFailed(shownCause(e)),
          ),
        ),
      );
    }
  }

  void _useAsExit() {
    final l = AppL10n.of(context);
    final id = _nodeId.text.trim();
    if (!_isHex64(id)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.nodeNeedsNodeId)));
      return;
    }
    final cur = ref.read(proxyRoutingProvider);
    final endpoints = [...cur.effectiveOproxies]
      ..removeWhere((endpoint) => endpoint.nodeId == id)
      ..add(
        OproxyEndpoint(
          nodeId: id.toLowerCase(),
          label: _label.text.trim().isEmpty
              ? 'oproxy ${id.substring(0, 8)}'
              : _label.text.trim(),
        ),
      );
    final defaults = cur.effectiveDefaultOproxyNodeIds.isEmpty
        ? [id.toLowerCase()]
        : cur.effectiveDefaultOproxyNodeIds;
    ref
        .read(proxyRoutingProvider.notifier)
        .set(
          cur.copyWith(
            socks5Enabled: true,
            exitNodeId: defaults.first,
            oProxies: endpoints,
            defaultOproxyNodeIds: defaults,
          ),
        );
    Navigator.of(context).pop();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l.nodeUseAsExitDone)));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final isEdit = widget.existing != null;
    final nodeId = _nodeId.text.trim();
    final canExit = _isHex64(nodeId);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        20 +
            MediaQuery.of(context).viewInsets.bottom +
            MediaQuery.of(context).viewPadding.bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              isEdit
                  ? l.nodeEdit
                  : _isBootstrapNew
                  ? l.nodesBootstrapNew
                  : l.nodesAddExisting,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline,
                  size: 18,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _isBootstrapNew
                        ? l.nodesBootstrapFieldsHint
                        : l.nodesAddExistingFieldsHint,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
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
            if (!_isBootstrapNew) ...[
              TextField(
                controller: _nodeId,
                minLines: 1,
                maxLines: 2,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                onChanged: (_) => setState(() => _nodeIdError = null),
                decoration: InputDecoration(
                  labelText: _isExistingNew
                      ? l.nodeIdRequiredLabel
                      : l.nodeIdLabel,
                  helperText: l.nodeIdHintText,
                  helperMaxLines: 2,
                  errorText: _nodeIdError,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _host,
              onChanged: (_) {
                setState(() {
                  _probeResult = null;
                  _hostError = null;
                });
                _onEndpointChanged();
              },
              decoration: InputDecoration(
                labelText: _isBootstrapNew
                    ? l.nodeSshHostRequiredLabel
                    : l.nodeSshHostLabel,
                errorText: _hostError,
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
                    onChanged: (_) => _onEndpointChanged(),
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
                    onChanged: (_) {
                      setState(() => _userError = null);
                      _onEndpointChanged();
                    },
                    decoration: InputDecoration(
                      labelText: _isBootstrapNew
                          ? l.nodeSshUserRequiredLabel
                          : l.nodeSshUserLabel,
                      errorText: _userError,
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              l.sshCredentialsTitle,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            if (!_credentialsLoaded)
              const LinearProgressIndicator()
            else ...[
              TextField(
                controller: _password,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: l.sshSavedPasswordLabel,
                  helperText: l.sshSavedPasswordHint,
                  helperMaxLines: 2,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                l.sshCredentialsEncryptedHint,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              if (_publicKeyOpenSsh != null && _privateKeyPem != null)
                SshPublicKeyCard(
                  publicKey: _publicKeyOpenSsh!,
                  onRemove: () => setState(() {
                    _privateKeyPem = null;
                    _publicKeyOpenSsh = null;
                  }),
                ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _generatingKey ? null : _generateKey,
                icon: _generatingKey
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.key),
                label: Text(
                  _privateKeyPem == null
                      ? l.sshGenerateEd25519
                      : l.sshRegenerateEd25519,
                ),
              ),
            ],
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
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.wifi_find),
                    label: Text(
                      _probing ? l.nodeChecking : l.nodeCheckReachable,
                    ),
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
                        Text(
                          _probeResult == ProbeResult.reachable
                              ? l.nodeReachable
                              : l.nodeUnreachable,
                        ),
                      ],
                    ),
                ],
              ),
            // SSH connect & check — needs a user. Saved credentials are passed
            // from the encrypted per-node record; overrides remain one-shot.
            if (_host.text.trim().isNotEmpty && _user.text.trim().isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: !_credentialsLoaded
                      ? null
                      : () => showDialog<void>(
                          context: context,
                          builder: (_) => SshCheckDialog(
                            host: _host.text.trim(),
                            port: int.tryParse(_port.text.trim()) ?? 22,
                            user: _user.text.trim(),
                            initialCredentials: _credentials,
                            expectedHostFingerprint:
                                widget.existing?.sshHostFingerprint,
                            onHostKeyObserved: _maybePinCheckedHost,
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
                  onPressed: _credentialsLoaded ? _openProvision : null,
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
            FilledButton(
              onPressed: !_credentialsLoaded || _saving ? null : _save,
              child: Text(
                _saving
                    ? l.sshCredentialsSaving
                    : _isBootstrapNew
                    ? l.nodesBootstrapContinue
                    : l.actionSave,
              ),
            ),
            if (isEdit) ...[
              const SizedBox(height: 4),
              TextButton.icon(
                onPressed: _remove,
                icon: Icon(
                  Icons.delete_outline,
                  color: Theme.of(context).colorScheme.error,
                ),
                label: Text(
                  l.nodeRemove,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
