import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/ids.dart';
import '../../domain/chat.dart';
import '../../l10n/app_localizations.dart';
import '../../state/messaging.dart';
import '../../state/notifications.dart';
import '../../state/providers.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.peerHex});
  final String peerHex;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _input = TextEditingController();
  // Keep the composer focused across sends — TextInputAction.send drops focus by
  // default (most visible on desktop: the caret leaves the field and the user has
  // to click back in before typing the next message).
  final _inputFocus = FocusNode();
  final _scroll = ScrollController();
  // The chat must OPEN at the latest message; after that we only auto-stick to
  // the bottom when already near it (so reading history isn't yanked down).
  bool _didInitialScroll = false;

  late final NodeId _peer = NodeId.fromHex(widget.peerHex);

  @override
  void initState() {
    super.initState();
    // Opening the chat clears its unread badge (marks read up to the latest
    // message). Deferred so the first frame isn't blocked.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(messagingServiceProvider).markRead(widget.peerHex);
        // Mark this chat as the one on screen so the notification layer
        // suppresses alerts for it while it's open + foreground.
        ref.read(activeConversationProvider.notifier).state = widget.peerHex;
      }
    });
  }

  @override
  void deactivate() {
    // Leaving the chat: clear the active-conversation marker (only if it still
    // points at us — a freshly-opened chat may have already claimed it). It has
    // a listener (the notification binder), so writing it synchronously here
    // trips Riverpod's "modify a provider during a widget life-cycle" guard.
    // Defer to a microtask via the captured container (which outlives us).
    final container = ProviderScope.containerOf(context, listen: false);
    final peer = widget.peerHex;
    Future.microtask(() {
      // Best-effort marker cleanup. If the whole ProviderScope was torn down
      // before this runs (app shutdown, or a test ending), the container is
      // disposed and there is nothing left to clear — swallow that.
      try {
        final n = container.read(activeConversationProvider.notifier);
        if (n.state == peer) n.state = null;
      } catch (_) {}
    });
    super.deactivate();
  }

  @override
  void dispose() {
    _input.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _submit(ContactStatus? status) async {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    _input.clear();
    // Re-grab focus immediately (before the async send) so typing the next
    // message never requires clicking back into the field.
    _inputFocus.requestFocus();
    final svc = ref.read(messagingServiceProvider);
    if (status == ContactStatus.accepted) {
      await svc.sendText(_peer, text);
    } else {
      // No contact yet / not accepted — the first message is the request.
      await svc.sendRequest(_peer, text);
    }
    _scrollToBottom(force: true);
    if (mounted) {
      _inputFocus.requestFocus(); // and again after the await settles
    }
  }

  Future<void> _accept() =>
      ref.read(messagingServiceProvider).acceptContact(_peer);

  Future<void> _block() async {
    await ref.read(messagingServiceProvider).blockContact(_peer);
    if (mounted) Navigator.of(context).maybePop();
  }

  Future<void> _resend() async {
    await ref.read(messagingServiceProvider).resendRequest(_peer);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppL10n.of(context).chatRequestSent)),
      );
    }
  }

  Future<void> _cancel() async {
    final l = AppL10n.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.chatRequestCancelTitle),
        content: Text(l.chatRequestCancelBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l.actionBack),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l.chatRequestCancel),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(messagingServiceProvider).cancelRequest(_peer);
    if (mounted) Navigator.of(context).maybePop();
  }

  /// Pick a file and send it to the peer (consent-gated in the service). Bytes
  /// are read in full (withData) and bounded by the same cap the receiver
  /// enforces.
  Future<void> _attach() async {
    final l = AppL10n.of(context);
    final picked = await FilePicker.pickFiles(withData: true);
    final file = picked?.files.firstOrNull;
    final bytes = file?.bytes;
    if (file == null || bytes == null) return; // cancelled / unreadable
    if (bytes.length > kMaxIncomingFileBytes) {
      if (mounted) _snack(l.chatFileTooLarge);
      return;
    }
    await ref.read(messagingServiceProvider).sendFile(_peer, bytes, file.name);
    _scrollToBottom(force: true);
  }

  /// Save a received (or sent) file out of the deniable container to a location
  /// the user picks.
  Future<void> _saveFile(Message m) async {
    final l = AppL10n.of(context);
    final bytes = await ref.read(storageProvider).loadFile(m.fileId!);
    if (bytes == null) {
      if (mounted) _snack(l.chatFileSaveFailed);
      return;
    }
    final path = await FilePicker.saveFile(fileName: m.fileName ?? 'file');
    if (path == null) return; // cancelled
    try {
      await File(path).writeAsBytes(bytes);
      if (mounted) _snack(l.chatFileSaved);
    } catch (_) {
      if (mounted) _snack(l.chatFileSaveFailed);
    }
  }

  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  /// Long-press menu on a message bubble. Own (outgoing) text messages can be
  /// edited or unsent for everyone; any message can be deleted from this device
  /// (the deniable "purge what was sent to you").
  Future<void> _showMessageActions(Message m) async {
    final l = AppL10n.of(context);
    final own = m.direction == MessageDirection.outgoing;
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!m.isFile)
              ListTile(
                leading: const Icon(Icons.copy_outlined),
                title: Text(l.chatMsgCopy),
                onTap: () {
                  Navigator.of(sheet).pop();
                  _copyMessage(m);
                },
              ),
            if (own && !m.isFile)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: Text(l.chatMsgEdit),
                onTap: () {
                  Navigator.of(sheet).pop();
                  _editMessage(m);
                },
              ),
            if (own)
              ListTile(
                leading: const Icon(Icons.delete_forever_outlined),
                title: Text(l.chatMsgDeleteForEveryone),
                onTap: () {
                  Navigator.of(sheet).pop();
                  _deleteMessage(m, forEveryone: true);
                },
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: Text(l.chatMsgDeleteForMe),
              onTap: () {
                Navigator.of(sheet).pop();
                _deleteMessage(m, forEveryone: false);
              },
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text(l.chatMsgInfo),
              onTap: () {
                Navigator.of(sheet).pop();
                _showMessageInfo(m);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Copy a text message's body to the clipboard. Local-only — nothing leaves
  /// the device, so it carries no anonymity/deniability cost (the user already
  /// holds the plaintext).
  Future<void> _copyMessage(Message m) async {
    final l = AppL10n.of(context);
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: m.body));
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(l.chatMsgCopied),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  Future<void> _editMessage(Message m) async {
    final l = AppL10n.of(context);
    // The dialog owns its TextEditingController via a StatefulWidget so it is
    // disposed in State.dispose() (after the close transition), not inline
    // right after showDialog returns. Inline disposal races the exit animation:
    // a teardown-driven rebuild (compaction / identity-switch / lock) can
    // rebuild the still-animating TextField against a disposed controller —
    // the "used after being disposed" + _dependents.isEmpty red screen.
    final newText = await showDialog<String>(
      context: context,
      builder: (_) => _EditMessageDialog(
        initial: m.body,
        title: l.chatEditTitle,
        saveLabel: l.chatEditSave,
        cancelLabel: l.actionCancel,
      ),
    );
    final trimmed = newText?.trim();
    if (trimmed == null || trimmed.isEmpty || trimmed == m.body) return;
    if (!mounted) return; // teardown may have unmounted us during the dialog
    await ref.read(messagingServiceProvider).editOwnMessage(m.id, trimmed);
  }

  Future<void> _deleteMessage(Message m, {required bool forEveryone}) async {
    final l = AppL10n.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l.chatDeleteTitle),
        content: Text(
          forEveryone ? l.chatDeleteForEveryoneBody : l.chatDeleteForMeBody,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(l.chatDeleteConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final svc = ref.read(messagingServiceProvider);
    if (forEveryone) {
      await svc.deleteForEveryone(m.id);
    } else {
      await svc.deleteMessageLocally(m.id);
    }
  }

  Future<void> _onMenuAction(
    _ChatMenuAction action,
    ContactStatus? status,
  ) async {
    final svc = ref.read(messagingServiceProvider);
    switch (action) {
      case _ChatMenuAction.block:
        await svc.blockContact(_peer);
      case _ChatMenuAction.unblock:
        await svc.unblockContact(_peer);
      case _ChatMenuAction.clear:
        await _clearHistory();
      case _ChatMenuAction.delete:
        await _deleteConversation();
    }
  }

  /// Wipe this conversation's messages but keep the contact — the chat stays in
  /// the list, emptied. Forensic erase (the peer is not notified).
  Future<void> _clearHistory() async {
    final l = AppL10n.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l.chatClearHistoryTitle),
        content: Text(l.chatClearHistoryBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(l.chatClearHistoryConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(messagingServiceProvider).clearConversation(_peer);
  }

  /// Erase this whole conversation (messages + contact) from THIS device. The
  /// peer is not notified — a local, deniable wipe. After it, [_peer] is unknown
  /// again, so we pop back to the chat list.
  Future<void> _deleteConversation() async {
    final l = AppL10n.of(context);
    final navigator = Navigator.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l.chatDeleteChatTitle),
        content: Text(l.chatDeleteChatBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(l.chatDeleteConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(messagingServiceProvider).deleteConversation(_peer);
    if (!mounted) return;
    navigator.pop(); // leave the now-empty conversation
  }

  /// Local, read-only detail sheet for one message: id, direction, time, and
  /// (for an outgoing message) its delivery status. Nothing leaves the device.
  void _showMessageInfo(Message m) {
    final l = AppL10n.of(context);
    final own = m.direction == MessageDirection.outgoing;
    showModalBottomSheet<void>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l.chatMsgInfo, style: Theme.of(sheet).textTheme.titleMedium),
              const SizedBox(height: 16),
              _InfoRow(label: l.msgInfoDirection, value: own ? l.dirOutgoing : l.dirIncoming),
              _InfoRow(label: l.msgInfoTime, value: formatDateTime(m.timestamp.toLocal())),
              if (own) _InfoRow(label: l.msgInfoStatus, value: _statusLabel(l, m.status)),
              if (m.isFile && m.fileName != null)
                _InfoRow(label: l.msgInfoFile, value: m.fileName!),
              _InfoRow(label: l.msgInfoId, value: m.id),
            ],
          ),
        ),
      ),
    );
  }

  String _statusLabel(AppL10n l, MessageStatus s) => switch (s) {
        MessageStatus.sending => l.msgStatusSending,
        MessageStatus.sent => l.msgStatusSent,
        MessageStatus.delivered => l.msgStatusDelivered,
        MessageStatus.failed => l.msgStatusFailed,
      };

  void _scrollToBottom({bool force = false}) {
    if (force) {
      // Chat-open / own-send: land at the last message. A SINGLE post-frame
      // jumpTo lands short (near the TOP) because the message list is loaded
      // async (off-isolate storage) + has variable-height items, so the
      // ListView's maxScrollExtent is still GROWING for a few frames after the
      // first build with messages. Re-jump each frame while the extent keeps
      // growing (bounded) so we reliably end up at the true bottom.
      _stickToBottomAcrossFrames();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final pos = _scroll.position;
      // Don't yank the view to the end on every inbound/status change (the
      // "jumps to the end" jank): only stick to the bottom when already near it.
      if (pos.maxScrollExtent - pos.pixels > 300) return;
      _scroll.animateTo(
        pos.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  /// Jump to the bottom once per frame while the scroll extent is still
  /// GROWING (the async-loaded, variable-height list lays out over several
  /// frames) — bounded to [framesLeft] frames so it can't loop. Stops as soon
  /// as the extent stabilises, so we reliably land at the true last message.
  void _stickToBottomAcrossFrames([
    int framesLeft = 10,
    double lastExtent = -1,
  ]) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final max = _scroll.position.maxScrollExtent;
      _scroll.jumpTo(max);
      if (framesLeft > 0 && max > lastExtent) {
        _stickToBottomAcrossFrames(framesLeft - 1, max);
      }
    });
  }

  /// Grow the visible window so the next-older page of messages loads. The
  /// newest messages stay pinned to the bottom, so keeping the user's
  /// distance-FROM-BOTTOM constant across the (top-prepended) rebuild leaves the
  /// same messages under their eyes instead of jumping them down by the height
  /// of the newly-loaded batch.
  void _loadEarlier() {
    final fromBottom = _scroll.hasClients
        ? _scroll.position.maxScrollExtent - _scroll.position.pixels
        : null;
    ref.read(chatWindowProvider(widget.peerHex).notifier).state +=
        kMessageWindowStep;
    if (fromBottom != null) _restoreFromBottom(fromBottom);
  }

  /// After the larger window lays out (older items prepended above), restore the
  /// same distance-from-bottom. Re-applied across a bounded number of frames
  /// because the async, off-isolate, variable-height list grows its scroll
  /// extent over several frames (same pattern as [_stickToBottomAcrossFrames]).
  void _restoreFromBottom(
    double fromBottom, [
    int framesLeft = 30,
    double lastExtent = -1,
  ]) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final max = _scroll.position.maxScrollExtent;
      _scroll.jumpTo((max - fromBottom).clamp(0.0, max));
      if (framesLeft > 0 && max > lastExtent) {
        _restoreFromBottom(fromBottom, framesLeft - 1, max);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final messages = ref.watch(messagesProvider(widget.peerHex));
    final window = ref.watch(chatWindowProvider(widget.peerHex));
    final status = ref.watch(contactProvider(widget.peerHex)).value?.status;
    ref.listen(messagesProvider(widget.peerHex), (_, _) => _scrollToBottom());

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            CircleAvatar(
              radius: 16,
              child: Text(_peer.short.characters.first.toUpperCase()),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(_peer.short, overflow: TextOverflow.ellipsis)),
          ],
        ),
        actions: [
          PopupMenuButton<_ChatMenuAction>(
            onSelected: (a) => _onMenuAction(a, status),
            itemBuilder: (_) => [
              // Block an accepted contact (their messages get dropped) or lift
              // an existing block — local-only, the peer is never told either way.
              if (status == ContactStatus.blocked)
                PopupMenuItem(
                  value: _ChatMenuAction.unblock,
                  child: Text(l.chatMenuUnblock),
                )
              else
                PopupMenuItem(
                  value: _ChatMenuAction.block,
                  child: Text(l.actionBlock),
                ),
              PopupMenuItem(
                value: _ChatMenuAction.clear,
                child: Text(l.chatMenuClearHistory),
              ),
              PopupMenuItem(
                value: _ChatMenuAction.delete,
                child: Text(l.chatMenuDeleteConversation),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: messages.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('$e')),
              data: (list) {
                // Land at the last message on open. Fire HERE (the data
                // builder, so the ListView is actually mounted) and only ONCE
                // per screen mount — NOT at the top of build, where a
                // lock+reopen reload still exposes the stale previous `.value`
                // while the spinner shows, which set the flag before the list
                // existed and left it stuck at the top.
                if (!_didInitialScroll && list.isNotEmpty) {
                  _didInitialScroll = true;
                  _scrollToBottom(force: true);
                }
                // A full page came back ⇒ older messages likely exist ⇒ offer
                // "load earlier" as the first item. (Heuristic: if fewer than a
                // full window returned, this is the whole conversation.)
                final hasMore = list.length >= window;
                return ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.all(12),
                  itemCount: list.length + (hasMore ? 1 : 0),
                  itemBuilder: (_, i) {
                    if (hasMore && i == 0) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: TextButton.icon(
                            icon: const Icon(Icons.history, size: 18),
                            label: Text(l.chatLoadEarlier),
                            onPressed: _loadEarlier,
                          ),
                        ),
                      );
                    }
                    return _Bubble(
                      message: list[hasMore ? i - 1 : i],
                      onTapFile: _saveFile,
                      onLongPress: _showMessageActions,
                    );
                  },
                );
              },
            ),
          ),
          _bottom(status, l),
        ],
      ),
    );
  }

  Widget _bottom(ContactStatus? status, AppL10n l) {
    switch (status) {
      case ContactStatus.pendingOutgoing:
        return _PendingOutgoingActions(
          text: l.chatRequestSent,
          resendLabel: l.chatRequestResend,
          cancelLabel: l.chatRequestCancel,
          onResend: _resend,
          onCancel: _cancel,
        );
      case ContactStatus.pendingIncoming:
        return _RequestActions(onAccept: _accept, onBlock: _block);
      case ContactStatus.blocked:
        return _Banner(icon: Icons.block, text: l.chatBlockedContact);
      case ContactStatus.accepted:
        return _Composer(
          controller: _input,
          focusNode: _inputFocus,
          hint: l.chatNewMessageHint,
          onSend: () => _submit(status),
          onAttach: _attach,
        );
      case null:
        return _Composer(
          controller: _input,
          focusNode: _inputFocus,
          hint: l.chatRequestHint,
          onSend: () => _submit(status),
        );
    }
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                text,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RequestActions extends StatelessWidget {
  const _RequestActions({required this.onAccept, required this.onBlock});
  final VoidCallback onAccept;
  final VoidCallback onBlock;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l.chatRequestTitle,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onBlock,
                    icon: const Icon(Icons.block, size: 18),
                    label: Text(l.actionBlock),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: onAccept,
                    icon: const Icon(Icons.check, size: 18),
                    label: Text(l.actionAccept),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Bottom bar for a sent-but-not-yet-accepted request: the "waiting" line plus
/// Resend / Cancel actions (so a request that didn't land can be retried or
/// retracted without minting a new identity).
class _PendingOutgoingActions extends StatelessWidget {
  const _PendingOutgoingActions({
    required this.text,
    required this.resendLabel,
    required this.cancelLabel,
    required this.onResend,
    required this.onCancel,
  });
  final String text;
  final String resendLabel;
  final String cancelLabel;
  final VoidCallback onResend;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.hourglass_top,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    text,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onCancel,
                    icon: const Icon(Icons.close, size: 18),
                    label: Text(cancelLabel),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: onResend,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: Text(resendLabel),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Chat AppBar overflow actions. Local-only — none of these touch the wire.
enum _ChatMenuAction { block, unblock, clear, delete }

/// One `label: value` line in the message-info sheet. The value is selectable
/// so the user can copy a message id / filename.
class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, this.onTapFile, this.onLongPress});
  final Message message;
  final void Function(Message message)? onTapFile;
  final void Function(Message message)? onLongPress;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final outgoing = message.direction == MessageDirection.outgoing;
    return Align(
      alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        // Long-press (touch) AND secondary-tap (desktop right-click) both open
        // the message actions — without the latter the menu is unreachable on
        // desktop, where there is no long-press.
        onLongPress: onLongPress == null ? null : () => onLongPress!(message),
        onSecondaryTap: onLongPress == null
            ? null
            : () => onLongPress!(message),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.75,
          ),
          decoration: BoxDecoration(
            color: outgoing
                ? scheme.primaryContainer
                : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(outgoing ? 16 : 4),
              bottomRight: Radius.circular(outgoing ? 4 : 16),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (message.isFile)
                InkWell(
                  onTap: onTapFile == null ? null : () => onTapFile!(message),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.insert_drive_file_outlined,
                        size: 20,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          message.fileName ?? message.body,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        Icons.download_outlined,
                        size: 16,
                        color: scheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                )
              else
                Text(message.body),
              const SizedBox(height: 2),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (message.edited) ...[
                    Text(
                      l.chatEdited,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                    const SizedBox(width: 4),
                  ],
                  Text(
                    formatHhmm(message.timestamp),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  if (outgoing) ...[
                    const SizedBox(width: 4),
                    Icon(
                      _statusIcon(message.status),
                      size: 13,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static IconData _statusIcon(MessageStatus s) => switch (s) {
    MessageStatus.sending => Icons.schedule,
    MessageStatus.sent => Icons.check,
    MessageStatus.delivered => Icons.done_all,
    MessageStatus.failed => Icons.error_outline,
  };
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.hint,
    required this.onSend,
    this.onAttach,
  });
  final TextEditingController controller;
  final FocusNode focusNode;
  final String hint;
  final VoidCallback onSend;

  /// When set (accepted contacts only), shows a file-attach button.
  final VoidCallback? onAttach;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        child: Row(
          children: [
            if (onAttach != null)
              IconButton(
                onPressed: onAttach,
                icon: const Icon(Icons.attach_file),
                tooltip: l.chatAttachTooltip,
              ),
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onSend(),
                decoration: InputDecoration(hintText: hint),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(onPressed: onSend, icon: const Icon(Icons.send)),
          ],
        ),
      ),
    );
  }
}

/// Edit-message dialog. A `StatefulWidget` so its [TextEditingController] is
/// disposed in [State.dispose] — which runs only once the dialog route is
/// fully removed (after the close transition), avoiding the disposed-controller
/// red screen when a teardown event forces a rebuild mid-animation.
class _EditMessageDialog extends StatefulWidget {
  const _EditMessageDialog({
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
  State<_EditMessageDialog> createState() => _EditMessageDialogState();
}

class _EditMessageDialogState extends State<_EditMessageDialog> {
  late final TextEditingController _ctl = TextEditingController(
    text: widget.initial,
  );

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
        autofocus: true,
        maxLines: null,
        textInputAction: TextInputAction.done,
      ),
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
}
