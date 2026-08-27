// Group chat (groups epic, phase 0, brick 5): the validated message list + a
// composer that posts (auto-fanned to members by the service). The member
// count sits in the app bar; an overflow menu opens the member sheet.

import 'dart:async' show Timer, scheduleMicrotask, unawaited;
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' show StateController;
import 'package:go_router/go_router.dart';

import '../../core/ids.dart';
import '../../data/serve_source.dart';
import '../../domain/chat.dart';
import '../../domain/call_signal.dart';
import '../../domain/group.dart';
import '../../domain/media_object.dart' show kInlineImageMaxBytes;
import '../../domain/group_message.dart';
import '../../domain/group_policy.dart';
import '../../domain/group_reaction.dart';
import '../../domain/inline_custom_emoji.dart';
import '../../domain/space_channel.dart';
import '../../domain/space_moderation.dart';
import '../../l10n/app_localizations.dart';
import '../../routing/back_affordance.dart';
import '../../state/group_service_providers.dart';
import '../../state/group_call_service.dart';
import '../../state/media_availability.dart';
import '../../data/storage/storage.dart';
import '../../state/messaging.dart'
    show
        MessagingService,
        conversationsProvider,
        contentProgressProvider,
        contentResumingProvider,
        kMaxIncomingFileBytes,
        messagingServiceProvider;
import '../../state/notifications.dart' show activeConversationProvider;
import '../../state/providers.dart';
import '../../state/reactions_visibility_controller.dart';
import '../../state/sticker_store.dart';
import '../../state/thumbnail.dart';
import '../../state/video_thumb.dart';
import '../../state/vnote_play_controller.dart';
import '../../state/vnote_record_controller.dart';
import '../../state/voice_message.dart' show formatVoiceDuration;
import '../../state/voice_play_controller.dart';
import '../../state/voice_record_controller.dart';
import '../chat/attachment_preview.dart';
import '../chat/vnote_preview.dart';
import '../chat/cancelable_download_progress.dart';
import '../chat/camera_capture_screen.dart';
import '../chat/chat_screen.dart'
    show
        ComposerAttachmentAction,
        MessageComposer,
        documentIcon,
        mediaPreviewCacheDimension;
import '../chat/custom_emoji_controller.dart';
import '../chat/message_markdown.dart';
import '../chat/reactors_sheet.dart';
import '../chat/video_player_screen.dart';
import 'group_disappearing.dart';

/// The actions behind the group chat's overflow menu. Only some are
/// owner-only: agreeing to see less on one's own device needs no role at all.
enum _GroupOwnerAction {
  disappearing,
  hideAfterRead,
  hideAfterReadLocal,
  convert,
}

void _cancelGroupContentDownload(WidgetRef ref, String contentId) {
  unawaited(
    ref.read(messagingServiceProvider).cancelContentDownload(contentId),
  );
}

/// Passive "group call in progress — join" strip under the app bar. Fed by
/// [GroupCallService.activeRoomFor] (periodic announces); tapping joins the
/// ongoing room. This is how a member who declined/missed the one full-screen
/// ring — or left mid-call — gets back in: the ring never repeats.
class _GroupCallBanner extends ConsumerStatefulWidget {
  const _GroupCallBanner({required this.gid});
  final NodeId gid;

  @override
  ConsumerState<_GroupCallBanner> createState() => _GroupCallBannerState();
}

