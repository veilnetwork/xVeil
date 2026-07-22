import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/ids.dart';
import '../../domain/group_policy.dart';
import '../../domain/group_reaction.dart';
import '../../domain/space_moderation.dart';
import '../../domain/space_post.dart';
import '../../l10n/app_localizations.dart';
import '../../state/group_service_providers.dart';
import '../../state/notifications.dart' show activeConversationProvider;
import '../../state/vnote_record_controller.dart';
import '../../state/voice_message.dart' show formatVoiceDuration;
import '../../state/voice_record_controller.dart';
import '../chat/vnote_preview.dart';
import '../chat/voice_waveform.dart';
import 'space_post_media.dart';
import 'space_post_reactions.dart';

typedef SpacePostVoiceMediaRegistrar =
    Future<MediaObject?> Function(VoiceClip clip);
typedef SpacePostVnoteMediaRegistrar =
    Future<MediaObject?> Function(VnoteClip clip);

class SpacePostsScreen extends ConsumerStatefulWidget {
  const SpacePostsScreen({
    super.key,
    required this.spaceIdHex,
    this.mediaPicker,
    this.voiceMediaRegistrar,
    this.vnoteMediaRegistrar,
  });

  final String spaceIdHex;
  final Future<SpacePostMediaPickResult> Function(int remaining)? mediaPicker;
  final SpacePostVoiceMediaRegistrar? voiceMediaRegistrar;
  final SpacePostVnoteMediaRegistrar? vnoteMediaRegistrar;

  @override
  ConsumerState<SpacePostsScreen> createState() => _SpacePostsScreenState();
}

class _SpacePostsScreenState extends ConsumerState<SpacePostsScreen> {
  StateController<String?>? _activeConversation;

