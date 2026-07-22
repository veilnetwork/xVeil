import 'dart:async';
import 'dart:convert' show base64Decode;
import 'dart:io';
import 'dart:ui' as ui show ImageFilter, PlatformDispatcher, Image;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:veil_media/veil_media.dart' show VeilVnotePlayer;

import '../../core/format.dart';
import '../../core/ids.dart';
import '../../data/serve_source.dart';
import '../../data/transport/wire_envelope.dart' show isChatDeletedMarker;
import '../../core/log.dart';
import 'chat_actions.dart';
import 'chat_search.dart';
import 'message_markdown.dart';
import 'mention_composer.dart';
import '../../domain/call_signal.dart';
import '../../domain/chat.dart';
import '../../domain/file_download_policy.dart';
import '../../domain/inline_custom_emoji.dart';
import '../../domain/space_recommendation.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_controller.dart';
import '../../state/call_service.dart';
import '../../state/chat_page_size_controller.dart';
import '../../state/messaging.dart';
import '../../state/group_service_providers.dart';
import '../../state/nickname_peers.dart';
import '../../state/notifications.dart';
import '../../state/providers.dart';
import '../../state/reactions_visibility_controller.dart';
import '../../state/sticker_message.dart';
import '../../state/sticker_image.dart';
import '../../state/sticker_store.dart';
import '../../state/thumbnail.dart';
import '../../state/transcription_controller.dart';
import '../../state/voice_message.dart';
import '../../state/vnote_message.dart';
import '../../state/vnote_play_controller.dart';
import '../../state/vnote_record_controller.dart';
import '../../state/voice_play_controller.dart';
import '../../state/voice_record_controller.dart';
import 'voice_waveform.dart';
import 'camera_capture_screen.dart';
import 'cancelable_download_progress.dart';
import 'composer_expression_panel.dart';
import 'custom_emoji_controller.dart';
import 'reactors_sheet.dart';
import 'vnote_preview.dart';
import 'video_player_screen.dart';

part 'chat_message_widgets.dart';
part 'chat_composer.dart';

/// The quick-react emoji bar shown atop the message-actions sheet.
const kQuickReactions = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

bool _sameCustomEmoji(
  List<InlineCustomEmoji> left,
  List<InlineCustomEmoji> right,
) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    if (left[i].offset != right[i].offset ||
        left[i].dataB64 != right[i].dataB64) {
      return false;
    }
  }
  return true;
}

String _safeDownloadName(String? value) {
  final sanitized = (value ?? 'file').trim().replaceAll(
    RegExp(r'[/\\\x00]'),
    '_',
  );
  return sanitized.isEmpty ? 'file' : sanitized;
}

