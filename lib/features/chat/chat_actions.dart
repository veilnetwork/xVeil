import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ids.dart';
import '../../core/log.dart';
import '../../domain/chat.dart';
import '../../l10n/app_localizations.dart';
import '../../state/messaging.dart';

/// Shared conversation-management actions, reused by the in-chat AppBar menu AND
/// the chats-list long-press so the user manages a dialog from either place. All
/// actions are LOCAL (rename/pin/mute/retention/block/clear) or local-erase
/// (delete) — none touch the wire.

/// Bottom sheet of management actions for [contact]. [onDeleted] runs after a
/// confirmed conversation delete (e.g. pop the chat screen); omit it on the
/// chats list (the list just refreshes).
Future<void> showConversationActions(
  BuildContext context,
  WidgetRef ref,
  Contact contact, {
  VoidCallback? onDeleted,
}) async {
  final l = AppL10n.of(context);
  final svc = ref.read(messagingServiceProvider);
  final peer = contact.nodeId;
  await showModalBottomSheet<void>(
    context: context,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: Text(l.chatMenuRename),
            onTap: () {
              Navigator.of(sheet).pop();
              _renameContact(context, ref, contact);
            },
          ),
          if (contact.pinned)
            ListTile(
              leading: const Icon(Icons.push_pin_outlined),
              title: Text(l.chatMenuUnpin),
              onTap: () {
                Navigator.of(sheet).pop();
                svc.setContactPinned(peer, false);
              },
            )
          else
            ListTile(
              leading: const Icon(Icons.push_pin),
              title: Text(l.chatMenuPin),
              onTap: () {
                Navigator.of(sheet).pop();
                svc.setContactPinned(peer, true);
              },
            ),
          if (contact.muted)
            ListTile(
              leading: const Icon(Icons.notifications_active_outlined),
              title: Text(l.chatMenuUnmute),
              onTap: () {
                Navigator.of(sheet).pop();
                svc.setContactMutedUntil(peer, null);
              },
            )
          else
            ListTile(
              leading: const Icon(Icons.notifications_off_outlined),
              title: Text(l.chatMenuMute),
              onTap: () {
                Navigator.of(sheet).pop();
                pickMuteDuration(context, ref, peer);
              },
            ),
          ListTile(
            leading: const Icon(Icons.mark_chat_read_outlined),
            title: Text(l.chatMenuMarkRead),
            onTap: () {
              Navigator.of(sheet).pop();
              svc.markRead(peer.hex);
            },
          ),
          if (contact.archived)
            ListTile(
              leading: const Icon(Icons.unarchive_outlined),
              title: Text(l.chatMenuUnarchive),
              onTap: () {
                Navigator.of(sheet).pop();
                svc.setContactArchived(peer, false);
              },
            )
          else
            ListTile(
              leading: const Icon(Icons.archive_outlined),
              title: Text(l.chatMenuArchive),
              onTap: () {
                Navigator.of(sheet).pop();
                svc.setContactArchived(peer, true);
              },
            ),
          ListTile(
            leading: const Icon(Icons.auto_delete_outlined),
            title: Text(l.chatMenuRetention),
            onTap: () {
              Navigator.of(sheet).pop();
              pickRetention(context, ref, peer, contact.retentionDays);
            },
          ),
          if (contact.status == ContactStatus.blocked)
            ListTile(
              leading: const Icon(Icons.lock_open_outlined),
              title: Text(l.chatMenuUnblock),
              onTap: () {
                Navigator.of(sheet).pop();
                svc.unblockContact(peer);
              },
            )
          else
            ListTile(
              leading: const Icon(Icons.block),
              title: Text(l.actionBlock),
              onTap: () {
                Navigator.of(sheet).pop();
                svc.blockContact(peer);
              },
            ),
          ListTile(
            leading: const Icon(Icons.cleaning_services_outlined),
            title: Text(l.chatMenuClearHistory),
            onTap: () {
              Navigator.of(sheet).pop();
              _confirmClear(context, ref, peer);
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: Text(l.chatMenuDeleteConversation),
            onTap: () {
              Navigator.of(sheet).pop();
              _confirmDelete(context, ref, peer, onDeleted);
            },
          ),
        ],
      ),
    ),
  );
}

