import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/node/managed_node.dart';
import '../../data/node/node_provisioner.dart';
import '../../data/node/ssh_client.dart';
import '../../l10n/app_localizations.dart';
import '../../state/managed_nodes_controller.dart';

/// Provision a veil node on a managed server over SSH: review the generated
/// install script (it runs as root), then run it. The script pulls veil-cli
/// from a release URL, pushes the bundled deployment PSK, mines an identity on
/// first run, installs a systemd unit and starts it — then reports the node id,
/// which we offer to save back onto the node (so it can be used as a routing
/// exit).
class NodeProvisionScreen extends ConsumerStatefulWidget {
  const NodeProvisionScreen({super.key, required this.node});
  final ManagedNode node;

  @override
  ConsumerState<NodeProvisionScreen> createState() =>
      _NodeProvisionScreenState();
}

class _NodeProvisionScreenState extends ConsumerState<NodeProvisionScreen> {
  final _releaseUrl = TextEditingController();
  final _sha256 = TextEditingController();
  final _password = TextEditingController();
  final _key = TextEditingController();
  final _passphrase = TextEditingController();
  bool _useKey = false;
  bool _runExit = true;
  String? _psk;
  bool _pskLoaded = false;
  bool _busy = false;
  String? _output;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadPsk();
  }

  Future<void> _loadPsk() async {
    String? psk;
    try {
      psk = (await rootBundle.loadString('assets/prod/obfs4_psk.b64')).trim();
    } catch (_) {
      psk = null;
    }
    if (mounted) {
      setState(() {
        _psk = (psk != null && psk.isNotEmpty) ? psk : null;
        _pskLoaded = true;
      });
    }
  }

  @override
  void dispose() {
    for (final c in [_releaseUrl, _sha256, _password, _key, _passphrase]) {
      c.dispose();
    }
    super.dispose();
  }

  NodeProvisionConfig? get _config {
    final psk = _psk;
    if (psk == null) return null;
    return NodeProvisionConfig(
      releaseUrl: _releaseUrl.text.trim(),
      expectedSha256: _sha256.text.trim(),
      obfs4PskB64: psk,
      runExit: _runExit,
    );
  }

  Future<void> _run() async {
    final cfg = _config;
    final l = AppL10n.of(context);
    if (cfg == null || !cfg.isValid) {
      setState(() => _error = l.provisionNeedUrl);
      return;
    }
    setState(() {
      _busy = true;
      _output = null;
      _error = null;
    });
    final auth = _useKey
        ? SshAuth.key(_key.text,
            passphrase: _passphrase.text.isEmpty ? null : _passphrase.text)
        : SshAuth.password(_password.text);
    try {
      final r = await sshRun(
        host: widget.node.sshHost!,
        port: widget.node.sshPort,
        user: widget.node.sshUser!,
        auth: auth,
        command: buildProvisionScript(cfg),
        // Pin the host key: enforce it if we already saved one (reject a MITM),
        // capture it trust-on-first-use otherwise. A mismatch throws below.
        expectedHostFingerprint: widget.node.sshHostFingerprint,
        // Mining the identity (PoW) on first run can take minutes.
        timeout: const Duration(minutes: 6),
      );
      final fpLine = r.hostFingerprint.isNotEmpty
          ? '\nhost key: ${r.hostFingerprint}'
          : '';
      final combined =
          '${r.stdout}${r.stderr.isNotEmpty ? '\n${r.stderr}' : ''}';
      if (mounted) {
        setState(() => _output = '$combined\n(exit ${r.exitCode})$fpLine');
      }
      await _persistAfterRun(fingerprint: r.hostFingerprint, output: combined);
    } on SshException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// One upsert after a successful run: pin the server's host-key fingerprint
  /// trust-on-first-use (only if not already pinned — a CHANGED key never gets
  /// here, [sshRun] throws on a pin mismatch) AND save a freshly-reported node
  /// id. Combined into a single derive-from-[widget.node] upsert so the two
  /// updates can't clobber each other.
  Future<void> _persistAfterRun({
    required String fingerprint,
    required String output,
  }) async {
    var node = widget.node;
    var changed = false;
    if (fingerprint.isNotEmpty && node.sshHostFingerprint == null) {
      node = node.copyWith(sshHostFingerprint: fingerprint);
      changed = true;
    }
    final m = RegExp(r'NODE_ID:\s*([0-9a-fA-F]{64})').firstMatch(output);
    final savedId = m != null;
    if (savedId) {
      node = node.copyWith(nodeId: m.group(1)!.toLowerCase());
      changed = true;
    }
    if (changed) {
      await ref.read(managedNodesProvider.notifier).upsert(node);
    }
    if (savedId && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppL10n.of(context).provisionSavedNodeId)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_pskLoaded && _psk == null) {
      return Scaffold(
        appBar: AppBar(title: Text(l.provisionTitle)),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Center(child: Text(l.provisionPskMissing)),
        ),
      );
    }
    final cfg = _config;
    final script = (cfg != null && _releaseUrl.text.trim().isNotEmpty)
        ? buildProvisionScript(cfg)
        : null;
    return Scaffold(
      appBar: AppBar(title: Text(l.provisionTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('${widget.node.sshUser}@${widget.node.sshHost}:${widget.node.sshPort}',
              style: const TextStyle(fontFamily: 'monospace')),
          const SizedBox(height: 12),
          TextField(
            controller: _releaseUrl,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: l.provisionReleaseUrl,
              helperText: l.provisionReleaseHint,
              helperMaxLines: 3,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _sha256,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: l.provisionSha256,
              helperText: l.provisionSha256Hint,
              helperMaxLines: 4,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l.provisionRunExit),
            value: _runExit,
            onChanged: (v) => setState(() => _runExit = v),
          ),
          // Auth — never stored.
          SegmentedButton<bool>(
            segments: [
              ButtonSegment(value: false, label: Text(l.sshUsePassword)),
              ButtonSegment(value: true, label: Text(l.sshUseKey)),
            ],
            selected: {_useKey},
            onSelectionChanged: (s) => setState(() => _useKey = s.first),
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
          else ...[
            TextField(
              controller: _key,
              minLines: 2,
              maxLines: 4,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              decoration: InputDecoration(
                labelText: l.sshKeyLabel,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _passphrase,
              obscureText: true,
              decoration: InputDecoration(
                labelText: l.sshKeyPassphraseLabel,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
          Text(l.sshCredsNotSaved,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.outline)),
          if (script != null) ...[
            const SizedBox(height: 16),
            Text(l.provisionScriptLabel,
                style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(script,
                  style:
                      const TextStyle(fontFamily: 'monospace', fontSize: 10.5)),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy ? null : _run,
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.rocket_launch),
            label: Text(_busy ? l.provisionRunning : l.provisionRun),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(l.sshError(_error!), style: TextStyle(color: scheme.error)),
          ],
          if (_output != null) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(_output!,
                  style:
                      const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            ),
          ],
        ],
      ),
    );
  }
}