class _GroupCallBannerState extends ConsumerState<_GroupCallBanner> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Room records expire only by TTL (announces stop when the room dies); a
    // coarse tick makes the banner honestly disappear without an event.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final calls = ref.watch(groupCallServiceProvider);
    if (calls == null) return const SizedBox.shrink();
    // Re-evaluate when our own call state flips (the room we are inside is
    // excluded from the banner).
    ref.watch(currentGroupCallProvider);
    final l = AppL10n.of(context);
    return ListenableBuilder(
      listenable: calls.roomsRevision,
      builder: (context, _) {
        final room = calls.activeRoomFor(widget.gid);
        if (room == null) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        return Material(
          key: const ValueKey('group-call-banner'),
          color: scheme.primaryContainer,
          child: InkWell(
            onTap: () => unawaited(calls.joinRoom(widget.gid)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Icon(
                    room.media.video ? Icons.videocam : Icons.call,
                    size: 18,
                    color: scheme.onPrimaryContainer,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      l.groupCallOngoing,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: scheme.onPrimaryContainer),
                    ),
                  ),
                  Text(
                    l.groupCallJoinAction,
                    key: const ValueKey('group-call-banner-join'),
                    style: TextStyle(
                      color: scheme.onPrimaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class GroupChatScreen extends ConsumerStatefulWidget {
  const GroupChatScreen({
    super.key,
    required this.groupIdHex,
    this.channelIdHex,
    this.initialJumpTo,
  });
  final String groupIdHex;
  final String? channelIdHex;
  final String? initialJumpTo;

  @override
  ConsumerState<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends ConsumerState<GroupChatScreen> {
  /// The identity this screen was opened under. See `_ChatScreenState` — the
  /// same shape, and the same reason: an all-online switch re-points the
  /// storage and the messaging pipeline without changing `AppPhase`, so this
  /// State stays mounted and every provider read after that resolves to
  /// whoever is active now (report17 XV17-H6).
  late final Storage _storage;
  late final MessagingService _messaging;

  final _input = CustomEmojiEditingController();
  final _inputFocus = FocusNode();
  final _scroll = ScrollController();
  final _initialTargetKey = GlobalKey();
  Timer? _highlightTimer;
  bool _initialJumpScheduled = false;
  String? _highlightRef;
  late final NodeId _gid = NodeId.fromHex(widget.groupIdHex);
  late final NodeId? _channelId = widget.channelIdHex == null
      ? null
      : NodeId.fromHex(widget.channelIdHex!);
  StateController<String?>? _activeConversation;

  String get _conversationKey => _channelId == null
      ? 'group:${widget.groupIdHex}'
      : 'space:${widget.groupIdHex}:channel:${widget.channelIdHex}';

  /// Whether this build has a call media engine at all. `read`, not `watch`:
  /// a library that failed to load does not appear later.
  bool get _mediaAvailable => ref.read(callMediaAvailableProvider);

  /// The message the composer is replying to, or null.
  GroupMessage? _replyTarget;

  @override
  void initState() {
    super.initState();
    // Taken here, not on first use: "first use" can be after a switch.
    _storage = ref.read(storageProvider);
    _messaging = ref.read(messagingServiceProvider);
    // Mark this group as the actively-viewed conversation so the notification
    // layer never alerts for the chat on screen (post-frame: a provider must
    // not be written during build).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _activeConversation = ref.read(activeConversationProvider.notifier);
      _activeConversation!.state = _conversationKey;
    });
  }

  /// The frame after the identity moved: nothing of A's, and on the way out.
  Widget _leftBehind() {
    _input.clear();
    _replyTarget = null;
    _highlightTimer?.cancel();
    _highlightTimer = null;
    _highlightRef = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        GoRouter.of(context).go('/home');
      } catch (_) {
        // No router above us (a widget test, or a torn-down app).
      }
    });
    return const Scaffold(body: SizedBox.shrink());
  }

  @override
  void dispose() {
    final activeConversation = _activeConversation;
    final conversationKey = _conversationKey;
    if (activeConversation?.state == conversationKey) {
      // Riverpod forbids provider mutations while Flutter finalizes a route's
      // widget tree. Clear the marker after the synchronous navigation frame.
      scheduleMicrotask(() {
        try {
          if (activeConversation!.state == conversationKey) {
            activeConversation.state = null;
          }
        } catch (_) {
          // The ProviderScope may already be gone during test/app teardown.
        }
      });
    }
    _input.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    _highlightTimer?.cancel();
    super.dispose();
  }

  void _scheduleInitialJump(List<GroupMessage> messages) {
    final target = widget.initialJumpTo;
    if (_initialJumpScheduled || target == null) return;
    final index = messages.indexWhere((message) => message.ref == target);
    if (index < 0) return;
    _initialJumpScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final fraction = messages.length <= 1
          ? 0.0
          : index / (messages.length - 1);
      _scroll.jumpTo(_scroll.position.maxScrollExtent * fraction);
      Future<void>.delayed(const Duration(milliseconds: 80), () async {
        if (!mounted) return;
        final targetContext = _initialTargetKey.currentContext;
        if (targetContext != null && targetContext.mounted) {
          await Scrollable.ensureVisible(
            targetContext,
            alignment: 0.45,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
          );
        }
        if (!mounted) return;
        setState(() => _highlightRef = target);
        _highlightTimer = Timer(const Duration(milliseconds: 1800), () {
          if (mounted) setState(() => _highlightRef = null);
        });
      });
    });
  }

  Future<bool> _postGroupMessage(
    GroupService svc,
    String body, {
    MediaObject? attachment,
    List<InlineCustomEmoji> customEmoji = const [],
    bool clearInput = false,
    bool consumeReply = true,
  }) async {
    final reply = consumeReply ? _replyTarget?.ref : null;
    final posted = await svc.postMessage(
      _gid,
      body,
      channelId: _channelId,
      attachment: attachment,
      replyTo: reply,
      customEmoji: customEmoji,
    );
    if (!mounted) return posted;
    if (!posted) {
      _snack(AppL10n.of(context).groupOperationFailed);
      return false;
    }
    if (clearInput) _input.clearWithCustomEmoji();
    if (consumeReply && _replyTarget != null) {
      setState(() => _replyTarget = null);
    }
    return true;
  }

  /// Quick reactions offered in the long-press sheet.
  static const _quickEmojis = ['👍', '❤', '😂', '😮', '😢', '🙏'];

  Future<(List<GroupMessage>, Map<String, MessageReactions>)> _loadFeed(
    GroupService svc,
  ) async {
    final msgs = await svc.messagesOf(_gid, channelId: _channelId);
    final reacts = await svc.reactionsOf(_gid);
    // Everything rendered is read — advance the unread watermark (covers both
    // opening the chat and messages arriving while it is open).
    unawaited(svc.markGroupSeen(_gid));
    // And separately record WHAT was rendered, in message coverage, for the
    // hide-after-read window. Separate because the seen watermark is a
    // wall-clock reading for the badge, and the two agree only while nobody's
    // clock lies.
    unawaited(
      svc.recordSpaceShown(_gid, channelId: _channelId, messages: msgs),
    );
    return (msgs, reacts);
  }

  /// Long-press on a message: quick-react emojis + a Reply action. The emoji
  /// bar honors the "show reactions" display preference.
  Future<void> _showMessageMenu(GroupService svc, GroupMessage m) async {
    final l = AppL10n.of(context);
    final showReactions = ref.read(showReactionsProvider);
    final state = await svc.stateOf(_gid);
    final bundle = await svc.load(_gid);
    final myRole = state?.roleOf(svc.selfId);
    final targetRole = state?.roleOf(m.author);
    final canModerate =
        bundle?.manifest.isSpace == true &&
        !m.isChannelEncrypted &&
        myRole != null &&
        targetRole != null &&
        m.author != svc.selfId &&
        canApply(
          authorRole: myRole,
          op: ControlOp.moderate,
          targetRole: targetRole,
        );
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showReactions)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Wrap(
                  alignment: WrapAlignment.center,
                  children: [
                    for (final e in _quickEmojis)
                      InkWell(
                        onTap: () {
                          Navigator.of(sheetCtx).pop();
                          svc.react(_gid, m.ref, e);
                        },
                        borderRadius: BorderRadius.circular(24),
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Text(e, style: const TextStyle(fontSize: 26)),
                        ),
                      ),
                  ],
                ),
              ),
            ListTile(
              leading: const Icon(Icons.reply),
              title: Text(l.groupReply),
              onTap: () {
                Navigator.of(sheetCtx).pop();
                setState(() => _replyTarget = m);
              },
            ),
            if (canModerate)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: Text(l.spaceModerationDeleteMessage),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  unawaited(_moderateDeleteMessage(svc, m));
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _moderateDeleteMessage(
    GroupService service,
    GroupMessage message,
  ) async {
    final l = AppL10n.of(context);
    final reason = await showDialog<String>(
      context: context,
      builder: (dialogContext) => const _ModerationReasonDialog(),
    );
    if (reason == null) return;
    final channelId = message.channelId ?? _channelId;
    final actionId = await service.moderateSpace(
      _gid,
      kind: SpaceModerationKind.deleteMessage,
      target: message.author,
      scope: channelId == null
          ? SpaceModerationScope.space
          : SpaceModerationScope.channel,
      reason: reason,
      channelId: channelId,
      reference: SpaceModerationReference(
        kind: SpaceModerationReferenceKind.message,
        author: message.author,
        seq: message.seq,
        channelId: channelId,
      ),
    );
    if (actionId == null && mounted) {
      _snack(l.spaceOperationFailed);
    }
  }

  /// Display name for a reactor: me → "You", a known contact → its alias,
  /// otherwise the short node id (group members need not be contacts).
  String _reactorName(NodeId id, GroupService svc, AppL10n l) {
    if (id == svc.selfId) return l.reactorsYou;
    final convos =
        ref.read(conversationsProvider).value ?? const <Conversation>[];
    for (final c in convos) {
      if (c.peer.nodeId == id) return c.peer.label;
    }
    return id.short;
  }

  /// Long-press on a reaction chip: who set what on this message.
  Future<void> _showReactors(GroupService svc, MessageReactions r) {
    final l = AppL10n.of(context);
    return showReactorsSheet(
      context,
      namesByEmoji: {
        for (final e in r.entries)
          e.key: [for (final n in e.value) _reactorName(n, svc, l)],
      },
    );
  }

  Future<void> _send(GroupService svc) async {
    final wire = _input.toWireValue();
    if (wire.body.isEmpty) return;
    await _postGroupMessage(
      svc,
      wire.body,
      customEmoji: wire.customEmoji,
      clearInput: true,
    );
  }

  /// A one-line preview of [m] for the reply bar / quote block (shared helper
  /// — attachments show a human kind label, never an opaque container name).
  String _msgPreview(GroupMessage m, AppL10n l) =>
      groupMessagePreviewText(l, m);

  /// Tap the mic: register the clip in the encrypted content store and keep
  /// only its strict reference in the signed/encrypted message. This avoids an
  /// inline clear-media fallback in protected channels at every clip length.
  Future<void> _sendVoiceClip(GroupService svc, VoiceClip clip) async {
    if (clip.bytes.isEmpty) return;
    final cid = await ref
        .read(messagingServiceProvider)
        .registerGroupContent(clip.bytes, name: 'voice.vop1');
    final duration = clip.durationMs > 0 ? clip.durationMs : 1;
    await _postGroupMessage(
      svc,
      '',
      attachment: MediaObject(
        kind: 'voice',
        contentId: cid,
        size: clip.bytes.length,
        width: duration,
        height: 1,
        durationMs: duration,
      ),
    );
  }

  /// Tap the camera: start a video-note recording; tap again: finish + post
  /// as a content-path REF (VN01 bytes are far too big for inline chunks).
  Future<void> _sendVnoteClip(GroupService svc, VnoteClip clip) async {
    if (clip.bytes.isEmpty) return;
    final cid = await ref
        .read(messagingServiceProvider)
        .registerGroupContent(clip.bytes, name: 'vnote.vn01');
    await _postGroupMessage(
      svc,
      '',
      attachment: MediaObject(
        kind: 'vnote',
        contentId: cid,
        size: clip.bytes.length,
        width: clip.durationMs > 0 ? clip.durationMs : 1,
        height: 1,
        durationMs: clip.durationMs > 0 ? clip.durationMs : 1,
      ),
    );
  }

  /// The "replying to …" bar shown above the composer.
  Widget _replyBar(BuildContext context, AppL10n l) {
    final t = _replyTarget!;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        border: Border(left: BorderSide(color: scheme.primary, width: 3)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  t.author.short,
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(color: scheme.primary),
                ),
                Text(
                  _msgPreview(t, l),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: AppL10n.of(context).actionCancel,
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => setState(() => _replyTarget = null),
          ),
        ],
      ),
    );
  }

  /// Pick an image and post it inline (groups media brick 1). The picture is
  /// downscaled + size-capped into the signed message so every member renders
  /// it without a content fetch; any caption typed in the composer rides along.
  Future<void> _attachImage(GroupService svc, {PlatformFile? selected}) async {
    final l = AppL10n.of(context);
    final picked = selected == null
        ? await FilePicker.pickFiles(type: FileType.image)
        : null;
    final file = selected ?? picked?.files.firstOrNull;
    if (file == null) return; // cancelled
    if (!isImageFileName(file.name)) {
      if (mounted) _snack(l.groupImageOnly);
      return;
    }
    final path = file.path;
    int? diskSize;
    if (path != null) {
      try {
        diskSize = await File(path).length();
      } catch (_) {}
    }
    if (path != null && diskSize != null && diskSize > kMaxIncomingFileBytes) {
      final size = diskSize;
      final sourcePath = File(path).absolute.path;
      final source = await veilSourceOpener(sourcePath);
      if (source == null) {
        if (mounted) _snack(l.chatFileUnreadable);
        return;
      }
      final InlineImage? thumb = await makeInlineImageFromPath(
        sourcePath,
        rawMax: _kRefThumbRawMax,
      );
      final String cid;
      try {
        cid = await ref
            .read(messagingServiceProvider)
            .registerGroupContentStreaming(
              file.name,
              size,
              source.read,
              close: source.close,
              sourcePath: sourcePath,
            );
      } catch (_) {
        if (mounted) _snack(l.chatFileUnreadable);
        return;
      }
      final caption = _input.toWireValue();
      await _postGroupMessage(
        svc,
        caption.body,
        customEmoji: caption.customEmoji,
        clearInput: true,
        attachment: MediaObject(
          // If the platform codec cannot make a bounded preview, keep the
          // bytes accessible as a normal file row instead of rejecting it.
          kind: thumb == null ? 'file' : 'image',
          dataB64: thumb?.b64 ?? 'QQ==',
          w: thumb?.w ?? size,
          h: thumb?.h ?? 1,
          cid: cid,
          name: file.name,
        ),
      );
      return;
    }
    Uint8List? bytes = file.bytes;
    if (bytes == null && path != null) {
      try {
        bytes = await File(path).readAsBytes();
      } catch (_) {
        /* fall through to the null check */
      }
    }
    if (bytes == null) return;
    if (bytes.length > kMaxIncomingFileBytes) {
      if (mounted) _snack(l.chatFileTooLarge);
      return;
    }
    // Content path (doc/GROUPS-CONTENT-PATH.md): the message carries only a
    // small thumb + the contentId; members stream the ORIGINAL bytes from us.
    // Fall back to the legacy full-inline payload when no thumb rung fits.
    final thumb = await makeInlineImageB64(bytes, rawMax: _kRefThumbRawMax);
    final caption = _input.toWireValue();
    if (thumb != null) {
      final cid = await ref
          .read(messagingServiceProvider)
          .registerGroupContent(bytes, name: file.name);
      await _postGroupMessage(
        svc,
        caption.body,
        customEmoji: caption.customEmoji,
        clearInput: true,
        attachment: MediaObject(
          kind: 'image',
          dataB64: thumb.b64,
          w: thumb.w,
          h: thumb.h,
          cid: cid,
          name: file.name,
        ),
      );
      return;
    }
    final img = await makeInlineImageB64(bytes);
    if (img == null) {
      if (mounted) _snack(l.groupImageTooLarge);
      return;
    }
    final cid = await ref
        .read(messagingServiceProvider)
        .registerGroupContent(bytes, name: file.name);
    await _postGroupMessage(
      svc,
      caption.body,
      customEmoji: caption.customEmoji,
      clearInput: true,
      attachment: MediaObject(
        kind: 'image',
        contentId: cid,
        size: bytes.length,
        width: img.w,
        height: img.h,
        name: file.name,
      ),
    );
  }

  /// The ref-form thumb cap (raw PNG bytes): small enough to fan out fast
  /// (~9 chunks), big enough to preview while the full bytes stream in.
  static const int _kRefThumbRawMax = 16000;

  Future<void> _pickGroupMedia(
    GroupService svc, {
    FileType type = FileType.any,
    List<String>? allowedExtensions,
  }) async {
    final picked = await FilePicker.pickFiles(
      type: type,
      allowedExtensions: allowedExtensions,
    );
    final file = picked?.files.firstOrNull;
    if (file != null) await _postGroupFile(svc, file);
  }

  Future<Uint8List?> _readPlatformFile(PlatformFile file) async {
    if (file.bytes != null) return file.bytes;
    if (file.path == null) return null;
    try {
      return await File(file.path!).readAsBytes();
    } catch (_) {
      return null;
    }
  }

  /// Generic group content path. Images keep their existing signed thumbnail
  /// treatment; video/document rows carry only an optional micro-preview,
  /// filename, byte size and membership-authorized cid.
  Future<void> _postGroupFile(GroupService svc, PlatformFile file) async {
    if (isImageFileName(file.name)) {
      await _attachImage(svc, selected: file);
      return;
    }
    var size = file.size;
    if (file.path != null) {
      try {
        size = await File(file.path!).length();
      } catch (_) {}
    }
    if (size <= 0) {
      if (mounted) _snack(AppL10n.of(context).chatFileUnreadable);
      return;
    }
    final messaging = _messaging;
    final String cid;
    if (file.path != null) {
      final path = File(file.path!).absolute.path;
      final source = await veilSourceOpener(path);
      if (source == null) {
        if (mounted) _snack(AppL10n.of(context).chatFileUnreadable);
        return;
      }
      try {
        cid = await messaging.registerGroupContentStreaming(
          file.name,
          size,
          source.read,
          close: source.close,
          sourcePath: path,
        );
      } catch (_) {
        if (mounted) _snack(AppL10n.of(context).chatFileUnreadable);
        return;
      }
    } else {
      // Native pickers provide a path. Keep the bounded in-memory fallback for
      // pathless platforms, but never accept an already-materialized giant
      // buffer into this route.
      if (size > kMaxIncomingFileBytes) {
        if (mounted) _snack(AppL10n.of(context).chatFileTooLarge);
        return;
      }
      final bytes = await _readPlatformFile(file);
      if (bytes == null || bytes.isEmpty) {
        if (mounted) _snack(AppL10n.of(context).chatFileUnreadable);
        return;
      }
      cid = await messaging.registerGroupContent(bytes, name: file.name);
    }
    String? thumb;
    if (isVideoFileName(file.name) && file.path != null) {
      thumb = await makeVideoThumbB64(file.path!);
    }
    final caption = _input.toWireValue();
    await _postGroupMessage(
      svc,
      caption.body,
      customEmoji: caption.customEmoji,
      clearInput: true,
      attachment: MediaObject(
        kind: isVideoFileName(file.name) ? 'video' : 'file',
        dataB64: thumb ?? 'QQ==',
        w: size,
        h: 1,
        cid: cid,
        name: file.name,
      ),
    );
  }

  Future<void> _handleAttachmentAction(
    GroupService svc,
    ComposerAttachmentAction action,
  ) async {
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
          await _postGroupFile(
            svc,
            PlatformFile(name: captured.name, size: size, path: captured.path),
          );
        } finally {
          try {
            await source.delete();
          } catch (_) {}
        }
      case ComposerAttachmentAction.photo:
        await _pickGroupMedia(svc, type: FileType.image);
      case ComposerAttachmentAction.video:
        await _pickGroupMedia(svc, type: FileType.video);
      case ComposerAttachmentAction.file:
        await _pickGroupMedia(svc);
      case ComposerAttachmentAction.gif:
        await _pickGroupMedia(
          svc,
          type: FileType.custom,
          allowedExtensions: const ['gif'],
        );
      case ComposerAttachmentAction.voice ||
          ComposerAttachmentAction.videoNote ||
          ComposerAttachmentAction.poll ||
          ComposerAttachmentAction.location:
        return;
    }
  }

  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _startGroupCall({required bool video}) async {
    final calls = ref.read(groupCallServiceProvider);
    final started = await calls?.startCall(
      _gid,
      CallMedia(audio: true, video: video),
    );
    if (started != true && mounted) {
      _snack(AppL10n.of(context).groupCallBusy);
    }
  }

  /// Pick a sticker from the user's library and post it inline (kind='sticker'
  /// → borderless render). Reuses the 1:1 sticker sheet; a small static sticker
  /// fits the inline-attachment path (delta-broadcast, one-time chunk cost).
  Future<void> _sendGroupSticker(GroupService svc, String picked) async {
    if (picked.startsWith('pack:')) return; // no group pack-share yet
    final bytes = await ref
        .read(storageProvider)
        .loadFile(stickerFileKey(picked));
    if (bytes == null) return;
    final img = await makeInlineImageB64(bytes);
    if (img == null) return;
    await _postGroupMessage(
      svc,
      '',
      consumeReply: false,
      attachment: MediaObject(
        kind: 'sticker',
        dataB64: img.b64,
        w: img.w,
        h: img.h,
      ),
    );
  }

  /// The member roster + management actions (add / mute / role / remove). Every
  /// action is gated by [canApply] against MY current role, so the UI only
  /// offers what the control-log would actually accept; the service re-checks on
  /// commit. The sheet is reactive (svc.changes) so it refreshes after an op.
  Future<void> _showMembers(GroupService svc) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => StreamBuilder<int>(
        stream: svc.changes.stream,
        builder: (context, _) => FutureBuilder<GroupState?>(
          future: svc.stateOf(_gid),
          builder: (context, snap) {
            final l = AppL10n.of(context);
            final state = snap.data;
            if (state == null) {
              return const SafeArea(
                child: Padding(
                  padding: EdgeInsets.all(28),
                  child: Center(child: CircularProgressIndicator()),
                ),
              );
            }
            final myRole = state.roleOf(svc.selfId);
            final canAdd =
                myRole != null &&
                canApply(
                  authorRole: myRole,
                  op: ControlOp.addMember,
                  newRole: GroupRole.member,
                );
            return SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            l.groupMembers(state.members.length),
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        if (canAdd)
                          TextButton.icon(
                            onPressed: () => _addMember(svc, state),
                            icon: const Icon(Icons.person_add_alt),
                            label: Text(l.groupAddMember),
                          ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final m in state.members.values)
                          _memberTile(svc, myRole, m, l),
                      ],
                    ),
                  ),
                  if (myRole != null && myRole != GroupRole.owner)
                    ListTile(
                      leading: Icon(
                        Icons.logout,
                        color: Theme.of(context).colorScheme.error,
                      ),
                      title: Text(
                        l.groupLeave,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                      onTap: () => _leaveGroup(svc),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _showChannelMembers(GroupService svc) async {
    final channelId = _channelId;
    if (channelId == null) return _showMembers(svc);
    final state = await svc.stateOf(_gid);
    final channels = await svc.channelsOf(_gid, includeArchived: true);
    final channel = channels
        .where((candidate) => candidate.channelId == channelId)
        .firstOrNull;
    if (!mounted || state == null || channel == null) return;
    if (channel.access == SpaceChannelAccess.space) {
      await context.push('/space/${_gid.hex}/settings');
      return;
    }
    final current = await svc.channelMembersOf(_gid, channelId);
    if (!mounted || current == null) return;
    final canManage = SpaceAcl(state).allows(
      svc.selfId,
      SpacePermission.manageChannels,
      channelId: channel.channelId,
      categoryId: channel.categoryId,
    );
    final selected = current.map((member) => member.hex).toSet();
    final saved = await showDialog<Set<String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(AppL10n.of(context).groupMembers(selected.length)),
          content: SizedBox(
            width: 420,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final member in state.members.values)
                  CheckboxListTile(
                    value: selected.contains(member.nodeId.hex),
                    onChanged:
                        !canManage || member.role.rank >= GroupRole.admin.rank
                        ? null
                        : (value) => setDialogState(() {
                            if (value ?? false) {
                              selected.add(member.nodeId.hex);
                            } else {
                              selected.remove(member.nodeId.hex);
                            }
                          }),
                    secondary: Icon(
                      member.role.rank >= GroupRole.admin.rank
                          ? Icons.shield_outlined
                          : Icons.person_outline,
                    ),
                    title: Text(member.nodeId.short),
                    subtitle: Text(member.role.name),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(AppL10n.of(context).actionCancel),
            ),
            if (canManage)
              FilledButton(
                onPressed: () =>
                    Navigator.of(dialogContext).pop(Set<String>.from(selected)),
                child: Text(AppL10n.of(context).actionSave),
              ),
          ],
        ),
      ),
    );
    if (saved == null) return;
    final applied = await svc.setChannelMembers(
      _gid,
      channelId,
      state.members.values
          .where((member) => saved.contains(member.nodeId.hex))
          .map((member) => member.nodeId),
    );
    if (!applied && mounted) {
      _snack(AppL10n.of(context).groupOperationFailed);
    }
  }

  /// Confirm + convert this group chat into a community (Space). Irreversible
  /// in practice: the chat gains a signed Space manifest and a default text
  /// channel, moves to «Сообщества», and keeps its members/history.
  /// The current window is read HERE rather than kept in the app bar's
  /// FutureBuilder: it is needed once, when the sheet opens, and putting it in
  /// the builder would re-read the signed timeline on every rebuild of a screen
  /// that rebuilds on every incoming message.
  Future<void> _pickDisappearing(GroupService svc) async {
    final current = groupDisappearingWindow(
      await svc.spaceRetentionPolicyOf(_gid),
    );
    if (!mounted) return;
    await pickGroupDisappearing(context, svc, _gid, current);
    if (mounted) setState(() {});
  }

  Future<void> _convertToCommunity(GroupService svc) async {
    final l = AppL10n.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.groupConvertToCommunity),
        content: Text(l.groupConvertConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            key: const ValueKey('group-convert-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l.groupConvertAction),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final converted = await svc.convertGroupToSpace(_gid);
    if (!mounted) return;
    if (!converted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.groupOperationFailed)));
      return;
    }
    // The chat is now a Space; open it in the communities section. Root the
    // stack at home and PUSH the space: a bare go() replaces the stack, so the
    // space hub would have nothing below it (flat router → canPop false) and
    // back — the arrow and the Android system gesture alike — would be stuck.
    GoRouter.of(context)
      ..go('/home')
      ..push('/space/${_gid.hex}');
  }

  /// Confirm + leave the group: closes the member sheet and returns to the list.
  Future<void> _leaveGroup(GroupService svc) async {
    final l = AppL10n.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.groupLeave),
        content: Text(l.groupLeaveConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l.groupLeave),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final left = await svc.leaveGroup(_gid);
    if (!mounted) return;
    if (!left) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.groupOperationFailed)));
      return;
    }
    final nav = Navigator.of(context);
    nav.pop(); // close the member sheet
    nav.pop(); // return to the group list
  }

  Widget _memberTile(
    GroupService svc,
    GroupRole? myRole,
    GroupMember m,
    AppL10n l,
  ) {
    final isSelf = m.nodeId == svc.selfId;
    final actions = <PopupMenuEntry<String>>[];
    if (myRole != null && !isSelf) {
      final tr = m.role;
      if (canApply(
        authorRole: myRole,
        op: m.muted ? ControlOp.unmute : ControlOp.mute,
        targetRole: tr,
      )) {
        actions.add(
          PopupMenuItem(
            value: m.muted ? 'unmute' : 'mute',
            child: Text(m.muted ? l.groupUnmute : l.groupMute),
          ),
        );
      }
      if (m.role == GroupRole.member &&
          canApply(
            authorRole: myRole,
            op: ControlOp.setRole,
            targetRole: tr,
            newRole: GroupRole.admin,
          )) {
        actions.add(
          PopupMenuItem(value: 'promote', child: Text(l.groupPromote)),
        );
      }
      if (m.role == GroupRole.admin &&
          canApply(
            authorRole: myRole,
            op: ControlOp.setRole,
            targetRole: tr,
            newRole: GroupRole.member,
          )) {
        actions.add(PopupMenuItem(value: 'demote', child: Text(l.groupDemote)));
      }
      if (canApply(
        authorRole: myRole,
        op: ControlOp.removeMember,
        targetRole: tr,
      )) {
        actions.add(PopupMenuItem(value: 'remove', child: Text(l.groupRemove)));
      }
    }
    return ListTile(
      dense: true,
      leading: Icon(
        m.role == GroupRole.owner
            ? Icons.star
            : (m.role == GroupRole.admin
                  ? Icons.shield_outlined
                  : Icons.person_outline),
      ),
      title: Text(m.nodeId.short),
      subtitle: Text(m.role.name),
      trailing: actions.isEmpty
          ? (m.muted ? const Icon(Icons.volume_off, size: 16) : null)
          : PopupMenuButton<String>(
              itemBuilder: (_) => actions,
              onSelected: (v) => _memberAction(svc, m, v),
            ),
    );
  }

  Future<void> _memberAction(
    GroupService svc,
    GroupMember m,
    String action,
  ) async {
    var applied = false;
    switch (action) {
      case 'mute':
        applied = await svc.addControlOp(
          _gid,
          ControlOp.mute,
          target: m.nodeId,
        );
      case 'unmute':
        applied = await svc.addControlOp(
          _gid,
          ControlOp.unmute,
          target: m.nodeId,
        );
      case 'promote':
        applied = await svc.addControlOp(
          _gid,
          ControlOp.setRole,
          target: m.nodeId,
          role: GroupRole.admin,
        );
      case 'demote':
        applied = await svc.addControlOp(
          _gid,
          ControlOp.setRole,
          target: m.nodeId,
          role: GroupRole.member,
        );
      case 'remove':
        applied = await svc.addControlOp(
          _gid,
          ControlOp.removeMember,
          target: m.nodeId,
        );
    }
    if (!applied && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppL10n.of(context).groupOperationFailed)),
      );
    }
  }

  /// Pick an accepted contact not already in the group and add them as a member
  /// (a full snapshot broadcast syncs the whole history to the joiner).
  Future<void> _addMember(GroupService svc, GroupState state) async {
    final l = AppL10n.of(context);
    final convos =
        ref.read(conversationsProvider).value ?? const <Conversation>[];
    final candidates = [
      for (final c in convos)
        if (c.peer.status == ContactStatus.accepted &&
            !state.isMember(c.peer.nodeId))
          c.peer,
    ];
    if (candidates.isEmpty) {
      _snack(l.groupNoContactsToAdd);
      return;
    }
    final picked = await showModalBottomSheet<NodeId>(
      context: context,
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final c in candidates)
              ListTile(
                leading: CircleAvatar(
                  child: Text(
                    ((c.name?.isNotEmpty ?? false) ? c.name! : c.nodeId.short)
                        .characters
                        .first
                        .toUpperCase(),
                  ),
                ),
                title: Text(
                  (c.name?.isNotEmpty ?? false) ? c.name! : c.nodeId.short,
                ),
                subtitle: Text(c.nodeId.short),
                onTap: () => Navigator.of(context).pop(c.nodeId),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    final added = await svc.addControlOp(
      _gid,
      ControlOp.addMember,
      target: picked,
      role: GroupRole.member,
    );
    if (!added && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.groupOperationFailed)));
    }
  }

  /// Tap the title → rename the group. Admins+ succeed (the op folds into every
  /// member's view via a signed setName delta); others get a "no permission"
  /// note, since renameGroup returns false when the fold would reject the op.
  Future<void> _renameDialog(GroupService svc, String current) async {
    final l = AppL10n.of(context);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _GroupRenameDialog(
        initial: current,
        title: l.groupRenameTitle,
        hint: l.spaceNameHint,
        cancelLabel: l.actionCancel,
        renameLabel: l.groupRenameAction,
      ),
    );
    if (name == null || name.isEmpty || name == current.trim()) return;
    final ok = await svc.renameGroup(_gid, name);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.groupRenameDenied)));
    }
  }

  Future<void> _showSyncSettings(GroupService svc) async {
    final l = AppL10n.of(context);
    var selected = await svc.groupSyncNeighborCount(_gid);
    if (!mounted) return;
    final saved = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(l.groupSyncNeighborsTitle),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.groupSyncNeighborsLabel(selected)),
                Slider(
                  key: const ValueKey('group-sync-neighbors-slider'),
                  min: GroupService.kMinGroupSyncNeighbors.toDouble(),
                  max: GroupService.kMaxGroupSyncNeighbors.toDouble(),
                  divisions:
                      GroupService.kMaxGroupSyncNeighbors -
                      GroupService.kMinGroupSyncNeighbors,
                  value: selected.toDouble(),
                  label: '$selected',
                  onChanged: (value) =>
                      setDialogState(() => selected = value.round()),
                ),
                Text(
                  l.groupSyncNeighborsHint,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l.actionCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(selected),
              child: Text(l.actionSave),
            ),
          ],
        ),
      ),
    );
    if (saved == null) return;
    await svc.setGroupSyncNeighborCount(_gid, saved);
    unawaited(svc.nudgeGroupSync(_gid));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    // The identity moved under this screen. A group conversation is A's, and
    // B is not in it — leave rather than repaint it.
    if (!identical(ref.watch(storageProvider), _storage)) return _leftBehind();
    final svc = ref.watch(groupServiceProvider);
    if (svc == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(
        leading: const RootedBackButton(),
        title: FutureBuilder<List<Object?>>(
          future: Future.wait<Object?>([
            svc.stateOf(_gid),
            if (_channelId != null) svc.channelsOf(_gid),
          ]),
          builder: (context, snap) {
            final state = snap.data?.firstOrNull as GroupState?;
            final channels = snap.data != null && snap.data!.length > 1
                ? snap.data![1] as List<SpaceChannel>
                : const <SpaceChannel>[];
            final spaceName = state?.name;
            final name = _channelId == null
                ? spaceName
                : channels
                      .where((channel) => channel.channelId == _channelId)
                      .firstOrNull
                      ?.name;
            return InkWell(
              onTap: _channelId == null
                  ? () => _renameDialog(svc, spaceName ?? '')
                  : null,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      name == null || name.isEmpty
                          ? (_channelId == null ? l.navChats : l.navCommunities)
                          : name,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (state != null) ...[
                    const SizedBox(width: 8),
                    Tooltip(
                      message: state.epochDescriptor != null
                          ? l.groupEncrypted
                          : l.groupEncryptionPending,
                      child: Icon(
                        state.epochDescriptor != null
                            ? Icons.lock_outline
                            : Icons.lock_open_outlined,
                        size: 16,
                        color: state.epochDescriptor != null
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        ),
        actions: [
          // No engine, no group call. Without this gate a start attempt fails
          // inside the FSM and the only feedback is `groupCallBusy` — a build
          // that cannot do calls at all telling everyone the call is busy.
          if (_channelId == null && _mediaAvailable) ...[
            IconButton(
              key: const ValueKey('group-call-start-audio'),
              icon: const Icon(Icons.call_outlined),
              tooltip: l.groupCallStartAudio,
              onPressed: () => _startGroupCall(video: false),
            ),
            IconButton(
              key: const ValueKey('group-call-start-video'),
              icon: const Icon(Icons.videocam_outlined),
              tooltip: l.groupCallStartVideo,
              onPressed: () => _startGroupCall(video: true),
            ),
          ],
          IconButton(
            icon: const Icon(Icons.group_outlined),
            tooltip: _channelId == null
                ? l.groupMembersTooltip
                : l.spaceMembersTooltip,
            onPressed: () => _showChannelMembers(svc),
          ),
          IconButton(
            key: const ValueKey('group-sync-settings'),
            icon: const Icon(Icons.hub_outlined),
            tooltip: l.groupSyncSettingsTooltip,
            onPressed: () => _showSyncSettings(svc),
          ),
          // Owner-only, group-chat-only: the explicit "convert this chat into
          // a community" action the canon reserves as a confirmed operation,
          // and the disappearing window, which is owner-only for the same
          // reason (`manageStorage` is not a built-in below owner).
          if (_channelId == null)
            FutureBuilder<List<Object?>>(
              future: Future.wait<Object?>([svc.stateOf(_gid), svc.load(_gid)]),
              builder: (context, snap) {
                final state = snap.data?.firstOrNull as GroupState?;
                final bundle = snap.data != null && snap.data!.length > 1
                    ? snap.data![1] as GroupBundle?
                    : null;
                final ownedGroupChat =
                    bundle != null &&
                    bundle.manifest.isLegacyGroup &&
                    !bundle.manifest.isSpace &&
                    state?.roleOf(svc.selfId) == GroupRole.owner;
                final member =
                    bundle != null && state?.memberOf(svc.selfId) != null;
                if (!member) return const SizedBox.shrink();
                // An overflow menu rather than two more icons. The bar already
                // carries four actions, and a sixth overflowed the row on a
                // narrow phone — content the owner cannot see or reach.
                //
                // Shown to every member now, not only the owner: the local
                // hide-after-read ceiling is a personal display preference and
                // gating it behind a role would be refusing someone the right
                // to see less.
                return PopupMenuButton<_GroupOwnerAction>(
                  key: const ValueKey('group-owner-menu'),
                  onSelected: (action) => switch (action) {
                    _GroupOwnerAction.disappearing => _pickDisappearing(svc),
                    _GroupOwnerAction.hideAfterRead => pickGroupHideAfterRead(
                      context,
                      svc,
                      _gid,
                      signed: true,
                    ),
                    _GroupOwnerAction.hideAfterReadLocal =>
                      pickGroupHideAfterRead(context, svc, _gid, signed: false),
                    _GroupOwnerAction.convert => _convertToCommunity(svc),
                  },
                  itemBuilder: (_) => [
                    if (ownedGroupChat) ...[
                      PopupMenuItem(
                        key: const ValueKey('group-disappearing'),
                        value: _GroupOwnerAction.disappearing,
                        child: Text(l.groupDisappearingTooltip),
                      ),
                      PopupMenuItem(
                        key: const ValueKey('group-hide-after-read'),
                        value: _GroupOwnerAction.hideAfterRead,
                        child: Text(l.groupHideAfterReadTitle),
                      ),
                    ],
                    PopupMenuItem(
                      key: const ValueKey('group-hide-after-read-local'),
                      value: _GroupOwnerAction.hideAfterReadLocal,
                      child: Text(l.groupHideAfterReadLocalTitle),
                    ),
                    if (ownedGroupChat)
                      PopupMenuItem(
                        key: const ValueKey('group-convert-to-community'),
                        value: _GroupOwnerAction.convert,
                        child: Text(l.groupConvertToCommunity),
                      ),
                  ],
                );
              },
            ),
        ],
      ),
      body: Column(
        children: [
          if (_channelId == null) _GroupCallBanner(gid: _gid),
          Expanded(
            child: StreamBuilder<int>(
              stream: svc.changes.stream,
              builder: (context, _) =>
                  FutureBuilder<
                    (List<GroupMessage>, Map<String, MessageReactions>)
                  >(
                    future: _loadFeed(svc),
                    builder: (context, snap) {
                      final msgs = snap.data?.$1 ?? const <GroupMessage>[];
                      _scheduleInitialJump(msgs);
                      final showReactions = ref.watch(showReactionsProvider);
                      final reacts = !showReactions
                          ? const <String, MessageReactions>{}
                          : snap.data?.$2 ?? const <String, MessageReactions>{};
                      if (msgs.isEmpty) {
                        return Center(child: Text(l.groupNoMessages));
                      }
                      final byRef = {for (final m in msgs) m.ref: m};
                      return ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.all(8),
                        itemCount: msgs.length,
                        itemBuilder: (context, i) {
                          final m = msgs[i];
                          final mine = m.author == svc.selfId;
                          return AnimatedContainer(
                            key: m.ref == widget.initialJumpTo
                                ? _initialTargetKey
                                : null,
                            duration: const Duration(milliseconds: 400),
                            color: m.ref == _highlightRef
                                ? Theme.of(
                                    context,
                                  ).colorScheme.primary.withValues(alpha: 0.14)
                                : Colors.transparent,
                            child: _GroupBubble(
                              message: m,
                              mine: mine,
                              selfId: svc.selfId,
                              quoted: m.replyTo == null
                                  ? null
                                  : byRef[m.replyTo],
                              reactions: reacts[m.ref],
                              onLongPress: () => _showMessageMenu(svc, m),
                              onToggleReaction: (e) =>
                                  svc.react(_gid, m.ref, e),
                              onShowReactors: () {
                                final r = reacts[m.ref];
                                if (r != null && r.isNotEmpty) {
                                  _showReactors(svc, r);
                                }
                              },
                              onFetchContent: m.attachment?.cid == null
                                  ? null
                                  : () => svc.fetchGroupContent(
                                      _gid,
                                      m.attachment!.cid!,
                                      m.author,
                                    ),
                            ),
                          );
                        },
                      );
                    },
                  ),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_replyTarget != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: _replyBar(context, l),
                ),
              FutureBuilder<GroupState?>(
                future: svc.stateOf(_gid),
                builder: (context, stateSnapshot) =>
                    FutureBuilder<List<SpaceChannel>>(
                      future: _channelId == null
                          ? Future.value(const <SpaceChannel>[])
                          : svc.channelsOf(_gid),
                      builder: (context, channelSnapshot) {
                        final protected =
                            _channelId != null &&
                            (channelSnapshot.connectionState !=
                                    ConnectionState.done ||
                                (channelSnapshot.data?.any(
                                      (channel) =>
                                          channel.channelId == _channelId &&
                                          channel.access !=
                                              SpaceChannelAccess.space,
                                    ) ??
                                    true));
                        return MessageComposer(
                          key: const ValueKey('group-message-composer'),
                          controller: _input,
                          focusNode: _inputFocus,
                          hint: l.chatNewMessageHint,
                          onSend: () => _send(svc),
                          mentionTargets:
                              stateSnapshot.data?.members.values
                                  .map((member) => member.nodeId)
                                  .toList(growable: false) ??
                              const [],
                          onAttachmentAction: (action) =>
                              _handleAttachmentAction(svc, action),
                          // Null with no engine — see the 1:1 composer.
                          onVoice: _mediaAvailable
                              ? (clip) => unawaited(_sendVoiceClip(svc, clip))
                              : null,
                          onVideoNote: _mediaAvailable
                              ? (clip) => unawaited(_sendVnoteClip(svc, clip))
                              : null,
                          onSticker: protected
                              ? null
                              : (itemId) =>
                                    unawaited(_sendGroupSticker(svc, itemId)),
                          allowStickerPackShare: false,
                        );
                      },
                    ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _GroupBubble extends StatelessWidget {
  const _GroupBubble({
    required this.message,
    required this.mine,
    required this.selfId,
    this.quoted,
    this.reactions,
    this.onLongPress,
    this.onToggleReaction,
    this.onShowReactors,
    this.onFetchContent,
  });
  final GroupMessage message;
  final bool mine;
  final NodeId selfId;

  /// The resolved message this one replies to (null if none / not held yet).
  final GroupMessage? quoted;

  /// This message's reactions (emoji -> reactors), or null if none.
  final MessageReactions? reactions;

  /// Long-press: open the react/reply menu.
  final VoidCallback? onLongPress;

  /// Tap a reaction chip to toggle that emoji.
  final void Function(String emoji)? onToggleReaction;

  /// Long-press (or right-click) a reaction chip: show who reacted.
  final VoidCallback? onShowReactors;

  /// Start the membership-authorized stream pull of this message's ref
  /// content (null when the attachment carries no cid).
  final VoidCallback? onFetchContent;

  /// The reaction chips shown under the bubble (empty widget if none).
  Widget _reactionChips(BuildContext context) {
    final r = reactions;
    if (r == null || r.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final entries = r.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));
    return Padding(
      padding: const EdgeInsets.only(top: 3, left: 4),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (final e in entries)
            InkWell(
              onTap: () => onToggleReaction?.call(e.key),
              onLongPress: onShowReactors,
              onSecondaryTap: onShowReactors,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: e.value.any((n) => n == selfId)
                      ? scheme.primaryContainer
                      : scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                  border: e.value.any((n) => n == selfId)
                      ? Border.all(color: scheme.primary, width: 1)
                      : null,
                ),
                child: Text(
                  '${e.key} ${e.value.length}',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// One-line preview of the quoted message for the in-bubble quote block
  /// (shared helper — kind labels, never an opaque container name).
  static String _preview(AppL10n l, GroupMessage m) =>
      groupMessagePreviewText(l, m);

  Widget _quoteBlock(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final q = quoted!;
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(8),
        border: Border(left: BorderSide(color: scheme.primary, width: 2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            q.author.short,
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: scheme.primary),
          ),
          Text(
            _preview(AppL10n.of(context), q),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l = AppL10n.of(context);
    final att = message.attachment;
    // A sticker renders BORDERLESS (no bubble background), like every messenger.
    if (att != null && att.kind == 'sticker' && message.body.isEmpty) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress: onLongPress,
        child: Align(
          alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
            child: Column(
              crossAxisAlignment: mine
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!mine)
                  Text(
                    message.author.short,
                    style: Theme.of(
                      context,
                    ).textTheme.labelSmall?.copyWith(color: scheme.primary),
                  ),
                SizedBox(
                  width: 140,
                  height: 140,
                  child: Image.memory(
                    base64Decode(att.dataB64),
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                    cacheWidth: mediaPreviewCacheDimension(
                      140,
                      MediaQuery.devicePixelRatioOf(context),
                    ),
                    cacheHeight: mediaPreviewCacheDimension(
                      140,
                      MediaQuery.devicePixelRatioOf(context),
                    ),
                    errorBuilder: (_, _, _) =>
                        const Icon(Icons.broken_image_outlined),
                  ),
                ),
                _reactionChips(context),
              ],
            ),
          ),
        ),
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: onLongPress,
      child: Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: Column(
          crossAxisAlignment: mine
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.symmetric(vertical: 3),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.75,
              ),
              decoration: BoxDecoration(
                color: mine
                    ? scheme.primaryContainer
                    : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!mine)
                    Text(
                      message.author.short,
                      style: Theme.of(
                        context,
                      ).textTheme.labelSmall?.copyWith(color: scheme.primary),
                    ),
                  if (quoted != null) _quoteBlock(context),
                  if (message.mediaHiddenByRetention)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.hide_image_outlined, size: 17),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              l.spaceRetentionMediaExpired,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (message.attachment != null &&
                      message.attachment!.kind == 'voice')
                    _GroupVoiceRow(
                      messageRef: message.ref,
                      attachment: message.attachment!,
                      onFetch: onFetchContent,
                    ),
                  if (message.attachment != null &&
                      message.attachment!.kind == 'vnote')
                    _GroupVnoteCircle(
                      messageRef: message.ref,
                      attachment: message.attachment!,
                      onFetch: onFetchContent,
                    ),
                  if (message.attachment != null &&
                      message.attachment!.kind == 'image')
                    Padding(
                      padding: EdgeInsets.only(
                        bottom: message.body.isEmpty ? 0 : 6,
                      ),
                      child: ConstrainedBox(
                        // Keep an inline photo to a sensible size regardless of the
                        // (small) encoded resolution or a wide desktop bubble.
                        constraints: const BoxConstraints(
                          maxWidth: 240,
                          maxHeight: 320,
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: AspectRatio(
                            aspectRatio: message.attachment!.h == 0
                                ? 1
                                : message.attachment!.w / message.attachment!.h,
                            child: message.attachment!.cid != null
                                ? _GroupRefImage(
                                    attachment: message.attachment!,
                                    onFetch: onFetchContent,
                                  )
                                : Image.memory(
                                    base64Decode(message.attachment!.dataB64),
                                    fit: BoxFit.cover,
                                    gaplessPlayback: true,
                                    cacheWidth: mediaPreviewCacheDimension(
                                      240,
                                      MediaQuery.devicePixelRatioOf(context),
                                    ),
                                    cacheHeight: mediaPreviewCacheDimension(
                                      320,
                                      MediaQuery.devicePixelRatioOf(context),
                                    ),
                                    errorBuilder: (_, _, _) =>
                                        const Icon(Icons.broken_image_outlined),
                                  ),
                          ),
                        ),
                      ),
                    ),
                  if (message.attachment != null &&
                      (message.attachment!.kind == 'video' ||
                          message.attachment!.kind == 'file'))
                    _GroupFileAttachment(
                      attachment: message.attachment!,
                      onFetch: onFetchContent,
                    ),
                  if (message.body.isNotEmpty)
                    FormattedText(
                      message.body,
                      customEmoji: message.customEmoji,
                    ),
                ],
              ),
            ),
            _reactionChips(context),
          ],
        ),
      ),
    );
  }
}

String _formatGroupBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} KB';
  final mb = kb / 1024;
  return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
}