  String get _conversationKey => 'space:${widget.spaceIdHex}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _activeConversation = ref.read(activeConversationProvider.notifier);
      _activeConversation!.state = _conversationKey;
    });
  }

  @override
  void dispose() {
    if (_activeConversation?.state == _conversationKey) {
      _activeConversation!.state = null;
    }
    super.dispose();
  }

  Future<MediaObject?> _registerVoice(WidgetRef ref, VoiceClip clip) =>
      widget.voiceMediaRegistrar?.call(clip) ??
      registerSpacePostRecording(
        ref,
        bytes: clip.bytes,
        name: 'voice.vop1',
        kind: 'voice',
        mimeType: 'audio/x-veil-vop1',
        durationMs: clip.durationMs,
      );

  Future<MediaObject?> _registerVnote(WidgetRef ref, VnoteClip clip) =>
      widget.vnoteMediaRegistrar?.call(clip) ??
      registerSpacePostRecording(
        ref,
        bytes: clip.bytes,
        name: 'vnote.vn01',
        kind: 'vnote',
        mimeType: 'video/x-veil-vnote',
        durationMs: clip.durationMs,
      );

  Future<void> _compose(
    BuildContext context,
    WidgetRef ref,
    NodeId spaceId,
  ) async {
    final l = AppL10n.of(context);
    final service = ref.read(groupServiceProvider);
    if (service == null) return;
    final saved = await service.spacePostDraft(spaceId);
    if (!context.mounted) return;
    final draft = await showDialog<_PostComposerValue>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PostComposerDialog(
        initialTitle: saved?.title ?? '',
        initialBody: saved?.body ?? '',
        initialType: saved?.type ?? SpacePostType.post,
        initialMedia: saved?.media ?? const [],
        onPickMedia: (remaining) =>
            widget.mediaPicker?.call(remaining) ??
            pickAndRegisterSpacePostMedia(ref, remaining: remaining),
        onRecordVoice: (clip) => _registerVoice(ref, clip),
        onRecordVnote: (clip) => _registerVnote(ref, clip),
        onSaveDraft: (title, body, type, media) => service.saveSpacePostDraft(
          spaceId,
          title: title,
          body: body,
          type: type,
          media: media,
        ),
      ),
    );
    if (draft == null || !draft.hasContent) return;
    final post = await service.publishSpacePost(
      spaceId,
      title: draft.title,
      body: draft.body,
      type: draft.type,
      media: draft.media,
    );
    if (post != null) {
      final cleared = await service.clearSpacePostDraft(spaceId);
      if (!cleared && context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l.spaceOperationFailed)));
      }
    } else if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.spaceOperationFailed)));
    }
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    NodeId spaceId,
    SpacePostView post,
  ) async {
    final l = AppL10n.of(context);
    final draft = await showDialog<_PostComposerValue>(
      context: context,
      builder: (_) => _PostComposerDialog(
        initialTitle: post.title,
        initialBody: post.body,
        initialType: post.type,
        initialMedia: post.media,
        editing: true,
        onPickMedia: (remaining) =>
            widget.mediaPicker?.call(remaining) ??
            pickAndRegisterSpacePostMedia(ref, remaining: remaining),
        onRecordVoice: (clip) => _registerVoice(ref, clip),
        onRecordVnote: (clip) => _registerVnote(ref, clip),
      ),
    );
    if (draft == null) return;
    final updated = await ref
        .read(groupServiceProvider)
        ?.editSpacePost(
          spaceId,
          post.postId,
          title: draft.title,
          body: draft.body,
          type: draft.type,
          media: draft.media,
        );
    if (updated == null && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.spaceOperationFailed)));
    }
  }

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    NodeId spaceId,
    SpacePostView post,
  ) async {
    final l = AppL10n.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.spacePostDeleteTitle),
        content: Text(l.spacePostDeleteBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            key: const ValueKey('space-post-delete-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l.spacePostDelete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final deleted =
        await ref
            .read(groupServiceProvider)
            ?.deleteSpacePost(spaceId, post.postId) ??
        false;
    if (!deleted && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.spaceOperationFailed)));
    }
  }

  Future<void> _moderateDelete(
    BuildContext context,
    WidgetRef ref,
    NodeId spaceId,
    SpacePostView post,
  ) async {
    final l = AppL10n.of(context);
    final controller = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l.spaceModerationDeletePost),
        content: TextField(
          key: const ValueKey('space-post-moderation-reason'),
          controller: controller,
          autofocus: true,
          maxLength: kSpaceModerationReasonMax,
          decoration: InputDecoration(labelText: l.spaceModerationReason),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              if (value.isNotEmpty) Navigator.of(dialogContext).pop(value);
            },
            child: Text(l.spaceModerationDeletePost),
          ),
        ],
      ),
    );
    controller.dispose();
    if (reason == null) return;
    final actionId = await ref
        .read(groupServiceProvider)
        ?.moderateSpace(
          spaceId,
          kind: SpaceModerationKind.deletePost,
          target: post.author,
          scope: SpaceModerationScope.posts,
          reason: reason,
          reference: SpaceModerationReference(
            kind: SpaceModerationReferenceKind.spacePost,
            author: post.author,
            seq: post.seq,
          ),
        );
    if (actionId == null && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.spaceOperationFailed)));
    }
  }

  Future<void> _setPinned(
    BuildContext context,
    WidgetRef ref,
    NodeId spaceId,
    SpacePostView post,
    bool pinned,
  ) async {
    final updated =
        await ref
            .read(groupServiceProvider)
            ?.setSpacePostPinned(spaceId, post.postId, pinned) ??
        false;
    if (!updated && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppL10n.of(context).spaceOperationFailed)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final service = ref.watch(groupServiceProvider);
    final NodeId spaceId;
    try {
      spaceId = NodeId.fromHex(widget.spaceIdHex);
    } catch (_) {
      return Scaffold(body: Center(child: Text(l.spaceOperationFailed)));
    }
    if (service == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return StreamBuilder<int>(
      stream: service.changes.stream,
      builder: (context, _) => FutureBuilder<List<Object?>>(
        future: Future.wait<Object?>([
          service.stateOf(spaceId),
          service.postsOf(spaceId),
          service.isSpaceFeedEnabled(spaceId),
          service.spacePostReactionsOf(spaceId),
        ]),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          final state = snapshot.data![0] as GroupState?;
          final posts = snapshot.data![1] as List<SpacePostView>;
          final enabled = snapshot.data![2] as bool;
          final reactions = snapshot.data![3] as Map<String, MessageReactions>;
          if (state == null) {
            return Scaffold(body: Center(child: Text(l.spaceOperationFailed)));
          }
          final canPublish = SpaceAcl(
            state,
          ).allows(service.selfId, SpacePermission.publishPosts);
          final canModerate = SpaceAcl(
            state,
          ).allows(service.selfId, SpacePermission.moderate);
          final canManagePosts = SpaceAcl(
            state,
          ).allows(service.selfId, SpacePermission.managePosts);
          final displayPosts = [
            ...posts.where((post) => !post.pinned),
            ...posts.where((post) => post.pinned).toList()..sort(
              (left, right) => (left.pinnedAtMs ?? left.publishedAtMs)
                  .compareTo(right.pinnedAtMs ?? right.publishedAtMs),
            ),
          ];
          WidgetsBinding.instance.addPostFrameCallback((_) {
            unawaited(service.markSpaceFeedSeen(spaceId));
          });
          return Scaffold(
            appBar: AppBar(
              title: Text(l.spacePostsTitle),
              actions: [
                IconButton(
                  tooltip: enabled ? l.spaceFeedDisable : l.spaceFeedEnable,
                  onPressed: () =>
                      service.setSpaceFeedEnabled(spaceId, !enabled),
                  icon: Icon(
                    enabled
                        ? Icons.dynamic_feed_outlined
                        : Icons.comments_disabled_outlined,
                  ),
                ),
              ],
            ),
            floatingActionButton: canPublish
                ? FloatingActionButton(
                    heroTag: 'xveil-space-post-${widget.spaceIdHex}',
                    tooltip: l.spacePostCreateTitle,
                    onPressed: () => _compose(context, ref, spaceId),
                    child: const Icon(Icons.edit_outlined),
                  )
                : null,
            body: posts.isEmpty
                ? Center(child: Text(l.spacePostsEmpty))
                : ListView.separated(
                    reverse: true,
                    padding: const EdgeInsets.only(top: 8, bottom: 96),
                    itemCount: displayPosts.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final post = displayPosts[index];
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 8,
                        ),
                        title: post.title.isEmpty ? null : Text(post.title),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (post.pinned)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 4),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.push_pin, size: 14),
                                    const SizedBox(width: 4),
                                    Text(
                                      l.spacePostPinned,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.labelSmall,
                                    ),
                                  ],
                                ),
                              ),
                            if (post.body.isNotEmpty) Text(post.body),
                            SpacePostMediaList(spaceId: spaceId, post: post),
                            if (post.edited)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  l.spacePostEdited,
                                  style: Theme.of(context).textTheme.labelSmall,
                                ),
                              ),
                            const SizedBox(height: 6),
                            SpacePostReactionBar(
                              postId: post.postId,
                              reactions: reactions[post.postId] ?? const {},
                              selfId: service.selfId,
                              onReact: (emoji) => service.reactToSpacePost(
                                spaceId,
                                post.postId,
                                emoji,
                              ),
                            ),
                            TextButton.icon(
                              key: ValueKey(
                                'space-post-comments-${post.postId}',
                              ),
                              onPressed: () => context.push(
                                '/space/${spaceId.hex}/comments?post='
                                '${Uri.encodeQueryComponent(post.postId)}',
                              ),
                              icon: const Icon(Icons.forum_outlined, size: 18),
                              label: Text(l.spacePostCommentsOpen),
                            ),
                          ],
                        ),
                        leading: Icon(
                          post.type == SpacePostType.article
                              ? Icons.article_outlined
                              : Icons.campaign_outlined,
                        ),
                        trailing:
                            post.author == service.selfId ||
                                canModerate ||
                                canManagePosts
                            ? PopupMenuButton<_PostAction>(
                                key: ValueKey('space-post-menu-${post.postId}'),
                                onSelected: (action) {
                                  switch (action) {
                                    case _PostAction.edit:
                                      unawaited(
                                        _edit(context, ref, spaceId, post),
                                      );
                                    case _PostAction.delete:
                                      unawaited(
                                        _delete(context, ref, spaceId, post),
                                      );
                                    case _PostAction.moderateDelete:
                                      unawaited(
                                        _moderateDelete(
                                          context,
                                          ref,
                                          spaceId,
                                          post,
                                        ),
                                      );
                                    case _PostAction.pin:
                                      unawaited(
                                        _setPinned(
                                          context,
                                          ref,
                                          spaceId,
                                          post,
                                          true,
                                        ),
                                      );
                                    case _PostAction.unpin:
                                      unawaited(
                                        _setPinned(
                                          context,
                                          ref,
                                          spaceId,
                                          post,
                                          false,
                                        ),
                                      );
                                  }
                                },
                                itemBuilder: (_) => [
                                  if (canManagePosts)
                                    PopupMenuItem(
                                      value: post.pinned
                                          ? _PostAction.unpin
                                          : _PostAction.pin,
                                      child: Text(
                                        post.pinned
                                            ? l.spacePostUnpin
                                            : l.spacePostPin,
                                      ),
                                    ),
                                  if (post.author == service.selfId) ...[
                                    PopupMenuItem(
                                      value: _PostAction.edit,
                                      child: Text(l.spacePostEdit),
                                    ),
                                    PopupMenuItem(
                                      value: _PostAction.delete,
                                      child: Text(l.spacePostDelete),
                                    ),
                                  ] else if (canModerate)
                                    PopupMenuItem(
                                      value: _PostAction.moderateDelete,
                                      child: Text(l.spaceModerationDeletePost),
                                    ),
                                ],
                              )
                            : null,
                      );
                    },
                  ),
          );
        },
      ),
    );
  }
}

