import 'dart:async';
import 'dart:convert' show base64Decode;
import 'dart:io';
import 'dart:ui' as ui show ImageFilter, PlatformDispatcher, Image;

import 'package:file_picker/file_picker.dart';
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
import '../../domain/call_signal.dart';
import '../../domain/chat.dart';
import '../../domain/file_download_policy.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_controller.dart';
import '../../state/call_service.dart';
import '../../state/chat_page_size_controller.dart';
import '../../state/messaging.dart';
import '../../state/nickname_peers.dart';
import '../../state/notifications.dart';
import '../../state/providers.dart';
import '../../state/reactions_visibility_controller.dart';
import '../../state/sticker_message.dart';
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
import 'emoji_panel.dart';
import 'reactors_sheet.dart';
import 'vnote_preview.dart';
import 'sticker_panel.dart';
import 'video_player_screen.dart';

/// The quick-react emoji bar shown atop the message-actions sheet.
const kQuickReactions = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

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
    final body = m.body.isNotEmpty ? m.body : (m.fileName ?? '');
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
    final text = _input.text;
    if (text.trim().isEmpty) return;
    _input.clear();
    // Consume the reply target (if any) for THIS send only.
    final replyToId = _replyingTo?.id;
    if (_replyingTo != null) setState(() => _replyingTo = null);
    // Re-grab focus immediately (before the async send) so typing the next
    // message never requires clicking back into the field.
    _inputFocus.requestFocus();
    final svc = ref.read(messagingServiceProvider);
    if (_saved) {
      // Saved Messages: a purely local note to self, never the wire.
      await svc.saveNote(text, replyToId: replyToId);
    } else if (status == ContactStatus.accepted) {
      await svc.sendText(_peer, text, replyToId: replyToId);
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
    final forMsg =
        ref.read(reactionsProvider(widget.peerHex)).valueOrNull?[m.id];
    if (forMsg == null || forMsg.isEmpty) return;
    final selfHex = ref.read(appControllerProvider).identity?.nodeId.hex;
    await showReactorsSheet(context, namesByEmoji: {
      for (final e in invertReactions(forMsg).entries)
        e.key: [for (final hex in e.value) _reactorName(hex, selfHex, l)],
    });
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
    // Do NOT force `withData: true`. On Android the picker then tries to load
    // the whole file into a Uint8List up-front, which returns `bytes == null`
    // for large files / SAF content URIs (and risks OOM). Take the cached path
    // and read it ourselves; fall back to `bytes` for platforms with no path
    // (web). The old code did `if (bytes == null) return` SILENTLY — the file
    // just never attached with no feedback ("перестал прикрепляться").
    final picked = await FilePicker.pickFiles();
    final file = picked?.files.firstOrNull;
    if (file == null) return; // cancelled

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
      if (size > kMaxIncomingFileBytes) {
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
    await ref.read(messagingServiceProvider).sendFile(
          _peer,
          data,
          file.name,
          // For a small VIDEO the platform frame-grabber needs the on-disk
          // source — the bytes alone can't produce a preview frame.
          sourcePath: file.path,
        );
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
        builder: (_) => VideoPlayerScreen(
          fileKey: key,
          name: m.fileName ?? '',
        ),
      ),
    );
  }

  /// Send a recorded voice clip (from the composer's hold-to-record button).
  void _sendVoiceClip(VoiceClip clip) {
    ref.read(messagingServiceProvider).sendVoice(
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
    await ref.read(messagingServiceProvider).sendVideoNote(
          _peer,
          clip.bytes,
          clip.durationMs,
          thumbB64: thumb,
        );
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
    final bytes =
        await ref.read(storageProvider).loadFile(stickerFileKey(result));
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
    ref
        .read(messagingServiceProvider)
        .contentDownloadFailed
        .firstWhere((c) => c == cid)
        .then((_) async {
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
    final name = m.fileName ?? 'file';
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

    // Large file on DESKTOP → STREAM it to the chosen path (decrypt chunk by
    // chunk) so a multi-GB blob is never held whole in RAM. (On mobile the save
    // plugin wants the bytes up-front, so the small/in-RAM path below is used.)
    final size = m.fileSize ?? 0;
    if (size > kMaxIncomingFileBytes &&
        !Platform.isAndroid &&
        !Platform.isIOS) {
      final dest = await FilePicker.saveFile(fileName: m.fileName ?? 'file');
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
      fileName: m.fileName ?? 'file',
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
    final showReactions = ref.read(showReactionsProvider);
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
              ListTile(
                leading: const Icon(Icons.reply_outlined),
                title: Text(l.chatMsgReply),
                onTap: () {
                  Navigator.of(sheet).pop();
                  _startReply(m);
                },
              ),
              if (!m.isFile)
                ListTile(
                  leading: const Icon(Icons.forward_outlined),
                  title: Text(l.chatMsgForward),
                  onTap: () {
                    Navigator.of(sheet).pop();
                    _forwardMessages([m]);
                  },
                ),
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
              ListTile(
                leading: const Icon(Icons.checklist_outlined),
                title: Text(l.chatMsgSelect),
                onTap: () {
                  Navigator.of(sheet).pop();
                  _toggleSelected(m);
                },
              ),
              if (!m.isFile)
                ListTile(
                  leading: const Icon(Icons.copy_outlined),
                  title: Text(l.chatMsgCopy),
                  onTap: () {
                    Navigator.of(sheet).pop();
                    _copyMessage(m);
                  },
                ),
              if (!m.isFile)
                ListTile(
                  leading: const Icon(Icons.copy_all_outlined),
                  title: Text(l.chatMsgCopyMeta),
                  onTap: () {
                    Navigator.of(sheet).pop();
                    _copyMessage(m, withMetadata: true);
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
              if (!own && !m.isFile && m.signature != MessageSignature.verified)
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
    final toForward = msgs.where((m) => !m.isFile).toList(growable: false);
    if (toForward.isEmpty) return;
    final myHex = ref.read(appControllerProvider).identity?.nodeId.hex;
    final target = await _pickForwardTarget();
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
      if (toSaved) {
        await svc.saveNote(m.body, forwardedFrom: originHex);
      } else {
        await svc.sendText(target, m.body, forwardedFrom: originHex);
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
  Future<NodeId?> _pickForwardTarget() async {
    final l = AppL10n.of(context);
    final convs = await ref.read(storageProvider).loadConversations();
    if (!mounted) return null;
    final myHex = ref.read(appControllerProvider).identity?.nodeId.hex;
    final accepted = convs
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
          _Composer(
            controller: _input,
            focusNode: _inputFocus,
            hint: l.savedNoteHint,
            onSend: () => _submit(status),
            // v1 notes are text-only (matches forward-to-saved, which skips
            // files); file notes land with the media-message work.
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
            _Composer(
              controller: _input,
              focusNode: _inputFocus,
              hint: l.chatNewMessageHint,
              onSend: () => _submit(status),
              onAttach: _attach,
              onVoice: _sendVoiceClip,
              onVideoNote: _sendVnoteClip,
              onSticker: _sendSticker,
            ),
          ],
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

// isImageFileName moved to state/thumbnail.dart (shared with the send path's
// thumb generation) and re-exported via the import above.

/// Type-specific icon for a document file row (media epic: "документы —
/// иконка типа"). Pure extension→icon mapping, unit-tested; anything
/// unrecognized keeps the generic file icon.
IconData documentIcon(String? name) {
  final ext = FileDownloadPolicy.extensionOf(name);
  return switch (ext) {
    'pdf' => Icons.picture_as_pdf_outlined,
    'zip' || 'rar' || '7z' || 'tar' || 'gz' || 'xz' || 'bz2' =>
      Icons.folder_zip_outlined,
    'mp3' || 'wav' || 'ogg' || 'opus' || 'm4a' || 'flac' || 'aac' =>
      Icons.audiotrack_outlined,
    'mp4' || 'mov' || 'mkv' || 'webm' || 'avi' => Icons.movie_outlined,
    'doc' || 'docx' || 'odt' || 'rtf' => Icons.description_outlined,
    'xls' || 'xlsx' || 'ods' || 'csv' => Icons.table_chart_outlined,
    'ppt' || 'pptx' || 'odp' => Icons.slideshow_outlined,
    'txt' || 'md' || 'log' => Icons.article_outlined,
    'apk' => Icons.android_outlined,
    _ => Icons.insert_drive_file_outlined,
  };
}

/// Inline preview for a downloaded image file: a rounded, bounded thumbnail
/// that opens a full-screen zoomable viewer on tap. Bytes come from the
/// encrypted container (loadFile), so nothing hits disk in the clear.
/// Decode a message's embedded micro-thumb ('tb'), or null when absent or
/// corrupt (a hostile field must fall back to the plain row, never throw).
Uint8List? _decodeThumbB64(String? tb) {
  if (tb == null) return null;
  try {
    return base64Decode(tb);
  } catch (_) {
    return null;
  }
}

/// A shared sticker pack: an install card (first-sticker thumb + name/count +
/// an Install button once the blob is held; a download affordance before).
/// Installing decodes the STKP1 blob into a new local pack.
class _StickerPackCard extends ConsumerStatefulWidget {
  const _StickerPackCard({
    required this.fileKey,
    required this.thumbB64,
    required this.downloaded,
    this.progress,
    this.onDownload,
  });

  final String fileKey;
  final String? thumbB64;
  final bool downloaded;
  final double? progress;
  final VoidCallback? onDownload;

  @override
  ConsumerState<_StickerPackCard> createState() => _StickerPackCardState();
}

class _StickerPackCardState extends ConsumerState<_StickerPackCard> {
  bool _installing = false;
  int? _installed;

  Future<void> _install() async {
    setState(() => _installing = true);
    try {
      final bytes =
          await ref.read(storageProvider).loadFile(widget.fileKey);
      if (bytes == null) return;
      final n =
          await ref.read(stickerControllerProvider.notifier).installPack(bytes);
      if (mounted) setState(() => _installed = n);
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final thumb = _decodeThumbB64(widget.thumbB64);
    return SizedBox(
      width: 220,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 48,
            height: 48,
            child: thumb != null
                ? Image.memory(thumb, fit: BoxFit.contain)
                : Icon(Icons.sticky_note_2_outlined,
                    color: scheme.onSurfaceVariant),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(l.stickerPackTitle,
                    style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 4),
                if (_installed != null)
                  Text(l.stickerImported(_installed!),
                      style: Theme.of(context).textTheme.labelSmall)
                else if (_installing)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else if (!widget.downloaded)
                  (widget.progress != null
                      ? SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            value: widget.progress == 0
                                ? null
                                : widget.progress,
                          ),
                        )
                      : TextButton(
                          onPressed: widget.onDownload,
                          child: Text(l.stickerPackDownload),
                        ))
                else
                  FilledButton.tonal(
                    onPressed: _install,
                    child: Text(l.stickerPackInstall),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A sticker: the image itself, naked (the bubble adds no chrome for sticker
/// messages). Until the blob lands, the blurred sidecar micro-thumb (or a
/// progress ring) stands in — stickers are small and auto-download, so this
/// is a blink. Animated WebP animates for free via Image.memory.
class _StickerContent extends ConsumerWidget {
  const _StickerContent({
    required this.fileKey,
    required this.thumbB64,
    this.progress,
  });

  final String fileKey;
  final String? thumbB64;
  final double? progress;

  static const double _side = 160;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final thumb = _decodeThumbB64(thumbB64);
    return SizedBox(
      width: _side,
      height: _side,
      child: fileKey.isEmpty
          ? _placeholder(context, thumb)
          : FutureBuilder<Uint8List?>(
              future: ref.read(storageProvider).loadFile(fileKey),
              builder: (context, snap) {
                final bytes = snap.data;
                if (bytes == null) return _placeholder(context, thumb);
                return Image.memory(
                  bytes,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.medium,
                  errorBuilder: (_, _, _) => _placeholder(context, thumb),
                );
              },
            ),
    );
  }

  Widget _placeholder(BuildContext context, Uint8List? thumb) {
    return Stack(
      fit: StackFit.expand,
      alignment: Alignment.center,
      children: [
        if (thumb != null)
          ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6),
            child: Image.memory(thumb, fit: BoxFit.contain),
          )
        else
          ColoredBox(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
          ),
        if (progress != null)
          Center(
            child: SizedBox(
              width: 32,
              height: 32,
              child: CircularProgressIndicator(
                value: progress == 0 ? null : progress,
                strokeWidth: 3,
              ),
            ),
          ),
      ],
    );
  }
}

/// Round video note. Before download: the first-frame micro-thumb from the
/// `vn1:` sidecar in a circle + a download affordance. Downloaded: tap plays
/// INLINE — live frames fill the circle (pulled at the audio position), a
/// progress ring runs around it, tap again pauses. Duration below turns into
/// a live clock while active.
class _VnoteBubble extends ConsumerWidget {
  const _VnoteBubble({
    required this.messageId,
    required this.fileKey,
    required this.sidecar,
    required this.outgoing,
    required this.downloaded,
    this.progress,
    this.onDownload,
  });

  final String messageId;
  final String fileKey;
  final VnoteSidecar? sidecar;
  final bool outgoing;
  final bool downloaded;
  final double? progress;
  final VoidCallback? onDownload;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final onBubble = outgoing ? scheme.onPrimary : scheme.onSurface;
    final thumb = _decodeThumbB64(sidecar?.thumbB64);
    final play = ref.watch(vnotePlayControllerProvider);
    final active = downloaded && play.isActive(messageId);
    final playing = downloaded && play.isPlaying(messageId);

    void onTap() {
      if (!downloaded) {
        onDownload?.call();
        return;
      }
      ref.read(vnotePlayControllerProvider.notifier).toggle(messageId, fileKey);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onTap,
          child: SizedBox(
            width: 184,
            height: 184,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Padding(
                  padding: const EdgeInsets.all(2),
                  child: ClipOval(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (active)
                          VnotePreview(
                            frameListenable: ref
                                .read(vnotePlayControllerProvider.notifier)
                                .frame,
                          )
                        else if (thumb != null)
                          Image.memory(thumb,
                              fit: BoxFit.cover,
                              filterQuality: FilterQuality.low)
                        else
                          ColoredBox(color: scheme.surfaceContainerHighest),
                        // Dim + center affordance only when NOT playing (the
                        // playing circle is clean video, Telegram-style).
                        if (!playing) ...[
                          ColoredBox(
                              color: Colors.black.withValues(alpha: 0.18)),
                          Center(
                            child: progress != null
                                ? SizedBox(
                                    width: 36,
                                    height: 36,
                                    child: CircularProgressIndicator(
                                      value: progress == 0 ? null : progress,
                                      strokeWidth: 3,
                                      color: Colors.white,
                                    ),
                                  )
                                : Icon(
                                    downloaded
                                        ? Icons.play_arrow
                                        : Icons.download,
                                    color: Colors.white,
                                    size: 44,
                                  ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                // Playback progress ring around the circle.
                if (active)
                  CircularProgressIndicator(
                    value: play.progress,
                    strokeWidth: 2.5,
                    color: scheme.primary,
                    backgroundColor: onBubble.withValues(alpha: 0.15),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          active
              ? formatVoiceDuration(Duration(milliseconds: play.positionMs))
              : formatVoiceDuration(sidecar?.duration),
          style: Theme.of(context)
              .textTheme
              .labelSmall
              ?.copyWith(color: onBubble.withValues(alpha: 0.8)),
        ),
      ],
    );
  }
}

/// Voice message: a play/download control + the clip waveform + duration,
/// rendered from the `vw1:` sidecar that travelled in the message (no decode
/// needed to show it). Play is enabled only once the small Opus blob is held
/// (it auto-downloads under the cap); while fetching it shows a progress ring,
/// otherwise a download affordance.
class _VoiceBubble extends ConsumerWidget {
  const _VoiceBubble({
    required this.messageId,
    required this.fileKey,
    required this.sidecar,
    required this.outgoing,
    required this.downloaded,
    this.progress,
    this.onDownload,
  });

  final String messageId;
  final String fileKey;
  final VoiceSidecar? sidecar;
  final bool outgoing;
  final bool downloaded;
  final double? progress;
  final VoidCallback? onDownload;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final onBubble = outgoing ? scheme.onPrimary : scheme.onSurface;
    final bars = sidecar?.bars ?? const <double>[];
    final play = ref.watch(voicePlayControllerProvider);
    final active = downloaded && play.isActive(messageId);
    final playing = downloaded && play.isPlaying(messageId);
    // Show the playback clock when active, else the total clip length.
    final label = active
        ? formatVoiceDuration(Duration(milliseconds: play.positionMs))
        : formatVoiceDuration(sidecar?.duration);

    void onLead() {
      if (!downloaded) {
        onDownload?.call();
        return;
      }
      ref.read(voicePlayControllerProvider.notifier).toggle(messageId, fileKey);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 232,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                onTap: onLead,
            child: SizedBox(
              width: 36,
              height: 36,
              child: progress != null
                  ? Padding(
                      padding: const EdgeInsets.all(6),
                      child: CircularProgressIndicator(
                        value: progress == 0 ? null : progress,
                        strokeWidth: 2,
                        color: onBubble,
                      ),
                    )
                  : Icon(
                      !downloaded
                          ? Icons.download
                          : (playing ? Icons.pause : Icons.play_arrow),
                      color: onBubble,
                      size: 32,
                    ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SizedBox(
              height: 32,
              child: bars.isEmpty
                  ? Align(
                      alignment: Alignment.centerLeft,
                      child: Icon(Icons.graphic_eq,
                          size: 20, color: onBubble.withValues(alpha: 0.5)),
                    )
                  // Tap anywhere on the waveform of the ACTIVE clip to seek to
                  // that fraction of the clip.
                  : LayoutBuilder(
                      builder: (context, box) => GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapDown: active && box.maxWidth > 0
                            ? (d) => ref
                                .read(voicePlayControllerProvider.notifier)
                                .seekTo(messageId,
                                    d.localPosition.dx / box.maxWidth)
                            : null,
                        child: VoiceWaveform(
                          bars: bars,
                          progress: active ? play.progress : 0,
                          playedColor: onBubble,
                          unplayedColor: onBubble.withValues(alpha: 0.4),
                        ),
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 8),
          // While active, a speed chip (1×/1.5×/2×) cycles playback rate;
          // otherwise just the duration.
          if (active)
            GestureDetector(
              onTap: () =>
                  ref.read(voicePlayControllerProvider.notifier).cycleSpeed(),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: onBubble.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${_speedLabel(play.speed)}×',
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: onBubble),
                ),
              ),
            )
          else
            Text(
              label,
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: onBubble.withValues(alpha: 0.8)),
            ),
            ],
          ),
        ),
        if (downloaded) _transcript(context, ref, onBubble),
      ],
    );
  }

  /// The on-device transcription affordance under a downloaded voice clip: a
  /// "Transcribe" button, a spinner while running, then the cached text. Hidden
  /// entirely when the native STT layer / model isn't present.
  Widget _transcript(BuildContext context, WidgetRef ref, Color onBubble) {
    final available =
        ref.watch(transcriptionAvailableProvider).valueOrNull ?? false;
    if (!available) return const SizedBox.shrink();
    final entry = ref.watch(
      transcriptionControllerProvider.select((m) => m[messageId]),
    );
    // Lazily load a cached transcript once (idempotent in the controller).
    if (entry == null) {
      Future.microtask(() => ref
          .read(transcriptionControllerProvider.notifier)
          .loadCached(messageId, fileKey));
    }
    final l = AppL10n.of(context);
    final muted = onBubble.withValues(alpha: 0.7);
    final style = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: onBubble);

    if (entry != null && entry.isRunning) {
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 1.6, color: muted),
            ),
            const SizedBox(width: 8),
            Text(l.chatVoiceTranscribing,
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: muted)),
          ],
        ),
      );
    }
    if (entry != null && entry.isDone) {
      final text = entry.text ?? '';
      if (text.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 260),
          child: Text(text, style: style),
        ),
      );
    }
    // none / failed → a tap-to-transcribe (re-tappable after a failure).
    final failed = entry?.phase == TranscriptPhase.failed;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: InkWell(
        onTap: () => ref
            .read(transcriptionControllerProvider.notifier)
            .transcribe(messageId, fileKey, senderLang: sidecar?.lang),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.subtitles_outlined, size: 15, color: muted),
            const SizedBox(width: 4),
            Text(
              failed ? l.chatVoiceTranscribeFailed : l.chatVoiceTranscribe,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: failed ? Theme.of(context).colorScheme.error : muted,
                  ),
            ),
          ],
        ),
      ),
    );
  }

  static String _speedLabel(double s) =>
      s == s.roundToDouble() ? s.toStringAsFixed(0) : s.toStringAsFixed(1);
}