class _GroupFileAttachment extends ConsumerWidget {
  const _GroupFileAttachment({required this.attachment, this.onFetch});

  final MediaObject attachment;
  final VoidCallback? onFetch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cid = attachment.cid;
    if (cid == null) return const SizedBox.shrink();
    final progress = ref.watch(contentProgressProvider.select((m) => m[cid]));
    final resuming = ref.watch(
      contentResumingProvider.select((ids) => ids.contains(cid)),
    );
    final downloading = progress != null || resuming;
    void cancel() => _cancelGroupContentDownload(ref, cid);
    final isVideo = attachment.kind == 'video';
    Uint8List? thumb;
    if (isVideo && attachment.dataB64 != 'QQ==') {
      try {
        thumb = base64Decode(attachment.dataB64);
      } catch (_) {}
    }
    return FutureBuilder<bool>(
      future: ref.read(storageProvider).hasFile(cid).catchError((_) => false),
      builder: (context, snapshot) {
        final held = snapshot.data ?? false;
        final scheme = Theme.of(context).colorScheme;
        if (isVideo && thumb != null) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: InkWell(
              onTap: downloading
                  ? cancel
                  : held
                  ? () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => VideoPlayerScreen(
                          fileKey: cid,
                          name: attachment.name ?? '',
                        ),
                      ),
                    )
                  : onFetch,
              borderRadius: BorderRadius.circular(10),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 220,
                  height: 124,
                  child: Stack(
                    fit: StackFit.expand,
                    alignment: Alignment.center,
                    children: [
                      Image.memory(thumb, fit: BoxFit.cover),
                      ColoredBox(color: Colors.black.withValues(alpha: 0.18)),
                      if (downloading)
                        Center(
                          child: CancelableDownloadProgress(
                            progress: progress,
                            onCancel: cancel,
                            size: 42,
                            strokeWidth: 3,
                            color: Colors.white,
                          ),
                        )
                      else
                        Center(
                          child: Icon(
                            held
                                ? Icons.play_circle_fill
                                : Icons.download_for_offline_outlined,
                            size: 42,
                            color: Colors.white,
                          ),
                        ),
                      Positioned(
                        left: 8,
                        right: 8,
                        bottom: 6,
                        child: Text(
                          attachment.name ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            shadows: [Shadow(blurRadius: 4)],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }
        return InkWell(
          onTap: downloading
              ? cancel
              : held && isVideo
              ? () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => VideoPlayerScreen(
                      fileKey: cid,
                      name: attachment.name ?? '',
                    ),
                  ),
                )
              : held
              ? null
              : onFetch,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(documentIcon(attachment.name), color: scheme.primary),
                const SizedBox(width: 8),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        attachment.name ?? 'file',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        !downloading
                            ? _formatGroupBytes(attachment.w)
                            : progress == null
                            ? AppL10n.of(context).fileResuming
                            : '${(progress * 100).round()}%',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (downloading)
                  CancelableDownloadProgress(
                    progress: progress,
                    onCancel: cancel,
                    size: 22,
                    strokeWidth: 2,
                  )
                else
                  Icon(
                    held ? Icons.check_circle_outline : Icons.download_outlined,
                    size: 20,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// A ref-form image (content path): renders the FULL bytes from the file
/// store once fetched, else the in-message thumb with a download affordance /
/// live progress ring on top. Completion flips [contentProgressProvider]
/// (entry removed) → rebuild → the store now holds the blob → full render.
class _GroupRefImage extends ConsumerStatefulWidget {
  const _GroupRefImage({required this.attachment, this.onFetch});
  final MediaObject attachment;
  final VoidCallback? onFetch;

  @override
  ConsumerState<_GroupRefImage> createState() => _GroupRefImageState();
}

class _GroupRefImageState extends ConsumerState<_GroupRefImage> {
  Uint8List? _full;
  bool _loadInFlight = false;
  bool _wasDownloading = false;
  DateTime? _lastAttemptAt;

  String get _cid => widget.attachment.cid!;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    if (_loadInFlight) return;
    final cid = _cid;
    _loadInFlight = true;
    _lastAttemptAt = DateTime.now();
    Uint8List? bytes;
    try {
      // Bounded: this renders the FULL bytes inline, and it had no ceiling at
      // all — a group attachment of any size someone else chose was read whole
      // into RAM and then decoded on top of that. Over the ceiling the thumb
      // and the download affordance stay, which is what they are for.
      bytes = await ref
          .read(storageProvider)
          .loadFile(cid, maxBytes: kInlineImageMaxBytes);
    } catch (_) {
      // Keep the thumb/download affordance and retry after a provider signal.
    } finally {
      _loadInFlight = false;
    }
    if (!mounted) return;
    if (_cid != cid) {
      unawaited(_load());
      return;
    }
    if (bytes != null) setState(() => _full = bytes);
  }

  @override
  void didUpdateWidget(covariant _GroupRefImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attachment.cid != widget.attachment.cid) {
      _full = null;
      _lastAttemptAt = null;
      unawaited(_load());
    }
  }

  @override
  Widget build(BuildContext context) {
    final cid = _cid;
    final progress = ref.watch(contentProgressProvider.select((m) => m[cid]));
    final resuming = ref.watch(
      contentResumingProvider.select((ids) => ids.contains(cid)),
    );
    final downloading = progress != null || resuming;
    final downloadEnded = _wasDownloading && !downloading;
    _wasDownloading = downloading;
    final last = _lastAttemptAt;
    final throttleElapsed =
        last == null ||
        DateTime.now().difference(last) > const Duration(seconds: 2);
    if (_full == null && !_loadInFlight && (downloadEnded || throttleElapsed)) {
      unawaited(_load());
    }
    void cancel() => _cancelGroupContentDownload(ref, cid);
    Uint8List? thumbBytes;
    try {
      thumbBytes = base64Decode(widget.attachment.dataB64);
    } catch (_) {
      // Corrupt thumb — icon fallback below.
    }
    final image = _full ?? thumbBytes;
    return Stack(
      alignment: Alignment.center,
      fit: StackFit.expand,
      children: [
        if (image != null)
          Image.memory(
            image,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            cacheWidth: mediaPreviewCacheDimension(
              240,
              MediaQuery.devicePixelRatioOf(context),
            ),
            cacheHeight: mediaPreviewCacheDimension(
              320,
              MediaQuery.devicePixelRatioOf(context),
            ),
            errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined),
          )
        else
          const Icon(Icons.broken_image_outlined),
        if (_full == null && downloading)
          Center(
            child: CancelableDownloadProgress(
              progress: progress,
              onCancel: cancel,
              size: 40,
              strokeWidth: 3,
            ),
          ),
        if (_full == null && !downloading && widget.onFetch != null)
          IconButton.filledTonal(
            // Same name the 1:1 chat gives the same button on the same blurred
            // thumbnail — an icon there said nothing about what it would do.
            tooltip: AppL10n.of(context).fileDownloadTitle,
            onPressed: widget.onFetch,
            icon: const Icon(Icons.download),
          ),
      ],
    );
  }
}

/// A group message's inline voice clip: play/pause + progress + clock, driven
/// by the shared [voicePlayControllerProvider] (one clip plays at a time, app-
/// wide). The clip id is the message's stable `<authorHex>:<seq>` ref; the
/// bytes come straight from the signed attachment (no file-store fetch).
class _GroupVoiceRow extends ConsumerWidget {
  const _GroupVoiceRow({
    required this.messageRef,
    required this.attachment,
    this.onFetch,
  });
  final String messageRef;
  final MediaObject attachment;

  /// Starts the membership-authorized fetch of a ref-form clip.
  final VoidCallback? onFetch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final play = ref.watch(voicePlayControllerProvider);
    final active = play.isActive(messageRef);
    final playing = play.isPlaying(messageRef);
    final cid = attachment.cid;
    final fetching = cid == null
        ? null
        : ref.watch(contentProgressProvider.select((m) => m[cid]));
    final resuming =
        cid != null &&
        ref.watch(contentResumingProvider.select((ids) => ids.contains(cid)));
    final downloading = fetching != null || resuming;
    // durationMs rides in the attachment's `w` (see _toggleVoiceRecording).
    final label = active
        ? formatVoiceDuration(Duration(milliseconds: play.positionMs))
        : formatVoiceDuration(Duration(milliseconds: attachment.w));
    return FutureBuilder<bool>(
      // A ref clip plays from the file store once fetched (its key IS the
      // cid); an inline clip is always "held".
      future: cid == null
          ? Future.value(true)
          : ref.read(storageProvider).hasFile(cid).catchError((_) => false),
      builder: (context, snap) {
        final held = cid == null || (snap.data ?? false);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: () {
                if (downloading && cid != null) {
                  _cancelGroupContentDownload(ref, cid);
                  return;
                }
                if (!held) {
                  onFetch?.call();
                  return;
                }
                if (cid != null) {
                  ref
                      .read(voicePlayControllerProvider.notifier)
                      .toggle(messageRef, cid);
                  return;
                }
                final Uint8List bytes;
                try {
                  bytes = base64Decode(attachment.dataB64);
                } catch (_) {
                  return; // corrupt attachment — nothing to play
                }
                ref
                    .read(voicePlayControllerProvider.notifier)
                    .toggleBytes(messageRef, bytes);
              },
              icon: downloading
                  ? CancelableDownloadProgress(
                      progress: fetching,
                      onCancel: () => _cancelGroupContentDownload(ref, cid!),
                      size: 24,
                      strokeWidth: 2.5,
                    )
                  : Icon(
                      !held
                          ? Icons.download
                          : (playing ? Icons.pause : Icons.play_arrow),
                      size: 28,
                    ),
            ),
            SizedBox(
              width: 110,
              child: LinearProgressIndicator(
                value: active ? play.progress : 0,
                minHeight: 3,
                color: scheme.primary,
                backgroundColor: scheme.onSurface.withValues(alpha: 0.15),
              ),
            ),
            const SizedBox(width: 8),
            Text(label, style: Theme.of(context).textTheme.labelSmall),
          ],
        );
      },
    );
  }
}

