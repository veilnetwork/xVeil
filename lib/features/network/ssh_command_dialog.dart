import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/node/managed_node.dart';
import '../../data/node/ssh_client.dart';
import '../../l10n/app_localizations.dart';
import '../../state/managed_nodes_controller.dart';

/// Generic one-shot SSH operation runner. Authentication material lives only in
/// this dialog's controllers and is disposed immediately when it closes.
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
  String? _output;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _key.dispose();
    _passphrase.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final node = widget.node;
    if (!node.hasSsh || node.sshUser == null) return;
    setState(() {
      _busy = true;
      _output = null;
      _error = null;
    });
    final auth = _useKey
        ? SshAuth.key(
            _key.text,
            passphrase: _passphrase.text.isEmpty ? null : _passphrase.text,
          )
        : SshAuth.password(_password.text);
    try {
      final result = await sshRun(
        host: node.sshHost!,
        port: node.sshPort,
        user: node.sshUser!,
        auth: auth,
        command: widget.command,
        expectedHostFingerprint: node.sshHostFingerprint,
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
        'exit ${result.exitCode}',
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
                TextField(
                  controller: _key,
                  minLines: 2,
                  maxLines: 5,
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
          onPressed: _busy ? null : _run,
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