/// Video message with an embedded preview frame: the media-box rendering
/// (Telegram-style still + overlay) replacing the play-icon file row. The
/// micro-thumb is upscaled + blurred exactly like an image's undownloaded
/// preview (we never decode the video locally for a full-res poster — the
/// frame travels in the advert). Overlay: download progress ring while a
/// transfer runs, play when the blob is held, download otherwise; a held
/// video keeps its save/export affordance as a corner button.
class _VideoPreviewBox extends StatelessWidget {
  const _VideoPreviewBox({
    required this.thumb,
    required this.playable,
    this.progress,
    this.sizeLabel,
    this.onTap,
    this.onSave,
  });

  final Uint8List thumb;
  final bool playable;
  final double? progress;
  final String? sizeLabel;
  final VoidCallback? onTap;
  final VoidCallback? onSave;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        // Fixed box for the same reason as the image preview: a 32-px thumb's
        // intrinsic size would collapse the bubble to a postage stamp.
        child: SizedBox(
          width: 260,
          height: 170,
          child: Stack(
            alignment: Alignment.center,
            fit: StackFit.expand,
            children: [
              ImageFiltered(
                imageFilter: ui.ImageFilter.blur(
                  sigmaX: 2.5,
                  sigmaY: 2.5,
                  tileMode: TileMode.decal,
                ),
                child: Image.memory(
                  thumb,
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.medium,
                  gaplessPlayback: true,
                ),
              ),
              Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.35),
                    shape: BoxShape.circle,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: progress != null
                        ? SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              value: progress == 0 ? null : progress,
                              strokeWidth: 2.5,
                              color: Colors.white,
                            ),
                          )
                        : Icon(
                            playable ? Icons.play_arrow : Icons.download,
                            size: 24,
                            color: Colors.white,
                          ),
                  ),
                ),
              ),
              if (onSave != null)
                Positioned(
                  top: 6,
                  right: 6,
                  child: GestureDetector(
                    onTap: onSave,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.35),
                        shape: BoxShape.circle,
                      ),
                      child: const Padding(
                        padding: EdgeInsets.all(6),
                        child: Icon(
                          Icons.save_alt,
                          size: 16,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              if (sizeLabel != null)
                Positioned(
                  left: 6,
                  bottom: 6,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      child: Text(
                        sizeLabel!,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ImagePreview extends ConsumerStatefulWidget {
  const _ImagePreview({
    required this.fileKey,
    required this.name,
    this.thumbB64,
    this.onOpen,
    this.onView,
  });
  final String fileKey;
  final String name;

  /// Tap on the DOWNLOADED preview — the swipeable conversation gallery
  /// (falls back to the single-image viewer when null).
  final VoidCallback? onView;

  /// Embedded micro-thumb (base64 PNG travelling IN the message) — rendered
  /// blurred/upscaled while the blob itself is not yet downloaded.
  final String? thumbB64;

  /// Fallback tap (download/open) when the bytes aren't in the store yet.
  final VoidCallback? onOpen;

  @override
  ConsumerState<_ImagePreview> createState() => _ImagePreviewState();
}

class _ImagePreviewState extends ConsumerState<_ImagePreview> {
  /// Memoized ONCE per fileKey. Creating the future inline in build() made
  /// every list rebuild (messagesProvider re-yields on each mailbox/drain
  /// signal) restart the load: bubbles flip-flopped spinner↔image and the
  /// whole chat visibly jittered (user-reported: «чат дрожит, скролл лечит»).
  late Future<Uint8List?> _bytes;

  @override
  void initState() {
    super.initState();
    _bytes = ref.read(storageProvider).loadFile(widget.fileKey);
  }

  @override
  void didUpdateWidget(covariant _ImagePreview old) {
    super.didUpdateWidget(old);
    if (old.fileKey != widget.fileKey) {
      _bytes = ref.read(storageProvider).loadFile(widget.fileKey);
    }
  }

  String get name => widget.name;
  String? get thumbB64 => widget.thumbB64;
  VoidCallback? get onOpen => widget.onOpen;
  VoidCallback? get onView => widget.onView;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<Uint8List?>(
      future: _bytes,
      builder: (context, snap) {
        // Still loading → spinner. Loaded-but-absent (not in store) → a
        // tappable file chip (download/open), NEVER a perpetual spinner.
        if (snap.connectionState != ConnectionState.done) {
          return const SizedBox(
            height: 120,
            width: 120,
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final bytes = snap.data;
        if (bytes == null) {
          // Not downloaded yet. With an embedded micro-thumb → an instant
          // blurred preview (tap = the same download affordance); without →
          // the compact file chip.
          Uint8List? thumb;
          final tb = thumbB64;
          if (tb != null) {
            try {
              thumb = base64Decode(tb);
            } catch (_) {
              thumb = null; // hostile/corrupt field — fall back to the chip
            }
          }
          if (thumb != null) {
            return GestureDetector(
              onTap: onOpen,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                // Fixed preview box: a 32-px micro-thumb has a tiny intrinsic
                // size, and max-constraints alone would render it (and the
                // bubble) postage-stamp small — size the box, cover-fit the
                // upscaled thumb into it.
                child: SizedBox(
                  width: 260,
                  height: 170,
                  child: Stack(
                    alignment: Alignment.center,
                    fit: StackFit.expand,
                    children: [
                      // The micro-thumb upscaled; the blur hides the pixels
                      // (Telegram-style) and reads as "loading", not "final".
                      ImageFiltered(
                        imageFilter: ui.ImageFilter.blur(
                          sigmaX: 2.5,
                          sigmaY: 2.5,
                          tileMode: TileMode.decal,
                        ),
                        child: Image.memory(
                          thumb,
                          fit: BoxFit.cover,
                          filterQuality: FilterQuality.medium,
                          gaplessPlayback: true,
                        ),
                      ),
                      // Download affordance over the preview (Center keeps it
                      // intrinsic-sized under StackFit.expand).
                      Center(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.35),
                            shape: BoxShape.circle,
                          ),
                          child: const Padding(
                            padding: EdgeInsets.all(8),
                            child: Icon(
                              Icons.download,
                              size: 24,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }
          return InkWell(
            onTap: onOpen,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.image_outlined, size: 20, color: scheme.primary),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(name, overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
          );
        }
        return GestureDetector(
          onTap: onView ??
              () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => _FullscreenImage(bytes: bytes, name: name),
                    ),
                  ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240, maxWidth: 280),
              child: Image.memory(
                bytes,
                fit: BoxFit.cover,
                gaplessPlayback: true,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// One entry of the conversation media gallery: an image message, keyed the
/// way the bubble keys its preview (fileId when held, else the contentId —
/// an incoming content-path image keeps fileContentId even после download,
/// its blob living under the hash; loadFile resolves both). [thumb] is the
/// embedded micro-thumb, the fallback rendering for pages whose blob isn't
/// downloaded yet.
typedef GalleryItem = ({
  String id,
  String fileKey,
  String name,
  String? thumb,
});

/// The swipeable-gallery item set for a loaded conversation: every image
/// message with a loadable key, in display order. Pure — unit-tested. Pages
/// without local bytes degrade to the embedded thumb / a placeholder, so an
/// offered-not-downloaded image doesn't break the swipe sequence.
List<GalleryItem> conversationGalleryItems(List<Message> messages) => [
      for (final msg in messages)
        if (isImageFileName(msg.fileName) &&
            (msg.fileId ?? msg.fileContentId) != null)
          (
            id: msg.id,
            fileKey: (msg.fileId ?? msg.fileContentId)!,
            name: msg.fileName ?? '',
            thumb: msg.thumb,
          ),
    ];

/// Swipeable full-screen gallery over every downloaded image of the
/// conversation (media epic: "свайп между медиа"). Pages load their bytes
/// from the encrypted store on demand; each page zooms independently. The
/// app bar shows the current file name and the position in the set.
class _MediaGallery extends ConsumerStatefulWidget {
  const _MediaGallery({required this.items, required this.initialIndex});
  final List<GalleryItem> items;
  final int initialIndex;

  @override
  ConsumerState<_MediaGallery> createState() => _MediaGalleryState();
}

class _MediaGalleryState extends ConsumerState<_MediaGallery> {
  late final PageController _page = PageController(
    initialPage: widget.initialIndex,
  );
  late int _current = widget.initialIndex;

  /// Per-key memoized loads — a page rebuild (every swipe setState) must not
  /// restart the read and flash a spinner (same jitter class as the bubble
  /// preview).
  final Map<String, Future<Uint8List?>> _loads = {};

  Future<Uint8List?> _load(String fileKey) =>
      _loads[fileKey] ??= ref.read(storageProvider).loadFile(fileKey);

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.items[_current];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(item.name, overflow: TextOverflow.ellipsis),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Text(
                '${_current + 1}/${widget.items.length}',
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(color: Colors.white70),
              ),
            ),
          ),
        ],
      ),
      body: PageView.builder(
        controller: _page,
        itemCount: widget.items.length,
        onPageChanged: (i) => setState(() => _current = i),
        itemBuilder: (context, i) {
          final it = widget.items[i];
          return FutureBuilder<Uint8List?>(
            future: _load(it.fileKey),
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              final bytes = snap.data;
              if (bytes == null) {
                // Not downloaded (offered) or vanished: degrade to the
                // embedded micro-thumb when the message carries one, else an
                // inert placeholder — never a crash or spinner.
                Uint8List? thumb;
                final tb = it.thumb;
                if (tb != null) {
                  try {
                    thumb = base64Decode(tb);
                  } catch (_) {
                    thumb = null;
                  }
                }
                if (thumb != null) {
                  return ImageFiltered(
                    imageFilter: ui.ImageFilter.blur(
                      sigmaX: 6,
                      sigmaY: 6,
                      tileMode: TileMode.decal,
                    ),
                    child: Image.memory(
                      thumb,
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                    ),
                  );
                }
                return const Center(
                  child: Icon(
                    Icons.image_not_supported_outlined,
                    color: Colors.white38,
                    size: 48,
                  ),
                );
              }
              return Center(
                child: InteractiveViewer(
                  minScale: 0.5,
                  maxScale: 5,
                  child: Image.memory(bytes, gaplessPlayback: true),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// Full-screen zoomable image viewer (pinch/scroll to zoom, drag to pan).
class _FullscreenImage extends StatelessWidget {
  const _FullscreenImage({required this.bytes, required this.name});
  final Uint8List bytes;
  final String name;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(name, overflow: TextOverflow.ellipsis),
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 5,
          child: Image.memory(bytes),
        ),
      ),
    );
  }
}

enum _FileAffordance { download, save, open, gone }

/// Resolve a forwarded message's origin (the original author's node-id hex on
/// the wire) to a display name using MY OWN contacts: "you" for my identity, my
/// contact name for a known peer, else a short node id. Legacy forwards that
/// stored a display label (pre node-id attribution) are shown as-is.
String _resolveForwardAuthor(WidgetRef ref, AppL10n l, String origin) {
  final NodeId id;
  try {
    id = NodeId.fromHex(origin);
  } catch (_) {
    return origin; // not a node id — an old label-based forward
  }
  final myHex = ref.read(appControllerProvider).identity?.nodeId.hex;
  if (myHex != null && id.hex == myHex) return l.chatYou;
  final contact = ref.watch(contactProvider(id.hex)).value;
  return contact?.name ?? id.short;
}

class _Bubble extends ConsumerWidget {
  const _Bubble({
    super.key,
    required this.message,
    this.quoted,
    this.selected = false,
    this.selecting = false,
    this.onTapFile,
    this.onLongPress,
    this.onTap,
    this.onTapQuote,
    this.onOpenImage,
    this.onPlayVideo,
    this.onToggleReaction,
    this.onShowReactors,
    this.highlight,
  });
  final Message message;

  /// Tap a reaction chip to toggle that emoji on this message.
  final void Function(Message message, String emoji)? onToggleReaction;

  /// Long-press (or right-click) a reaction chip: show who reacted.
  final void Function(Message message)? onShowReactors;

  /// Tap on a DOWNLOADED inline image — the chat screen opens the swipeable
  /// media gallery positioned on this message (null = fall back to the
  /// single-image viewer).
  final void Function(Message message)? onOpenImage;

  /// Tap on a HELD video file row — the chat screen opens the in-app player
  /// (loopback-streamed; null = the row keeps the plain save behavior).
  final void Function(Message message)? onPlayVideo;

  /// Active in-chat search query — occurrences in the body get a highlight
  /// background (null when not searching).
  final String? highlight;

  /// The message this one replies to, resolved from the visible window (null if
  /// it's not a reply, or the quoted message is out of the window / deleted).
  final Message? quoted;

  /// Multi-select rendering: [selected] tints the row; [selecting] means a plain
  /// tap toggles selection (via [onTap]) instead of doing nothing.
  final bool selected;
  final bool selecting;
  final void Function(Message message)? onTapFile;
  final void Function(Message message)? onLongPress;
  final VoidCallback? onTap;

  /// Tap on the quoted-reply block — the chat screen jumps to the quoted
  /// message.
  final VoidCallback? onTapQuote;

  /// Whether the file blob is locally available (bubble shows "save" vs
  /// "download"). Resilient: a not-yet-open / erroring store falls back to the
  /// fileId presence instead of throwing out of build.
  /// What tapping the file does right now: download an OFFER, SAVE a blob we hold
  /// in the app, or OPEN a file already downloaded unencrypted to disk.
  Future<_FileAffordance> _affordance(WidgetRef ref) async {
    final key = message.fileId ?? message.fileContentId;
    if (key == null) {
      return message.fileId != null
          ? _FileAffordance.save
          : _FileAffordance.download;
    }
    try {
      if (await ref.read(storageProvider).hasFile(key)) {
        return _FileAffordance.save;
      }
    } catch (_) {
      if (message.fileId != null) return _FileAffordance.save;
    }
    final cid = message.fileContentId ?? message.fileId;
    if (cid != null) {
      final saved = await ref
          .read(messagingServiceProvider)
          .contentSavedPath(cid);
      if (saved != null &&
          await _savedFileLooksComplete(
            saved,
            expectedSize: message.fileSize,
          )) {
        return _FileAffordance.open;
      }
      // Every known holder said the bytes are gone — render the terminal
      // "ask the sender to re-send" state. A tap still retries (the download
      // entry point clears the mark; a live holder then re-offers).
      try {
        if (await ref
            .read(messagingServiceProvider)
            .isContentUnavailable(cid)) {
          return _FileAffordance.gone;
        }
      } catch (_) {}
    }
    return _FileAffordance.download;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final outgoing = message.direction == MessageDirection.outgoing;
    final naked = message.isFile && isStickerFileName(message.fileName);
    // In-flight download fraction for this file (null = not downloading). Falls
    // back to fileId so our OWN re-download (pulling a deleted sent file back
    // from the recipient) shows progress too.
    final cid = message.fileContentId ?? message.fileId;
    final progress = cid == null
        ? null
        : ref.watch(contentProgressProvider.select((m) => m[cid]));
    // A parked auto-resume shows NO progress until a pull moves bytes; surface
    // it as "resuming…" so a queued/retrying download does not look idle.
    final resuming =
        cid != null &&
        progress == null &&
        ref.watch(contentResumingProvider.select((s) => s.contains(cid)));
    return Container(
      // Selected rows get a full-width tint so the selection reads at a glance.
      color: selected ? scheme.primary.withValues(alpha: 0.12) : null,
      child: Align(
        alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
        child: GestureDetector(
          // Long-press (touch) AND secondary-tap (desktop right-click) both open
          // the message actions — without the latter the menu is unreachable on
          // desktop, where there is no long-press. In select mode a plain tap
          // toggles the row instead.
          onTap: onTap,
          onLongPress: onLongPress == null ? null : () => onLongPress!(message),
          onSecondaryTap: onLongPress == null
              ? null
              : () => onLongPress!(message),
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            // A sticker renders NAKED (no bubble chrome), Telegram-style —
            // just the image with the meta row under it.
            padding: naked
                ? EdgeInsets.zero
                : const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.75,
            ),
            decoration: naked
                ? null
                : BoxDecoration(
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
                // "Forwarded from X" caption. The wire carries the original
                // author's node-id hex; resolve it through MY OWN contacts here so
                // the sender's private alias never leaked (see _forwardMessages).
                if (message.forwardedFrom != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.forward,
                          size: 13,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            l.chatForwardedFrom(
                              _resolveForwardAuthor(
                                ref,
                                l,
                                message.forwardedFrom!,
                              ),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                  fontStyle: FontStyle.italic,
                                ),
                          ),
                        ),
                      ],
                    ),
                  ),
                // Quoted reply preview (a reference to a deleted/out-of-window
                // message shows a generic stub). Tapping it jumps to the quoted
                // message.
                if (message.replyToId != null)
                  GestureDetector(
                    onTap: onTapQuote,
                    child: _QuoteBlock(quoted: quoted, outgoing: outgoing),
                  ),
                if (message.isFile && isStickerPackFileName(message.fileName))
                  _StickerPackCard(
                    fileKey: message.fileId ?? message.fileContentId ?? '',
                    thumbB64: message.thumb,
                    downloaded:
                        progress == null && (message.fileId != null),
                    progress: progress,
                    onDownload: onTapFile == null
                        ? null
                        : () => onTapFile!(message),
                  )
                else if (message.isFile && isStickerFileName(message.fileName))
                  _StickerContent(
                    fileKey: message.fileId ?? message.fileContentId ?? '',
                    thumbB64: message.thumb,
                    progress: progress,
                  )
                else if (message.isFile && isVnoteFileName(message.fileName))
                  FutureBuilder<_FileAffordance>(
                    future: _affordance(ref),
                    builder: (context, snap) {
                      final a = snap.data ??
                          (message.fileId != null
                              ? _FileAffordance.save
                              : _FileAffordance.download);
                      final downloaded = progress == null &&
                          a == _FileAffordance.save;
                      return _VnoteBubble(
                        messageId: message.id,
                        fileKey: message.fileId ?? message.fileContentId ?? '',
                        sidecar: decodeVnoteSidecar(message.thumb),
                        outgoing: outgoing,
                        downloaded: downloaded,
                        progress: progress,
                        onDownload: (!downloaded && onTapFile != null)
                            ? () => onTapFile!(message)
                            : null,
                      );
                    },
                  )
                else if (message.isFile && isVoiceFileName(message.fileName))
                  FutureBuilder<_FileAffordance>(
                    future: _affordance(ref),
                    builder: (context, snap) {
                      final a = snap.data ??
                          (message.fileId != null
                              ? _FileAffordance.save
                              : _FileAffordance.download);
                      final downloaded = progress == null &&
                          a == _FileAffordance.save;
                      return _VoiceBubble(
                        messageId: message.id,
                        fileKey: message.fileId ?? message.fileContentId ?? '',
                        sidecar: decodeVoiceSidecar(message.thumb),
                        outgoing: outgoing,
                        downloaded: downloaded,
                        progress: progress,
                        onDownload: (!downloaded && onTapFile != null)
                            ? () => onTapFile!(message)
                            : null,
                      );
                    },
                  )
                else if (message.isFile &&
                    isImageFileName(message.fileName) &&
                    (message.fileId ?? message.fileContentId) != null)
                  _ImagePreview(
                    fileKey: (message.fileId ?? message.fileContentId)!,
                    name: message.fileName ?? '',
                    thumbB64: message.thumb,
                    onOpen: onTapFile == null
                        ? null
                        : () => onTapFile!(message),
                    onView: onOpenImage == null
                        ? null
                        : () => onOpenImage!(message),
                  )
                else if (message.isFile)
                  FutureBuilder<_FileAffordance>(
                    future: _affordance(ref),
                    builder: (context, snap) {
                      final a =
                          snap.data ??
                          (message.fileId != null
                              ? _FileAffordance.save
                              : _FileAffordance.download);
                      // Terminal state only renders when nothing is in flight —
                      // a live retry's spinner wins over the stale mark.
                      final gone =
                          progress == null && a == _FileAffordance.gone;
                      // A HELD video plays on tap (the in-app player over the
                      // loopback stream); save moves to the trailing button.
                      final playable = onPlayVideo != null &&
                          a == _FileAffordance.save &&
                          isVideoFileName(message.fileName);
                      // A video WITH an embedded preview frame renders as a
                      // media box (thumb + play/download overlay) instead of
                      // the file row. Terminal-degraded states (gone /
                      // resuming) keep the row — its honest status text.
                      final videoThumb =
                          isVideoFileName(message.fileName) && !gone && !resuming
                              ? _decodeThumbB64(message.thumb)
                              : null;
                      if (videoThumb != null) {
                        return _VideoPreviewBox(
                          thumb: videoThumb,
                          playable: playable,
                          progress: progress,
                          sizeLabel: message.fileSize != null
                              ? _formatBytes(message.fileSize!)
                              : null,
                          onTap: playable
                              ? () => onPlayVideo!(message)
                              : (onTapFile == null
                                  ? null
                                  : () => onTapFile!(message)),
                          onSave: playable && onTapFile != null
                              ? () => onTapFile!(message)
                              : null,
                        );
                      }
                      return InkWell(
                        onTap: playable
                            ? () => onPlayVideo!(message)
                            : (onTapFile == null
                                ? null
                                : () => onTapFile!(message)),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              playable
                                  ? Icons.play_circle_outline
                                  : documentIcon(message.fileName),
                              size: 20,
                              color: playable
                                  ? scheme.primary
                                  : scheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    message.fileName ?? message.body,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  // Subtitle: "Downloading NN%" while a transfer
                                  // is in flight; the ask-to-re-send notice when
                                  // every holder said GONE; else the file size.
                                  if (progress != null)
                                    Text(
                                      '${l.fileDownloading} ${(progress * 100).round()}%',
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelSmall
                                          ?.copyWith(
                                            color: scheme.onSurfaceVariant,
                                          ),
                                    )
                                  else if (resuming)
                                    Text(
                                      l.fileResuming,
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelSmall
                                          ?.copyWith(
                                            color: scheme.onSurfaceVariant,
                                          ),
                                    )
                                  else if (gone)
                                    Text(
                                      l.fileGoneAskResend,
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelSmall
                                          ?.copyWith(color: scheme.error),
                                    )
                                  else if (message.fileSize != null)
                                    Text(
                                      _formatBytes(message.fileSize!),
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelSmall
                                          ?.copyWith(
                                            color: scheme.onSurfaceVariant,
                                          ),
                                    ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            // While downloading: a ring at the current fraction.
                            // Else an icon per affordance. A HELD blob shows the
                            // "downloaded ✓" mark (NOT a plain down-arrow — that
                            // reads as "still needs downloading", the exact
                            // confusion users hit after storage compaction, which
                            // keeps the file but the bubble looked un-fetched);
                            // tapping it still exports/saves.
                            if (progress != null)
                              SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  value: progress == 0 ? null : progress,
                                  strokeWidth: 2,
                                  color: scheme.onSurfaceVariant,
                                ),
                              )
                            else if (resuming)
                              // Indeterminate: a parked resume has no fraction yet.
                              SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: scheme.onSurfaceVariant,
                                ),
                              )
                            else if (playable)
                              // Row-tap plays; saving the video moved here.
                              InkWell(
                                onTap: onTapFile == null
                                    ? null
                                    : () => onTapFile!(message),
                                child: Icon(
                                  Icons.download_done_outlined,
                                  size: 16,
                                  color: scheme.primary,
                                ),
                              )
                            else
                              Icon(
                                switch (a) {
                                  _FileAffordance.save =>
                                    Icons.download_done_outlined,
                                  _FileAffordance.open => Icons.open_in_new,
                                  _FileAffordance.gone =>
                                    Icons.file_download_off_outlined,
                                  _FileAffordance.download =>
                                    Icons.download_outlined,
                                },
                                size: 16,
                                color: switch (a) {
                                  _FileAffordance.gone => scheme.error,
                                  _FileAffordance.save => scheme.primary,
                                  _ => scheme.onSurfaceVariant,
                                },
                              ),
                          ],
                        ),
                      );
                    },
                  )
                else
                  FormattedText(message.body, highlight: highlight),
                // Reaction chips: aggregated emoji → count for this message.
                // Tap toggles my reaction, long-press / right-click lists the
                // reactors; hidden entirely by the "show reactions" preference.
                // In select mode the chips go inert so taps fall through to
                // the row-selection gesture.
                Builder(
                  builder: (context) {
                    if (!ref.watch(showReactionsProvider)) {
                      return const SizedBox.shrink();
                    }
                    final forMsg = ref
                        .watch(reactionsProvider(message.conversationId))
                        .valueOrNull?[message.id];
                    if (forMsg == null || forMsg.isEmpty) {
                      return const SizedBox.shrink();
                    }
                    final selfHex = ref.watch(
                      appControllerProvider.select(
                        (s) => s.identity?.nodeId.hex,
                      ),
                    );
                    final mine = selfHex == null ? null : forMsg[selfHex];
                    final counts = <String, int>{};
                    for (final e in forMsg.values) {
                      counts[e] = (counts[e] ?? 0) + 1;
                    }
                    return Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: [
                          for (final entry in counts.entries)
                            InkWell(
                              onTap: selecting || onToggleReaction == null
                                  ? null
                                  : () =>
                                        onToggleReaction!(message, entry.key),
                              onLongPress: selecting || onShowReactors == null
                                  ? null
                                  : () => onShowReactors!(message),
                              onSecondaryTap:
                                  selecting || onShowReactors == null
                                  ? null
                                  : () => onShowReactors!(message),
                              borderRadius: BorderRadius.circular(10),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: mine == entry.key
                                      ? scheme.primaryContainer
                                      : scheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(10),
                                  border: mine == entry.key
                                      ? Border.all(
                                          color: scheme.primary,
                                          width: 1,
                                        )
                                      : null,
                                ),
                                child: Text(
                                  '${entry.key} ${entry.value}',
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
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
                    ..._signatureBadge(context, l, scheme),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Attestation badge for the "request signature" feature — an icon + tooltip
  /// reflecting [Message.signature]. Empty for [MessageSignature.none].
  List<Widget> _signatureBadge(
    BuildContext context,
    AppL10n l,
    ColorScheme scheme,
  ) {
    final (
      IconData icon,
      Color color,
      String tip,
    ) = switch (message.signature) {
      MessageSignature.none => (Icons.circle, Colors.transparent, ''),
      MessageSignature.requested => (
        Icons.hourglass_empty,
        scheme.onSurfaceVariant,
        l.chatSignaturePending,
      ),
      MessageSignature.verified => (
        Icons.verified,
        Colors.green,
        l.chatSignatureVerified,
      ),
      MessageSignature.refused => (
        Icons.gpp_bad_outlined,
        scheme.onSurfaceVariant,
        l.chatSignatureRefused,
      ),
      MessageSignature.failed => (
        Icons.error_outline,
        scheme.error,
        l.chatSignatureFailed,
      ),
    };
    if (message.signature == MessageSignature.none) return const [];
    return [
      const SizedBox(width: 4),
      Tooltip(
        message: tip,
        child: Icon(icon, size: 13, color: color),
      ),
    ];
  }

  static IconData _statusIcon(MessageStatus s) => switch (s) {
    MessageStatus.sending => Icons.schedule,
    MessageStatus.sent => Icons.check,
    MessageStatus.delivered => Icons.done_all,
    MessageStatus.failed => Icons.error_outline,
  };
}

/// Live round self-preview while recording a video note: converts the
/// controller's latest RGBA frame to a [ui.Image], coalescing decodes (a slow
/// frame is skipped, never queued) — the calls' remote-video pattern.
class _Composer extends ConsumerStatefulWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.hint,
    required this.onSend,
    this.onAttach,
    this.onVoice,
    this.onVideoNote,
    this.onSticker,
  });
  final TextEditingController controller;
  final FocusNode focusNode;
  final String hint;
  final VoidCallback onSend;

  /// When set (accepted contacts only), shows a file-attach button.
  final VoidCallback? onAttach;

  /// When set (accepted contacts only), shows a hold-to-record mic button on
  /// an empty field; releasing sends the recorded [VoiceClip].
  final void Function(VoiceClip clip)? onVoice;

  /// When set, the capture button gains a mic↔camera mode toggle and the
  /// camera mode records a round video note ([VnoteClip]).
  final void Function(VnoteClip clip)? onVideoNote;

  /// When set, a sticker button opens the sticker panel; picking one passes
  /// its store item id here to send.
  final void Function(String itemId)? onSticker;

  @override
  ConsumerState<_Composer> createState() => _ComposerState();
}

class _ComposerState extends ConsumerState<_Composer> {
  TextEditingController get controller => widget.controller;
  FocusNode get focusNode => widget.focusNode;
  VoidCallback get onSend => widget.onSend;
  VoidCallback? get onAttach => widget.onAttach;

  /// Rolling recent capture levels, painted as the live waveform while
  /// recording. Fed from the record controller's poll ticks.
  final List<double> _liveLevels = [];

  /// Capture mode of the empty-field button: false = voice, true = video note.
  bool _vnoteMode = false;

  /// Wrap the current selection (or insert at the cursor) with a formatting
  /// marker, keeping focus + the wrapped selection so the user can keep typing
  /// or stack another format.
  void _wrap(String marker) {
    final v = controller.value;
    final r = applyMarker(v.text, v.selection, marker);
    controller.value = v.copyWith(
      text: r.text,
      selection: r.selection,
      composing: TextRange.empty,
    );
    focusNode.requestFocus();
  }

  /// Insert [s] at the cursor (replacing any selection), keeping focus and
  /// placing the caret after the insertion. Drives the emoji picker and the
  /// Shift+Enter newline.
  void _insertText(String s) {
    final v = controller.value;
    final sel = v.selection;
    final start = sel.isValid ? sel.start : v.text.length;
    final end = sel.isValid ? sel.end : v.text.length;
    controller.value = v.copyWith(
      text: v.text.replaceRange(start, end, s),
      selection: TextSelection.collapsed(offset: start + s.length),
      composing: TextRange.empty,
    );
    focusNode.requestFocus();
  }

  /// Bound to Shift+Enter: Flutter maps no default editing action to it, so
  /// without an explicit binding the keystroke would do NOTHING once plain
  /// Enter is claimed by the send shortcut.
  void _insertNewline() => _insertText('\n');

  /// Prefix every line spanned by the selection (or the cursor's line) with
  /// `> `, turning it into a block quote. Line-level, so it can't reuse the
  /// marker-wrap path — the region is expanded to whole lines first.
  void _prefixQuote() {
    final v = controller.value;
    final text = v.text;
    final sel = v.selection;
    final start = sel.isValid ? sel.start : text.length;
    final end = sel.isValid ? sel.end : text.length;
    final lineStart = text.lastIndexOf('\n', start - 1) + 1;
    var lineEnd = text.indexOf('\n', end);
    if (lineEnd < 0) lineEnd = text.length;
    final region = text.substring(lineStart, lineEnd);
    final quoted = region.split('\n').map((l) => '> $l').join('\n');
    final newText = text.substring(0, lineStart) + quoted + text.substring(lineEnd);
    controller.value = v.copyWith(
      text: newText,
      selection: TextSelection.collapsed(
        offset: lineEnd + (quoted.length - region.length),
      ),
      composing: TextRange.empty,
    );
    focusNode.requestFocus();
  }

  Future<void> _startRecording() async {
    _liveLevels.clear();
    await ref.read(voiceRecordControllerProvider.notifier).start();
  }

  /// Stop recording and send the clip (the recording bar's Send button).
  void _sendRecording() {
    final clip = ref.read(voiceRecordControllerProvider.notifier).stop();
    if (clip != null) widget.onVoice?.call(clip);
  }

  Future<void> _startVnoteRecording() async {
    await ref.read(vnoteRecordControllerProvider.notifier).start();
  }

  void _sendVnoteRecording() {
    final clip = ref.read(vnoteRecordControllerProvider.notifier).stop();
    if (clip != null) widget.onVideoNote?.call(clip);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    // Feed the live waveform + surface permission/record failures.
    ref.listen<VoiceRecordState>(voiceRecordControllerProvider, (prev, next) {
      if (next.phase == VoiceRecordPhase.recording) {
        setState(() {
          _liveLevels.add(next.level);
          if (_liveLevels.length > 44) _liveLevels.removeAt(0);
        });
      } else if (_liveLevels.isNotEmpty) {
        setState(_liveLevels.clear);
      }
      if (next.phase == VoiceRecordPhase.denied) {
        _showCenterToast(l.chatVoiceMicDenied);
      } else if (next.phase == VoiceRecordPhase.error) {
        _showCenterToast(l.chatVoiceRecordFailed);
      }
    });
    // Video-note phases: toasts on failure + pick up the 60s auto-stop clip.
    ref.listen<VnoteRecordState>(vnoteRecordControllerProvider, (prev, next) {
      if (next.phase == VnoteRecordPhase.denied) {
        _showCenterToast(l.chatVnoteDenied);
      } else if (next.phase == VnoteRecordPhase.error) {
        _showCenterToast(l.chatVoiceRecordFailed);
      }
      if (prev?.isRecording == true && next.phase == VnoteRecordPhase.idle) {
        final auto =
            ref.read(vnoteRecordControllerProvider.notifier).takeAutoStopped();
        if (auto != null) widget.onVideoNote?.call(auto);
      }
    });
    final rec = ref.watch(voiceRecordControllerProvider);
    if (rec.isRecording) {
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          child: _recordingBar(context, l, rec),
        ),
      );
    }
    final vnoteRec = ref.watch(vnoteRecordControllerProvider);
    if (vnoteRec.isRecording) {
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          child: _vnoteRecordingBar(context, l, vnoteRec),
        ),
      );
    }
    // Desktop formatting hotkeys: Cmd/Ctrl + B / I / U (and E for inline code).
    final field = CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyB, meta: true): () =>
            _wrap('**'),
        const SingleActivator(LogicalKeyboardKey.keyB, control: true): () =>
            _wrap('**'),
        const SingleActivator(LogicalKeyboardKey.keyI, meta: true): () =>
            _wrap('*'),
        const SingleActivator(LogicalKeyboardKey.keyI, control: true): () =>
            _wrap('*'),
        const SingleActivator(LogicalKeyboardKey.keyU, meta: true): () =>
            _wrap('__'),
        const SingleActivator(LogicalKeyboardKey.keyU, control: true): () =>
            _wrap('__'),
        const SingleActivator(LogicalKeyboardKey.keyE, meta: true): () =>
            _wrap('`'),
        const SingleActivator(LogicalKeyboardKey.keyE, control: true): () =>
            _wrap('`'),
        // Telegram convention: Enter SENDS, Shift+Enter inserts a newline.
        // Both are explicit bindings: plain Enter is claimed by send, and
        // Flutter maps no default editing action to Shift+Enter, so the
        // newline must be inserted by hand. On mobile the IME return key is
        // a plain newline (textInputAction: newline) and sending is the
        // send button.
        const SingleActivator(LogicalKeyboardKey.enter): onSend,
        const SingleActivator(LogicalKeyboardKey.numpadEnter): onSend,
        const SingleActivator(LogicalKeyboardKey.enter, shift: true):
            _insertNewline,
        const SingleActivator(LogicalKeyboardKey.numpadEnter, shift: true):
            _insertNewline,
      },
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        minLines: 1,
        maxLines: 5,
        textInputAction: TextInputAction.newline,
        keyboardType: TextInputType.multiline,
        decoration: InputDecoration(hintText: widget.hint),
      ),
    );
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
            // Formatting menu — the mobile counterpart to the desktop hotkeys.
            PopupMenuButton<String>(
              icon: const Icon(Icons.text_format),
              tooltip: l.chatFormatTooltip,
              onSelected: (v) => v == '>' ? _prefixQuote() : _wrap(v),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: '**',
                  child: Text(
                    l.chatFormatBold,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                PopupMenuItem(
                  value: '*',
                  child: Text(
                    l.chatFormatItalic,
                    style: const TextStyle(fontStyle: FontStyle.italic),
                  ),
                ),
                PopupMenuItem(
                  value: '__',
                  child: Text(
                    l.chatFormatUnderline,
                    style: const TextStyle(
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
                PopupMenuItem(
                  value: '~~',
                  child: Text(
                    l.chatFormatStrike,
                    style: const TextStyle(
                      decoration: TextDecoration.lineThrough,
                    ),
                  ),
                ),
                PopupMenuItem(
                  value: '`',
                  child: Text(
                    l.chatFormatCode,
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                ),
                PopupMenuItem(value: '||', child: Text(l.chatFormatSpoiler)),
                PopupMenuItem(
                  value: '>',
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.format_quote, size: 18),
                      const SizedBox(width: 8),
                      Text(l.chatFormatQuote),
                    ],
                  ),
                ),
              ],
            ),
            Expanded(child: field),
            // Emoji picker — right of the field, left of send (remark #2):
            // desktop's only emoji entry point; a complement on mobile.
            Builder(
              builder: (context) => IconButton(
                tooltip: l.chatEmojiTooltip,
                icon: const Icon(Icons.emoji_emotions_outlined),
                onPressed: () async {
                  final picked = await showEmojiPanel(context);
                  if (picked != null) _insertText(picked);
                },
              ),
            ),
            // Sticker panel — only where the note/sticker send path is wired
            // (accepted contacts), same gate as voice/video.
            if (widget.onSticker != null)
              Builder(
                builder: (context) => IconButton(
                  tooltip: l.stickerTitle,
                  icon: const Icon(Icons.sticky_note_2_outlined),
                  onPressed: () async {
                    final itemId = await showStickerPanel(context);
                    if (itemId != null) widget.onSticker!(itemId);
                  },
                ),
              ),
            const SizedBox(width: 4),
            // Empty field + voice enabled → tap-to-record capture button (mic
            // or, with the toggle, a round video note); otherwise send.
            if (widget.onVoice != null)
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: controller,
                builder: (_, value, child) => value.text.trim().isEmpty
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (widget.onVideoNote != null) _modeToggle(context, l),
                          _vnoteMode && widget.onVideoNote != null
                              ? _vnoteButton(context)
                              : _micButton(context),
                        ],
                      )
                    : IconButton.filled(
                        onPressed: onSend, icon: const Icon(Icons.send)),
              )
            else
              IconButton.filled(
                  onPressed: onSend, icon: const Icon(Icons.send)),
          ],
        ),
      ),
    );
  }

  /// Tap-to-record mic button (hands-free): a tap starts recording; the
  /// recording bar's Send/Cancel then finish or discard — no hold required, so
  /// it works the same on desktop and mobile and the stop action is explicit.
  Widget _micButton(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton.filled(
      onPressed: _startRecording,
      icon: const Icon(Icons.mic),
      color: scheme.onPrimary,
    );
  }

  /// Tap-to-record round-video button (the camera mode of the capture toggle).
  Widget _vnoteButton(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton.filled(
      onPressed: _startVnoteRecording,
      icon: const Icon(Icons.videocam),
      color: scheme.onPrimary,
    );
  }

  /// Switches the capture button between voice and round-video mode (shows
  /// the mode you'd switch TO, Telegram-desktop style).
  Widget _modeToggle(BuildContext context, AppL10n l) {
    return IconButton(
      icon: Icon(_vnoteMode ? Icons.mic_none : Icons.videocam_outlined),
      tooltip: _vnoteMode ? l.chatVoiceTooltip : l.chatVnoteTooltip,
      onPressed: () => setState(() => _vnoteMode = !_vnoteMode),
    );
  }

  /// While recording a video note: Cancel + live round self-preview + elapsed
  /// + Send. The preview repaints off the controller's frame notifier, not the
  /// widget state (12 fps repaints must not rebuild the whole composer).
  Widget _vnoteRecordingBar(
      BuildContext context, AppL10n l, VnoteRecordState rec) {
    final scheme = Theme.of(context).colorScheme;
    final ctrl = ref.read(vnoteRecordControllerProvider.notifier);
    final elapsed = formatVoiceDuration(Duration(milliseconds: rec.elapsedMs));
    return Row(
      children: [
        IconButton(
          icon: Icon(Icons.delete_outline, color: scheme.error),
          tooltip: l.actionCancel,
          onPressed: ctrl.cancel,
        ),
        Icon(Icons.fiber_manual_record, color: scheme.error, size: 14),
        const SizedBox(width: 8),
        SizedBox(
          width: 44,
          child:
              Text(elapsed, style: Theme.of(context).textTheme.labelMedium),
        ),
        Expanded(
          child: Center(
            child: ClipOval(
              child: SizedBox(
                width: 96,
                height: 96,
                child: VnotePreview(frameListenable: ctrl.preview),
              ),
            ),
          ),
        ),
        const SizedBox(width: 4),
        IconButton.filled(
          onPressed: _sendVnoteRecording,
          icon: const Icon(Icons.send),
        ),
      ],
    );
  }

  /// While recording: Cancel (left) + record dot + elapsed + live waveform +
  /// a prominent Send (right) that stops and sends. Send is the clear "stop".
  Widget _recordingBar(BuildContext context, AppL10n l, VoiceRecordState rec) {
    final scheme = Theme.of(context).colorScheme;
    final elapsed = formatVoiceDuration(Duration(milliseconds: rec.elapsedMs));
    return Row(
      children: [
        IconButton(
          icon: Icon(Icons.delete_outline, color: scheme.error),
          tooltip: l.actionCancel,
          onPressed: () =>
              ref.read(voiceRecordControllerProvider.notifier).cancel(),
        ),
        // Pulsing record dot + elapsed time.
        Icon(Icons.fiber_manual_record, color: scheme.error, size: 14),
        const SizedBox(width: 8),
        SizedBox(
          width: 44,
          child: Text(elapsed,
              style: Theme.of(context).textTheme.labelMedium),
        ),
        Expanded(
          child: SizedBox(
            height: 28,
            child: _liveLevels.isEmpty
                ? const SizedBox.shrink()
                : VoiceWaveform(
                    bars: _liveLevels,
                    playedColor: scheme.primary,
                    unplayedColor: scheme.primary,
                  ),
          ),
        ),
        const SizedBox(width: 4),
        // The explicit STOP + send.
        IconButton.filled(
          onPressed: _sendRecording,
          icon: const Icon(Icons.send),
        ),
      ],
    );
  }

  /// A brief, centered, translucent toast (an overlay, not a bottom snackbar so
  /// it never covers the composer). Auto-dismisses.
  void _showCenterToast(String msg) {
    if (!mounted) return;
    final overlay = Overlay.of(context);
    late final OverlayEntry entry;
    var removed = false;
    void remove() {
      if (removed) return;
      removed = true;
      entry.remove();
    }

    entry = OverlayEntry(
      builder: (ctx) => IgnorePointer(
        child: Center(
          child: Material(
            color: Colors.transparent,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                msg,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 15),
              ),
            ),
          ),
        ),
      ),
    );
    overlay.insert(entry);
    Future.delayed(const Duration(milliseconds: 1600), remove);
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
