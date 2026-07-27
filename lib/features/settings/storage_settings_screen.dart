import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../state/transcription_controller.dart';
import '../../state/whisper_model_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../routing/back_affordance.dart';
import '../../state/app_controller.dart';

String fmtBytes(int b) {
  if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(1)} GB';
  if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
  if (b >= 1 << 10) return '${(b / (1 << 10)).toStringAsFixed(0)} KB';
  return '$b B';
}

/// Settings → Data & storage: the encrypted container (size, compaction,
/// padding) and file auto-download rules. Was a bottom sheet — a full page
/// since the category split.
class StorageSettingsScreen extends ConsumerStatefulWidget {
  const StorageSettingsScreen({super.key});

  @override
  ConsumerState<StorageSettingsScreen> createState() =>
      _StorageSettingsScreenState();
}

class _StorageSettingsScreenState extends ConsumerState<StorageSettingsScreen> {
  int? _size;
  bool _autoCompact = false;
  bool _leanPadding = true;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ctrl = ref.read(appControllerProvider.notifier);
    final size = await ctrl.containerSizeBytes();
    final autoCompact = await ctrl.autoCompactEnabled();
    final leanPadding = await ctrl.leanStoragePaddingEnabled();
    if (!mounted) return;
    setState(() {
      _size = size;
      _autoCompact = autoCompact;
      _leanPadding = leanPadding;
      _loaded = true;
    });
  }

  Future<void> _compact(AppL10n l) async {
    final pw = await showDialog<String>(
      context: context,
      builder: (d) => CompactPasswordDialog(
        title: l.settingsStorageCompact,
        hint: l.settingsStoragePasswordHint,
        confirmLabel: l.settingsStorageCompact,
        cancelLabel: l.actionCancel,
      ),
    );
    if (pw == null || pw.isEmpty) return;
    if (!mounted) return;
    // Capture the ROOT messenger BEFORE the await — compactStorage tears the
    // session down and re-opens (navigating away), so this context may be
    // unmounted by the time the result is ready.
    final messenger = ScaffoldMessenger.of(context);
    try {
      final r = await ref
          .read(appControllerProvider.notifier)
          .compactStorage(pw);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '${l.settingsStorageCompactDone}: ${fmtBytes(r.before)} → ${fmtBytes(r.after)}',
          ),
        ),
      );
    } catch (_) {
      messenger.showSnackBar(
        SnackBar(content: Text(l.settingsStorageCompactFailed)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final ctrl = ref.read(appControllerProvider.notifier);
    return Scaffold(
      appBar: AppBar(
        leading: const RootedBackButton(),
        title: Text(l.settingsCatData),
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                ListTile(
                  leading: const Icon(Icons.sd_storage_outlined),
                  title: Text(l.settingsStorage),
                  subtitle: Text(_size == null ? '—' : fmtBytes(_size!)),
                ),
                if (ctrl.canCompactStorage)
                  ListTile(
                    leading: const Icon(Icons.compress),
                    title: Text(l.settingsStorageCompact),
                    subtitle: Text(l.settingsStorageCompactBody),
                    onTap: () => _compact(l),
                  ),
                if (ctrl.canCompactStorage)
                  // Opt-in ONLY: auto-compaction keeps just the unlocked
                  // space, so flipping this is the user's attestation that no
                  // other hidden identity lives in this container (same
                  // contract as the manual compact above).
                  SwitchListTile(
                    secondary: const Icon(Icons.compress_outlined),
                    title: Text(l.settingsStorageAutoCompact),
                    subtitle: Text(l.settingsStorageAutoCompactBody),
                    isThreeLine: true,
                    value: _autoCompact,
                    onChanged: (v) {
                      setState(() => _autoCompact = v);
                      ctrl.setAutoCompactEnabled(v);
                    },
                  ),
                SwitchListTile(
                  secondary: const Icon(Icons.speed_outlined),
                  title: Text(l.settingsStorageLeanPadding),
                  subtitle: Text(l.settingsStorageLeanPaddingBody),
                  isThreeLine: true,
                  value: _leanPadding,
                  onChanged: (v) {
                    setState(() => _leanPadding = v);
                    ctrl.setLeanStoragePaddingEnabled(v);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.download_outlined),
                  title: Text(l.settingsFiles),
                  subtitle: Text(l.settingsFilesHint),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/file-settings'),
                ),
                const _WhisperModelTile(),
              ],
            ),
    );
  }
}

/// Password-entry dialog for storage compaction. A `StatefulWidget` so its
/// [TextEditingController] is owned by the element and disposed in
/// [State.dispose] — which runs only once the dialog route is fully removed
/// (after the close transition). This avoids the "TextEditingController used
/// after being disposed" / `_dependents.isEmpty` red screen that an
/// inline-disposed controller hits when the caller (compaction) tears the
/// widget tree down while the dialog is still animating out.
class CompactPasswordDialog extends StatefulWidget {
  const CompactPasswordDialog({
    super.key,
    required this.title,
    required this.hint,
    required this.confirmLabel,
    required this.cancelLabel,
  });

  final String title;
  final String hint;
  final String confirmLabel;
  final String cancelLabel;

  @override
  State<CompactPasswordDialog> createState() => _CompactPasswordDialogState();
}

class _CompactPasswordDialogState extends State<CompactPasswordDialog> {
  final _ctl = TextEditingController();

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _ctl,
        obscureText: true,
        autofocus: true,
        decoration: InputDecoration(labelText: widget.hint),
        onSubmitted: (v) => Navigator.of(context).pop(v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(widget.cancelLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_ctl.text),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

/// The speech model: fetch it, see that it is here, give the space back.
///
/// It is not in the build — 57 MiB for a feature most people never touch —
/// and it is stored once for the whole app rather than per profile, so this
/// tile speaks for every profile at once.
class _WhisperModelTile extends ConsumerWidget {
  const _WhisperModelTile();

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
