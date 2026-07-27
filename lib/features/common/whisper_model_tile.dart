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
      );
    }
    if (model.isReady) {
      return ListTile(
        leading: const Icon(Icons.graphic_eq),
        title: Text(l.voiceModelInstalled),
        subtitle: Text(l.voiceModelRemoveHint),
        trailing: TextButton(
          onPressed: notifier.remove,
          child: Text(l.voiceModelRemove),
        ),
      );
    }
    final failed = model.phase == WhisperModelPhase.failed;
    return ListTile(
      leading: const Icon(Icons.graphic_eq_outlined),
      title: Text(failed ? l.voiceModelFailed : l.voiceModelDownload),
      subtitle: Text(l.voiceModelSize),
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
