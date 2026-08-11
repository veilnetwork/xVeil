import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../state/model_exchange_service.dart';

/// Whether this device answers a contact asking which models it has.
///
/// Its own tile rather than a line inside the translation one, because it
/// governs both kinds — language pairs and the speech model — and a switch
/// that lives under one of two things it controls is a switch people
/// misunderstand.
///
/// The subtitle changes with the position, and says the part that is easy to
/// miss: turning it off is silence, and silence is indistinguishable from
/// having no models. That is deliberate — if a contact could tell the two
/// apart, the setting itself would be the disclosure it exists to prevent.
class ModelSharingTile extends ConsumerWidget {
  const ModelSharingTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final setting = ref.watch(answerModelInventoryProvider);

    return setting.when(
      // Nothing rather than a guessed position. Showing the switch one way and
      // then flipping it under someone's hand is worse than a moment of
      // blankness, and worse still when it describes what this device tells
      // other people.
      loading: () => ListTile(
        leading: const Icon(Icons.inventory_2_outlined),
        title: Text(l.modelSharingTitle),
        trailing: const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      error: (_, _) => ListTile(
        leading: const Icon(Icons.inventory_2_outlined),
        title: Text(l.modelSharingTitle),
        subtitle: Text(l.modelSharingOff),
      ),
      data: (enabled) => SwitchListTile(
        secondary: const Icon(Icons.inventory_2_outlined),
        title: Text(l.modelSharingTitle),
        subtitle: Text(enabled ? l.modelSharingOn : l.modelSharingOff),
        value: enabled,
        onChanged: (value) =>
            ref.read(answerModelInventoryProvider.notifier).set(value),
      ),
    );
  }
}
