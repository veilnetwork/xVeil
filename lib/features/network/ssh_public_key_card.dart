import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';

class SshPublicKeyCard extends StatelessWidget {
  const SshPublicKeyCard({super.key, required this.publicKey, this.onRemove});

  final String publicKey;
  final VoidCallback? onRemove;

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: publicKey));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppL10n.of(context).sshPublicKeyCopied)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.key, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l.sshSavedEd25519Title,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  tooltip: l.sshCopyPublicKey,
                  onPressed: () => _copy(context),
                  icon: const Icon(Icons.copy_outlined),
                ),
                if (onRemove != null)
                  IconButton(
                    tooltip: l.sshRemoveSavedKey,
                    onPressed: onRemove,
                    icon: const Icon(Icons.delete_outline),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              l.sshPublicKeyLabel,
              style: Theme.of(context).textTheme.labelSmall,
            ),
            const SizedBox(height: 4),
            SelectableText(
              publicKey,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}
