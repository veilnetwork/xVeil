import 'package:flutter/material.dart';
import '../../domain/storage_protection.dart';
import '../../l10n/app_localizations.dart';
import '../common/help_label.dart';

class StorageProtectionChoice extends StatelessWidget {
  const StorageProtectionChoice({
    super.key,
    required this.selected,
    required this.onChanged,
    required this.onNext,
  });
  final StorageProtection selected;
  final ValueChanged<StorageProtection> onChanged;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l.storageTitle, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 16),
        for (final (mode, title, brief, help, icon) in [
          (
            StorageProtection.encrypted,
            l.storageEncryptedTitle,
            l.storageEncryptedBrief,
            l.storageEncryptedBody,
            Icons.lock_outline,
          ),
          (
            StorageProtection.hidden,
            l.storageHiddenTitle,
            l.storageHiddenBrief,
            l.storageHiddenBody,
            Icons.visibility_off_outlined,
          ),
          (
            StorageProtection.unencrypted,
            l.storageUnencryptedTitle,
            l.storageUnencryptedBrief,
            l.storageUnencryptedWarning,
            Icons.folder_open_outlined,
          ),
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Card(
              key: ValueKey('storage-protection-${mode.name}'),
              color: mode == selected
                  ? Theme.of(context).colorScheme.primaryContainer
                  : null,
              child: ListTile(
                leading: Icon(icon),
                title: HelpLabel(title: title, help: help),
                subtitle: Text(brief),
                trailing: mode == selected
                    ? const Icon(Icons.check_circle)
                    : null,
                onTap: () => onChanged(mode),
              ),
            ),
          ),
        if (selected == StorageProtection.unencrypted)
          Text(
            l.storageUnencryptedWarning,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        const Spacer(),
        FilledButton(onPressed: onNext, child: Text(l.actionContinue)),
      ],
    );
  }
}
