import 'package:flutter/material.dart';

import '../../core/ids.dart';
import '../../domain/space_retention.dart';
import '../../l10n/app_localizations.dart';
import '../../state/group_service.dart';
import '../chat/chat_actions.dart' show formatDisappearingWindow;

/// The current window as the picker's radio state, or null when nothing is
/// deleted. Only a bounded Space-wide rule counts: a channel override belongs
/// to a community's settings, and a group has no channels anyway.
Duration? groupDisappearingWindow(SpaceRetentionPolicy? policy) =>
    policy != null &&
        policy.mode == SpaceRetentionMode.deleteAfter &&
        policy.channelId == null &&
        !policy.mediaOnly
    ? Duration(milliseconds: policy.retentionMs!)
    : null;

/// Choose the group's disappearing window.
///
/// Unlike the one-to-one picker this writes a SIGNED control revision, so the
/// choice is a fact about the group rather than an announcement to one peer:
/// every member folds the same row and reaches the same answer. What the
/// subtitle has to be honest about is the one case it cannot cover — a member
/// on a build whose floor is still a day rejects a minute-long revision as
/// structurally invalid and keeps its copies.
Future<void> pickGroupDisappearing(
  BuildContext context,
  GroupService service,
  NodeId groupId,
  Duration? current,
) async {
  final l = AppL10n.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final isCustom = current != null && !kGroupDisappearingPresets.contains(current);

  final picked = await showDialog<(bool, Duration?)>(
    context: context,
    builder: (dialog) => SimpleDialog(
      title: Text(l.groupDisappearingTitle),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
          child: Text(
            l.groupDisappearingSubtitle,
            style: Theme.of(dialog).textTheme.bodySmall,
          ),
        ),
        SimpleDialogOption(
          key: const ValueKey('group-disappearing-off'),
          onPressed: () => Navigator.of(dialog).pop((true, null)),
          child: _radioRow(l.groupDisappearingOff, current == null),
        ),
        for (final window in kGroupDisappearingPresets)
          SimpleDialogOption(
            key: ValueKey('group-disappearing-${window.inMinutes}'),
            onPressed: () => Navigator.of(dialog).pop((true, window)),
            child: _radioRow(
              formatDisappearingWindow(l, window.inSeconds),
              window == current,
            ),
          ),
        SimpleDialogOption(
          key: const ValueKey('group-disappearing-custom'),
          // The sentinel is `Duration.zero` rather than null, which already
          // means "off" one line above.
          onPressed: () => Navigator.of(dialog).pop((true, Duration.zero)),
          child: _radioRow(
            isCustom
                ? formatDisappearingWindow(l, current.inSeconds)
                : l.groupDisappearingCustom,
            isCustom,
          ),
        ),
      ],
    ),
  );
  if (picked == null || !context.mounted) return;

  var window = picked.$2;
  if (window == Duration.zero) {
    final minutes = await showDialog<int>(
      context: context,
      builder: (_) => _MinutesDialog(initial: current?.inMinutes),
    );
    if (minutes == null || !context.mounted) return;
    window = Duration(minutes: minutes);
  }

  final ok = await service.setSpaceRetentionPolicy(
    groupId,
    window == null
        ? const SpaceRetentionPolicy(mode: SpaceRetentionMode.keepForever)
        : SpaceRetentionPolicy.forWindow(window),
  );
  if (!ok) {
    messenger.showSnackBar(
      SnackBar(content: Text(l.groupDisappearingFailed)),
    );
  }
}

class _MinutesDialog extends StatefulWidget {
  const _MinutesDialog({this.initial});
  final int? initial;

  @override
  State<_MinutesDialog> createState() => _MinutesDialogState();
}

