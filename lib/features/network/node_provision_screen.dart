import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../common/shown_cause.dart';
import '../../data/node/managed_node.dart';
import '../../data/node/node_provisioner.dart';
import '../../data/node/proxy_routing.dart';
import '../../data/node/ssh_client.dart';
import '../../data/node/ssh_credentials.dart';
import '../../data/node/veil_github_release.dart';
import '../../data/transport/bootstrap_invite.dart';
import '../../l10n/app_localizations.dart';
import '../../state/managed_nodes_controller.dart';
import '../../state/providers.dart';
import '../../state/proxy_routing_controller.dart';
import '../../state/ssh_credentials.dart';
import 'ssh_public_key_card.dart';

enum _ArtifactSource { github, custom }

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
  final _tlsAutomaticName = TextEditingController();
  final _tlsEmail = TextEditingController();
  final _selfSignedName = TextEditingController();
  final _selfSignedDays = TextEditingController(text: '365');
  late final Map<NodeComponent, TextEditingController> _componentUrls;
  late final Map<NodeComponent, TextEditingController> _componentShas;
  late final Map<NodeListenTransport, TextEditingController> _transportPorts;
  late final VeilGithubReleaseResolver _releaseResolver;
  final Set<NodeComponent> _extraComponents = {};
  final Map<NodeComponent, _ArtifactSource> _componentSources = {
    for (final component in NodeComponent.values)
      if (component != NodeComponent.veilCli) component: _ArtifactSource.github,
  };
  final Set<NodeListenTransport> _transports = {NodeListenTransport.obfs4Tcp};
  _ArtifactSource _veilCliSource = _ArtifactSource.github;
  bool _useKey = false;
  bool _runExit = true;
  NodeTlsCertificateMode _tlsCertificateMode = NodeTlsCertificateMode.automatic;
  bool _tlsAgreeToTerms = false;
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
    _releaseResolver = widget.releaseResolver ?? VeilGithubReleaseResolver();
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
    unawaited(_loadGithubArtifacts());
  }

  TextEditingController _urlController(NodeComponent component) =>
      component == NodeComponent.veilCli
      ? _releaseUrl
      : _componentUrls[component]!;

  TextEditingController _shaController(NodeComponent component) =>
      component == NodeComponent.veilCli ? _sha256 : _componentShas[component]!;

  _ArtifactSource _sourceFor(NodeComponent component) =>
      component == NodeComponent.veilCli
      ? _veilCliSource
      : _componentSources[component]!;

  Future<void> _loadGithubArtifacts({bool refresh = false}) async {
    final request = ++_releaseRequest;
    final components = <NodeComponent>[
      if (_veilCliSource == _ArtifactSource.github) NodeComponent.veilCli,
      for (final component in _extraComponents)
        if (_componentSources[component] == _ArtifactSource.github) component,
    ];
    if (components.isEmpty) {
      if (mounted) {
        setState(() {
          _releaseLoading = false;
          _releaseLoadError = null;
        });
      }
      return;
    }
    if (refresh) _releaseResolver.clearCache();
    setState(() {
      _releaseLoading = true;
      _releaseLoadError = null;
    });
    try {
      final releases = await Future.wait([
        for (final component in components)
          _releaseResolver.resolveArtifact(
            target: _releaseTarget,
            binaryName: component.binaryName,
          ),
      ]);
      if (!mounted || request != _releaseRequest) return;
      setState(() {
        for (var i = 0; i < components.length; i++) {
          final component = components[i];
          final release = releases[i];
          // A source may have changed while the request was in flight.
          if (_sourceFor(component) != _ArtifactSource.github) continue;
          _urlController(component).text = release.downloadUrl;
          _shaController(component).text = release.sha256;
        }
        _releaseTag = releases.first.tag;
        _releaseLoading = false;
      });
    } on Object catch (error) {
      if (!mounted || request != _releaseRequest) return;
      setState(() {
        _releaseLoading = false;
        _releaseLoadError = shownCause(error, kind: 'provision');
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
      _tlsAutomaticName,
      _tlsEmail,
      _selfSignedName,
      _selfSignedDays,
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
    final automaticName = _tlsAutomaticName.text.trim().isNotEmpty
        ? _tlsAutomaticName.text.trim()
        : _advertiseHost.text.trim();
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
      tlsCertificateMode: _tlsCertificateMode,
      tlsDomain: automaticName.isEmpty ? null : automaticName,
      tlsEmail: _tlsEmail.text.trim().isEmpty ? null : _tlsEmail.text.trim(),
      tlsAgreeToTerms: _tlsAgreeToTerms,
      selfSignedName: _selfSignedName.text.trim().isEmpty
          ? null
          : _selfSignedName.text.trim(),
      selfSignedDays: int.tryParse(_selfSignedDays.text.trim()) ?? 0,
    );
  }

  Future<void> _run() async {
    final cfg = _config;
    final l = AppL10n.of(context);
    if (cfg == null || !cfg.isValid) {
      setState(() => _error = l.provisionInvalidConfig);
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
  /// Everything a successful run should leave behind.
  ///
  /// Deployment used to end here with a saved node id and a snackbar, which
  /// meant a server could be installed, running and reachable while staying
  /// invisible to the app: not in the peer list, and — if an oproxy exit was
  /// installed — not in the proxy catalog either. The operator had no way to
  /// finish the job by hand, because the one thing needed to dial the node (its
  /// bootstrap entry) never left the server.
  ///
  /// The host-key pin and the node id are still one upsert derived from
  /// [widget.node] so the two updates cannot clobber each other.
  Future<void> _persistAfterRun({
    required String fingerprint,
    required String output,
  }) async {
    final report = parseProvisionReport(
      output,
      reachableHost: widget.node.sshHost,
    );
    var node = widget.node;
    var changed = false;
    if (fingerprint.isNotEmpty && node.sshHostFingerprint == null) {
      node = node.copyWith(sshHostFingerprint: fingerprint);
      changed = true;
    }
    if (report.nodeId != null) {
      node = node.copyWith(nodeId: report.nodeId);
      changed = true;
    }
    if (changed) {
      await ref.read(managedNodesProvider.notifier).upsert(node);
    }

    final done = <String>[];
    final l = mounted ? AppL10n.of(context) : null;
    if (report.nodeId != null && l != null) done.add(l.provisionSavedNodeId);

    // Add the node as a bootstrap peer. Failure here is reported, never
    // swallowed: a deployment that cannot be dialled is the whole defect this
    // step exists to close, and a silent catch would restore it.
    if (report.invite != null && l != null) {
      try {
        final invite = BootstrapInvite.parse(report.invite!);
        await ref.read(realStackProvider)?.addContact(invite);
        done.add(l.provisionAddedPeer);
      } catch (e) {
        done.add(l.provisionPeerFailed(shownCause(e, kind: 'provision')));
      }
    }

    // An oproxy exit is only useful once it is in the catalog the routing UI
    // reads. The catalog keys on node id, so a node that failed to report one
    // cannot be registered — say so rather than adding a blank entry.
    if (report.components.contains(NodeComponent.oproxyServer) && l != null) {
      final id = report.nodeId;
      if (id == null) {
        done.add(l.provisionProxyNeedsNodeId);
      } else {
        final routing = ref.read(proxyRoutingProvider);
        final already = routing.oProxies.any((e) => e.nodeId == id);
        if (!already) {
          await ref
              .read(proxyRoutingProvider.notifier)
              .set(
                routing.copyWith(
                  oProxies: [
                    ...routing.oProxies,
                    OproxyEndpoint(
                      nodeId: id,
                      label: node.label.isNotEmpty
                          ? node.label
                          : (node.sshHost ?? id.substring(0, 8)),
                    ),
                  ],
                ),
              );
        }
        done.add(l.provisionAddedProxy);
      }
    }

    if (done.isNotEmpty && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(done.join('\n'))));
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

  String _tlsModeLabel(AppL10n l, NodeTlsCertificateMode mode) =>
      switch (mode) {
        NodeTlsCertificateMode.existingFiles => l.provisionTlsModeExisting,
        NodeTlsCertificateMode.automatic => l.provisionTlsModeAutomatic,
        NodeTlsCertificateMode.selfSigned => l.provisionTlsModeSelfSigned,
      };

  bool get _hasGithubArtifacts =>
      _veilCliSource == _ArtifactSource.github ||
      _extraComponents.any(
        (component) => _componentSources[component] == _ArtifactSource.github,
      );

  Widget _artifactSourceSelector(AppL10n l, NodeComponent component) {
    final source = _sourceFor(component);
    return SegmentedButton<_ArtifactSource>(
      key: ValueKey('artifact-source-${component.binaryName}'),
      segments: [
        ButtonSegment(
          value: _ArtifactSource.github,
          icon: const Icon(Icons.cloud_download_outlined),
          label: Text(l.provisionSourceGithub),
        ),
        ButtonSegment(
          value: _ArtifactSource.custom,
          icon: const Icon(Icons.link),
          label: Text(l.provisionSourceCustom),
        ),
      ],
      selected: {source},
      onSelectionChanged: (selection) {
        final next = selection.first;
        if (next == source) return;
        setState(() {
          if (component == NodeComponent.veilCli) {
            _veilCliSource = next;
          } else {
            _componentSources[component] = next;
          }
        });
        unawaited(_loadGithubArtifacts());
      },
    );
  }

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
                unawaited(_loadGithubArtifacts());
              },
      ),
      const SizedBox(height: 12),
      _artifactSourceSelector(l, NodeComponent.veilCli),
      const SizedBox(height: 12),
      TextField(
        key: const ValueKey('veil-release-url'),
        controller: _releaseUrl,
        readOnly: _veilCliSource == _ArtifactSource.github,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          labelText: l.provisionReleaseUrl,
          helperText: _veilCliSource == _ArtifactSource.github
              ? l.provisionReleaseHint
              : l.provisionCustomReleaseHint,
          helperMaxLines: 3,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        key: const ValueKey('veil-release-sha'),
        controller: _sha256,
        readOnly: _veilCliSource == _ArtifactSource.github,
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
            onPressed: _hasGithubArtifacts
                ? () => unawaited(_loadGithubArtifacts(refresh: true))
                : null,
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
                onSelected: (selected) {
                  setState(() {
                    if (selected) {
                      _extraComponents.add(component);
                    } else {
                      _extraComponents.remove(component);
                    }
                  });
                  if (selected &&
                      _componentSources[component] == _ArtifactSource.github) {
                    unawaited(_loadGithubArtifacts());
                  }
                },
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
              _artifactSourceSelector(l, component),
              const SizedBox(height: 12),
              TextField(
                key: ValueKey('artifact-url-${component.binaryName}'),
                controller: _componentUrls[component],
                readOnly:
                    _componentSources[component] == _ArtifactSource.github,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: l.provisionComponentUrl(component.binaryName),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: ValueKey('artifact-sha-${component.binaryName}'),
                controller: _componentShas[component],
                readOnly:
                    _componentSources[component] == _ArtifactSource.github,
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
    final automaticName = _tlsAutomaticName.text.trim().isNotEmpty
        ? _tlsAutomaticName.text.trim()
        : _advertiseHost.text.trim();
    final automaticIsDomain = NodeProvisionConfig.isDnsName(automaticName);
    final automaticIsIp = NodeProvisionConfig.isIpAddress(automaticName);
    return _SettingsCard(
      title: l.provisionTransportCommon,
      subtitle: l.provisionTransportCommonHint,
      children: [
        TextField(
          key: const ValueKey('advertise-host'),
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
              DropdownButtonFormField<NodeTlsCertificateMode>(
                key: const ValueKey('tls-certificate-mode'),
                initialValue: _tlsCertificateMode,
                decoration: InputDecoration(
                  labelText: l.provisionTlsMode,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  for (final mode in NodeTlsCertificateMode.values)
                    DropdownMenuItem(
                      value: mode,
                      child: Text(_tlsModeLabel(l, mode)),
                    ),
                ],
                onChanged: (mode) {
                  if (mode != null) {
                    setState(() => _tlsCertificateMode = mode);
                  }
                },
              ),
              const SizedBox(height: 12),
              if (_tlsCertificateMode ==
                  NodeTlsCertificateMode.existingFiles) ...[
                TextField(
                  key: const ValueKey('tls-existing-cert'),
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
                  key: const ValueKey('tls-existing-key'),
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
                  key: const ValueKey('tls-existing-ca'),
                  controller: _tlsCa,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: l.provisionTlsCa,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ] else if (_tlsCertificateMode ==
                  NodeTlsCertificateMode.automatic) ...[
                TextField(
                  key: const ValueKey('tls-automatic-name'),
                  controller: _tlsAutomaticName,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: l.provisionTlsAutomaticName,
                    helperText: l.provisionTlsAutomaticNameHint,
                    helperMaxLines: 3,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  automaticIsDomain
                      ? l.provisionTlsLetsEncryptHint
                      : automaticIsIp
                      ? l.provisionTlsIpHint
                      : l.provisionTlsUnknownHint,
                  key: const ValueKey('tls-automatic-result'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                if (automaticIsDomain) ...[
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey('tls-email'),
                    controller: _tlsEmail,
                    keyboardType: TextInputType.emailAddress,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: l.provisionTlsEmail,
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  CheckboxListTile(
                    key: const ValueKey('tls-agree-terms'),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(l.provisionTlsAgreeTerms),
                    value: _tlsAgreeToTerms,
                    onChanged: (value) =>
                        setState(() => _tlsAgreeToTerms = value ?? false),
                  ),
                ] else if (automaticIsIp) ...[
                  const SizedBox(height: 12),
                  _selfSignedDaysField(l),
                ],
              ] else ...[
                TextField(
                  key: const ValueKey('tls-self-signed-name'),
                  controller: _selfSignedName,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: l.provisionTlsSelfSignedName,
                    helperText: l.provisionTlsSelfSignedNameHint,
                    helperMaxLines: 2,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                _selfSignedDaysField(l),
                const SizedBox(height: 8),
                Text(
                  l.provisionTlsSelfSignedHint,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }

  Widget _selfSignedDaysField(AppL10n l) => TextField(
    key: const ValueKey('tls-self-signed-days'),
    controller: _selfSignedDays,
    keyboardType: TextInputType.number,
    onChanged: (_) => setState(() {}),
    decoration: InputDecoration(
      labelText: l.provisionTlsSelfSignedDays,
      border: const OutlineInputBorder(),
      isDense: true,
    ),
  );

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
        // The bottom inset rather than a flat 16: the deploy button is the last
        // control on the list, and on a phone with gesture navigation a
        // constant leaves it under the system bar, half-visible and awkward to
        // hit exactly when the operator is waiting to press it.
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          16 + MediaQuery.viewPaddingOf(context).bottom,
        ),
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