enum _PostAction { pin, unpin, edit, delete, moderateDelete }

class _PostComposerValue {
  const _PostComposerValue(this.title, this.body, this.type, this.media);

  final String title;
  final String body;
  final SpacePostType type;
  final List<MediaObject> media;

  bool get hasContent =>
      title.trim().isNotEmpty || body.trim().isNotEmpty || media.isNotEmpty;
}

class _PostComposerDialog extends ConsumerStatefulWidget {
  const _PostComposerDialog({
    this.initialTitle = '',
    this.initialBody = '',
    this.initialType = SpacePostType.post,
    this.initialMedia = const [],
    this.editing = false,
    this.onPickMedia,
    this.onRecordVoice,
    this.onRecordVnote,
    this.onSaveDraft,
  });

  final String initialTitle;
  final String initialBody;
  final SpacePostType initialType;
  final List<MediaObject> initialMedia;
  final bool editing;
  final Future<SpacePostMediaPickResult> Function(int remaining)? onPickMedia;
  final SpacePostVoiceMediaRegistrar? onRecordVoice;
  final SpacePostVnoteMediaRegistrar? onRecordVnote;
  final Future<bool> Function(
    String title,
    String body,
    SpacePostType type,
    List<MediaObject> media,
  )?
  onSaveDraft;

