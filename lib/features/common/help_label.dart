import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

/// Keeps the control's label visible; the explanation opens on an explicit tap.
class HelpLabel extends StatelessWidget {
  const HelpLabel({super.key, required this.title, required this.help});

  final String title;
  final String help;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(child: Text(title)),
      IconButton(
        tooltip: '${AppL10n.of(context).navHelp}: $title',
        icon: const Icon(Icons.help_outline),
        onPressed: () => showDialog<void>(
          context: context,
          builder: (dialog) => AlertDialog(
            title: Text(title),
            content: SingleChildScrollView(child: Text(help)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog),
                child: Text(MaterialLocalizations.of(dialog).closeButtonLabel),
              ),
            ],
          ),
        ),
      ),
    ],
  );
}
