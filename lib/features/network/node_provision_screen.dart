import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/node/managed_node.dart';
import '../../data/node/node_provisioner.dart';
import '../../data/node/ssh_client.dart';
import '../../data/node/ssh_credentials.dart';
import '../../data/node/veil_github_release.dart';
import '../../l10n/app_localizations.dart';
import '../../state/managed_nodes_controller.dart';
import '../../state/ssh_credentials.dart';
import 'ssh_public_key_card.dart';

/// Provision a veil node on a managed server over SSH: review the generated
/// install script (it runs as root), then run it. The script pulls veil-cli
/// from a release URL, pushes the bundled deployment PSK, mines an identity on
/// first run, installs a systemd unit and starts it — then reports the node id,
/// which we offer to save back onto the node (so it can be used as a routing
/// exit).
class NodeProvisionScreen extends ConsumerStatefulWidget {
  const NodeProvisionScreen({
    super.key,
    required this.node,
    this.initialCredentials,
    this.releaseResolver,
  });
  final ManagedNode node;
  final SavedSshCredentials? initialCredentials;
  final VeilGithubReleaseResolver? releaseResolver;

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
  final _advertiseHost = TextEditingController();
  final _tlsCert = TextEditingController();
  final _tlsKey = TextEditingController();
  final _tlsCa = TextEditingController();
  late final Map<NodeComponent, TextEditingController> _componentUrls;
  late final Map<NodeComponent, TextEditingController> _componentShas;
  late final Map<NodeListenTransport, TextEditingController> _transportPorts;
  final Set<NodeComponent> _extraComponents = {};
  final Set<NodeListenTransport> _transports = {NodeListenTransport.obfs4Tcp};
  bool _useKey = false;
  bool _runExit = true;
  String? _psk;
  bool _pskLoaded = false;
  bool _credentialsLoaded = false;
  SavedSshCredentials _credentials = const SavedSshCredentials();
  bool _busy = false;
  String? _output;
  String? _error;
  VeilLinuxReleaseTarget _releaseTarget = VeilLinuxReleaseTarget.x86_64Musl;
  bool _releaseLoading = false;
  String? _releaseTag;
  String? _releaseLoadError;
  int _releaseRequest = 0;

  @override
  void initState() {
    super.initState();
    _componentUrls = {
      for (final component in NodeComponent.values)
        if (component != NodeComponent.veilCli)
          component: TextEditingController(),
    };
    _componentShas = {
      for (final component in NodeComponent.values)
        if (component != NodeComponent.veilCli)
          component: TextEditingController(),
    };
    _transportPorts = {
      for (final transport in NodeListenTransport.values)
        transport: TextEditingController(text: '${transport.defaultPort}'),
    };
    unawaited(_loadPsk());
    unawaited(_loadCredentials());
    unawaited(_loadLatestRelease());
  }

  Future<void> _loadLatestRelease({bool replaceManualValues = false}) async {
    final request = ++_releaseRequest;
    setState(() {
      _releaseLoading = true;
      _releaseLoadError = null;
    });
    try {
      final release =
          await (widget.releaseResolver ?? VeilGithubReleaseResolver()).resolve(
            _releaseTarget,
          );
      if (!mounted || request != _releaseRequest) return;
      final mayReplace =
          replaceManualValues ||
          (_releaseUrl.text.trim().isEmpty && _sha256.text.trim().isEmpty);
      setState(() {
        if (mayReplace) {
          _releaseUrl.text = release.downloadUrl;
          _sha256.text = release.sha256;
        }
        _releaseTag = release.tag;
        _releaseLoading = false;
      });
    } on Object catch (error) {
      if (!mounted || request != _releaseRequest) return;
      setState(() {
        _releaseLoading = false;
        _releaseLoadError = error.toString();
      });
    }
  }

  Future<void> _loadCredentials() async {
    final credentials =
        widget.initialCredentials ??
        await ref.read(sshCredentialsRepositoryProvider).load(widget.node.id);
    if (!mounted) return;
    _password.text = credentials.password ?? '';
    setState(() {
      _credentials = credentials;
      _useKey = !credentials.hasPassword && credentials.hasKey;
      _credentialsLoaded = true;
    });
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
    for (final c in [
      _releaseUrl,
      _sha256,
      _password,
      _key,
      _passphrase,
      _advertiseHost,
      _tlsCert,
      _tlsKey,
      _tlsCa,
      ..._componentUrls.values,
      ..._componentShas.values,
      ..._transportPorts.values,
    ]) {
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
      extraArtifacts: [
        for (final component in _extraComponents)
          NodeReleaseArtifact(
            component: component,
            releaseUrl: _componentUrls[component]!.text.trim(),
            expectedSha256: _componentShas[component]!.text.trim(),
          ),
      ],
      transports: Set.unmodifiable(_transports),
      transportPorts: {
        for (final transport in _transports)
          transport: int.tryParse(_transportPorts[transport]!.text.trim()) ?? 0,
      },
      advertiseHost: _advertiseHost.text.trim().isEmpty
          ? null
          : _advertiseHost.text.trim(),
      tlsCertPath: _tlsCert.text.trim().isEmpty ? null : _tlsCert.text.trim(),
      tlsKeyPath: _tlsKey.text.trim().isEmpty ? null : _tlsKey.text.trim(),
      tlsCaCertPath: _tlsCa.text.trim().isEmpty ? null : _tlsCa.text.trim(),
    );
  }