  @override
  ConsumerState<_PostComposerDialog> createState() =>
      _PostComposerDialogState();
}

class _PostComposerDialogState extends ConsumerState<_PostComposerDialog> {
  late final TextEditingController _title;
  late final TextEditingController _body;
  late SpacePostType _type;
  late List<MediaObject> _media;
  Timer? _draftTimer;
  bool _draftSettled = false;
  bool _saving = false;
  bool _saveFailed = false;
  bool _ownsVoiceRecording = false;
  bool _ownsVnoteRecording = false;
  bool _startingVoiceRecording = false;
  bool _startingVnoteRecording = false;
  final List<double> _liveVoiceLevels = [];

  bool get _recordingBusy =>
      _startingVoiceRecording ||
      _startingVnoteRecording ||
      _ownsVoiceRecording ||
      _ownsVnoteRecording;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.initialTitle);
    _body = TextEditingController(text: widget.initialBody);
    _type = widget.initialType;
    _media = List<MediaObject>.of(widget.initialMedia);
  }

  @override
  void dispose() {
    _draftTimer?.cancel();
    if (_ownsVoiceRecording) {
      ref.read(voiceRecordControllerProvider.notifier).cancel();
    }
    if (_ownsVnoteRecording) {
      ref.read(vnoteRecordControllerProvider.notifier).cancel();
    }
    if (!widget.editing && !_draftSettled && widget.onSaveDraft != null) {
      final value = _value;
      unawaited(
        widget.onSaveDraft!(value.title, value.body, value.type, value.media),
      );
    }
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  _PostComposerValue get _value => _PostComposerValue(
    _title.text,
    _body.text,
    _type,
    List.unmodifiable(_media),
  );

  void _scheduleDraft() {
    if (widget.editing || widget.onSaveDraft == null) {
      setState(() {});
      return;
    }
    setState(() => _saveFailed = false);
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 450), () async {
      final value = _value;
      final saved = await widget.onSaveDraft!(
        value.title,
        value.body,
        value.type,
        value.media,
      );
      if (mounted && !saved) setState(() => _saveFailed = true);
    });
  }

  Future<void> _finish({required bool publish}) async {
    if (_saving || (publish && _recordingBusy)) return;
    final value = _value;
    if (publish && !value.hasContent) return;
    _draftTimer?.cancel();
    setState(() => _saving = true);
    if (!widget.editing && widget.onSaveDraft != null) {
      bool saved;
      try {
        saved = await widget.onSaveDraft!(
          value.title,
          value.body,
          value.type,
          value.media,
        );
      } catch (_) {
        saved = false;
      }
      if (!mounted) return;
      if (!saved) {
        setState(() {
          _saving = false;
          _saveFailed = true;
        });
        return;
      }
      _draftSettled = true;
    }
    if (mounted) Navigator.of(context).pop(publish ? value : null);
  }

  Future<void> _pickMedia() async {
    final picker = widget.onPickMedia;
    if (picker == null ||
        _saving ||
        _recordingBusy ||
        _media.length >= kSpacePostMediaMax) {
      return;
    }
    setState(() => _saving = true);
    final SpacePostMediaPickResult result;
    try {
      result = await picker(kSpacePostMediaMax - _media.length);
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppL10n.of(context).spacePostMediaRejected)),
      );
      return;
    }
    if (!mounted) return;
    final known = {for (final item in _media) item.contentId};
    var rejected = result.rejected;
    for (final item in result.media) {
      if (_media.length >= kSpacePostMediaMax ||
          !item.isStructurallyValid ||
          !known.add(item.contentId)) {
        rejected++;
      } else {
        _media.add(item);
      }
    }
    setState(() => _saving = false);
    _scheduleDraft();
    if (rejected > 0 && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppL10n.of(context).spacePostMediaRejected)),
      );
    }
  }

  Future<void> _startVoiceRecording() async {
    if (_saving ||
        _recordingBusy ||
        widget.onRecordVoice == null ||
        _media.length >= kSpacePostMediaMax) {
      return;
    }
    final controller = ref.read(voiceRecordControllerProvider.notifier);
    setState(() => _startingVoiceRecording = true);
    _liveVoiceLevels.clear();
    try {
      await controller.start();
    } catch (_) {
      if (mounted) {
        setState(() => _startingVoiceRecording = false);
        _showRecordingError(AppL10n.of(context).chatVoiceRecordFailed);
      }
      return;
    }
    if (!mounted) {
      controller.cancel();
      return;
    }
    final recording = ref.read(voiceRecordControllerProvider).isRecording;
    if (_type != SpacePostType.voiceMessage && recording) {
      controller.cancel();
    }
    setState(() {
      _startingVoiceRecording = false;
      _ownsVoiceRecording = recording && _type == SpacePostType.voiceMessage;
    });
  }

  Future<void> _startVnoteRecording() async {
    if (_saving ||
        _recordingBusy ||
        widget.onRecordVnote == null ||
        _media.length >= kSpacePostMediaMax) {
      return;
    }
    final controller = ref.read(vnoteRecordControllerProvider.notifier);
    setState(() => _startingVnoteRecording = true);
    try {
      await controller.start();
    } catch (_) {
      if (mounted) {
        setState(() => _startingVnoteRecording = false);
        _showRecordingError(AppL10n.of(context).chatVoiceRecordFailed);
      }
      return;
    }
    if (!mounted) {
      controller.cancel();
      return;
    }
    final recording = ref.read(vnoteRecordControllerProvider).isRecording;
    if (_type != SpacePostType.shortVideo && recording) {
      controller.cancel();
    }
    setState(() {
      _startingVnoteRecording = false;
      _ownsVnoteRecording = recording && _type == SpacePostType.shortVideo;
    });
  }

  void _cancelVoiceRecording() {
    if (_ownsVoiceRecording ||
        ref.read(voiceRecordControllerProvider).isRecording) {
      ref.read(voiceRecordControllerProvider.notifier).cancel();
    }
    _ownsVoiceRecording = false;
    _startingVoiceRecording = false;
    _liveVoiceLevels.clear();
    if (mounted) setState(() {});
  }

  void _cancelVnoteRecording() {
    if (_ownsVnoteRecording ||
        ref.read(vnoteRecordControllerProvider).isRecording) {
      ref.read(vnoteRecordControllerProvider.notifier).cancel();
    }
    _ownsVnoteRecording = false;
    _startingVnoteRecording = false;
    if (mounted) setState(() {});
  }

  Future<void> _finishVoiceRecording() async {
    if (!_ownsVoiceRecording) return;
    final clip = ref.read(voiceRecordControllerProvider.notifier).stop();
    _ownsVoiceRecording = false;
    _liveVoiceLevels.clear();
    if (mounted) setState(() {});
    if (clip != null) await _attachVoiceClip(clip);
  }

  Future<void> _finishVnoteRecording() async {
    if (!_ownsVnoteRecording) return;
    final clip = ref.read(vnoteRecordControllerProvider.notifier).stop();
    _ownsVnoteRecording = false;
    if (mounted) setState(() {});
    if (clip != null) await _attachVnoteClip(clip);
  }

  Future<void> _attachVoiceClip(VoiceClip clip) async {
    final registrar = widget.onRecordVoice;
    if (registrar == null) return;
    await _attachRecordedMedia(() => registrar(clip));
  }

  Future<void> _attachVnoteClip(VnoteClip clip) async {
    final registrar = widget.onRecordVnote;
    if (registrar == null) return;
    await _attachRecordedMedia(() => registrar(clip));
  }

  Future<void> _attachRecordedMedia(
    Future<MediaObject?> Function() register,
  ) async {
    if (_saving || _media.length >= kSpacePostMediaMax) return;
    setState(() => _saving = true);
    MediaObject? recorded;
    try {
      recorded = await register();
    } catch (_) {}
    if (!mounted) return;
    final duplicate =
        recorded != null &&
        _media.any((item) => item.contentId == recorded!.contentId);
    if (recorded == null || !recorded.isStructurallyValid || duplicate) {
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppL10n.of(context).spacePostMediaRejected)),
      );
      return;
    }
    setState(() {
      _media.add(recorded!);
      _saving = false;
    });
    _scheduleDraft();
  }

  void _removeMedia(MediaObject media) {
    setState(() {
      _media.removeWhere((item) => item.contentId == media.contentId);
    });
    _scheduleDraft();
  }

  void _showRecordingError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _voiceRecordingCard(
    BuildContext context,
    AppL10n l,
    VoiceRecordState recording,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            IconButton(
              key: const ValueKey('space-post-cancel-voice-recording'),
              onPressed: _cancelVoiceRecording,
              tooltip: l.actionCancel,
              icon: Icon(Icons.delete_outline, color: scheme.error),
            ),
            Icon(Icons.fiber_manual_record, color: scheme.error, size: 14),
            const SizedBox(width: 8),
            Text(
              formatVoiceDuration(Duration(milliseconds: recording.elapsedMs)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: SizedBox(
                height: 28,
                child: _liveVoiceLevels.isEmpty
                    ? const SizedBox.shrink()
                    : VoiceWaveform(
                        bars: _liveVoiceLevels,
                        playedColor: scheme.primary,
                        unplayedColor: scheme.primary,
                      ),
              ),
            ),
            IconButton.filled(
              key: const ValueKey('space-post-use-voice-recording'),
              onPressed: _finishVoiceRecording,
              tooltip: l.spacePostUseRecording,
              icon: const Icon(Icons.check),
            ),
          ],
        ),
      ),
    );
  }

  Widget _vnoteRecordingCard(
    BuildContext context,
    AppL10n l,
    VnoteRecordState recording,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final controller = ref.read(vnoteRecordControllerProvider.notifier);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            IconButton(
              key: const ValueKey('space-post-cancel-vnote-recording'),
              onPressed: _cancelVnoteRecording,
              tooltip: l.actionCancel,
              icon: Icon(Icons.delete_outline, color: scheme.error),
            ),
            Icon(Icons.fiber_manual_record, color: scheme.error, size: 14),
            const SizedBox(width: 8),
            Text(
              formatVoiceDuration(Duration(milliseconds: recording.elapsedMs)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Center(
                child: ClipOval(
                  child: SizedBox.square(
                    dimension: 84,
                    child: VnotePreview(
                      frameListenable: controller.preview,
                      mirror: true,
                    ),
                  ),
                ),
              ),
            ),
            IconButton.filled(
              key: const ValueKey('space-post-use-vnote-recording'),
              onPressed: _finishVnoteRecording,
              tooltip: l.spacePostUseRecording,
              icon: const Icon(Icons.check),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    ref.listen<VoiceRecordState>(voiceRecordControllerProvider, (prev, next) {
      if (_ownsVoiceRecording && next.isRecording) {
        setState(() {
          _liveVoiceLevels.add(next.level);
          if (_liveVoiceLevels.length > 44) _liveVoiceLevels.removeAt(0);
        });
      }
      if (next.phase == VoiceRecordPhase.denied &&
          prev?.phase != VoiceRecordPhase.denied) {
        _ownsVoiceRecording = false;
        _showRecordingError(l.chatVoiceMicDenied);
      } else if (next.phase == VoiceRecordPhase.error &&
          prev?.phase != VoiceRecordPhase.error) {
        _ownsVoiceRecording = false;
        _showRecordingError(l.chatVoiceRecordFailed);
      }
      if (_ownsVoiceRecording &&
          prev?.isRecording == true &&
          next.phase == VoiceRecordPhase.idle) {
        _ownsVoiceRecording = false;
        _liveVoiceLevels.clear();
        final clip = ref
            .read(voiceRecordControllerProvider.notifier)
            .takeAutoStopped();
        if (clip != null) unawaited(_attachVoiceClip(clip));
      }
    });
    ref.listen<VnoteRecordState>(vnoteRecordControllerProvider, (prev, next) {
      if (next.phase == VnoteRecordPhase.denied &&
          prev?.phase != VnoteRecordPhase.denied) {
        _ownsVnoteRecording = false;
        _showRecordingError(l.chatVnoteDenied);
      } else if (next.phase == VnoteRecordPhase.error &&
          prev?.phase != VnoteRecordPhase.error) {
        _ownsVnoteRecording = false;
        _showRecordingError(l.chatVoiceRecordFailed);
      }
      if (_ownsVnoteRecording &&
          prev?.isRecording == true &&
          next.phase == VnoteRecordPhase.idle) {
        _ownsVnoteRecording = false;
        final clip = ref
            .read(vnoteRecordControllerProvider.notifier)
            .takeAutoStopped();
        if (clip != null) unawaited(_attachVnoteClip(clip));
      }
    });
    final voiceRecording = ref.watch(voiceRecordControllerProvider);
    final vnoteRecording = ref.watch(vnoteRecordControllerProvider);
    return AlertDialog(
      title: Text(widget.editing ? l.spacePostEdit : l.spacePostCreateTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('space-post-title-field'),
              controller: _title,
              maxLength: kSpacePostTitleMax,
              onChanged: (_) => _scheduleDraft(),
              decoration: InputDecoration(hintText: l.spacePostTitleHint),
            ),
            TextField(
              key: const ValueKey('space-post-body-field'),
              controller: _body,
              autofocus: true,
              minLines: 4,
              maxLines: 10,
              maxLength: kSpacePostBodyMax,
              onChanged: (_) => _scheduleDraft(),
              decoration: InputDecoration(
                hintText: l.spacePostBodyHint,
                counterText: '',
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<SpacePostType>(
              key: const ValueKey('space-post-type-field'),
              initialValue: _type,
              items: [
                for (final type in SpacePostType.values)
                  DropdownMenuItem(
                    value: type,
                    child: Text(_postTypeLabel(l, type)),
                  ),
              ],
              onChanged: _startingVoiceRecording || _startingVnoteRecording
                  ? null
                  : (value) {
                      if (value != null) {
                        if (_ownsVoiceRecording) _cancelVoiceRecording();
                        if (_ownsVnoteRecording) _cancelVnoteRecording();
                        _type = value;
                        _scheduleDraft();
                      }
                    },
            ),
            const SizedBox(height: 12),
            if (_type == SpacePostType.voiceMessage &&
                widget.onRecordVoice != null) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: _ownsVoiceRecording && voiceRecording.isRecording
                    ? _voiceRecordingCard(context, l, voiceRecording)
                    : OutlinedButton.icon(
                        key: const ValueKey('space-post-record-voice'),
                        onPressed:
                            _saving ||
                                _recordingBusy ||
                                _media.length >= kSpacePostMediaMax
                            ? null
                            : _startVoiceRecording,
                        icon: const Icon(Icons.mic_none_outlined),
                        label: Text(l.spacePostRecordVoice),
                      ),
              ),
              const SizedBox(height: 8),
            ],
            if (_type == SpacePostType.shortVideo &&
                widget.onRecordVnote != null) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: _ownsVnoteRecording && vnoteRecording.isRecording
                    ? _vnoteRecordingCard(context, l, vnoteRecording)
                    : OutlinedButton.icon(
                        key: const ValueKey('space-post-record-vnote'),
                        onPressed:
                            _saving ||
                                _recordingBusy ||
                                _media.length >= kSpacePostMediaMax
                            ? null
                            : _startVnoteRecording,
                        icon: const Icon(Icons.video_camera_front_outlined),
                        label: Text(l.spacePostRecordShortVideo),
                      ),
              ),
              const SizedBox(height: 8),
            ],
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: const ValueKey('space-post-attach-media'),
                onPressed:
                    _saving ||
                        _recordingBusy ||
                        _media.length >= kSpacePostMediaMax ||
                        widget.onPickMedia == null
                    ? null
                    : _pickMedia,
                icon: const Icon(Icons.attach_file),
                label: Text(l.spacePostMediaAttach),
              ),
            ),
            if (_media.isNotEmpty) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final media in _media)
                      InputChip(
                        key: ValueKey(
                          'space-post-draft-media-${media.contentId}',
                        ),
                        avatar: Icon(spacePostMediaIcon(media.kind), size: 18),
                        label: Text(
                          media.name ?? media.kind,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onDeleted: _saving ? null : () => _removeMedia(media),
                      ),
                  ],
                ),
              ),
            ],
            if (!widget.editing) ...[
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Icon(Icons.lock_outline, size: 18),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _saveFailed
                          ? l.spaceOperationFailed
                          : l.spacePostDraftHint,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: _saveFailed
                            ? Theme.of(context).colorScheme.error
                            : null,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => _finish(publish: false),
          child: Text(l.actionCancel),
        ),
        FilledButton(
          key: ValueKey(
            widget.editing ? 'space-post-save-edit' : 'space-post-publish',
          ),
          onPressed: _saving || _recordingBusy || !_value.hasContent
              ? null
              : () => _finish(publish: true),
          child: Text(widget.editing ? l.actionSave : l.spacePostPublish),
        ),
      ],
    );
  }
}

String _postTypeLabel(AppL10n l, SpacePostType type) => switch (type) {
  SpacePostType.post => l.spacePostTypePost,
  SpacePostType.article => l.spacePostTypeArticle,
  SpacePostType.video => l.spacePostTypeVideo,
  SpacePostType.shortVideo => l.spacePostTypeShortVideo,
  SpacePostType.audio => l.spacePostTypeAudio,
  SpacePostType.voiceMessage => l.spacePostTypeVoiceMessage,
};
