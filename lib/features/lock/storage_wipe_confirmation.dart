import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

/// Captures the selected deletion scope before showing an irreversible action.
Future<bool?> showStorageWipeConfirmation(
  BuildContext context, {
  required bool wholeProfile,
}) => showDialog<bool>(
  context: context,
  builder: (_) => _WipeConfirmDialog(wholeProfile: wholeProfile),
);

/// Irreversible-wipe confirmation gated behind typing an exact phrase, so an
/// accidental double-tap can't destroy stored identities. Owns its own controller
/// (disposed correctly) — pops `true` only once the phrase matches.
class _WipeConfirmDialog extends StatefulWidget {
  const _WipeConfirmDialog({required this.wholeProfile});

  final bool wholeProfile;

  @override
  State<_WipeConfirmDialog> createState() => _WipeConfirmDialogState();
}

class _WipeConfirmDialogState extends State<_WipeConfirmDialog> {
  final _typed = TextEditingController();

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final phrase = l.lockWipePhrase;
    final matches = _typed.text.trim().toLowerCase() == phrase.toLowerCase();
    return AlertDialog(
      icon: Icon(Icons.warning_amber_rounded, color: scheme.error),
      title: Text(l.lockWipe),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.wholeProfile ? l.profileWipeBody : l.lockWipeBody),
            const SizedBox(height: 16),
            Text(
              l.lockWipeTypePrompt,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Text(
              '"$phrase"',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: scheme.error,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _typed,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l.actionCancel),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: scheme.error,
            foregroundColor: scheme.onError,
          ),
          // Disabled until the phrase is typed exactly.
          onPressed: matches ? () => Navigator.of(context).pop(true) : null,
          child: Text(l.lockWipeConfirm),
        ),
      ],
    );
  }
}