  Future<void> _run() async {
    final cfg = _config;
    final l = AppL10n.of(context);
    if (cfg == null || !cfg.isValid) {
      setState(() => _error = l.provisionNeedUrl);
      return;
    }
    final key = _key.text.trim().isNotEmpty
        ? _key.text
        : _credentials.privateKeyPem;
    if ((!_useKey && _password.text.isEmpty) ||
        (_useKey && (key == null || key.isEmpty))) {
      setState(() => _error = l.sshCredentialRequired);
      return;
    }
    setState(() {
      _busy = true;
      _output = null;
      _error = null;
    });
    final auth = _useKey
        ? SshAuth.key(
            key!,
            passphrase: _passphrase.text.isEmpty ? null : _passphrase.text,
          )
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

  String _releaseTargetLabel(AppL10n l, VeilLinuxReleaseTarget target) =>
      switch (target) {
        VeilLinuxReleaseTarget.x86_64Musl => l.provisionReleaseTargetX64,
        VeilLinuxReleaseTarget.aarch64Musl => l.provisionReleaseTargetArm64,
      };

  String _transportHint(AppL10n l, NodeListenTransport transport) =>
      switch (transport) {
        NodeListenTransport.obfs4Tcp => l.provisionTransportObfs4TcpHint,
        NodeListenTransport.tcp => l.provisionTransportTcpHint,
        NodeListenTransport.tls => l.provisionTransportTlsHint,
        NodeListenTransport.quic => l.provisionTransportQuicHint,
        NodeListenTransport.wss => l.provisionTransportWssHint,
      };

  String _transportNetwork(NodeListenTransport transport) =>
      transport == NodeListenTransport.quic ? 'UDP' : 'TCP';

  Widget _releaseSection(AppL10n l) => _SettingsCard(
    title: l.provisionReleaseSection,
    children: [
      DropdownButtonFormField<VeilLinuxReleaseTarget>(
        key: const ValueKey('veil-release-target'),
        initialValue: _releaseTarget,
        decoration: InputDecoration(
          labelText: l.provisionReleaseTarget,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        items: [
          for (final target in VeilLinuxReleaseTarget.values)
            DropdownMenuItem(
              value: target,
              child: Text(_releaseTargetLabel(l, target)),
            ),
        ],
        onChanged: _releaseLoading
            ? null
            : (target) {
                if (target == null || target == _releaseTarget) return;
                setState(() => _releaseTarget = target);
                unawaited(_loadLatestRelease(replaceManualValues: true));
              },
      ),
      const SizedBox(height: 12),
      TextField(
        key: const ValueKey('veil-release-url'),
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
      const SizedBox(height: 12),
      TextField(
        key: const ValueKey('veil-release-sha'),
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
      const SizedBox(height: 8),
      if (_releaseLoading)
        Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(l.provisionReleaseLoading)),
          ],
        )
      else ...[
        if (_releaseLoadError != null)
          Text(
            l.provisionReleaseError(_releaseLoadError!),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          )
        else if (_releaseTag != null)
          Text(
            l.provisionReleaseLoaded(_releaseTag!),
            style: TextStyle(color: Theme.of(context).colorScheme.primary),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('veil-release-refresh'),
            onPressed: () =>
                unawaited(_loadLatestRelease(replaceManualValues: true)),
            icon: const Icon(Icons.refresh),
            label: Text(l.provisionReleaseRefresh),
          ),
        ),
      ],
    ],
  );

