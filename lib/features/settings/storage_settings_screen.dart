import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../common/whisper_model_tile.dart';
import '../../domain/storage_compaction_policy.dart';
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

  /// The maintenance readout, or null when there is nothing honest to report
  /// (no real container, several identities, a backing that cannot measure).
  /// Null renders the size ALONE — never "0 B reclaimable".
  StorageReclaim? _reclaim;
  bool _autoCompact = false;
  bool _leanPadding = true;
  bool _loaded = false;

  /// The two knobs behind the compaction offer. Defaults until [_load] answers,
  /// which is also what a container that will not open should show.
  CompactionOfferSettings _offer = const CompactionOfferSettings();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ctrl = ref.read(appControllerProvider.notifier);
    final size = await ctrl.containerSizeBytes();
    final reclaim = await ctrl.storageReclaim();
    final autoCompact = await ctrl.autoCompactEnabled();
    final leanPadding = await ctrl.leanStoragePaddingEnabled();
    final offer = await ctrl.compactionOfferSettings();
    if (!mounted) return;
    setState(() {
      _size = size;
      _reclaim = reclaim;
      _autoCompact = autoCompact;
      _leanPadding = leanPadding;
      _offer = offer;
      _loaded = true;
    });
  }

  Future<void> _saveOffer(CompactionOfferSettings next) async {
    setState(() => _offer = next);
    await ref
        .read(appControllerProvider.notifier)
        .setCompactionOfferSettings(next);
  }

  /// Days between offers. The choices are the ones a person actually means —
  /// "not more than weekly", not an arbitrary number typed into a box.
  Future<void> _pickPeriod(AppL10n l) async {
    const options = [1, 3, 7, 14, 30];
    final chosen = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(l.settingsCompactOfferPeriod),
        children: [
          for (final days in options)
            ListTile(
              title: Text(l.settingsCompactOfferDays(days)),
              trailing: _offer.period.inDays == days
                  ? const Icon(Icons.check)
                  : null,
              onTap: () => Navigator.of(ctx).pop(days),
            ),
        ],
      ),
    );
    if (chosen == null) return;
    await _saveOffer(_offer.copyWith(period: Duration(days: chosen)));
  }

  Future<void> _pickThreshold(AppL10n l) async {
    const options = [
      256 << 20,
      512 << 20,
      1 << 30,
      2 << 30,
      5 << 30,
      10 << 30,
    ];
    final chosen = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(l.settingsCompactOfferThreshold),
        children: [
          for (final bytes in options)
            ListTile(
              title: Text(fmtBytes(bytes)),
              trailing: _offer.thresholdBytes == bytes
                  ? const Icon(Icons.check)
                  : null,
              onTap: () => Navigator.of(ctx).pop(bytes),
            ),
        ],
      ),
    );
    if (chosen == null) return;
    await _saveOffer(_offer.copyWith(thresholdBytes: chosen));
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
    // Re-read: the size and the dead share both just changed, and the nudge
    // has to disappear on its own once it has been acted on.
    if (mounted) await _load();
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
                // The decision is made ONCE, in AppController; the screen only
                // renders it. Re-deriving "is the file bloated?" from
                // thresholds here is how the two would drift apart.
                if (_reclaim?.worthCompacting ?? false)
                  _BloatNudge(
                    reclaimableBytes: _reclaim!.reclaimableBytes,
                    onCompact: () => _compact(l),
                  ),
                ListTile(
                  leading: const Icon(Icons.sd_storage_outlined),
                  title: Text(l.settingsStorage),
                  subtitle: Text(
                    _size == null
                        ? '—'
                        // No reclaim figure ⇒ show the size alone. "0 B
                        // reclaimable" would be a claim we cannot make.
                        : _reclaim == null
                        ? fmtBytes(_size!)
                        : '${fmtBytes(_size!)} · '
                              '${l.settingsStorageReclaimable(fmtBytes(_reclaim!.reclaimableBytes))}',
                  ),
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
                  secondary: const Icon(Icons.notifications_active_outlined),
                  title: Text(l.settingsCompactOffer),
                  subtitle: Text(l.settingsCompactOfferHint),
                  isThreeLine: true,
                  value: _offer.enabled,
                  onChanged: (v) => _saveOffer(_offer.copyWith(enabled: v)),
                ),
                if (_offer.enabled) ...[
                  ListTile(
                    leading: const Icon(Icons.schedule_outlined),
                    title: Text(l.settingsCompactOfferPeriod),
                    trailing: Text(l.settingsCompactOfferDays(_offer.period.inDays)),
                    onTap: () => _pickPeriod(l),
                  ),
                  ListTile(
                    leading: const Icon(Icons.data_usage_outlined),
                    title: Text(l.settingsCompactOfferThreshold),
                    trailing: Text(fmtBytes(_offer.thresholdBytes)),
                    onTap: () => _pickThreshold(l),
                  ),
                ],
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
                const WhisperModelTile(),
              ],
            ),
    );
  }
}

/// The unprompted "your container is mostly padding" remark.
///
/// Inline and dismissible by acting on it, NOT a dialog: the container is fine,
/// the data is intact, and this is a note about disk space. It is styled from
/// the theme's *secondary* container rather than its error colours for the same
/// reason — an alarm here would be a lie about what is happening.
///
/// Tapping it opens the ordinary compaction flow, password prompt and all. It
/// never compacts by itself: that tears the session down and needs the
/// password, so it stays something the user asks for.
class _BloatNudge extends StatelessWidget {
  const _BloatNudge({required this.reclaimableBytes, required this.onCompact});

  final int reclaimableBytes;
  final VoidCallback onCompact;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      color: scheme.secondaryContainer,
      elevation: 0,
      child: ListTile(
        leading: Icon(Icons.compress, color: scheme.onSecondaryContainer),
        title: Text(
          l.settingsStorageBloatTitle(fmtBytes(reclaimableBytes)),
          style: TextStyle(color: scheme.onSecondaryContainer),
        ),
        subtitle: Text(
          l.settingsStorageBloatBody,
          style: TextStyle(color: scheme.onSecondaryContainer),
        ),
        isThreeLine: true,
        onTap: onCompact,
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