/// A round group video note (content path): the circle plays live frames when
/// active, else shows a placeholder with a play / download / progress
/// affordance; the clock below turns live while playing. The fetched blob's
/// file-store key IS the cid, so the shared vnote player's file-key toggle
/// works unchanged.
class _GroupVnoteCircle extends ConsumerWidget {
  const _GroupVnoteCircle({
    required this.messageRef,
    required this.attachment,
    this.onFetch,
  });
  final String messageRef;
  final MediaObject attachment;
  final VoidCallback? onFetch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final play = ref.watch(vnotePlayControllerProvider);
    final active = play.isActive(messageRef);
    final playing = play.isPlaying(messageRef);
    final cid = attachment.cid;
    final fetching = cid == null
        ? null
        : ref.watch(contentProgressProvider.select((m) => m[cid]));
    final resuming =
        cid != null &&
        ref.watch(contentResumingProvider.select((ids) => ids.contains(cid)));
    final downloading = fetching != null || resuming;
    final label = active
        ? formatVoiceDuration(Duration(milliseconds: play.positionMs))
        : formatVoiceDuration(Duration(milliseconds: attachment.w));
    return FutureBuilder<bool>(
      future: cid == null
          ? Future.value(false)
          : ref.read(storageProvider).hasFile(cid).catchError((_) => false),
      builder: (context, snap) {
        final held = snap.data ?? false;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: () {
                if (downloading && cid != null) {
                  _cancelGroupContentDownload(ref, cid);
                  return;
                }
                if (!held) {
                  onFetch?.call();
                  return;
                }
                ref
                    .read(vnotePlayControllerProvider.notifier)
                    .toggle(messageRef, cid!);
              },
              child: SizedBox(
                width: 160,
                height: 160,
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
                      else
                        ColoredBox(color: scheme.surfaceContainerHighest),
                      if (!playing) ...[
                        ColoredBox(color: Colors.black.withValues(alpha: 0.18)),
                        Center(
                          child: downloading
                              ? CancelableDownloadProgress(
                                  progress: fetching,
                                  onCancel: () =>
                                      _cancelGroupContentDownload(ref, cid!),
                                  size: 36,
                                  strokeWidth: 3,
                                  color: Colors.white,
                                )
                              : Icon(
                                  held ? Icons.play_arrow : Icons.download,
                                  color: Colors.white,
                                  size: 44,
                                ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 6),
              child: Text(label, style: Theme.of(context).textTheme.labelSmall),
            ),
          ],
        );
      },
    );
  }
}

