// Shared REST projection for the group core. Both the Flutter host and the
// Flutter-free headless daemon use this adapter, so validation, visibility and
// policy outcomes cannot drift between the two runtimes.

import 'dart:io';
import 'dart:typed_data';

import '../core/ids.dart';
import '../data/serve_source.dart';
import '../domain/group.dart';
import '../domain/group_message.dart';
import '../domain/media_file_name.dart';
import '../domain/group_policy.dart';
import '../domain/group_reaction.dart';
import '../domain/space_channel.dart';
import '../domain/space_moderation.dart';
import '../domain/space_post.dart';
import '../domain/space_retention.dart';
import '../domain/space_rules.dart';
import '../state/group_service.dart';

typedef RegisterGroupContentSource =
    Future<String> Function(
      String name,
      int size,
      Future<Uint8List> Function(int offset, int length) read, {
      required Future<void> Function() close,
      String? sourcePath,
    });

final class GroupApiAdapter {
  const GroupApiAdapter(
    this._groups, {
    required this.registerContentSource,
    required this.loadContent,
  });

  final GroupService _groups;
  final RegisterGroupContentSource registerContentSource;
  final Future<List<int>?> Function(String contentId) loadContent;

  Future<List<Map<String, dynamic>>> list() async => [
    for (final group in await _groups.listGroups()) _listEntry(group),
  ];

  Future<List<Map<String, dynamic>>> listSpaces() async => [
    for (final space in await _groups.listSpaces()) _listEntry(space),
  ];

  Map<String, dynamic> _listEntry(GroupListEntry group) => {
    'spaceId': group.groupId.hex,
    'groupId': group.groupId.hex,
    'name': group.name,
    'description': group.description,
    if (group.visibility != null) 'visibility': group.visibility!.name,
    'discoverable': group.discoverable,
    'unread': group.unread,
    'postUnread': group.postUnread,
    'muted': group.muted,
    'preview': group.preview,
    'lastTs': group.lastTs,
  };

  Future<String?> create(String name) async {
    try {
      return (await _groups.createGroup(name)).hex;
    } catch (_) {
      return null;
    }
  }

