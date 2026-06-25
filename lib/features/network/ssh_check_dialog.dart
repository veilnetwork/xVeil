import 'package:flutter/material.dart';

import '../../data/node/ssh_client.dart';
import '../../l10n/app_localizations.dart';

/// A one-shot SSH connect-and-check dialog for a managed node. Prompts for auth
/// (password or PEM key), connects to host:port as user, runs a read-only status
/// command, and shows the output. Credentials are held only for the call and
/// never persisted.
class SshCheckDialog extends StatefulWidget {
  const SshCheckDialog({
    super.key,
    required this.host,
    required this.port,
    required this.user,
    this.expectedHostFingerprint,
    this.onHostKeyObserved,
  });

  final String host;
  final int port;
  final String user;

  /// Pinned `SHA256:…` host key, if this node already has one. When set the
  /// check refuses a server presenting a different key (possible MITM — which
  /// would otherwise capture the SSH password typed here). When null it is a
  /// first-contact check: the observed key is shown so the user can verify it.
  final String? expectedHostFingerprint;

  /// Fires once with the server's observed `SHA256:…` fingerprint after a
  /// successful connect, so the caller can pin it trust-on-first-use (the check
  /// dialog is the natural first-contact action — without this only the
  /// provision path ever established a pin).
  final void Function(String fingerprint)? onHostKeyObserved;

  @override
  State<SshCheckDialog> createState() => _SshCheckDialogState();
}

class _SshCheckDialogState extends State<SshCheckDialog> {
  // Read-only diagnostic: identify the host + whether a veil service runs. No
  // state change on the server.
  static const _statusCmd =
      r'echo "host: $(hostname 2>/dev/null)"; '
      r'echo "veil: $(systemctl is-active veil 2>/dev/null || echo none)"; '
      r'echo "veil-cli: $(command -v veil-cli || echo absent)"';

  bool _useKey = false;
  final _password = TextEditingController();
  final _key = TextEditingController();
  final _passphrase = TextEditingController();
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
    setState(() {
      _busy = true;
      _output = null;
      _error = null;
    });
    final auth = _useKey
        ? SshAuth.key(_key.text,
            passphrase:
                _passphrase.text.isEmpty ? null : _passphrase.text)
        : SshAuth.password(_password.text);
    try {
      final r = await sshRun(
        host: widget.host,
        port: widget.port,
        user: widget.user,
        auth: auth,
        command: _statusCmd,
        expectedHostFingerprint: widget.expectedHostFingerprint,
      );
      // Pin trust-on-first-use: surface the observed key to the caller so a
      // check (not just a provision) establishes the pin for later connects.
      if (r.hostFingerprint.isNotEmpty) {
        widget.onHostKeyObserved?.call(r.hostFingerprint);
      }
      if (mounted) {
        setState(() {
          _output = '${r.stdout}${r.stderr.isNotEmpty ? '\n${r.stderr}' : ''}'
              '\n(exit ${r.exitCode})'
              '${r.hostFingerprint.isNotEmpty ? '\nhost key: ${r.hostFingerprint}' : ''}';
        });
      }
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
      title: Text(l.sshDialogTitle('${widget.user}@${widget.host}')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<bool>(
              segments: [
                ButtonSegment(value: false, label: Text(l.sshUsePassword)),
                ButtonSegment(value: true, label: Text(l.sshUseKey)),
              ],
              selected: {_useKey},
              onSelectionChanged: (s) => setState(() => _useKey = s.first),
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
            const SizedBox(height: 6),
            Text(l.sshCredsNotSaved,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.outline)),
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
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 12)),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(l.sshError(_error!),
                  style: TextStyle(color: scheme.error)),
            ],
          ],
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
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.terminal),
          label: Text(_busy ? l.sshConnecting : l.sshConnectRun),
        ),
      ],
    );
  }
}