/// Why a moderator is deleting a message, owning its own controller.
///
/// The caller used to dispose the controller on the line after the await, and
/// `showDialog` returns while the route is still animating out — so the
/// `TextField` kept using a disposed controller. Same defect as the cloud
/// storage prompts and the debootstrap confirm; the visible symptom is three
/// framework errors 0.15 s apart, the last of which is the red screen.
class _ModerationReasonDialog extends StatefulWidget {
  const _ModerationReasonDialog();

  @override
  State<_ModerationReasonDialog> createState() =>
      _ModerationReasonDialogState();
}

class _ModerationReasonDialogState extends State<_ModerationReasonDialog> {
  final TextEditingController _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return AlertDialog(
      title: Text(l.spaceModerationDeleteMessage),
      content: TextField(
        key: const ValueKey('space-message-moderation-reason'),
        controller: _reason,
        autofocus: true,
        maxLength: kSpaceModerationReasonMax,
        decoration: InputDecoration(labelText: l.spaceModerationReason),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.actionCancel),
        ),
        FilledButton(
          onPressed: () {
            final value = _reason.text.trim();
            if (value.isNotEmpty) Navigator.of(context).pop(value);
          },
          child: Text(l.spaceModerationDeleteMessage),
        ),
      ],
    );
  }
}

/// Renames a group, owning the controller that holds the name.
///
/// Same reason as every other dialog in this tree that grew its own State: a
/// controller the caller owns is one `dispose()` away from outliving nothing
/// and being used by a `TextField` that is still on screen through the route's
/// exit transition.
class _GroupRenameDialog extends StatefulWidget {
  const _GroupRenameDialog({
    required this.initial,
    required this.title,
    required this.hint,
    required this.cancelLabel,
    required this.renameLabel,
  });

  final String initial;
  final String title;
  final String hint;
  final String cancelLabel;
  final String renameLabel;

  @override
  State<_GroupRenameDialog> createState() => _GroupRenameDialogState();
}

class _GroupRenameDialogState extends State<_GroupRenameDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _name,
        autofocus: true,
        maxLength: 64,
        decoration: InputDecoration(hintText: widget.hint),
        onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(widget.cancelLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_name.text.trim()),
          child: Text(widget.renameLabel),
        ),
      ],
    );
  }
}
