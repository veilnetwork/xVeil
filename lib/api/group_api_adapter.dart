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
    for (final group in await _groups.listGroups())
      {
        'groupId': group.groupId.hex,
        'name': group.name,
        'unread': group.unread,
        'muted': group.muted,
        'preview': group.preview,
        'lastTs': group.lastTs,
      },
  ];

  Future<String?> create(String name) async {
    try {
      return (await _groups.createGroup(name)).hex;
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic> messageJson(GroupMessage message) => {
    'id': message.ref,
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
    final peer = _parseId(peerHex);
    if (peer == null) return 'invalid peer';
    final role = roleName == null ? null : GroupRole.fromName(roleName);

    final state = visible.$2;
    final authorRole = state.roleOf(_groups.selfId)!;
    final targetRole = state.roleOf(peer);
    final ControlOp operation;
    final GroupRole? newRole;
    switch (action) {
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
    // listGroups is the authoritative membership + user-visible filter. It
    // also excludes the sovereign infrastructure device group.
    final listed = (await _groups.listGroups()).any(
      (entry) => entry.groupId == groupId,
    );
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
}