/// Pick how long to mute [peer]: presets from 30 minutes to a month, forever,
/// or a custom hour count. The deadline is stored (not a flag), so a timed
/// mute expires on its own — see [Contact.mutedUntil]. Shared by the in-chat
/// menu and the chats-list sheet.
Future<void> pickMuteDuration(
  BuildContext context,
  WidgetRef ref,
  NodeId peer,
) async {
  final l = AppL10n.of(context);
  // (label, duration); null duration = forever, -1h sentinel = custom.
  final presets = <(String, Duration?)>[
    (l.mute30m, const Duration(minutes: 30)),
    (l.mute1h, const Duration(hours: 1)),
    (l.mute8h, const Duration(hours: 8)),
    (l.mute3d, const Duration(days: 3)),
    (l.mute1w, const Duration(days: 7)),
    (l.mute1mo, const Duration(days: 30)),
    (l.muteForever, null),
    (l.muteCustom, const Duration(hours: -1)),
  ];
  final picked = await showDialog<(String, Duration?)>(
    context: context,
    builder: (dialog) => SimpleDialog(
      title: Text(l.chatMenuMute),
      children: [
        for (final o in presets)
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialog).pop(o),
            child: Text(o.$1),
          ),
      ],
    ),
  );
  if (picked == null || !context.mounted) return;
  Duration? d = picked.$2;
  if (d != null && d.isNegative) {
    final hours = await showDialog<int>(
      context: context,
      builder: (_) => _HoursDialog(),
    );
    if (hours == null || !context.mounted) return;
    d = Duration(hours: hours);
  }
  final until = d == null ? kMuteForever : DateTime.now().add(d);
  await ref.read(messagingServiceProvider).setContactMutedUntil(peer, until);
}

/// Pick [peer]'s auto-delete window — the existing presets PLUS a custom day
/// count. Applies immediately (prunes by original post time). Shared so the
/// picker (and the custom-days input) live in one place.
Future<void> pickRetention(
  BuildContext context,
  WidgetRef ref,
  NodeId peer,
  int? current,
) async {
  final l = AppL10n.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final presets = <(String, int?)>[
    (l.retentionUnlimited, null),
    (l.retention7, 7),
    (l.retention30, 30),
    (l.retention90, 90),
    (l.retention365, 365),
  ];
  final isCustom = current != null && !presets.any((p) => p.$2 == current);
  final picked = await showDialog<(String, int?)>(
    context: context,
    builder: (dialog) => SimpleDialog(
      title: Text(l.chatMenuRetention),
      children: [
        for (final o in presets)
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialog).pop(o),
            child: _radioRow(o.$1, o.$2 == current),
          ),
        SimpleDialogOption(
          onPressed: () => Navigator.of(dialog).pop(('', -1)),
          child: _radioRow(
            isCustom ? l.retentionCustomN(current) : l.retentionCustom,
            isCustom,
          ),
        ),
      ],
    ),
  );
  if (picked == null || !context.mounted) return;
  int? days;
  if (picked.$2 == -1) {
    days = await showDialog<int>(
      context: context,
      builder: (_) => _DaysDialog(initial: current),
    );
    if (days == null || !context.mounted) return;
  } else {
    days = picked.$2;
  }
  await ref.read(messagingServiceProvider).setContactRetention(peer, days);
  if (days != null && days > 0) {
    messenger.showSnackBar(
      SnackBar(content: Text(l.retentionApplied), duration: const Duration(seconds: 1)),
    );
  }
}

Widget _radioRow(String label, bool selected) => Row(
      children: [
        Icon(
          selected ? Icons.radio_button_checked : Icons.radio_button_off,
          size: 18,
        ),
        const SizedBox(width: 12),
        Expanded(child: Text(label)),
      ],
    );

