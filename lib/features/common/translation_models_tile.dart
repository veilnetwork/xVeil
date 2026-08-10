import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/translation_model_store.dart';
import '../../l10n/app_localizations.dart';
import '../../state/translation_model_controller.dart';

/// Translation languages: what is installed, install another, give the space
/// back.
///
/// One direction per entry, because ru→en and en→ru are different models and a
/// person who installed one will otherwise wonder why the other way round does
/// nothing.
class TranslationModelsTile extends ConsumerWidget {
  const TranslationModelsTile({super.key});

  static String _label(TranslationPair pair) => '${pair.from} → ${pair.to}';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final theme = Theme.of(context);
    final state = ref.watch(translationModelsControllerProvider);
    final notifier = ref.read(translationModelsControllerProvider.notifier);

    if (state.isImporting) {
      return ListTile(
        leading: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            value: state.progress,
          ),
        ),
        title: Text(l.translationModelsImporting),
        subtitle: state.progress == null
            ? null
            : Text('${(state.progress! * 100).round()}%'),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          leading: const Icon(Icons.translate),
          title: Text(l.translationModels),
          subtitle: Text(
            state.hasAny
                ? state.installed.map(_label).join(', ')
                : l.translationModelsNone,
          ),
        ),
        for (final pair in state.installed)
          ListTile(
            dense: true,
            leading: const SizedBox(width: 24),
            title: Text(_label(pair)),
            // An icon rather than a labelled button: ListTile gives the
            // trailing widget the width it asks for, and a Russian action
            // label crushed the title into a column on a real phone — the
            // same lesson the speech model tile paid for.
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: l.translationModelsRemove,
              onPressed: () => notifier.remove(pair),
            ),
          ),
        ListTile(
          leading: const Icon(Icons.folder_open),
          title: Text(l.translationModelsImport),
          subtitle: Text(l.translationModelsHint),
          onTap: () async {
            final path = await ref.read(translationBundlePickerProvider)();
            if (path == null) return; // Dismissed the picker; not a failure.
            await notifier.importBundle(path);
          },
        ),
        if (state.phase == TranslationImportPhase.failed)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              // The reason as well as the verdict. "Could not install" alone
              // leaves nobody able to tell a truncated transfer from a file
              // that was never a bundle.
              state.error == null
                  ? l.translationModelsFailed
                  : '${l.translationModelsFailed}: ${state.error}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
      ],
    );
  }
}
