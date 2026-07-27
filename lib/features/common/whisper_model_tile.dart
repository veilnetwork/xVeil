import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../state/transcription_controller.dart';
import '../../state/whisper_model_controller.dart';

/// The speech model: fetch it, see that it is here, give the space back.
///
/// It is not in the build — 57 MiB for a feature most people never touch —
/// and it is stored once for the whole app rather than per profile, so this
/// tile speaks for every profile at once.
class WhisperModelTile extends ConsumerWidget {
  const WhisperModelTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final model = ref.watch(whisperModelControllerProvider);
    final notifier = ref.read(whisperModelControllerProvider.notifier);

    if (model.isBusy) {
      return ListTile(
        leading: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            value: model.progress,
          ),
        ),
        title: Text(l.voiceModelDownloading),
        subtitle: model.progress == null
            ? null
            : Text('${(model.progress! * 100).round()}%'),
        // 57 MB on mobile data is a thing to be able to stop. What is already
        // fetched is kept, so this is a pause and the offer will say so.
        trailing: TextButton(
          onPressed: notifier.cancel,
          child: Text(l.voiceModelCancel),
        ),
      );
    }
    if (model.isReady) {
      return ListTile(
        leading: const Icon(Icons.graphic_eq),
        title: Text(l.voiceModelInstalled),
        subtitle: Text(l.voiceModelRemoveHint),
        // An icon, not a text button. ListTile gives the trailing widget the
        // width it asks for and the title takes what is left, so a Russian
        // action label crushed "Модель распознавания установлена" into a
        // one-word-per-line column on a real phone. Shortening the label was
        // not enough — measured 120px of title on a 360px-wide screen — so
        // the action is an icon and the words live in its tooltip.
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: l.voiceModelRemove,
          onPressed: notifier.remove,
        ),
      );
    }
    final failed = model.phase == WhisperModelPhase.failed;
    // An interrupted attempt is resumed, not restarted — say so, because
    // "download 57 MB" and "continue, 80% is already here" are different
    // decisions on mobile data.
    final resume = model.resumeFraction;
    return ListTile(
      leading: const Icon(Icons.graphic_eq_outlined),
      title: Text(
        failed
            ? l.voiceModelFailed
            : (resume != null ? l.voiceModelResume : l.voiceModelDownload),
      ),
      subtitle: Text(
        resume != null
            ? l.voiceModelResumeAt((resume * 100).round())
            : l.voiceModelSize,
      ),
      trailing: const Icon(Icons.download_outlined),
      onTap: () async {
        final ok = await notifier.download();
        if (ok) {
          ref.invalidate(transcriptionAvailableProvider);
          ref.invalidate(transcriptionNativeReadyProvider);
        }
      },
    );
  }
}