Future<void> _renameContact(
  BuildContext context,
  WidgetRef ref,
  Contact contact,
) async {
  final l = AppL10n.of(context);
  final newName = await showDialog<String>(
    context: context,
    builder: (_) => _TextDialog(
      initial: contact.name ?? '',
      title: l.chatRenameTitle,
      saveLabel: l.actionSave,
      cancelLabel: l.actionCancel,
    ),
  );
  if (newName == null || !context.mounted) return;
  await ref.read(messagingServiceProvider).setContactName(contact.nodeId, newName);
}

Future<void> _confirmClear(
  BuildContext context,
  WidgetRef ref,
  NodeId peer,
) async {
  final l = AppL10n.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(l.chatClearHistoryTitle),
      content: Text(l.chatClearHistoryBody),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(l.actionCancel)),
        FilledButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(l.chatClearHistoryConfirm)),
      ],
    ),
  );
  if (ok != true) return;
  // Route through the service (not storageProvider directly): clearConversation
  // emits the changes signal so messagesProvider reloads and the now-empty chat
  // actually re-renders. Calling storage.clearMessages directly cleared the
  // store but left the UI showing the old messages (looked like nothing happened).
  try {
    await ref.read(messagingServiceProvider).clearConversation(peer);
  } catch (e, st) {
    // Surface the failure instead of a silent no-op (a too-large commit threw
    // PayloadTooLarge and the clear aborted, leaving the history intact).
    devLog(() => 'xVeil[clear]: clearConversation FAILED for ${peer.short}: $e\n$st');
  }
}

Future<void> _confirmDelete(
  BuildContext context,
  WidgetRef ref,
  NodeId peer,
  VoidCallback? onDeleted,
) async {
  final l = AppL10n.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(l.chatDeleteChatTitle),
      content: Text(l.chatDeleteChatBody),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(l.actionCancel)),
        FilledButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(l.chatDeleteConfirm)),
      ],
    ),
  );
  if (ok != true) return;
  await ref.read(messagingServiceProvider).deleteConversation(peer);
  onDeleted?.call();
}

/// Number-of-hours input dialog for the custom mute window (owns its
/// controller, same disposal rationale as [_DaysDialog]).
class _HoursDialog extends StatefulWidget {
  @override
  State<_HoursDialog> createState() => _HoursDialogState();
}

class _HoursDialogState extends State<_HoursDialog> {
  final _ctl = TextEditingController();

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return AlertDialog(
      title: Text(l.muteCustomTitle),
      content: TextField(
        controller: _ctl,
        autofocus: true,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(suffixText: l.muteHoursSuffix),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.actionCancel),
        ),
        FilledButton(
          onPressed: () {
            final n = int.tryParse(_ctl.text.trim());
            Navigator.of(context).pop(n != null && n > 0 ? n : null);
          },
          child: Text(l.actionSave),
        ),
      ],
    );
  }
}

/// Number-of-days input dialog (StatefulWidget so the controller is disposed in
/// dispose(), not inline — avoids the "controller used after disposed" race).
class _DaysDialog extends StatefulWidget {
  const _DaysDialog({this.initial});
  final int? initial;
  @override
  State<_DaysDialog> createState() => _DaysDialogState();
}

class _DaysDialogState extends State<_DaysDialog> {
  late final TextEditingController _ctl =
      TextEditingController(text: widget.initial?.toString() ?? '');

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return AlertDialog(
      title: Text(l.retentionCustomTitle),
      content: TextField(
        controller: _ctl,
        autofocus: true,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(suffixText: l.retentionDaysSuffix),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.actionCancel),
        ),
        FilledButton(
          onPressed: () {
            final n = int.tryParse(_ctl.text.trim());
            Navigator.of(context).pop(n != null && n > 0 ? n : null);
          },
          child: Text(l.actionSave),
        ),
      ],
    );
  }
}

/// Generic single-line text dialog (owns its controller). Returns the text or
/// null on cancel.
class _TextDialog extends StatefulWidget {
  const _TextDialog({
    required this.initial,
    required this.title,
    required this.saveLabel,
    required this.cancelLabel,
  });
  final String initial;
  final String title;
  final String saveLabel;
  final String cancelLabel;
  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  late final TextEditingController _ctl =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: TextField(controller: _ctl, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(widget.cancelLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(_ctl.text),
            child: Text(widget.saveLabel),
          ),
        ],
      );
}