Future<void> _cancelContentDownload(WidgetRef ref, String contentId) async {
  final partialPath = await ref
      .read(messagingServiceProvider)
      .cancelContentDownload(contentId);
  if (partialPath == null) return;
  try {
    await File(partialPath).delete();
  } catch (_) {
    // Already absent or the platform revoked the picker grant.
  }
}

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.peerHex, this.initialJumpTo});
  final String peerHex;

  /// Message id to land on after the first load (a global-search hit or a
  /// pinned/quoted reference from outside the chat). Null = land at bottom.
  final String? initialJumpTo;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _input = CustomEmojiEditingController();
  // Keep the composer focused across sends — TextInputAction.send drops focus by
  // default (most visible on desktop: the caret leaves the field and the user has
  // to click back in before typing the next message).
  final _inputFocus = FocusNode();
  final _scroll = ScrollController();
  // The chat must OPEN at the latest message; after that we only auto-stick to
  // the bottom when already near it (so reading history isn't yanked down).
  bool _didInitialScroll = false;

  late final NodeId _peer = NodeId.fromHex(widget.peerHex);

  /// The message being replied to (composer shows a quote banner; the next send
  /// carries its id). Null = a normal send.
  Message? _replyingTo;

  /// Multi-select mode: the set of selected message ids. Non-empty ⇒ the app bar
  /// switches to the selection bar (count + bulk copy/forward/delete).
  final Set<String> _selected = <String>{};
  bool get _selecting => _selected.isNotEmpty;

  /// Whether the user has scrolled far enough up that a "jump to latest"
  /// button should appear (reading history, then getting back is a long drag).
  bool _awayFromBottom = false;

  void _onScrollChanged() {
    if (!_scroll.hasClients) return;
    final away =
        _scroll.position.maxScrollExtent - _scroll.position.pixels >
        _kAwayFromBottomPx;
    if (away != _awayFromBottom) setState(() => _awayFromBottom = away);
  }

  /// How far (px) from the bottom counts as "away" — roughly a screenful, so
  /// the button never flickers during normal near-bottom reading.
  static const double _kAwayFromBottomPx = 600;

  /// Per-message keys so "jump to the quoted message" can ensureVisible its
  /// bubble. Keyed by message id; entries are cheap and bounded by the loaded
  /// window (the map is rebuilt keys-on-demand, stale ids just linger unused).
  final Map<String, GlobalKey> _bubbleKeys = <String, GlobalKey>{};
  GlobalKey _bubbleKey(String id) => _bubbleKeys[id] ??= GlobalKey();

  // ── In-chat search ─────────────────────────────────────────────────────────
  // The scan covers the WHOLE conversation (not just the loaded window);
  // navigation reuses the quote-jump machinery, so stepping to an old match
  // grows the window as needed.
  final _chatSearchCtl = TextEditingController();
  Timer? _chatSearchDebounce;
  bool _chatSearching = false;
  List<String> _chatMatches = const []; // message ids, oldest → newest
  int _chatMatchIdx = -1;
  // The scanned needle, mirrored so bubbles highlight exactly what matched
  // (empty = no highlight). Tracks _chatMatches, not the raw controller text.
  String _chatSearchNeedle = '';

  /// Flash highlight of a just-landed message (search hit / quote jump).
  String? _highlightId;
  Timer? _highlightTimer;

  /// True when this is the Saved Messages chat (peer == our own node id) —
  /// set at the top of build, read by _submit / _bottom / the app bar.
  bool _saved = false;

  // ── Pinned message (LOCAL, one per conversation) ────────────────────────────
  // Stored in the settings KV as JSON {id, t} — the snippet travels with the
  // id so the banner renders even when the message is outside the loaded
  // window. Local-only, like the chat pin / alias / mute (no wire frame).
  PinnedRef? _pinned;

  Future<void> _loadPin() async {
    try {
      final raw = await ref
          .read(storageProvider)
          .getSetting('pin:${widget.peerHex}');
      final rec = decodePinned(raw);
      if (rec != null && mounted) setState(() => _pinned = rec);
    } catch (_) {
      // Corrupt/absent pin — leave unpinned.
    }
  }

  Future<void> _setPin(Message m) async {
    final body = messageSearchText(m).isNotEmpty
        ? messageSearchText(m)
        : (m.fileName ?? '');
    final encoded = encodePinned(m.id, body);
    setState(() => _pinned = decodePinned(encoded));
    try {
      await ref
          .read(storageProvider)
          .putSetting('pin:${widget.peerHex}', encoded);
    } catch (_) {}
  }

  Future<void> _clearPin() async {
    setState(() => _pinned = null);
    try {
      await ref.read(storageProvider).putSetting('pin:${widget.peerHex}', '');
    } catch (_) {}
  }

  Widget _pinnedBanner(AppL10n l) {
    final scheme = Theme.of(context).colorScheme;
    final p = _pinned!;
    return Material(
      color: scheme.surfaceContainerHighest,
      child: InkWell(
        onTap: () => _jumpToMessage(p.id, maxAttempts: 40),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.push_pin_outlined, size: 18, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l.chatPinnedLabel,
                      style: TextStyle(fontSize: 11, color: scheme.primary),
                    ),
                    Text(p.text, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                tooltip: l.chatMsgUnpin,
                onPressed: _clearPin,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _flash(String id) {
    _highlightTimer?.cancel();
    setState(() => _highlightId = id);
    _highlightTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _highlightId = null);
    });
  }

  void _enterChatSearch() => setState(() => _chatSearching = true);

  void _exitChatSearch() {
    _chatSearchDebounce?.cancel();
    _chatSearchCtl.clear();
    setState(() {
      _chatSearching = false;
      _chatMatches = const [];
      _chatMatchIdx = -1;
      _chatSearchNeedle = '';
    });
  }

  void _onChatQueryChanged(String q) {
    _chatSearchDebounce?.cancel();
    _chatSearchDebounce = Timer(
      const Duration(milliseconds: 300),
      () => _scanChat(q),
    );
  }

  /// Full-conversation match scan; lands on the newest match.
  Future<void> _scanChat(String q) async {
    final needle = q.trim().toLowerCase();
    if (needle.isEmpty) {
      if (mounted) {
        setState(() {
          _chatMatches = const [];
          _chatMatchIdx = -1;
          _chatSearchNeedle = '';
        });
      }
      return;
    }
    List<Message> msgs;
    try {
      msgs = await ref.read(storageProvider).loadMessages(widget.peerHex);
    } catch (_) {
      return;
    }
    final ids = [
      for (final m in msgs)
        if (messageMatchesQuery(m, needle)) m.id,
    ];
    if (!mounted) return;
    setState(() {
      _chatMatches = ids;
      _chatMatchIdx = ids.isEmpty ? -1 : ids.length - 1;
      _chatSearchNeedle = q.trim();
    });
    if (ids.isNotEmpty) _jumpToMessage(ids.last, maxAttempts: 40);
  }

  /// Step to the previous (-1, older) / next (+1, newer) match.
  void _stepChatMatch(int delta) {
    if (_chatMatches.isEmpty) return;
    final next = (_chatMatchIdx + delta).clamp(0, _chatMatches.length - 1);
    if (next == _chatMatchIdx) return;
    setState(() => _chatMatchIdx = next);
    _jumpToMessage(_chatMatches[next], maxAttempts: 40);
  }

  AppBar _chatSearchBar(AppL10n l) {
    final n = _chatMatches.length;
    final pos = n == 0 ? 0 : _chatMatchIdx + 1;
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: _exitChatSearch,
      ),
      title: TextField(
        controller: _chatSearchCtl,
        autofocus: true,
        decoration: InputDecoration(
          hintText: l.searchHint,
          border: InputBorder.none,
        ),
        onChanged: _onChatQueryChanged,
      ),
      actions: [
        Center(child: Text('$pos/$n')),
        IconButton(
          icon: const Icon(Icons.keyboard_arrow_up),
          onPressed: n == 0 ? null : () => _stepChatMatch(-1),
        ),
        IconButton(
          icon: const Icon(Icons.keyboard_arrow_down),
          onPressed: n == 0 ? null : () => _stepChatMatch(1),
        ),
      ],
    );
  }

  /// Scroll the chat so the message [id] is on screen. The list is lazy, so an
  /// off-screen target has no context yet — step upward a couple of viewports
  /// at a time until its bubble mounts, then ensureVisible. If the id is not in
  /// the loaded window at all, grow the window (one page) and retry briefly.
  Future<void> _jumpToMessage(String id, {int maxAttempts = 3}) async {
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final list =
          ref.read(messagesProvider(widget.peerHex)).valueOrNull ?? const [];
      if (list.any((m) => m.id == id)) {
        if (await _scrollUntilVisible(id) && mounted) _flash(id);
        return; // flashed, or in the window but never mounted — stop either way
      }
      // Not in the window: load one more page of history and retry.
      ref.read(chatWindowProvider(widget.peerHex).notifier).state += ref.read(
        chatPageSizeProvider,
      );
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (!mounted) return;
    }
    if (mounted) _snack(AppL10n.of(context).chatQuoteUnavailable);
  }

  /// Step the scroll position upward until [id]'s bubble is built, then align
  /// it. Bounded (~80 viewport-steps) so a pathological state can't spin.
  Future<bool> _scrollUntilVisible(String id) async {
    for (var i = 0; i < 80; i++) {
      final ctx = _bubbleKeys[id]?.currentContext;
      if (ctx != null && ctx.mounted) {
        await Scrollable.ensureVisible(
          ctx,
          alignment: 0.3,
          duration: const Duration(milliseconds: 150),
        );
        return true;
      }
      if (!_scroll.hasClients || _scroll.position.pixels <= 0) return false;
      _scroll.jumpTo(
        (_scroll.position.pixels - _scroll.position.viewportDimension * 2)
            .clamp(0.0, _scroll.position.maxScrollExtent),
      );
      // Let the lazy list build the newly-exposed rows.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return false;
    }
    return false;
  }

  void _toggleSelected(Message m) {
    setState(() {
      if (!_selected.remove(m.id)) _selected.add(m.id);
    });
  }

  void _clearSelection() => setState(_selected.clear);

  @override
  void initState() {
    super.initState();
    // Show/hide the "jump to latest" button as the user scrolls.
    _scroll.addListener(_onScrollChanged);
    // Opening the chat clears its unread badge (marks read up to the latest
    // message). Deferred so the first frame isn't blocked.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(messagingServiceProvider).markRead(widget.peerHex);
        // Apply this chat's retention policy on open, so an expired message
        // disappears even without a periodic sweep (no-op when unlimited).
        ref
            .read(messagingServiceProvider)
            .pruneConversation(NodeId.fromHex(widget.peerHex));
        // Mark this chat as the one on screen so the notification layer
        // suppresses alerts for it while it's open + foreground.
        ref.read(activeConversationProvider.notifier).state = widget.peerHex;
        unawaited(_loadPin());
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
    _chatSearchDebounce?.cancel();
    _highlightTimer?.cancel();
    _chatSearchCtl.dispose();
    _input.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _submit(ContactStatus? status) async {
    final wireValue = _input.toWireValue();
    final text = wireValue.body;
    if (text.trim().isEmpty) return;
    _input.clearWithCustomEmoji();
    // Consume the reply target (if any) for THIS send only.
    final replyToId = _replyingTo?.id;
    if (_replyingTo != null) setState(() => _replyingTo = null);
    // Re-grab focus immediately (before the async send) so typing the next
    // message never requires clicking back into the field.
    _inputFocus.requestFocus();
    final svc = ref.read(messagingServiceProvider);
    if (_saved) {
      // Saved Messages: a purely local note to self, never the wire.
      await svc.saveNote(
        text,
        replyToId: replyToId,
        customEmoji: wireValue.customEmoji,
      );
    } else if (status == ContactStatus.accepted) {
      await svc.sendText(
        _peer,
        text,
        replyToId: replyToId,
        customEmoji: wireValue.customEmoji,
      );
    } else {
      // No contact yet / not accepted — the first message is the request.
      await svc.sendRequest(_peer, text);
    }
    _scrollToBottom(force: true);
    if (mounted) {
      _inputFocus.requestFocus(); // and again after the await settles
    }
  }

  void _startReply(Message m) {
    setState(() => _replyingTo = m);
    _inputFocus.requestFocus();
  }

  /// Toggle a reaction to [m]: tapping the emoji you already set removes it.
  Future<void> _react(Message m, String emoji) async {
    final myHex = ref.read(appControllerProvider).identity?.nodeId.hex;
    final current = ref.read(reactionsProvider(widget.peerHex)).valueOrNull;
    final mine = myHex == null ? null : current?[m.id]?[myHex];
    await ref
        .read(messagingServiceProvider)
        .sendReaction(_peer, m.id, mine == emoji ? '' : emoji);
  }

  /// Display name for a reactor hex: me → "You", the peer → their alias,
  /// anything else (future-proofing) → the short node id.
  String _reactorName(String hex, String? selfHex, AppL10n l) {
    if (hex == selfHex) return l.reactorsYou;
    if (hex == widget.peerHex) {
      final convos = ref.read(conversationsProvider).valueOrNull;
      for (final c in convos ?? const <Conversation>[]) {
        if (c.peer.nodeId.hex == hex) return c.peer.label;
      }
    }
    return NodeId.fromHex(hex).short;
  }

  /// Long-press (or right-click) on a reaction chip: who set what on [m].
  Future<void> _showReactors(Message m) async {
    final l = AppL10n.of(context);
    final forMsg = ref
        .read(reactionsProvider(widget.peerHex))
        .valueOrNull?[m.id];
    if (forMsg == null || forMsg.isEmpty) return;
    final selfHex = ref.read(appControllerProvider).identity?.nodeId.hex;
    await showReactorsSheet(
      context,
      namesByEmoji: {
        for (final e in invertReactions(forMsg).entries)
          e.key: [for (final hex in e.value) _reactorName(hex, selfHex, l)],
      },
    );
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
  Future<void> _pickAttachment(ComposerAttachmentAction action) async {
    switch (action) {
      case ComposerAttachmentAction.camera:
        final captured = await captureComposerMedia(context);
        if (captured == null) {
          if (mounted && !composerCameraSupported) {
            _snack(AppL10n.of(context).composerCameraUnavailable);
          }
          return;
        }
        final source = File(captured.path);
        try {
          final size = await source.length();
          await _attachPlatformFile(
            PlatformFile(name: captured.name, size: size, path: captured.path),
            allowStreaming: false,
          );
        } finally {
          try {
            await source.delete();
          } catch (_) {}
        }
      case ComposerAttachmentAction.photo:
        await _pickAndAttach(type: FileType.image);
      case ComposerAttachmentAction.video:
        await _pickAndAttach(type: FileType.video);
      case ComposerAttachmentAction.file:
        await _pickAndAttach();
      case ComposerAttachmentAction.gif:
        await _pickAndAttach(
          type: FileType.custom,
          allowedExtensions: const ['gif'],
        );
      case ComposerAttachmentAction.voice ||
          ComposerAttachmentAction.videoNote ||
          ComposerAttachmentAction.poll ||
          ComposerAttachmentAction.location:
        // Recording is owned by MessageComposer. Planned entries are disabled.
        return;
    }
  }

  Future<void> _pickAndAttach({
    FileType type = FileType.any,
    List<String>? allowedExtensions,
  }) async {
    // Do NOT force `withData: true`. On Android the picker then tries to load
    // the whole file into a Uint8List up-front, which returns `bytes == null`
    // for large files / SAF content URIs (and risks OOM). Take the cached path
    // and read it ourselves; fall back to `bytes` for platforms with no path
    // (web). The old code did `if (bytes == null) return` SILENTLY — the file
    // just never attached with no feedback ("перестал прикрепляться").
    final picked = await FilePicker.pickFiles(
      type: type,
      allowedExtensions: allowedExtensions,
    );
    final file = picked?.files.firstOrNull;
    if (file == null) return; // cancelled

    await _attachPlatformFile(file);
  }

  Future<void> _attachPlatformFile(
    PlatformFile file, {
    bool allowStreaming = true,
  }) async {
    final l = AppL10n.of(context);
    // Saved Messages has no receiver to stream to — a file note is bounded by
    // the in-RAM path's cap (an honest "too large" instead of a silent drop).
    final canStream = allowStreaming && !_saved;

    // A file too big for the in-RAM path, with a real filesystem path, is
    // STREAMED: read range-by-range off disk so a multi-GB / TB attachment is
    // never loaded whole into memory (readAsBytes would OOM first) — no size
    // ceiling on this path. Without a path (web / some SAF URIs) we can't seek,
    // so fall through to the in-RAM path and its cap.
    final path = file.path;
    if (path != null) {
      // Authoritative size from the FILESYSTEM. file_picker's PlatformFile.size
      // is frequently 0 / stale on Android SAF content URIs — trusting it would
      // wrongly skip streaming and shove a huge file down the in-RAM path, where
      // it trips the cap and is dropped with NOTHING recorded (the observed bug).
      var size = file.size;
      try {
        final fsLen = await File(path).length();
        if (fsLen > 0) size = fsLen;
      } catch (_) {
        /* unreadable length → keep the picker's size */
      }
      if (size > kMaxIncomingFileBytes && !canStream) {
        if (mounted) _snack(l.chatFileTooLarge);
        return;
      }
      if (size > kMaxIncomingFileBytes && canStream) {
        devLog(() => 'xVeil[attach]: ${file.name} size=$size -> stream');
        // Serve-from-source: the sender already HAS this file, so we don't copy
        // or encrypt it — MessagingService reads chunks straight from disk on
        // request via this serialized source (a single-cursor RandomAccessFile,
        // so reads MUST be serialized) and OWNS it (closes it when serving ends).
        final src = await veilSourceOpener(path);
        if (src == null) {
          if (mounted) _snack(l.chatFileUnreadable);
          return;
        }
        try {
          await ref
              .read(messagingServiceProvider)
              .sendFileStreaming(
                _peer,
                file.name,
                size,
                src.read,
                close: src.close,
                // Persist this path so a reoffer after a restart can re-open + re-serve
                // (durable offers). Best-effort — works while the file stays here.
                sourcePath: path,
              );
        } catch (e) {
          devLog(() => 'xVeil[attach]: stream send failed ${file.name}: $e');
          if (mounted) _snack(l.chatFileUnreadable);
        }
        if (mounted) _scrollToBottom(force: true);
        return;
      }
    }

    Uint8List? bytes = file.bytes;
    if (bytes == null && file.path != null) {
      try {
        bytes = await File(file.path!).readAsBytes();
      } catch (e) {
        devLog(
          () =>
              'xVeil[attach]: read failed ${file.name} '
              'path=${file.path}: $e',
        );
      }
    }
    if (bytes == null) {
      devLog(
        () =>
            'xVeil[attach]: ${file.name} UNREADABLE '
            '(path=${file.path}, size=${file.size}) — no bytes, nothing sent',
      );
      if (mounted) _snack(l.chatFileUnreadable);
      return;
    }
    final data = bytes; // promoted non-null for the closures below
    devLog(() => 'xVeil[attach]: ${file.name} size=${data.length} -> sendFile');
    if (data.length > kMaxIncomingFileBytes) {
      if (mounted) _snack(l.chatFileTooLarge);
      return;
    }
    if (_saved) {
      // Saved Messages: a purely local file note — stored encrypted, never
      // on the wire (sendFile would drop it anyway: self isn't a contact).
      await ref
          .read(messagingServiceProvider)
          .saveFileNote(data, file.name, sourcePath: file.path);
    } else {
      await ref
          .read(messagingServiceProvider)
          .sendFile(
            _peer,
            data,
            file.name,
            // For a small VIDEO the platform frame-grabber needs the on-disk
            // source — the bytes alone can't produce a preview frame.
            sourcePath: file.path,
          );
    }
    _scrollToBottom(force: true);
  }

  /// Tap on a DOWNLOADED inline image: open the swipeable media gallery over
  /// every downloaded image of the loaded conversation, positioned on [m].
  void _openImageGallery(Message m) {
    final items = conversationGalleryItems(
      ref.read(messagesProvider(widget.peerHex)).valueOrNull ??
          const <Message>[],
    );
    if (items.isEmpty) return;
    var initial = items.indexWhere((it) => it.id == m.id);
    if (initial < 0) initial = 0;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _MediaGallery(items: items, initialIndex: initial),
      ),
    );
  }

  /// Tap on a HELD video row: the in-app player (decrypted to RAM, served
  /// over the loopback media server — plaintext never touches disk).
  void _openVideoPlayer(Message m) {
    final key = m.fileId ?? m.fileContentId;
    if (key == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => VideoPlayerScreen(fileKey: key, name: m.fileName ?? ''),
      ),
    );
  }

  /// Send a recorded voice clip (from the composer's hold-to-record button).
  void _sendVoiceClip(VoiceClip clip) {
    ref
        .read(messagingServiceProvider)
        .sendVoice(
          _peer,
          clip.bytes,
          clip.durationMs,
          clip.waveform,
          // Tag the note with our UI language so the receiver transcribes it
          // in the language it was spoken in.
          lang: ui.PlatformDispatcher.instance.locale.languageCode,
        );
    _scrollToBottom(force: true);
  }

  /// Send a recorded round video note: grab the first frame as the sidecar
  /// micro-thumb (the receiver renders the circle before downloading), then
  /// ship the clip through the content path.
  Future<void> _sendVnoteClip(VnoteClip clip) async {
    String? thumb;
    final player = VeilVnotePlayer.create(clip.bytes);
    if (player != null) {
      try {
        final f = player.frameAt(0);
        if (f != null) {
          thumb = await makeRgbaThumbB64(f.rgba, f.width, f.height);
        }
      } finally {
        player.dispose();
      }
    }
    await ref
        .read(messagingServiceProvider)
        .sendVideoNote(_peer, clip.bytes, clip.durationMs, thumbB64: thumb);
    _scrollToBottom(force: true);
  }

  /// Handle a sticker-panel pick: a `pack:<id>` result shares that pack to the
  /// chat, otherwise the id is a single sticker to send.
  Future<void> _sendSticker(String result) async {
    if (result.startsWith('pack:')) {
      final packId = result.substring('pack:'.length);
      final ctrl = ref.read(stickerControllerProvider.notifier);
      final blob = await ctrl.packToBlob(packId);
      if (blob == null) return;
      // Preview the first sticker before download.
      final bundle = decodeStickerPack(blob);
      String? thumb;
      if (bundle != null && bundle.images.isNotEmpty) {
        thumb = await makeMessageThumbB64(bundle.images.first);
      }
      await ref
          .read(messagingServiceProvider)
          .sendStickerPack(_peer, blob, firstThumbB64: thumb);
      _scrollToBottom(force: true);
      return;
    }
    final bytes = await ref
        .read(storageProvider)
        .loadFile(stickerFileKey(result));
    if (bytes == null) return;
    await ref.read(messagingServiceProvider).sendSticker(_peer, bytes);
    _scrollToBottom(force: true);
  }

  /// Tap on a file bubble: if we already hold the blob, save it out. For an OFFER
  /// we have not downloaded: a small file downloads into the deniable volume
  /// directly; a LARGE file asks WHERE — the encrypted in-app tier, or a plain
  /// unencrypted file on disk (the bubble flips to "downloaded" for the in-app
  /// case when it completes — messagesProvider re-yields on _signal).
  Future<void> _onTapFile(Message m) async {
    final key = m.fileId ?? m.fileContentId;
    if (key == null) return;
    if (await ref.read(storageProvider).hasFile(key)) {
      await _saveFile(m);
      return;
    }
    // The content hash used to REQUEST the bytes. For an OFFERED incoming file
    // it's fileContentId; for our OWN sent file (served from a source that is
    // now gone) it's fileId — falling back lets us pull our own file back from
    // the recipient (content-addressed: they still hold the identical bytes).
    final cid = m.fileContentId ?? m.fileId;
    if (cid == null) return;
    // Already downloaded UNENCRYPTED to a plain file → OPEN it (it isn't in the
    // app store, so hasFile is false — don't re-offer).
    final saved = await ref
        .read(messagingServiceProvider)
        .contentSavedPath(cid);
    if (saved != null &&
        await _savedFileLooksComplete(saved, expectedSize: m.fileSize)) {
      await _openSavedFile(saved);
      return;
    }
    if ((m.fileSize ?? 0) > kMaxIncomingFileBytes) {
      // A LARGE file: honour this identity's preference — ask, always encrypted,
      // or always unencrypted-to-disk (set in Settings → Files).
      switch (ref
          .read(messagingServiceProvider)
          .fileDownloadPolicy
          .largeFileMode) {
        case LargeFileMode.ask:
          await _showDownloadMenu(m, cid);
        case LargeFileMode.encrypted:
          await _downloadEncrypted(cid);
        case LargeFileMode.open:
          await _downloadUnencrypted(m, cid, warn: false); // settings = consent
      }
    } else {
      await _downloadEncrypted(cid);
    }
  }

  /// Open a previously-saved (unencrypted) file with the OS handler. Desktop uses
  /// the platform opener; on mobile (no generic opener wired) we surface the path.
  Future<void> _openSavedFile(String path) async {
    final l = AppL10n.of(context);
    try {
      if (Platform.isMacOS) {
        await Process.run('open', [path]);
        return;
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [path]);
        return;
      } else if (Platform.isWindows) {
        await Process.run('explorer', [path]);
        return;
      }
    } catch (_) {
      /* fall through to showing the path */
    }
    if (mounted) _snack('${l.chatFileSaved}: $path');
  }

  /// Start an in-app download (encrypted tier / in-volume) + surface a hint if we
  /// had to ask the sender to re-advertise (stale offer after a restart).
  Future<void> _downloadEncrypted(String cid) async {
    final r = await ref
        .read(messagingServiceProvider)
        .downloadContent(_peer, cid);
    if (mounted && r == ContentDownloadResult.requestedReoffer) {
      _snack(AppL10n.of(context).fileRequestingResend);
      _watchDownloadFailure(cid);
    }
  }

  /// After a re-advertise REQUEST, react if it times out (the sender no longer
  /// serves the file): tell the user to ask for a re-send, and delete the empty
  /// destination file an unencrypted download had already created.
  void _watchDownloadFailure(
    String cid, {
    String? deletePath,
    Iterable<String> deletePaths = const [],
  }) {
    final messaging = ref.read(messagingServiceProvider);
    final terminal = Completer<bool>();
    late final StreamSubscription<String> failureSubscription;
    late final StreamSubscription<String> cancellationSubscription;

    failureSubscription = messaging.contentDownloadFailed.listen((failedCid) {
      if (failedCid == cid && !terminal.isCompleted) {
        terminal.complete(true);
      }
    });
    cancellationSubscription = messaging.contentDownloadCancelled.listen((
      cancelledCid,
    ) {
      if (cancelledCid == cid && !terminal.isCompleted) {
        terminal.complete(false);
      }
    });

    terminal.future
        .then((failed) async {
          await failureSubscription.cancel();
          await cancellationSubscription.cancel();
          if (!failed) return;
          for (final path in [?deletePath, ...deletePaths]) {
            try {
              await File(path).delete();
            } catch (_) {
              /* already gone */
            }
          }
          if (mounted) _snack(AppL10n.of(context).fileReofferFailed);
        })
        .catchError((_) {
          /* stream closed before any failure */
        });
  }

  /// Ask where to put a LARGE offered file: the encrypted in-app tier, or a plain
  /// unencrypted file on disk (with a warning).
  Future<void> _showDownloadMenu(Message m, String cid) async {
    final l = AppL10n.of(context);
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.lock_outline),
              title: Text(l.fileSaveEncrypted),
              subtitle: Text(l.fileSaveEncryptedHint),
              onTap: () => Navigator.of(sheet).pop('enc'),
            ),
            ListTile(
              leading: const Icon(Icons.warning_amber_outlined),
              title: Text(l.fileSavePlain),
              subtitle: Text(l.fileSavePlainHint),
              onTap: () => Navigator.of(sheet).pop('plain'),
            ),
          ],
        ),
      ),
    );
    if (choice == 'enc') {
      await _downloadEncrypted(cid);
    } else if (choice == 'plain') {
      await _downloadUnencrypted(m, cid);
    }
  }

  /// Download a large offer UNENCRYPTED, streamed straight to a plaintext file.
  /// [warn] shows the one-off confirmation (the ASK path); it is skipped when the
  /// identity's setting already chose "always unencrypted" (that is the consent).
  /// Desktop: the user picks the path. Mobile: the app documents dir (the save
  /// plugin can't stream to a chosen location there).
  Future<void> _downloadUnencrypted(
    Message m,
    String cid, {
    bool warn = true,
  }) async {
    final l = AppL10n.of(context);
    if (warn) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          content: Text(l.fileSavePlainWarn),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(d).pop(false),
              child: Text(l.actionCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(d).pop(true),
              child: Text(l.fileSavePlainConfirm),
            ),
          ],
        ),
      );
      if (ok != true) return;
      if (!mounted) return;
    }
    final name = _safeDownloadName(m.fileName);
    String? dest;
    if (!Platform.isAndroid && !Platform.isIOS) {
      dest = await FilePicker.saveFile(fileName: name);
    } else {
      dest = '${(await getApplicationDocumentsDirectory()).path}/$name';
    }
    if (dest == null) return; // cancelled
    // Write STRAIGHT to the chosen path — no `.part-` sibling. On a sandboxed
    // macOS release build the NSSavePanel grants a read-write exception for the
    // exact selected path ONLY; a sibling temp file (`dest.part-…`) is outside
    // the sandbox and its open() fails with "Operation not permitted", which
    // silently stranded every large-file save (worked in the sandbox-off debug
    // build, hid the bug). A partial file on failure is cleaned by
    // _watchDownloadFailure(deletePath: dest).
    final raf = await File(dest).open(mode: FileMode.write);
    if (!mounted) {
      await raf.close();
      try {
        await File(dest).delete();
      } catch (_) {}
      return;
    }
    final svc = ref.read(messagingServiceProvider);
    _watchDownloadFailure(
      cid,
      deletePath: dest,
    ); // clean up empty/partial files
    // Snackbar once the streamed plaintext file is fully written.
    svc.contentReceived
        .firstWhere((e) => e.contentId == cid && e.savedToPath != null)
        .then((e) {
          if (mounted) _snack('${l.chatFileSaved}: ${e.savedToPath}');
        })
        .catchError((_) {
          /* stream closed before completion */
        });
    final r = await svc.downloadContentToFile(
      _peer,
      cid,
      dest,
      write: (offset, bytes) async {
        await raf.setPosition(offset);
        await raf.writeFrom(bytes);
      },
      close: () async {
        await raf.close();
      },
    );
    if (mounted && r == ContentDownloadResult.requestedReoffer) {
      _snack(l.fileRequestingResend);
    }
  }

  /// Save a received (or sent) file out of the deniable container to a location
  /// the user picks.
  Future<void> _saveFile(Message m) async {
    final l = AppL10n.of(context);
    final key = m.fileId ?? m.fileContentId;
    if (key == null) return;

    // Large file → STREAM it out of the encrypted store chunk by chunk so a
    // multi-GB blob is never held whole in RAM. Android/iOS file_picker requires
    // all bytes up front for saveFile (a 128 MiB export can OOM the platform
    // MethodChannel), so mobile uses the same app-documents destination as the
    // direct plaintext-download path. Desktop can safely pick an exact path.
    final size = m.fileSize ?? 0;
    if (size > kMaxIncomingFileBytes) {
      final String? dest;
      if (Platform.isAndroid || Platform.isIOS) {
        dest =
            '${(await getApplicationDocumentsDirectory()).path}/${_safeDownloadName(m.fileName)}';
      } else {
        dest = await FilePicker.saveFile(
          fileName: _safeDownloadName(m.fileName),
        );
      }
      if (dest == null) return; // cancelled
      final storage = ref.read(storageProvider);
      final sink = File(dest).openWrite();
      var off = 0;
      try {
        const chunk = 4 * 1024 * 1024;
        while (off < size) {
          final want = (size - off) < chunk ? (size - off) : chunk;
          final part = await storage.readFileRange(key, off, want);
          if (part == null || part.isEmpty) break;
          sink.add(part);
          off += part.length;
        }
      } finally {
        await sink.close();
      }
      if (mounted) {
        _snack(off >= size ? l.chatFileSaved : l.chatFileSaveFailed);
      }
      return;
    }

    final bytes = await ref.read(storageProvider).loadFile(key);
    if (bytes == null) {
      if (mounted) _snack(l.chatFileSaveFailed);
      return;
    }
    // saveFile REQUIRES `bytes` on Android/iOS (it writes the file itself there
    // and returns the path); passing it without bytes threw "bytes parameter is
    // required" and the save did nothing. On desktop `bytes` is accepted too but
    // the plugin only returns a chosen path, so we still write it ourselves.
    final path = await FilePicker.saveFile(
      fileName: _safeDownloadName(m.fileName),
      bytes: bytes,
    );
    if (path == null) return; // cancelled
    try {
      if (!Platform.isAndroid && !Platform.isIOS) {
        await File(path).writeAsBytes(bytes);
      }
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
    final recommendation = parseSpaceRecommendationMessage(m.body) != null;
    final showReactions = ref.read(showReactionsProvider);
    // A file is forwardable only to Saved Messages and only when its blob is
    // already HELD locally (a copy-reference — no re-download). An
    // undownloaded offer honestly gets no forward entry at all.
    final fileKey = m.fileId ?? m.fileContentId;
    final fileHeld =
        m.isFile &&
        fileKey != null &&
        await ref.read(storageProvider).hasFile(fileKey);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      // Scrollable: with reply/forward/select/copy/edit/delete/history/info the
      // action list can exceed a short sheet (small screens / large text).
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Quick-react bar: tap an emoji to (toggle) react to this
              // message. Hidden entirely by the "show reactions" preference.
              if (showReactions) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      for (final e in kQuickReactions)
                        IconButton(
                          icon: Text(e, style: const TextStyle(fontSize: 24)),
                          onPressed: () {
                            Navigator.of(sheet).pop();
                            _react(m, e);
                          },
                        ),
                    ],
                  ),
                ),
                const Divider(height: 1),
              ],
              if (!recommendation)
                ListTile(
                  leading: const Icon(Icons.reply_outlined),
                  title: Text(l.chatMsgReply),
                  onTap: () {
                    Navigator.of(sheet).pop();
                    _startReply(m);
                  },
                ),
              if (!recommendation && (!m.isFile || fileHeld))
                ListTile(
                  leading: const Icon(Icons.forward_outlined),
                  title: Text(l.chatMsgForward),
                  onTap: () {
                    Navigator.of(sheet).pop();
                    _forwardMessages([m]);
                  },
                ),
              if (!recommendation)
                ListTile(
                  leading: Icon(
                    _pinned?.id == m.id
                        ? Icons.push_pin
                        : Icons.push_pin_outlined,
                  ),
                  title: Text(
                    _pinned?.id == m.id ? l.chatMsgUnpin : l.chatMsgPin,
                  ),
                  onTap: () {
                    Navigator.of(sheet).pop();
                    if (_pinned?.id == m.id) {
                      _clearPin();
                    } else {
                      _setPin(m);
                    }
                  },
                ),
              if (!recommendation)
                ListTile(
                  leading: const Icon(Icons.checklist_outlined),
                  title: Text(l.chatMsgSelect),
                  onTap: () {
                    Navigator.of(sheet).pop();
                    _toggleSelected(m);
                  },
                ),
              if (!m.isFile && !recommendation)
                ListTile(
                  leading: const Icon(Icons.copy_outlined),
                  title: Text(l.chatMsgCopy),
                  onTap: () {
                    Navigator.of(sheet).pop();
                    _copyMessage(m);
                  },
                ),
              if (!m.isFile && !recommendation)
                ListTile(
                  leading: const Icon(Icons.copy_all_outlined),
                  title: Text(l.chatMsgCopyMeta),
                  onTap: () {
                    Navigator.of(sheet).pop();
                    _copyMessage(m, withMetadata: true);
                  },
                ),
              if (own && !m.isFile && !recommendation)
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
              if (m.edited && !m.isFile)
                ListTile(
                  leading: const Icon(Icons.history),
                  title: Text(l.chatMsgHistory),
                  onTap: () {
                    Navigator.of(sheet).pop();
                    _showMessageHistory(m);
                  },
                ),
              // Ask the AUTHOR to attest they wrote this incoming message. Only
              // for a peer's text message that isn't already verified.
              if (!own &&
                  !m.isFile &&
                  !recommendation &&
                  m.signature != MessageSignature.verified)
                ListTile(
                  leading: const Icon(Icons.verified_user_outlined),
                  title: Text(l.chatMsgRequestSignature),
                  onTap: () {
                    Navigator.of(sheet).pop();
                    _requestSignature(m);
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
      ),
    );
  }

  /// Ask the message's author to prove they wrote it (opt-in attestation). The
  /// peer's device answers per their policy (prompt / auto / refuse); the result
  /// lands back on this message as a verified/refused/failed badge.
  Future<void> _requestSignature(Message m) async {
    final l = AppL10n.of(context);
    final messenger = ScaffoldMessenger.of(context);
    await ref
        .read(messagingServiceProvider)
        .requestSignature(_peer, m.id, m.body);
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(l.chatSignatureRequested),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// Copy a text message's body to the clipboard. Local-only — nothing leaves
  /// the device, so it carries no anonymity/deniability cost (the user already
  /// holds the plaintext). With [withMetadata], a bracketed header line carries
  /// the message's metadata (time, direction, status, author/seq, id) above the
  /// body — pasteable evidence of what was said, when, by whom.
  Future<void> _copyMessage(Message m, {bool withMetadata = false}) async {
    final l = AppL10n.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final own = m.direction == MessageDirection.outgoing;
    final text = !withMetadata
        ? m.body
        : [
            '[${l.msgInfoTime}: ${formatDateTime(m.timestamp.toLocal())}'
                ' | ${l.msgInfoDirection}: ${own ? l.dirOutgoing : l.dirIncoming}'
                '${own ? ' | ${l.msgInfoStatus}: ${_statusLabel(l, m.status)}' : ''}'
                '${m.edited ? ' | ${l.msgInfoEdited.toLowerCase()}' : ''}'
                '${m.author != null ? ' | ${l.msgInfoAuthor}: ${m.author}' : ''}'
                '${m.seq != null ? ' | ${l.msgInfoSeq}: ${m.seq}' : ''}'
                ' | ${l.msgInfoId}: ${m.id}]',
            m.body,
          ].join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(l.chatMsgCopied),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  /// Forward [msgs] (text only) to a conversation the user picks, attributed to
  /// the ORIGINAL AUTHOR's node id — NOT my private alias for them. The wire
  /// carries the author's node-id hex; each viewer resolves it through THEIR OWN
  /// contacts (their name, or a short id) so my local naming never leaks and the
  /// forward still honestly says WHO wrote it. Attribution only — deliberately
  /// no cryptographic signature (that would make authorship non-repudiable and
  /// break veil's deniability). Sends in on-screen order to the chosen peer.
  Future<void> _forwardMessages(List<Message> msgs) async {
    // Files forward ONLY to Saved Messages, and only when the blob is already
    // held locally — the saved row is a copy-reference to the same stored
    // blob, so nothing is re-sent or re-downloaded. Wire-forwarding a file to
    // another peer is a real (re-)send and stays out of scope here.
    final storage = ref.read(storageProvider);
    final heldFiles = <String>{};
    for (final m in msgs.where((m) => m.isFile)) {
      final key = m.fileId ?? m.fileContentId;
      if (key != null && await storage.hasFile(key)) heldFiles.add(m.id);
    }
    final toForward = msgs
        .where((m) => !m.isFile || heldFiles.contains(m.id))
        .toList(growable: false);
    if (toForward.isEmpty) return;
    if (!mounted) return;
    final myHex = ref.read(appControllerProvider).identity?.nodeId.hex;
    // A files-only forward can land nowhere but Saved — offer only that.
    final target = await _pickForwardTarget(
      savedOnly: toForward.every((m) => m.isFile),
    );
    if (target == null || !mounted) return;
    final svc = ref.read(messagingServiceProvider);
    final toSaved = myHex != null && target.hex == myHex;
    for (final m in toForward) {
      // Preserve the true origin when re-forwarding an already-forwarded
      // message; else the author is me (outgoing) or the conversation peer /
      // recorded event-log author (incoming).
      final originHex =
          m.forwardedFrom ??
          (m.direction == MessageDirection.outgoing
              ? (myHex ?? widget.peerHex)
              : (m.author ?? widget.peerHex));
      if (m.isFile) {
        // Held-file copy-reference; skipped for a wire target (mixed
        // selections keep the pre-existing text-only behavior there).
        if (toSaved) await svc.saveFileNoteRef(m, forwardedFrom: originHex);
      } else if (toSaved) {
        await svc.saveNote(
          m.body,
          forwardedFrom: originHex,
          customEmoji: m.customEmoji,
        );
      } else {
        await svc.sendText(
          target,
          m.body,
          forwardedFrom: originHex,
          customEmoji: m.customEmoji,
        );
      }
    }
    _clearSelection();
    if (mounted) {
      _snack(AppL10n.of(context).chatForwarded);
      // Jump to the target conversation so the user sees it landed.
      if (target.hex != widget.peerHex) context.push('/chat/${target.hex}');
    }
  }

  /// Pick an accepted contact to forward to (a simple searchable list is a later
  /// polish — the accepted set is small). Returns the chosen peer or null.
  /// [savedOnly] hides the contact list — a files-only forward is a local
  /// copy-reference, so Saved Messages is the only honest destination.
  Future<NodeId?> _pickForwardTarget({bool savedOnly = false}) async {
    final l = AppL10n.of(context);
    final convs = await ref.read(storageProvider).loadConversations();
    if (!mounted) return null;
    final myHex = ref.read(appControllerProvider).identity?.nodeId.hex;
    final accepted = savedOnly
        ? const <Conversation>[]
        : convs
              .where(
                (c) =>
                    c.peer.status == ContactStatus.accepted &&
                    c.peer.nodeId.hex != myHex,
              )
              .toList(growable: false);
    return showModalBottomSheet<NodeId>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                l.chatForwardTo,
                style: Theme.of(sheet).textTheme.titleMedium,
              ),
            ),
            // Saved Messages is always a target (forward to self, local).
            if (myHex != null)
              ListTile(
                leading: const CircleAvatar(
                  child: Icon(Icons.bookmark_outline, size: 18),
                ),
                title: Text(l.savedMessages),
                onTap: () => Navigator.of(sheet).pop(NodeId.fromHex(myHex)),
              ),
            if (accepted.isEmpty && myHex == null)
              ListTile(title: Text(l.chatForwardNoTargets))
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final c in accepted)
                      ListTile(
                        leading: CircleAvatar(
                          child: Text(
                            c.peer.label.characters.first.toUpperCase(),
                          ),
                        ),
                        title: Text(c.peer.label),
                        onTap: () => Navigator.of(sheet).pop(c.peer.nodeId),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Copy every selected text message (newline-joined, on-screen order) to the
  /// clipboard, then leave selection mode.
  Future<void> _copySelected(List<Message> all) async {
    final l = AppL10n.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final text = all
        .where((m) => _selected.contains(m.id) && !m.isFile)
        .map((m) => m.body)
        .join('\n');
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    _clearSelection();
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(l.chatMsgCopied),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  /// Delete every selected message. Own messages offer "for everyone"; others
  /// only "for me". A mixed selection asks once and applies the broadest each
  /// message allows (own → for-everyone when chosen; incoming → for-me).
  Future<void> _deleteSelected(List<Message> all) async {
    final l = AppL10n.of(context);
    final chosen = all
        .where((m) => _selected.contains(m.id))
        .toList(growable: false);
    if (chosen.isEmpty) return;
    final anyOwn = chosen.any((m) => m.direction == MessageDirection.outgoing);
    final forEveryone = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l.chatMsgDeleteTitle),
        content: Text(l.chatMsgDeleteSelectedBody(chosen.length)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(null),
            child: Text(l.actionCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(l.chatMsgDeleteForMe),
          ),
          if (anyOwn)
            FilledButton(
              onPressed: () => Navigator.of(dialog).pop(true),
              child: Text(l.chatMsgDeleteForEveryone),
            ),
        ],
      ),
    );
    if (forEveryone == null) return;
    final svc = ref.read(messagingServiceProvider);
    for (final m in chosen) {
      if (forEveryone && m.direction == MessageDirection.outgoing) {
        await svc.deleteForEveryone(m.id);
      } else {
        await svc.deleteMessageLocally(m.id);
      }
    }
    _clearSelection();
  }

  Future<void> _editMessage(Message m) async {
    final l = AppL10n.of(context);
    // The dialog owns its TextEditingController via a StatefulWidget so it is
    // disposed in State.dispose() (after the close transition), not inline
    // right after showDialog returns. Inline disposal races the exit animation:
    // a teardown-driven rebuild (compaction / identity-switch / lock) can
    // rebuild the still-animating TextField against a disposed controller —
    // the "used after being disposed" + _dependents.isEmpty red screen.
    final edited = await showDialog<CustomEmojiWireValue>(
      context: context,
      builder: (_) => _EditCustomEmojiDialog(
        message: m,
        title: l.chatEditTitle,
        saveLabel: l.chatEditSave,
        cancelLabel: l.actionCancel,
      ),
    );
    if (edited == null || edited.body.isEmpty) return;
    if (edited.body == m.body &&
        _sameCustomEmoji(edited.customEmoji, m.customEmoji)) {
      return;
    }
    if (!mounted) return; // teardown may have unmounted us during the dialog
    await ref
        .read(messagingServiceProvider)
        .editOwnMessage(m.id, edited.body, customEmoji: edited.customEmoji);
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
      case _ChatMenuAction.rename:
        await _renameContact();
      case _ChatMenuAction.pin:
        await svc.setContactPinned(_peer, true);
      case _ChatMenuAction.unpin:
        await svc.setContactPinned(_peer, false);
      case _ChatMenuAction.mute:
        if (mounted) await pickMuteDuration(context, ref, _peer);
      case _ChatMenuAction.unmute:
        await svc.setContactMutedUntil(_peer, null);
      case _ChatMenuAction.retention:
        await _pickRetention();
      case _ChatMenuAction.communication:
        final contact = ref.read(contactProvider(widget.peerHex)).value;
        if (contact != null && mounted) {
          await showConversationActions(context, ref, contact);
        }
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

  /// Pick this conversation's auto-delete window (presets + custom days) — shared
  /// with the chats-list management sheet so both offer the same picker.
  Future<void> _pickRetention() async {
    final current = ref
        .read(contactProvider(widget.peerHex))
        .value
        ?.retentionDays;
    await pickRetention(context, ref, _peer, current);
  }

  /// Set or clear a LOCAL alias for this contact. Blank input clears it (falls
  /// back to the short node id). Never leaves the device.
  Future<void> _renameContact() async {
    final l = AppL10n.of(context);
    final current = ref.read(contactProvider(widget.peerHex)).value?.name ?? '';
    final newName = await showDialog<String>(
      context: context,
      builder: (_) => _EditMessageDialog(
        initial: current,
        title: l.chatRenameTitle,
        saveLabel: l.actionSave,
        cancelLabel: l.actionCancel,
      ),
    );
    if (newName == null) return; // cancelled
    if (!mounted) return;
    await ref.read(messagingServiceProvider).setContactName(_peer, newName);
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

  /// Erase this whole conversation (messages + contact) from THIS device. A
  /// local, deniable wipe by default; the shared dialog offers the OPT-IN
  /// "notify the peer" farewell. After it, [_peer] is unknown again, so we pop
  /// back to the chat list.
  Future<void> _deleteConversation() async {
    final navigator = Navigator.of(context);
    final choice = await confirmChatDeleteDialog(context);
    if (choice == null) return;
    await ref
        .read(messagingServiceProvider)
        .deleteConversation(_peer, notifyPeer: choice.notify);
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
              _InfoRow(
                label: l.msgInfoDirection,
                value: own ? l.dirOutgoing : l.dirIncoming,
              ),
              _InfoRow(
                label: l.msgInfoTime,
                value: formatDateTime(m.timestamp.toLocal()),
              ),
              if (own)
                _InfoRow(
                  label: l.msgInfoStatus,
                  value: _statusLabel(l, m.status),
                ),
              if (m.edited)
                _InfoRow(label: l.msgInfoEdited, value: l.msgInfoYes),
              if (m.isFile && m.fileName != null)
                _InfoRow(label: l.msgInfoFile, value: m.fileName!),
              if (m.fileSize != null)
                _InfoRow(label: l.msgInfoSize, value: formatBytes(m.fileSize!)),
              // Event-log identity: the authenticated originator + its per-author
              // sequence — the convergent cross-device key (§15). Null on legacy
              // rows written before the event-log foundation.
              if (m.author != null)
                _InfoRow(label: l.msgInfoAuthor, value: m.author!),
              if (m.seq != null)
                _InfoRow(label: l.msgInfoSeq, value: '${m.seq}'),
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

  /// Read-only edit-history sheet: every retained version of [m], oldest-first,
  /// each labelled original/edited with its time. Local — nothing leaves the
  /// device; the versions are scrubbed by clear-history / retention / panic.
  Future<void> _showMessageHistory(Message m) async {
    final l = AppL10n.of(context);
    final theme = Theme.of(context);
    final versions = await ref
        .read(storageProvider)
        .loadMessageHistory(widget.peerHex, m.id);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l.chatMsgHistory, style: theme.textTheme.titleMedium),
              const SizedBox(height: 12),
              if (versions.isEmpty)
                Text(l.chatHistoryEmpty)
              else
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final v in versions)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${v.isOriginal ? l.chatHistoryOriginal : l.chatHistoryEdited}'
                                ' · ${formatDateTime(v.timestamp.toLocal())}',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 2),
                              SelectableText(v.body),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

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
    ref.read(chatWindowProvider(widget.peerHex).notifier).state += ref.read(
      chatPageSizeProvider,
    );
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
    final contact = ref.watch(contactProvider(widget.peerHex)).value;
    final status = contact?.status;
    // Saved Messages = a chat with yourself (peer == our own node id). Purely
    // local: notes append without the wire, and the consent/call UI is hidden.
    final myHex = ref.watch(
      appControllerProvider.select((s) => s.identity?.nodeId.hex),
    );
    _saved = myHex != null && myHex == widget.peerHex;
    // Show the local alias when set, else the short node id (Contact.label).
    final title = _saved ? l.savedMessages : (contact?.label ?? _peer.short);
    ref.listen(messagesProvider(widget.peerHex), (_, _) => _scrollToBottom());

    final selectionBar = _selecting
        ? AppBar(
            leading: IconButton(
              icon: const Icon(Icons.close),
              onPressed: _clearSelection,
            ),
            title: Text('${_selected.length}'),
            actions: [
              IconButton(
                tooltip: l.chatMsgCopy,
                icon: const Icon(Icons.copy_outlined),
                onPressed: () =>
                    _copySelected(messages.valueOrNull ?? const []),
              ),
              IconButton(
                tooltip: l.chatMsgForward,
                icon: const Icon(Icons.forward_outlined),
                onPressed: () => _forwardMessages(
                  (messages.valueOrNull ?? const [])
                      .where((m) => _selected.contains(m.id))
                      .toList(),
                ),
              ),
              IconButton(
                tooltip: l.chatMsgDelete,
                icon: const Icon(Icons.delete_outline),
                onPressed: () =>
                    _deleteSelected(messages.valueOrNull ?? const []),
              ),
            ],
          )
        : null;

    return Scaffold(
      appBar:
          selectionBar ??
          (_chatSearching ? _chatSearchBar(l) : null) ??
          AppBar(
            title: Row(
              children: [
                CircleAvatar(
                  radius: 16,
                  child: _saved
                      ? const Icon(Icons.bookmark_outline, size: 18)
                      : Text(title.characters.first.toUpperCase()),
                ),
                const SizedBox(width: 12),
                // Local alias first; the verified @nickname (when this
                // contact was added by name, or a binding is stored) goes
                // UNDER it — the alias always outranks the network name.
                // A binding whose resolve no longer matches the pinned node
                // id gets a warning: the name changed owners, the contact
                // did NOT re-point (design: «Безопасность перехвата»).
                Expanded(
                  child: Builder(
                    builder: (_) {
                      final nick = _saved
                          ? null
                          : ref
                                .watch(peerNicknameProvider(widget.peerHex))
                                .valueOrNull;
                      if (nick == null) {
                        return Text(title, overflow: TextOverflow.ellipsis);
                      }
                      final theme = Theme.of(context);
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(title, overflow: TextOverflow.ellipsis),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  '@${nick.name}',
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: nick.ownerChanged
                                        ? theme.colorScheme.error
                                        : theme.colorScheme.primary,
                                  ),
                                ),
                              ),
                              if (nick.ownerChanged) ...[
                                const SizedBox(width: 4),
                                Tooltip(
                                  message: l.nicknameOwnerChanged,
                                  child: Icon(
                                    Icons.warning_amber_rounded,
                                    size: 14,
                                    color: theme.colorScheme.error,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.search),
                tooltip: l.searchHint,
                onPressed: _enterChatSearch,
              ),
              // Start a call — only an accepted contact can be dialled (never
              // in Saved Messages). Picks the media set; the CallService FSM
              // sends the offer + negotiates the path.
              if (!_saved && status == ContactStatus.accepted)
                PopupMenuButton<CallMedia>(
                  icon: const Icon(Icons.call),
                  tooltip: l.callStartTooltip,
                  onSelected: (m) =>
                      ref.read(callServiceProvider).placeCall(_peer, m),
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: const CallMedia(audio: true),
                      child: Row(
                        children: [
                          const Icon(Icons.call, size: 18),
                          const SizedBox(width: 12),
                          Text(l.callAudio),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: const CallMedia(audio: true, video: true),
                      child: Row(
                        children: [
                          const Icon(Icons.videocam, size: 18),
                          const SizedBox(width: 12),
                          Text(l.callVideo),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: const CallMedia(audio: true, screen: true),
                      child: Row(
                        children: [
                          const Icon(Icons.screen_share, size: 18),
                          const SizedBox(width: 12),
                          Text(l.callScreen),
                        ],
                      ),
                    ),
                  ],
                ),
              // No rename/block/mute/delete-conversation on Saved Messages —
              // there's no peer to act on. "Clear history" stays useful but
              // the whole menu is hidden for a clean self-chat in v1.
              if (!_saved)
                PopupMenuButton<_ChatMenuAction>(
                  onSelected: (a) => _onMenuAction(a, status),
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: _ChatMenuAction.rename,
                      child: Text(l.chatMenuRename),
                    ),
                    // Pin/unpin this conversation to the top of the chat list.
                    if (contact?.pinned ?? false)
                      PopupMenuItem(
                        value: _ChatMenuAction.unpin,
                        child: Text(l.chatMenuUnpin),
                      )
                    else
                      PopupMenuItem(
                        value: _ChatMenuAction.pin,
                        child: Text(l.chatMenuPin),
                      ),
                    // Mute/unmute local notifications for this conversation.
                    if (contact?.muted ?? false)
                      PopupMenuItem(
                        value: _ChatMenuAction.unmute,
                        child: Text(l.chatMenuUnmute),
                      )
                    else
                      PopupMenuItem(
                        value: _ChatMenuAction.mute,
                        child: Text(l.chatMenuMute),
                      ),
                    PopupMenuItem(
                      value: _ChatMenuAction.retention,
                      child: Text(l.chatMenuRetention),
                    ),
                    PopupMenuItem(
                      value: _ChatMenuAction.communication,
                      child: Text(l.chatMenuCommunicationSettings),
                    ),
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
      // "Jump to latest": appears once the user is a screenful+ away from the
      // bottom (getting back from deep history is otherwise a long drag).
      floatingActionButton: _awayFromBottom
          ? FloatingActionButton.small(
              onPressed: () => _scrollToBottom(force: true),
              child: const Icon(Icons.keyboard_double_arrow_down),
            )
          : null,
      body: Column(
        children: [
          if (_pinned != null) _pinnedBanner(l),
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
                  // A search hit (or external reference) to land on: give the
                  // bottom-scroll a frame, then walk back to the target. A
                  // deep hit may live many pages up — allow a generous but
                  // bounded number of window growths.
                  final target = widget.initialJumpTo;
                  if (target != null) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) _jumpToMessage(target, maxAttempts: 40);
                    });
                  }
                }
                // A full page came back ⇒ older messages likely exist ⇒ offer
                // "load earlier" as the first item. (Heuristic: if fewer than a
                // full window returned, this is the whole conversation.)
                final hasMore = list.length >= window;
                // id → message, so a reply bubble can resolve + render its quote.
                final byId = {for (final m in list) m.id: m};
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
                    final m = list[hasMore ? i - 1 : i];
                    // A chatDeleted farewell marker renders as a centered
                    // system notice, not a peer bubble (nobody typed it).
                    if (m.direction == MessageDirection.incoming &&
                        isChatDeletedMarker(m.body)) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Text(
                            l.chatDeletedByPeer,
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      );
                    }
                    final bubble = _Bubble(
                      key: _bubbleKey(m.id),
                      message: m,
                      quoted: m.replyToId == null ? null : byId[m.replyToId],
                      selected: _selected.contains(m.id),
                      selecting: _selecting,
                      onTapFile: _onTapFile,
                      onOpenImage: _openImageGallery,
                      onPlayVideo: _openVideoPlayer,
                      onLongPress: _showMessageActions,
                      onToggleReaction: _react,
                      onShowReactors: _showReactors,
                      onTap: _selecting ? () => _toggleSelected(m) : null,
                      onTapQuote: m.replyToId == null
                          ? null
                          : () => _jumpToMessage(m.replyToId!),
                      highlight: _chatSearchNeedle.isEmpty
                          ? null
                          : _chatSearchNeedle,
                    );
                    // Flash the just-landed message (search hit / quote jump)
                    // so the eye finds it; fades back via AnimatedContainer.
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 400),
                      color: m.id == _highlightId
                          ? Theme.of(
                              context,
                            ).colorScheme.primary.withValues(alpha: 0.14)
                          : Colors.transparent,
                      child: bubble,
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
    // Saved Messages: always a plain composer (no consent flow) — notes append
    // locally via _submit's _saved branch.
    if (_saved) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_replyingTo != null)
            _ReplyBanner(
              message: _replyingTo!,
              onCancel: () => setState(() => _replyingTo = null),
            ),
          MessageComposer(
            controller: _input,
            focusNode: _inputFocus,
            hint: l.savedNoteHint,
            onSend: () => _submit(status),
            mentionTargets: [_peer],
            // File notes: the paperclip stores the pick LOCALLY (saveFileNote
            // — never the wire). Voice/vnote/sticker notes are a later polish.
            onAttachmentAction: _pickAttachment,
          ),
        ],
      );
    }
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
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_replyingTo != null)
              _ReplyBanner(
                message: _replyingTo!,
                onCancel: () => setState(() => _replyingTo = null),
              ),
            MessageComposer(
              controller: _input,
              focusNode: _inputFocus,
              hint: l.chatNewMessageHint,
              onSend: () => _submit(status),
              mentionTargets: [_peer],
              onAttachmentAction: _pickAttachment,
              onVoice: _sendVoiceClip,
              onVideoNote: _sendVnoteClip,
              onSticker: _sendSticker,
            ),
          ],
        );
      case null:
        return MessageComposer(
          controller: _input,
          focusNode: _inputFocus,
          hint: l.chatRequestHint,
          onSend: () => _submit(status),
          mentionTargets: [_peer],
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
enum _ChatMenuAction {
  rename,
  pin,
  unpin,
  mute,
  unmute,
  retention,
  communication,
  block,
  unblock,
  clear,
  delete,
}

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

/// Compact human size for a file offer ("3.2 MB"). Binary units, one source.
String _formatBytes(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
  if (b < 1024 * 1024 * 1024) {
    return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

Future<bool> _savedFileLooksComplete(String path, {int? expectedSize}) async {
  try {
    final f = File(path);
    if (!await f.exists()) return false;
    final len = await f.length();
    if (expectedSize != null && expectedSize > 0) {
      return len == expectedSize;
    }
    return len > 0;
  } catch (_) {
    return false;
  }
}

/// The one-line preview text for a quoted/replied message (file → its name).
String _quotePreview(AppL10n l, Message m) =>
    m.isFile ? (m.fileName ?? l.chatFileLabel) : m.body;

/// Banner above the composer while replying: a leading accent bar, the quoted
/// preview, and an X to cancel the reply.
class _ReplyBanner extends StatelessWidget {
  const _ReplyBanner({required this.message, required this.onCancel});
  final Message message;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
        child: Row(
          children: [
            Icon(Icons.reply, size: 18, color: scheme.primary),
            const SizedBox(width: 8),
            Container(width: 3, height: 32, color: scheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    l.chatReplyingTo,
                    style: Theme.of(
                      context,
                    ).textTheme.labelSmall?.copyWith(color: scheme.primary),
                  ),
                  Text(
                    _quotePreview(l, message),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              onPressed: onCancel,
            ),
          ],
        ),
      ),
    );
  }
}

/// The quoted-message preview shown INSIDE a reply bubble (accent bar + one
/// line). [quoted] is null when the referenced message is deleted or scrolled
/// out of the loaded window — then a generic stub renders.
class _QuoteBlock extends StatelessWidget {
  const _QuoteBlock({required this.quoted, required this.outgoing});
  final Message? quoted;
  final bool outgoing;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final accent = outgoing ? scheme.onPrimaryContainer : scheme.primary;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.only(left: 8),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: accent, width: 3)),
      ),
      child: Text(
        quoted == null ? l.chatQuoteUnavailable : _quotePreview(l, quoted!),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
          fontStyle: quoted == null ? FontStyle.italic : null,
        ),
      ),
    );
  }
}