class _MinutesDialogState extends State<_MinutesDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial?.toString() ?? '',
  );

  /// The bounds are the SIGNED policy's own, converted — not a second opinion
  /// this dialog invents. A number outside them would be refused after the
  /// user typed it, with nothing to explain why.
  static const int _minMinutes = kMinSpaceRetentionMs ~/ (60 * 1000);
  static final int _maxMinutes = kMaxSpaceRetentionMs ~/ (60 * 1000);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  int? get _value {
    final parsed = int.tryParse(_controller.text.trim());
    if (parsed == null || parsed < _minMinutes || parsed > _maxMinutes) {
      return null;
    }
    return parsed;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return AlertDialog(
      title: Text(l.groupDisappearingCustomTitle),
      content: TextField(
        key: const ValueKey('group-disappearing-minutes-field'),
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          suffixText: l.groupDisappearingMinutesSuffix,
        ),
        onChanged: (_) => setState(() {}),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        TextButton(
          key: const ValueKey('group-disappearing-minutes-ok'),
          onPressed: _value == null
              ? null
              : () => Navigator.of(context).pop(_value),
          child: Text(MaterialLocalizations.of(context).okButtonLabel),
        ),
      ],
    );
  }
}

/// Choose a hide-after-read window for a group — the SIGNED one when [signed]
/// (owner asking every member's device) or this device's own ceiling.
///
/// One picker for both on purpose: the choices and their meaning are the same,
/// and only the subtitle and the write differ. The signed write PRESERVES the
/// deletion half of the policy — the two halves ride one revision, and a
/// picker that rebuilt the policy from scratch would turn "hide after five
/// minutes" into "and also stop deleting", silently.
Future<void> pickGroupHideAfterRead(
  BuildContext context,
  GroupService service,
  NodeId groupId, {
  required bool signed,
}) async {
  final l = AppL10n.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final current = signed
      ? (await service.spaceRetentionPolicyOf(groupId))?.hideAfterReadMs
      : await service.localSpaceHideAfterReadMs(groupId);
  if (!context.mounted) return;

  const presets = <Duration>[
    Duration(minutes: 1),
    Duration(minutes: 5),
    Duration(minutes: 30),
    Duration(minutes: 60),
  ];
  final currentWindow = current == null
      ? null
      : Duration(milliseconds: current);
  final picked = await showDialog<(bool, Duration?)>(
    context: context,
    builder: (dialog) => SimpleDialog(
      title: Text(
        signed ? l.groupHideAfterReadTitle : l.groupHideAfterReadLocalTitle,
      ),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
          child: Text(
            signed
                ? l.groupHideAfterReadSubtitle
                : l.groupHideAfterReadLocalSubtitle,
            style: Theme.of(dialog).textTheme.bodySmall,
          ),
        ),
        SimpleDialogOption(
          key: const ValueKey('group-hide-read-off'),
          onPressed: () => Navigator.of(dialog).pop((true, null)),
          child: _radioRow(l.groupDisappearingOff, currentWindow == null),
        ),
        for (final window in presets)
          SimpleDialogOption(
            key: ValueKey('group-hide-read-${window.inMinutes}'),
            onPressed: () => Navigator.of(dialog).pop((true, window)),
            child: _radioRow(
              formatDisappearingWindow(l, window.inSeconds),
              window == currentWindow,
            ),
          ),
      ],
    ),
  );
  if (picked == null || !context.mounted) return;
  final ms = picked.$2?.inMilliseconds;

  final bool ok;
  if (signed) {
    final held =
        await service.spaceRetentionPolicyOf(groupId) ??
        const SpaceRetentionPolicy(mode: SpaceRetentionMode.keepForever);
    ok = await service.setSpaceRetentionPolicy(
      groupId,
      SpaceRetentionPolicy(
        mode: held.mode,
        retentionMs: held.retentionMs,
        mediaOnly: held.mediaOnly,
        hideAfterReadMs: ms,
        physicalDeletionGraceMs: held.physicalDeletionGraceMs,
        includeArchivedChannels: held.includeArchivedChannels,
      ),
    );
  } else {
    ok = await service.setLocalSpaceHideAfterReadMs(groupId, ms);
  }
  if (!ok) {
    messenger.showSnackBar(SnackBar(content: Text(l.groupDisappearingFailed)));
  }
}

Widget _radioRow(String label, bool selected) => Row(
  children: [
    Icon(
      selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
      size: 20,
    ),
    const SizedBox(width: 12),
    Expanded(child: Text(label)),
  ],
);
