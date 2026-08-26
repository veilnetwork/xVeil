import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ssh_host_confirm.dart';

import '../../data/node/managed_node.dart';
import '../../data/node/exit_allowlist.dart';
import '../../data/node/proxy_routing.dart';
import '../../data/node/node_lifecycle.dart';
import '../../data/node/ssh_client.dart';
import '../../l10n/app_localizations.dart';
import 'ssh_private_key_field.dart';
import '../../state/managed_nodes_controller.dart';

/// Full-text advanced editor for the real remote TOML. Reads and writes through
/// framed base64; apply is transactional and the server rolls back if validation
/// or service activation fails.
class NodeConfigScreen extends ConsumerStatefulWidget {
  const NodeConfigScreen({super.key, required this.node, required this.target});

  final ManagedNode node;
  final NodeConfigTarget target;

  @override
  ConsumerState<NodeConfigScreen> createState() => _NodeConfigScreenState();
}

class _NodeConfigScreenState extends ConsumerState<NodeConfigScreen> {
  final _password = TextEditingController();
  final _key = TextEditingController();
  final _passphrase = TextEditingController();
  final _config = TextEditingController();
  final _admit = TextEditingController();
  bool _useKey = false;
  bool _busy = false;
  bool _loaded = false;
  String? _output;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _key.dispose();
    _passphrase.dispose();
    _config.dispose();
    _admit.dispose();
    super.dispose();
  }

  SshAuth get _auth => _useKey
      ? SshAuth.key(
          _key.text,
          passphrase: _passphrase.text.isEmpty ? null : _passphrase.text,
        )
      : SshAuth.password(_password.text);

  Future<SshResult?> _run(String command) async {
    final node = widget.node;
    setState(() {
      _busy = true;
      _error = null;
      _output = null;
    });
    try {
      // Identity before credentials — see confirmSshHost.
      final pin = await confirmSshHost(
        context,
        host: node.sshHost!,
        port: node.sshPort,
        pinned: node.sshHostFingerprint,
      );
      if (pin == null) {
        if (mounted) {
          setState(() => _error = AppL10n.of(context).sshHostNotConfirmed);
        }
        return null;
      }
      final result = await sshRun(
        host: node.sshHost!,
        port: node.sshPort,
        user: node.sshUser!,
        auth: _auth,
        command: command,
        expectedHostFingerprint: pin,
        timeout: const Duration(minutes: 2),
      );
      if (result.hostFingerprint.isNotEmpty &&
          node.sshHostFingerprint == null) {
        await ref
            .read(managedNodesProvider.notifier)
            .upsert(node.copyWith(sshHostFingerprint: result.hostFingerprint));
      }
      return result;
    } on SshException catch (e) {
      if (mounted) setState(() => _error = e.message);
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load() async {
    final result = await _run(buildReadNodeConfigScript(widget.target));
    if (result == null || !mounted) return;
    final parsed = parseReadNodeConfig(result.stdout);
    if (parsed == null) {
      final l = AppL10n.of(context);
      setState(
        () => _error = result.stderr.isNotEmpty
            ? result.stderr
            : l.sshRemoteConfigEmpty,
      );
      return;
    }
    setState(() {
      _config.text = parsed;
      _loaded = true;
      _output = 'loaded ${widget.target.path}';
    });
  }

  Future<void> _apply() async {
    if (!_loaded) return;
    final result = await _run(
      buildWriteNodeConfigScript(widget.target, _config.text),
    );
    if (result == null || !mounted) return;
    setState(() {
      _output = [
        result.stdout,
        result.stderr,
      ].where((part) => part.isNotEmpty).join('\n');
      if (!result.ok) _error = 'exit ${result.exitCode}';
    });
  }

  /// Rewrite the loaded document's `[proxy.exit]` admission and keep the raw
  /// editor in step. Nothing leaves the device until Apply — which is the same
  /// transactional write, with the same validation and the same rollback, that
  /// the raw editor uses.
  void _setAdmission({List<String>? ids, bool? allowAll}) {
    final current = readExitAllowlist(_config.text);
    final next = withExitAllowlist(
      _config.text,
      allowedNodeIds: ids ?? current?.allowedNodeIds ?? const [],
      allowAll: allowAll ?? current?.allowAll ?? false,
    );
    setState(() {
      _config.text = next;
      _output = AppL10n.of(context).exitAdmissionUnsaved;
    });
  }

  Widget _admissionCard(AppL10n l, ColorScheme scheme) {
    final admission = readExitAllowlist(_config.text);
    if (admission == null) return const SizedBox.shrink();
    final id = _admit.text.trim().toLowerCase();
    // The catalog's own validator, not a fourth copy of the hex check: this is
    // the same 64-hex node id the routing screen accepts.
    final canAdd =
        ProxyRouting.isValidNodeId(id) &&
        !admission.allowedNodeIds.contains(id);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l.exitAdmissionTitle, style: Theme.of(context).textTheme.titleSmall),
            // The state that costs people their traffic, said plainly rather
            // than left to be inferred from an empty list.
            if (admission.admitsNobody)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  l.exitAdmissionNobody,
                  style: TextStyle(color: scheme.error),
                ),
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(l.exitAdmissionOpen),
              value: admission.allowAll,
              onChanged: _busy
                  ? null
                  : (value) => _setAdmission(allowAll: value),
            ),
            for (final entry in admission.allowedNodeIds)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(
                  entry,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
                trailing: IconButton(
                  tooltip: MaterialLocalizations.of(context).deleteButtonTooltip,
                  onPressed: _busy
                      ? null
                      : () => _setAdmission(
                          ids: admission.allowedNodeIds
                              .where((value) => value != entry)
                              .toList(),
                        ),
                  icon: const Icon(Icons.person_remove_outlined),
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _admit,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: l.exitAdmissionAddHint,
                      errorText: id.isEmpty || canAdd
                          ? null
                          : l.exitAdmissionInvalid,
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _busy || !canAdd
                      ? null
                      : () {
                          _setAdmission(
                            ids: [...admission.allowedNodeIds, id],
                          );
                          _admit.clear();
                        },
                  child: Text(l.exitAdmissionAdd),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final targetLabel = switch (widget.target) {
      NodeConfigTarget.veil => 'veil · node.toml',
      NodeConfigTarget.ogate => 'ogate · ogate.toml',
      NodeConfigTarget.oproxyClient => 'oproxy-client · client.toml',
      NodeConfigTarget.oproxyServer => 'oproxy-server · server.toml',
    };
    return Scaffold(
      appBar: AppBar(title: Text(targetLabel)),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<bool>(
                segments: [
                  ButtonSegment(value: false, label: Text(l.sshUsePassword)),
                  ButtonSegment(value: true, label: Text(l.sshUseKey)),
                ],
                selected: {_useKey},
                onSelectionChanged: _busy
                    ? null
                    : (selection) => setState(() => _useKey = selection.first),
              ),
              const SizedBox(height: 8),
              if (!_useKey)
                TextField(
                  controller: _password,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: l.sshPasswordLabel,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                )
              else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 2,
                      child: SshPrivateKeyField(
                        controller: _key,
                        maxLines: 4,
                        labelText: l.sshKeyLabel,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _passphrase,
                        obscureText: true,
                        decoration: InputDecoration(
                          labelText: l.sshKeyPassphraseLabel,
                          border: const OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                  ],
                ),
              const SizedBox(height: 8),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _load,
                    icon: const Icon(Icons.download),
                    label: Text(l.nodeConfigLoad),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _busy || !_loaded ? null : _apply,
                    icon: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.publish),
                    label: Text(l.nodeConfigApply),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (!_loaded)
                Text(
                  l.nodeConfigNotLoaded,
                  style: TextStyle(color: scheme.outline),
                ),
              if (_error != null)
                Text(
                  l.sshError(_error!),
                  style: TextStyle(color: scheme.error),
                ),
              if (_output != null)
                Text(
                  _output!,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
              const SizedBox(height: 8),
              if (_loaded && widget.target == NodeConfigTarget.veil)
                _admissionCard(l, scheme),
              Expanded(
                child: TextField(
                  controller: _config,
                  enabled: _loaded && !_busy,
                  expands: true,
                  minLines: null,
                  maxLines: null,
                  textAlignVertical: TextAlignVertical.top,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
