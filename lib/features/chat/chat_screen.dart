import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/ids.dart';
import '../../domain/chat.dart';
import '../../l10n/app_localizations.dart';
import '../../state/messaging.dart';
import '../../state/providers.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.peerHex});
  final String peerHex;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  late final NodeId _peer = NodeId.fromHex(widget.peerHex);

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _submit(ContactStatus? status) async {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    _input.clear();
    final svc = ref.read(messagingServiceProvider);
    if (status == ContactStatus.accepted) {
      await svc.sendText(_peer, text);
    } else {
      // No contact yet / not accepted — the first message is the request.
      await svc.sendRequest(_peer, text);
    }
    _scrollToBottom();
  }

  Future<void> _accept() =>
      ref.read(messagingServiceProvider).acceptContact(_peer);

  Future<void> _block() async {
    await ref.read(messagingServiceProvider).blockContact(_peer);
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
    _scrollToBottom();
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
    final path = await FilePicker.saveFile(
      fileName: m.fileName ?? 'file',
    );
    if (path == null) return; // cancelled
    try {
      await File(path).writeAsBytes(bytes);
      if (mounted) _snack(l.chatFileSaved);
    } catch (_) {
      if (mounted) _snack(l.chatFileSaveFailed);
    }
  }

  void _snack(String msg) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(msg)));

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final messages = ref.watch(messagesProvider(widget.peerHex));
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
            Expanded(
              child: Text(_peer.short, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: messages.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('$e')),
              data: (list) => ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.all(12),
                itemCount: list.length,
                itemBuilder: (_, i) =>
                    _Bubble(message: list[i], onTapFile: _saveFile),
              ),
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
        return _Banner(
          icon: Icons.hourglass_top,
          text: l.chatRequestSent,
        );
      case ContactStatus.pendingIncoming:
        return _RequestActions(onAccept: _accept, onBlock: _block);
      case ContactStatus.blocked:
        return _Banner(icon: Icons.block, text: l.chatBlockedContact);
      case ContactStatus.accepted:
        return _Composer(
          controller: _input,
          hint: l.chatNewMessageHint,
          onSend: () => _submit(status),
          onAttach: _attach,
        );
      case null:
        return _Composer(
          controller: _input,
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
              child: Text(text,
                  style: TextStyle(color: scheme.onSurfaceVariant)),
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
            Text(l.chatRequestTitle,
                style: Theme.of(context).textTheme.bodyMedium),
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

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, this.onTapFile});
  final Message message;
  final void Function(Message message)? onTapFile;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final outgoing = message.direction == MessageDirection.outgoing;
    return Align(
      alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        decoration: BoxDecoration(
          color: outgoing ? scheme.primaryContainer : scheme.surfaceContainerHighest,
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
                    Icon(Icons.insert_drive_file_outlined,
                        size: 20, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(message.fileName ?? message.body,
                          overflow: TextOverflow.ellipsis),
                    ),
                    const SizedBox(width: 8),
                    Icon(Icons.download_outlined,
                        size: 16, color: scheme.onSurfaceVariant),
                  ],
                ),
              )
            else
              Text(message.body),
            const SizedBox(height: 2),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  formatHhmm(message.timestamp),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
                if (outgoing) ...[
                  const SizedBox(width: 4),
                  Icon(_statusIcon(message.status),
                      size: 13, color: scheme.onSurfaceVariant),
                ],
              ],
            ),
          ],
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
    required this.hint,
    required this.onSend,
    this.onAttach,
  });
  final TextEditingController controller;
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
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onSend(),
                decoration: InputDecoration(hintText: hint),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: onSend,
              icon: const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }
}