  Future<String?> createSpace(
    String name,
    String description,
    String visibilityName,
  ) async {
    final visibility = SpaceVisibility.fromName(visibilityName);
    if (visibility == null) return null;
    try {
      return (await _groups.createSpace(
        name,
        description: description,
        visibility: visibility,
        // Public discovery needs its own holder/discovery protocol. Do not
        // claim searchability merely because clear signed posts are possible.
        discoverable: false,
      )).hex;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> profile(String spaceHex) async {
    final visible = await _visible(spaceHex);
    if (visible == null) return null;
    final bundle = await _groups.load(visible.$1);
    if (bundle == null || !bundle.manifest.isSpace) return null;
    return {
      'spaceId': visible.$1.hex,
      'name': visible.$2.name,
      'description': visible.$2.description,
      'visibility': bundle.manifest.visibility!.name,
      'discoverable': bundle.manifest.discoverable ?? false,
      if (bundle.manifest.avatarContentId != null)
        'avatarContentId': bundle.manifest.avatarContentId,
      if (bundle.manifest.coverContentId != null)
        'coverContentId': bundle.manifest.coverContentId,
    };
  }

  Future<String?> updateDescription(String spaceHex, String description) async {
    final visible = await _visible(spaceHex);
    if (visible == null) return 'space not found';
    final role = visible.$2.roleOf(_groups.selfId)!;
    if (!canApply(authorRole: role, op: ControlOp.setDescription)) {
      return 'operation rejected by space policy';
    }
    return await _groups.setSpaceDescription(visible.$1, description)
        ? null
        : 'space mutation failed';
  }

  Future<Map<String, dynamic>?> retention(String spaceHex) async {
    final visible = await _visible(spaceHex);
    if (visible == null) return null;
    final bundle = await _groups.load(visible.$1);
    if (bundle == null || !bundle.manifest.isSpace) return null;
    final policy = visible.$2.effectiveRetentionPolicy();
    final localDays = await _groups.localSpaceRetentionDays(visible.$1);
    return {
      'spaceId': visible.$1.hex,
      'community': policy.toJson(),
      'localDevice': {
        'mode': localDays == null ? 'keepForever' : 'deleteAfter',
        'retentionDays': ?localDays,
      },
      'history': [
        for (final revision in visible.$2.retentionHistory)
          {
            'policy': revision.policy.toJson(),
            'activatedAt': revision.activatedAtMs,
            'author': revision.author.hex,
            'authorSeq': revision.authorSeq,
          },
      ],
    };
  }

  Future<String?> setRetention(
    String spaceHex,
    int? days,
    bool localDevice,
  ) async {
    final visible = await _visible(spaceHex);
    if (visible == null) return 'space not found';
    final bundle = await _groups.load(visible.$1);
    if (bundle == null || !bundle.manifest.isSpace) return 'space not found';
    if (days != null && (days <= 0 || days > 36500)) {
      return 'invalid retention days';
    }
    if (localDevice) {
      return await _groups.setLocalSpaceRetentionDays(visible.$1, days)
          ? null
          : 'local retention update failed';
    }
    if (!SpaceAcl(
      visible.$2,
    ).allows(_groups.selfId, SpacePermission.manageStorage)) {
      return 'operation rejected by space policy';
    }
    final policy = days == null
        ? const SpaceRetentionPolicy(mode: SpaceRetentionMode.keepForever)
        : SpaceRetentionPolicy(
            mode: SpaceRetentionMode.deleteAfter,
            retentionMs: Duration(days: days).inMilliseconds,
          );
    return await _groups.setSpaceRetentionPolicy(visible.$1, policy)
        ? null
        : 'retention update failed';
  }

  static Map<String, dynamic> rulesVersionJson(SpaceRulesVersion rules) => {
    'version': rules.version,
    'fullText': rules.fullText,
    'summary': rules.summary,
    'author': rules.author.hex,
    'publishedAt': rules.publishedAtMs,
    'effectiveAt': rules.effectiveAtMs,
    if (rules.previousVersion != null) 'previousVersion': rules.previousVersion,
  };

  Future<Map<String, dynamic>?> rules(String spaceHex) async {
    final visible = await _visible(spaceHex);
    if (visible == null) return null;
    final bundle = await _groups.load(visible.$1);
    if (bundle == null || !bundle.manifest.isSpace) return null;
    final state = await _groups.stateOf(visible.$1);
    if (state == null) return null;
    final current = state.currentRules;
    final acceptance = state.rulesAcceptanceOf(_groups.selfId);
    final history = state.rulesHistory.values.toList()
      ..sort((a, b) => b.version.compareTo(a.version));
    return {
      'spaceId': visible.$1.hex,
      if (current != null) 'current': rulesVersionJson(current),
      'history': [for (final revision in history) rulesVersionJson(revision)],
      'acceptanceRequired': state.requiresRulesAcceptance(_groups.selfId),
      if (acceptance != null)
        'acceptance': {
          'rulesVersion': acceptance.rulesVersion,
          'acceptedAt': acceptance.acceptedAtMs,
        },
    };
  }

  Future<String?> publishRules(
    String spaceHex,
    String fullText,
    String summary,
    int? effectiveAtMs,
  ) async {
    final visible = await _visible(spaceHex);
    if (visible == null) return 'space not found';
    final state = visible.$2;
    if (!SpaceAcl(
      state,
    ).allows(_groups.selfId, SpacePermission.manageSettings)) {
      return 'operation rejected by space policy';
    }
    return await _groups.publishSpaceRules(
          visible.$1,
          fullText: fullText,
          summary: summary,
          effectiveAtMs: effectiveAtMs,
        )
        ? null
        : 'rules publication failed';
  }

  Future<String?> acceptRules(String spaceHex) async {
    final visible = await _visible(spaceHex);
    if (visible == null) return 'space not found';
    return await _groups.acceptSpaceRules(visible.$1)
        ? null
        : 'rules acceptance failed';
  }

  static Map<String, dynamic> moderationRecordJson(
    SpaceModerationRecord record, {
    int? atMs,
  }) {
    final action = record.action;
    final reference = action.reference;
    return {
      'actionId': record.actionId,
      'actor': record.actor.hex,
      'target': action.target.hex,
      'kind': action.kind.name,
      'scope': action.scope.name,
      'reason': action.reason,
      'createdAt': action.createdAtMs,
      'active': record.isActiveAt(
        atMs ?? DateTime.now().millisecondsSinceEpoch,
      ),
      if (action.channelId != null) 'channelId': action.channelId!.hex,
      if (action.expiresAtMs != null) 'expiresAt': action.expiresAtMs,
      if (reference != null)
        'reference': {
          'kind': reference.kind.name,
          'id': reference.contentId,
          if (reference.channelId != null)
            'channelId': reference.channelId!.hex,
        },
      if (record.revokedBy != null) 'revokedBy': record.revokedBy!.hex,
      if (record.revokedAtMs != null) 'revokedAt': record.revokedAtMs,
      if (record.revocationReason != null)
        'revocationReason': record.revocationReason,
    };
  }

  Future<List<Map<String, dynamic>>?> moderationAudit(String spaceHex) async {
    final visible = await _visible(spaceHex);
    if (visible == null) return null;
    final bundle = await _groups.load(visible.$1);
    if (bundle == null || !bundle.manifest.isSpace) return null;
    final now = DateTime.now().millisecondsSinceEpoch;
    return [
      for (final record in await _groups.spaceModerationAudit(visible.$1))
        moderationRecordJson(record, atMs: now),
    ];
  }

  Future<({String? error, String? actionId})> moderate(
    String spaceHex,
    String kindName,
    String targetHex,
    String scopeName,
    String reason,
    String? channelHex,
    int? expiresAtMs,
    String? referenceKindName,
    String? referenceId,
    String? referenceChannelHex,
  ) async {
    final visible = await _visible(spaceHex);
    if (visible == null) return (error: 'space not found', actionId: null);
    final bundle = await _groups.load(visible.$1);
    if (bundle == null || !bundle.manifest.isSpace) {
      return (error: 'space not found', actionId: null);
    }
    final kind = SpaceModerationKind.fromName(kindName);
    final scope = SpaceModerationScope.fromName(scopeName);
    final target = _parseId(targetHex);
    final channel = channelHex == null ? null : _parseId(channelHex);
    if (kind == null ||
        scope == null ||
        target == null ||
        (channelHex != null && channel == null)) {
      return (error: 'invalid moderation action', actionId: null);
    }
    SpaceModerationReference? reference;
    if (referenceKindName != null || referenceId != null) {
      final referenceKind = SpaceModerationReferenceKind.fromName(
        referenceKindName,
      );
      final parsedReference = _parseLogReference(referenceId ?? '');
      final referenceChannel = referenceChannelHex == null
          ? null
          : _parseId(referenceChannelHex);
      if (referenceKind == null ||
          parsedReference == null ||
          (referenceChannelHex != null && referenceChannel == null)) {
        return (error: 'invalid moderation reference', actionId: null);
      }
      reference = SpaceModerationReference(
        kind: referenceKind,
        author: parsedReference.$1,
        seq: parsedReference.$2,
        channelId: referenceChannel,
      );
    }
    final actionId = await _groups.moderateSpace(
      visible.$1,
      kind: kind,
      target: target,
      scope: scope,
      reason: reason,
      channelId: channel,
      expiresAtMs: expiresAtMs,
      reference: reference,
    );
    return actionId == null
        ? (error: 'moderation action rejected', actionId: null)
        : (error: null, actionId: actionId);
  }

  Future<String?> revokeModeration(
    String spaceHex,
    String actionId,
    String reason,
  ) async {
    final visible = await _visible(spaceHex);
    if (visible == null) return 'space not found';
    final bundle = await _groups.load(visible.$1);
    if (bundle == null || !bundle.manifest.isSpace) return 'space not found';
    return await _groups.revokeSpaceModeration(
          visible.$1,
          actionId,
          reason: reason,
        )
        ? null
        : 'moderation revocation rejected';
  }

  static Map<String, dynamic> messageJson(GroupMessage message) => {
    'id': message.ref,
    if (message.channelId != null) 'channelId': message.channelId!.hex,
    'author': message.author.hex,
    'body': message.body,
    'sentAt': message.createdAtMs,
    if (message.replyTo != null) 'replyTo': message.replyTo,
    if (message.attachment != null)
      'attachment': {
        'kind': message.attachment!.kind,
        'width': message.attachment!.w,
        'height': message.attachment!.h,
        if (message.attachment!.name != null) 'name': message.attachment!.name,
        if (message.attachment!.cid != null)
          'contentId': message.attachment!.cid,
      },
  };

  static Map<String, dynamic> postJson(
    SpacePostView post, {
    String? spaceName,
    MessageReactions reactions = const {},
  }) => {
    'postId': post.postId,
    'revisionId': post.revisionId,
    'spaceId': post.spaceId.hex,
    'spaceName': ?spaceName,
    'author': post.author.hex,
    'type': post.type.name,
    'visibility': post.visibility.name,
    'title': post.title,
    'body': post.body,
    'publishedAt': post.publishedAtMs,
    'updatedAt': post.updatedAtMs,
    'edited': post.edited,
    'reactions': {
      for (final entry in reactions.entries)
        entry.key: [for (final reactor in entry.value) reactor.hex],
    },
    'cursor': SpaceFeedCursor.fromView(post).encode(),
    if (post.media.isNotEmpty)
      'media': [for (final item in post.media) item.toJson()],
  };

  Future<Map<String, dynamic>?> posts(
    String spaceHex,
    int limit,
    String? before,
  ) async {
    final visible = await _visible(spaceHex);
    if (visible == null) return null;
    final cursor = SpaceFeedCursor.decode(before);
    final posts = (await _groups.postsOf(visible.$1)).reversed.where(
      (post) =>
          cursor == null ||
          SpaceFeedCursor.fromView(post).compareTo(cursor) < 0,
    );
    final page = posts.take(limit).toList();
    final reactions = await _groups.spacePostReactionsOf(visible.$1);
    return {
      'posts': [
        for (final post in page)
          postJson(post, reactions: reactions[post.postId] ?? const {}),
      ],
      if (page.length == limit)
        'nextCursor': SpaceFeedCursor.fromView(page.last).encode(),
    };
  }

  Future<({String? error, Map<String, dynamic>? post})> publishPost(
    String spaceHex,
    String title,
    String body,
    String typeName,
  ) async {
    final visible = await _visible(spaceHex);
    if (visible == null) return (error: 'space not found', post: null);
    final type = SpacePostType.fromName(typeName);
    if (type == null) return (error: 'invalid post type', post: null);
    final post = await _groups.publishSpacePost(
      visible.$1,
      title: title,
      body: body,
      type: type,
    );
    return post == null
        ? (error: 'post publication rejected', post: null)
        : (
            error: null,
            post: postJson(SpacePostView(root: post, effective: post)),
          );
  }

  Future<({String? error, Map<String, dynamic>? post})> editPost(
    String spaceHex,
    String postId,
    String title,
    String body,
    String? typeName,
  ) async {
    final visible = await _visible(spaceHex);
    if (visible == null) return (error: 'space not found', post: null);
    final type = typeName == null ? null : SpacePostType.fromName(typeName);
    if (typeName != null && type == null) {
      return (error: 'invalid post type', post: null);
    }
    final post = await _groups.editSpacePost(
      visible.$1,
      postId,
      title: title,
      body: body,
      type: type,
    );
    return post == null
        ? (error: 'post edit rejected', post: null)
        : (error: null, post: postJson(post));
  }

  Future<String?> deletePost(String spaceHex, String postId) async {
    final visible = await _visible(spaceHex);
    if (visible == null) return 'space not found';
    return await _groups.deleteSpacePost(visible.$1, postId)
        ? null
        : 'post deletion rejected';
  }

  Future<String?> reactToPost(
    String spaceHex,
    String postId,
    String emoji,
  ) async {
    final visible = await _visible(spaceHex);
    if (visible == null) return 'space not found';
    return await _groups.reactToSpacePost(visible.$1, postId, emoji)
        ? null
        : 'post reaction rejected';
  }

  Future<Map<String, dynamic>> feed(int limit, String? before) async {
    final cursor = SpaceFeedCursor.decode(before);
    final items = await _groups.spaceFeed(before: cursor, limit: limit);
    return {
      'posts': [
        for (final item in items)
          postJson(
            item.post,
            spaceName: item.spaceName,
            reactions: item.reactions,
          ),
      ],
      if (items.length == limit)
        'nextCursor': SpaceFeedCursor.fromView(items.last.post).encode(),
    };
  }

  Future<String?> setFeedEnabled(String spaceHex, bool enabled) async {
    final visible = await _visible(spaceHex);
    if (visible == null) return 'space not found';
    try {
      await _groups.setSpaceFeedEnabled(visible.$1, enabled);
      return null;
    } catch (_) {
      return 'subscription update rejected';
    }
  }

  Future<List<Map<String, dynamic>>> invites() async => [
    for (final pending in await _groups.pendingSpaceInvites())
      {
        'inviteId': pending.invite.inviteId,
        'spaceId': pending.invite.spaceId.hex,
        'name': pending.invite.spaceName,
        'inviter': pending.invite.inviter.hex,
        'role': pending.invite.role.name,
        'visibility': pending.invite.visibility.name,
        'createdAt': pending.invite.createdAtMs,
        'expiresAt': pending.invite.expiresAtMs,
        'accepted': pending.accepted,
      },
  ];

  Future<String?> decideInvite(String inviteId, bool accept) async =>
      await _groups.decideSpaceInvite(inviteId, accept: accept)
      ? null
      : 'space invitation decision rejected';

  Future<List<Map<String, dynamic>>?> messages(
    String groupHex,
    int limit,
  ) async {
    final visible = await _visible(groupHex);
    if (visible == null) return null;
    final all = await _groups.messagesOf(visible.$1);
    return [
      for (final message in all.skip(
        all.length > limit ? all.length - limit : 0,
      ))
        messageJson(message),
    ];
  }

  Future<String?> sendMessage(
    String groupHex,
    String body,
    String? replyTo,
  ) async {
    final parsed = _parseId(groupHex);
    if (parsed == null) return 'invalid group';
    if (await _visible(groupHex) == null) return 'group not found';
    final sent = await _groups.postMessage(parsed, body, replyTo: replyTo);
    return sent ? null : 'not a writable group member';
  }

  Future<List<Map<String, dynamic>>?> channels(String spaceHex) async {
    final visible = await _visible(spaceHex);
    if (visible == null) return null;
    return [
      for (final channel in await _groups.channelsOf(
        visible.$1,
        includeArchived: true,
      ))
        {
          'spaceId': channel.spaceId.hex,
          'channelId': channel.channelId.hex,
          'kind': channel.kind.name,
          'name': channel.name,
          'description': channel.description,
          if (channel.categoryId != null) 'categoryId': channel.categoryId!.hex,
          'position': channel.position,
          'default': channel.isDefault,
          'archived': channel.archived,
          'history': channel.history.name,
          'access': channel.access.name,
          if (channel.historySinceMs != null)
            'historySince': channel.historySinceMs,
        },
    ];
  }

  Future<({String? error, String? channelId})> createChannel(
    String spaceHex,
    String name,
    String kindName,
    String? categoryHex,
    int position,
    String historyName,
    int? historySinceMs,
    String accessName,
    List<String> memberHexes,
  ) async {
    final visible = await _visible(spaceHex);
    if (visible == null) return (error: 'space not found', channelId: null);
    final kind = SpaceChannelKind.fromName(kindName);
    final history = SpaceChannelHistory.fromName(historyName);
    final access = SpaceChannelAccess.fromName(accessName);
    final category = categoryHex == null ? null : _parseId(categoryHex);
    final members = memberHexes.map(_parseId).toList();
    if (kind == null ||
        history == null ||
        access == null ||
        members.any((member) => member == null) ||
        (categoryHex != null && category == null)) {
      return (error: 'invalid channel properties', channelId: null);
    }
    final id = await _groups.createChannel(
      visible.$1,
      name: name,
      kind: kind,
      categoryId: category,
      position: position,
      history: history,
      historySinceMs: historySinceMs,
      access: access,
      members: members.whereType<NodeId>(),
    );
    return id == null
        ? (error: 'channel mutation rejected', channelId: null)
        : (error: null, channelId: id.hex);
  }

  Future<String?> channelAction(
    String spaceHex,
    String channelHex,
    String action,
  ) async {
    final visible = await _visible(spaceHex);
    if (visible == null) return 'space not found';
    final channelId = _parseId(channelHex);
    if (channelId == null) return 'invalid channel';
    final applied = switch (action) {
      'archive' => _groups.setChannelArchived(visible.$1, channelId, true),
      'restore' => _groups.setChannelArchived(visible.$1, channelId, false),
      'default' => _groups.setDefaultChannel(visible.$1, channelId),
      _ => Future<bool>.value(false),
    };
    return await applied ? null : 'channel mutation rejected';
  }

  Future<String?> setChannelMembers(
    String spaceHex,
    String channelHex,
    List<String> memberHexes,
  ) async {
    final visible = await _visible(spaceHex);
    final channelId = _parseId(channelHex);
    final members = memberHexes.map(_parseId).toList();
    if (visible == null ||
        channelId == null ||
        members.any((member) => member == null)) {
      return 'invalid channel members';
    }
    return await _groups.setChannelMembers(
          visible.$1,
          channelId,
          members.whereType<NodeId>(),
        )
        ? null
        : 'channel ACL mutation rejected';
  }

  Future<List<Map<String, dynamic>>?> channelMessages(
    String spaceHex,
    String channelHex,
    int limit,
  ) async {
    final visible = await _visible(spaceHex);
    final channelId = _parseId(channelHex);
    if (visible == null || channelId == null) return null;
    final channels = await _groups.channelsOf(
      visible.$1,
      includeArchived: true,
    );
    if (!channels.any((channel) => channel.channelId == channelId)) return null;
    final all = await _groups.messagesOf(visible.$1, channelId: channelId);
    return [
      for (final message in all.skip(
        all.length > limit ? all.length - limit : 0,
      ))
        messageJson(message),
    ];
  }

  Future<String?> sendChannelMessage(
    String spaceHex,
    String channelHex,
    String body,
    String? replyTo,
  ) async {
    final visible = await _visible(spaceHex);
    final channelId = _parseId(channelHex);
    if (visible == null || channelId == null) return 'channel not found';
    return await _groups.postMessage(
          visible.$1,
          body,
          channelId: channelId,
          replyTo: replyTo,
        )
        ? null
        : 'channel is not writable';
  }

  /// Register a local file in the existing membership-authorized content path
  /// and post only its signed content reference to the group. The source is
  /// hashed and served by bounded range reads: no all-file RAM copy and no
  /// plaintext staging file, including for multi-gigabyte inputs.
  Future<({String? error, String? contentId})> sendFile(
    String groupHex,
    String path,
    String? requestedName,
    String caption,
    String? replyTo,
  ) async {
    final visible = await _visible(groupHex);
    if (visible == null) {
      return (error: 'group not found', contentId: null);
    }
    final me = visible.$2.memberOf(_groups.selfId);
    if (me == null || me.muted) {
      return (error: 'not a writable group member', contentId: null);
    }
    final file = File(path);
    try {
      if (!await file.exists()) {
        return (error: 'source not found', contentId: null);
      }
      final size = await file.length();
      if (size <= 0) return (error: 'source is empty', contentId: null);
      final fallbackName = file.uri.pathSegments.isEmpty
          ? 'file'
          : file.uri.pathSegments.last;
      final name = requestedName?.trim().isNotEmpty == true
          ? requestedName!.trim()
          : fallbackName;
      if (name.length > 255) {
        return (error: 'file name too long', contentId: null);
      }
      final source = await veilSourceOpener(file.absolute.path);
      if (source == null) {
        return (error: 'source unreadable', contentId: null);
      }
      final cid = await registerContentSource(
        name,
        size,
        source.read,
        close: source.close,
        sourcePath: file.absolute.path,
      );
      final posted = await _groups.postMessage(
        visible.$1,
        caption,
        replyTo: replyTo,
        attachment: GroupAttachment(
          // A video has a dedicated player even without a poster. Other
          // sources use the generic file row; image-specific rendering needs
          // a real signed micro-thumbnail, which headless cannot fabricate.
          kind: isVideoFileName(name) ? 'video' : 'file',
          dataB64: 'QQ==',
          w: size,
          h: 1,
          cid: cid,
          name: name,
        ),
      );
      return posted
          ? (error: null, contentId: cid)
          : (error: 'group mutation failed', contentId: null);
    } on FileSystemException {
      return (error: 'source unreadable', contentId: null);
    } catch (_) {
      return (error: 'content registration failed', contentId: null);
    }
  }

  /// Start the normal signed membership fetch for the exact attachment
  /// referenced by [messageRef]. The caller never supplies a holder node id:
  /// the validated message author is authoritative, avoiding a content oracle.
  Future<String?> fetchFile(String groupHex, String messageRef) async {
    final resolved = await _resolveAttachment(groupHex, messageRef);
    if (resolved == null) return 'group message attachment not found';
    try {
      if (await loadContent(resolved.$2) != null) return null;
      return await _groups.fetchGroupContent(
            resolved.$1,
            resolved.$2,
            resolved.$3,
          )
          ? null
          : 'group content fetch unavailable';
    } catch (_) {
      return 'group content fetch failed';
    }
  }

  /// Load an encrypted-store blob only when a validated message in the named
  /// visible group references it. This deliberately accepts no bare contentId.
  Future<({String? error, List<int>? bytes})> loadFile(
    String groupHex,
    String messageRef,
  ) async {
    final resolved = await _resolveAttachment(groupHex, messageRef);
    if (resolved == null) {
      return (error: 'group message attachment not found', bytes: null);
    }
    try {
      final bytes = await loadContent(resolved.$2);
      return bytes == null
          ? (error: 'group content not downloaded', bytes: null)
          : (error: null, bytes: bytes);
    } catch (_) {
      return (error: 'group content load failed', bytes: null);
    }
  }

  Future<(NodeId, String, NodeId)?> _resolveAttachment(
    String groupHex,
    String messageRef,
  ) async {
    final visible = await _visible(groupHex);
    if (visible == null) return null;
    for (final message in await _groups.messagesOf(visible.$1)) {
      if (message.ref == messageRef && message.attachment?.cid != null) {
        return (visible.$1, message.attachment!.cid!, message.author);
      }
    }
    return null;
  }

  /// Current validated roster. Only user-visible groups that still contain the
  /// active identity resolve; infrastructure device groups remain invisible.
  Future<Map<String, dynamic>?> members(String groupHex) async {
    final visible = await _visible(groupHex);
    if (visible == null) return null;
    final state = visible.$2;
    final members = state.members.values.toList()
      ..sort((a, b) {
        final role = b.role.rank.compareTo(a.role.rank);
        return role != 0 ? role : a.nodeId.hex.compareTo(b.nodeId.hex);
      });
    return {
      'groupId': visible.$1.hex,
      'name': state.name,
      'description': state.description,
      'epoch': state.epoch,
      'policyVersion': state.policyVersion,
      'selfRole': state.roleOf(_groups.selfId)!.name,
      'members': [
        for (final member in members)
          {
            'nodeId': member.nodeId.hex,
            'short': member.nodeId.short,
            'role': member.role.name,
            'muted': member.muted,
            'self': member.nodeId == _groups.selfId,
          },
      ],
    };
  }

  /// Apply one explicit membership/moderation action through the existing
  /// signed control-log. Policy is checked before the mutation so a permitted
  /// operation that later fails (for example because a new peer has no
  /// resolvable epoch-encryption key) is reported honestly as a conflict, not
  /// mislabelled as an authorization failure.
  Future<String?> memberAction(
    String groupHex,
    String action,
    String peerHex,
    String? roleName,
  ) async {
    final visible = await _visible(groupHex);
    if (visible == null) return 'group not found';
    final bundle = await _groups.load(visible.$1);
    if (bundle?.manifest.isSpace == true && action == 'mute') {
      return 'use the reasoned /v1/spaces/moderation action';
    }
    final peer = _parseId(peerHex);
    if (peer == null) return 'invalid peer';
    final role = roleName == null ? null : GroupRole.fromName(roleName);

    final state = visible.$2;
    final authorRole = state.roleOf(_groups.selfId)!;
    final targetRole = state.roleOf(peer);
    final ControlOp operation;
    final GroupRole? newRole;
    switch (action) {
      case 'invite':
        if (targetRole != null) return 'member already exists';
        operation = ControlOp.addMember;
        newRole = role;
      case 'add':
        if (targetRole != null) return 'member already exists';
        operation = ControlOp.addMember;
        newRole = role;
      case 'remove':
        if (targetRole == null) return 'member not found';
        operation = ControlOp.removeMember;
        newRole = null;
      case 'set_role':
        if (targetRole == null) return 'member not found';
        operation = ControlOp.setRole;
        newRole = role;
      case 'mute':
        if (targetRole == null) return 'member not found';
        operation = ControlOp.mute;
        newRole = null;
      case 'unmute':
        if (targetRole == null) return 'member not found';
        operation = ControlOp.unmute;
        newRole = null;
      case 'transfer_owner':
        if (targetRole == null) return 'member not found';
        operation = ControlOp.transferOwnership;
        newRole = null;
      default:
        return 'invalid member action';
    }
    if (!canApply(
      authorRole: authorRole,
      op: operation,
      targetRole: targetRole,
      newRole: newRole,
    )) {
      return 'operation rejected by group policy';
    }

    final bool applied;
    switch (action) {
      case 'invite':
        applied = await _groups.inviteToSpace(
          visible.$1,
          peer,
          role: role ?? GroupRole.member,
        );
      case 'add':
        applied = await _groups.addControlOp(
          visible.$1,
          ControlOp.addMember,
          target: peer,
          role: role,
        );
      case 'remove':
        applied = await _groups.addControlOp(
          visible.$1,
          ControlOp.removeMember,
          target: peer,
        );
      case 'set_role':
        applied = await _groups.addControlOp(
          visible.$1,
          ControlOp.setRole,
          target: peer,
          role: role,
        );
      case 'mute':
        applied = await _groups.addControlOp(
          visible.$1,
          ControlOp.mute,
          target: peer,
        );
      case 'unmute':
        applied = await _groups.addControlOp(
          visible.$1,
          ControlOp.unmute,
          target: peer,
        );
      case 'transfer_owner':
        applied = await _groups.transferSpaceOwnership(visible.$1, peer);
      default:
        return 'invalid member action'; // guarded by the policy switch above
    }
    return applied ? null : 'group mutation failed';
  }

  Future<String?> rename(String groupHex, String name) async {
    final visible = await _visible(groupHex);
    if (visible == null) return 'group not found';
    final role = visible.$2.roleOf(_groups.selfId)!;
    if (!canApply(authorRole: role, op: ControlOp.setName)) {
      return 'operation rejected by group policy';
    }
    return await _groups.renameGroup(visible.$1, name)
        ? null
        : 'group mutation failed';
  }

  Future<String?> leave(String groupHex) async {
    final visible = await _visible(groupHex);
    if (visible == null) return 'group not found';
    final role = visible.$2.roleOf(_groups.selfId)!;
    if (!canApply(authorRole: role, op: ControlOp.leave)) {
      return 'operation rejected by group policy';
    }
    return await _groups.leaveGroup(visible.$1)
        ? null
        : 'group mutation failed';
  }

  Future<(NodeId, GroupState)?> _visible(String groupHex) async {
    final groupId = _parseId(groupHex);
    if (groupId == null) return null;
    // The two user-facing lists are disjoint, but shared group/Space mutation
    // helpers still need to resolve either kind. Infrastructure device groups
    // occur in neither list.
    final listed = [
      ...await _groups.listGroups(),
      ...await _groups.listSpaces(),
    ].any((entry) => entry.groupId == groupId);
    if (!listed) return null;
    final state = await _groups.stateOf(groupId);
    if (state == null || !state.isMember(_groups.selfId)) return null;
    return (groupId, state);
  }

  static NodeId? _parseId(String value) {
    try {
      return NodeId.fromHex(value);
    } catch (_) {
      return null;
    }
  }

  static (NodeId, int)? _parseLogReference(String value) {
    final separator = value.lastIndexOf(':');
    if (separator <= 0 || separator == value.length - 1) return null;
    final author = _parseId(value.substring(0, separator));
    final seq = int.tryParse(value.substring(separator + 1));
    return author == null || seq == null || seq < 0 ? null : (author, seq);
  }
}
