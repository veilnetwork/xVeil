import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ssh_host_confirm.dart';

import '../../data/node/managed_node.dart';
import '../../data/node/ssh_client.dart';
import '../../data/node/ssh_credentials.dart';
import '../../l10n/app_localizations.dart';
import '../../state/managed_nodes_controller.dart';
import '../../state/ssh_credentials.dart';
import 'ssh_private_key_field.dart';
import 'ssh_public_key_card.dart';

/// Generic SSH operation runner. It can use the node's encrypted saved
/// credential; any manually entered override lives only in this dialog.
class SshCommandDialog extends ConsumerStatefulWidget {
  const SshCommandDialog({
    super.key,
    required this.node,
    required this.title,
    required this.command,
    this.timeout = const Duration(minutes: 2),
    this.showCommandPreview = false,
    this.onSuccess,
  });

  final ManagedNode node;
  final String title;
  final String command;
  final Duration timeout;
  final bool showCommandPreview;
  final Future<void> Function(SshResult result)? onSuccess;

  @override
  ConsumerState<SshCommandDialog> createState() => _SshCommandDialogState();
}

class _SshCommandDialogState extends ConsumerState<SshCommandDialog> {
  final _password = TextEditingController();
  final _key = TextEditingController();
  final _passphrase = TextEditingController();
  bool _useKey = false;
  bool _busy = false;
  bool _credentialsLoaded = false;
  SavedSshCredentials _credentials = const SavedSshCredentials();
  String? _output;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_loadCredentials());
  }

  Future<void> _loadCredentials() async {
    final credentials = await ref
        .read(sshCredentialsRepositoryProvider)
        .load(widget.node.id);
    if (!mounted) return;
    _password.text = credentials.password ?? '';
    setState(() {
      _credentials = credentials;
      _useKey = !credentials.hasPassword && credentials.hasKey;
      _credentialsLoaded = true;
    });
  }

  @override
  void dispose() {
    _password.dispose();
    _key.dispose();
    _passphrase.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final node = widget.node;
    if (!node.hasSsh || node.sshUser == null || !_credentialsLoaded) return;
    final l = AppL10n.of(context);
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
      // Identity before credentials: on first contact this learns the host key
      // on a connection that offers nothing, and asks the user to compare it.
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
        return;
      }
      final result = await sshRun(
        host: node.sshHost!,
        port: node.sshPort,
        user: node.sshUser!,
        auth: auth,
        command: widget.command,
        expectedHostFingerprint: pin,
        timeout: widget.timeout,
      );
      if (result.hostFingerprint.isNotEmpty &&
          node.sshHostFingerprint == null) {
        await ref
            .read(managedNodesProvider.notifier)
            .upsert(node.copyWith(sshHostFingerprint: result.hostFingerprint));
      }
      if (result.ok) await widget.onSuccess?.call(result);
      if (!mounted) return;
      final combined = [
        if (result.stdout.isNotEmpty) result.stdout.trimRight(),
        if (result.stderr.isNotEmpty) result.stderr.trimRight(),
        // The one line in this blob that says whether the command WORKED, and
        // it was the one line left in English. The string for it already
        // existed; nothing used it.
        l.sshDone('${result.exitCode}'),
        if (result.hostFingerprint.isNotEmpty)
          'host key: ${result.hostFingerprint}',
      ].join('\n');
      setState(() => _output = combined);
    } on SshException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 680,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${widget.node.sshUser}@${widget.node.sshHost}:${widget.node.sshPort}',
                style: const TextStyle(fontFamily: 'monospace'),
              ),
              const SizedBox(height: 12),
              if (!_credentialsLoaded) ...[
                const LinearProgressIndicator(),
                const SizedBox(height: 12),
              ],
              SegmentedButton<bool>(
                segments: [
                  ButtonSegment(value: false, label: Text(l.sshUsePassword)),
                  ButtonSegment(value: true, label: Text(l.sshUseKey)),
                ],
                selected: {_useKey},
                onSelectionChanged: _busy || !_credentialsLoaded
                    ? null
                    : (selection) => setState(() => _useKey = selection.first),
              ),
              const SizedBox(height: 12),
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
                SshPrivateKeyField(
                  controller: _key,
                  maxLines: 5,
                  labelText: _credentials.hasKey
                      ? l.sshOtherKeyLabel
                      : l.sshKeyLabel,
                  helperText: _credentials.hasKey ? l.sshUseSavedKeyHint : null,
                  helperMaxLines: 2,
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
              const SizedBox(height: 6),
              Text(
                l.sshCredsNotSaved,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.outline),
              ),
              if (widget.showCommandPreview) ...[
                const SizedBox(height: 12),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text(l.provisionScriptLabel),
                  children: [
                    SelectableText(
                      widget.command,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10.5,
                      ),
                    ),
                  ],
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  l.sshError(_error!),
                  style: TextStyle(color: scheme.error),
                ),
              ],
              if (_output != null) ...[
                const SizedBox(height: 12),
                Text(l.nodeOperationOutput),
                const SizedBox(height: 6),
                SelectableText(
                  _output!,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(l.actionDone),
        ),
        FilledButton.icon(
          onPressed: _busy || !_credentialsLoaded ? null : _run,
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.terminal),
          label: Text(_busy ? l.sshConnecting : l.nodeOperationRun),
        ),
      ],
    );
  }
}