  Widget _componentsSection(AppL10n l) => _SettingsCard(
    title: l.provisionComponents,
    children: [
      Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          const Chip(
            avatar: Icon(Icons.check, size: 18),
            label: Text('veil-cli'),
          ),
          for (final component in NodeComponent.values)
            if (component != NodeComponent.veilCli)
              FilterChip(
                label: Text(component.binaryName),
                selected: _extraComponents.contains(component),
                onSelected: (selected) => setState(() {
                  if (selected) {
                    _extraComponents.add(component);
                  } else {
                    _extraComponents.remove(component);
                  }
                }),
              ),
        ],
      ),
      for (final component in NodeComponent.values)
        if (_extraComponents.contains(component)) ...[
          const SizedBox(height: 12),
          _SettingsCard(
            title: component.binaryName,
            nested: true,
            children: [
              TextField(
                controller: _componentUrls[component],
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: l.provisionComponentUrl(component.binaryName),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _componentShas[component],
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: l.provisionComponentSha(component.binaryName),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ],
          ),
        ],
    ],
  );

  Widget _transportsSection(AppL10n l) => _SettingsCard(
    title: l.provisionTransports,
    children: [
      for (final transport in NodeListenTransport.values) ...[
        _SettingsCard(
          key: ValueKey('transport-${transport.scheme}'),
          nested: true,
          children: [
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(transport.scheme),
              subtitle: Text(_transportHint(l, transport)),
              value: _transports.contains(transport),
              onChanged: (selected) => setState(() {
                if (selected ?? false) {
                  _transports.add(transport);
                } else if (_transports.length > 1) {
                  _transports.remove(transport);
                }
              }),
            ),
            if (_transports.contains(transport)) ...[
              const SizedBox(height: 4),
              TextField(
                key: ValueKey('transport-port-${transport.scheme}'),
                controller: _transportPorts[transport],
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: l.provisionTransportPort(transport.scheme),
                  helperText: l.provisionTransportNetwork(
                    _transportNetwork(transport),
                  ),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ],
          ],
        ),
        if (transport != NodeListenTransport.values.last)
          const SizedBox(height: 8),
      ],
    ],
  );

  Widget _sharedTransportSection(AppL10n l) {
    final tlsTransports = _transports.where((transport) => transport.needsTls);
    return _SettingsCard(
      title: l.provisionTransportCommon,
      subtitle: l.provisionTransportCommonHint,
      children: [
        TextField(
          controller: _advertiseHost,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: l.provisionAdvertiseHost,
            helperText: l.provisionAdvertiseHostHint,
            helperMaxLines: 3,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
        if (tlsTransports.isNotEmpty) ...[
          const SizedBox(height: 12),
          _SettingsCard(
            title: l.provisionTlsShared,
            subtitle: l.provisionTlsSharedHint(
              tlsTransports.map((transport) => transport.scheme).join(', '),
            ),
            nested: true,
            children: [
              TextField(
                controller: _tlsCert,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: l.provisionTlsCert,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _tlsKey,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: l.provisionTlsKey,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _tlsCa,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: l.provisionTlsCa,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ],
          ),
        ],
      ],
    );
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
    // Only render (and later run) the script once the config is fully valid —
    // a partial/invalid URL or checksum must never be interpolated into a
    // root-sudo script, not even in the copyable preview.
    final script = (cfg != null && cfg.isValid)
        ? buildProvisionScript(cfg)
        : null;
    return Scaffold(
      appBar: AppBar(title: Text(l.provisionTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '${widget.node.sshUser}@${widget.node.sshHost}:${widget.node.sshPort}',
            style: const TextStyle(fontFamily: 'monospace'),
          ),
          const SizedBox(height: 12),
          _releaseSection(l),
          const SizedBox(height: 12),
          _componentsSection(l),
          const SizedBox(height: 12),
          _transportsSection(l),
          const SizedBox(height: 12),
          _sharedTransportSection(l),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l.provisionRunExit),
            value: _runExit,
            onChanged: (v) => setState(() => _runExit = v),
          ),
          // Auth: prefer the encrypted per-node credential, while still
          // allowing a one-shot password/key override for this run.
          if (!_credentialsLoaded) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: 8),
          ],
          SegmentedButton<bool>(
            segments: [
              ButtonSegment(value: false, label: Text(l.sshUsePassword)),
              ButtonSegment(value: true, label: Text(l.sshUseKey)),
            ],
            selected: {_useKey},
            onSelectionChanged: !_credentialsLoaded || _busy
                ? null
                : (s) => setState(() => _useKey = s.first),
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
            if (_credentials.hasKey) ...[
              SshPublicKeyCard(publicKey: _credentials.publicKeyOpenSsh!),
              const SizedBox(height: 8),
            ],
            TextField(
              controller: _key,
              minLines: 2,
              maxLines: 4,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              decoration: InputDecoration(
                labelText: _credentials.hasKey
                    ? l.sshOtherKeyLabel
                    : l.sshKeyLabel,
                helperText: _credentials.hasKey ? l.sshUseSavedKeyHint : null,
                helperMaxLines: 2,
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
          Text(
            l.sshCredsNotSaved,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.outline),
          ),
          if (script != null) ...[
            const SizedBox(height: 16),
            Text(
              l.provisionScriptLabel,
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                script,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 10.5),
              ),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy || !_credentialsLoaded ? null : _run,
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
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
              child: SelectableText(
                _output!,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({
    super.key,
    this.title,
    this.subtitle,
    this.nested = false,
    required this.children,
  });

  final String? title;
  final String? subtitle;
  final bool nested;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      elevation: nested ? 0 : null,
      color: nested ? theme.colorScheme.surfaceContainerLow : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title != null) ...[
              Text(title!, style: theme.textTheme.titleMedium),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 12),
            ],
            ...children,
          ],
        ),
      ),
    );
  }
}
