import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/api_server.dart';

// The automation API's auth + routing (pure ApiHandler — no socket).

void main() {
  final sent = <(String, String)>[];
  final groupPosts = <(String, String, String?)>[];
  final groupActions = <(String, String, String, String?)>[];
  final channelPosts = <(String, String, String, String?)>[];
  final channelCreates = <(String, String, List<String>)>[];
  final channelAcls = <(String, String, List<String>)>[];
  final spacePublications = <(String, String, String, String)>[];
  final spacePostEdits = <(String, String, String, String, String?)>[];
  final spacePostDeletes = <(String, String)>[];
  final spacePostReactions = <(String, String, String)>[];
  final subscriptions = <(String, bool)>[];
  final feedPostPreferences = <(String, String, bool)>[];
  final spaceInviteDecisions = <(String, bool)>[];
  final spaceJoinActions = <(String, String?, String?, String?)>[];
  final spaceCreates = <(String, String, String)>[];
  final spaceDescriptions = <(String, String)>[];
  final spaceLifecycleActions = <(String, String)>[];
  final spaceRetentionUpdates = <(String, int?, bool)>[];
  final spaceRulesPublications = <(String, String, String, int?)>[];
  final spaceRulesAcceptances = <String>[];
  final spaceModerationActions = <(String, String, String, String, String)>[];
  final spaceModerationRevocations = <(String, String, String)>[];
  final renames = <(String, String)>[];
  final leaves = <String>[];
  Map<String, dynamic>? call;
  Map<String, dynamic>? groupCall;
  ApiHandler make({
    String token = 'secret-token',
    bool readOnly = false,
    bool callsAvailable = true,
    bool groupCallsAvailable = true,
    bool groupMediaAvailable = true,
  }) {
    sent.clear();
    groupPosts.clear();
    groupActions.clear();
    channelPosts.clear();
    channelCreates.clear();
    channelAcls.clear();
    spacePublications.clear();
    spacePostEdits.clear();
    spacePostDeletes.clear();
    spacePostReactions.clear();
    subscriptions.clear();
    feedPostPreferences.clear();
    spaceInviteDecisions.clear();
    spaceJoinActions.clear();
    spaceCreates.clear();
    spaceDescriptions.clear();
    spaceLifecycleActions.clear();
    spaceRetentionUpdates.clear();
    spaceRulesPublications.clear();
    spaceRulesAcceptances.clear();
    spaceModerationActions.clear();
    spaceModerationRevocations.clear();
    renames.clear();
    leaves.clear();
    groupCall = null;
    return ApiHandler(
      tokens: token.isEmpty
          ? const []
          : [
              ApiToken(
                id: 't1',
                name: 'test',
                token: token,
                readOnly: readOnly,
              ),
            ],
      status: () => {'ok': true, 'nodeId': 'abcd'},
      contacts: () async => [
        {'nodeId': 'beef', 'short': 'beef'},
      ],
      requestContact: (target, greeting) async {
        if (target == 'bad') return 'invalid target';
        sent.add((target, greeting));
        return null;
      },
      contactAction: (peer, action) async {
        if (peer == 'bad') return 'invalid peer';
        sent.add((peer, action));
        return null;
      },
      send: (to, body) async {
        if (to == 'bad') return 'invalid peer';
        sent.add((to, body));
        return null;
      },
      messages: (peer, limit) async => [
        {'id': 'm1', 'body': 'hi', 'direction': 'incoming'},
      ],
      sendFile: (to, path, name) async => to == 'bad' ? 'invalid peer' : null,
      loadFile: (fileId) async => fileId == 'known' ? [1, 2, 3] : null,
      placeCall: (to, media) async => to == 'bad' ? 'invalid peer' : null,
      callState: () => call,
      callAction: (action) async => call = null,
      callsAvailable: callsAvailable,
      groups: () async => [
        {
          'groupId': 'aa',
          'name': 'Family',
          'unread': 2,
          'muted': false,
          'preview': 'hello',
          'lastTs': 123,
        },
      ],
      createGroup: (name) async => name == 'bad' ? null : 'new-group',
      createSpace: (name, description, visibility) async {
        spaceCreates.add((name, description, visibility));
        return name == 'bad' ? null : 'new-space';
      },
      groupMessages: (group, limit) async => group == 'missing'
          ? null
          : [
              {
                'id': '${'ab' * 32}:1',
                'author': 'author',
                'body': 'group hi',
                'sentAt': 123,
              },
            ],
      sendGroupMessage: (group, body, replyTo) async {
        if (group == 'bad') return 'invalid group';
        groupPosts.add((group, body, replyTo));
        return null;
      },
      sendGroupFile: (group, path, name, caption, replyTo) async =>
          group == 'missing'
          ? (error: 'group not found', contentId: null)
          : group == 'large'
          ? (error: 'group file too large', contentId: null)
          : (error: null, contentId: 'group-content'),
      fetchGroupFile: (group, message) async =>
          group == 'missing' ? 'group message attachment not found' : null,
      loadGroupFile: (group, message) async => group == 'missing'
          ? (error: 'group message attachment not found', bytes: null)
          : group == 'pending'
          ? (error: 'group content not downloaded', bytes: null)
          : (error: null, bytes: <int>[4, 5, 6]),
      groupMembers: (group) async => group == 'missing'
          ? null
          : {
              'groupId': group,
              'name': 'Family',
              'epoch': 2,
              'policyVersion': 0,
              'selfRole': 'owner',
              'members': [
                {
                  'nodeId': '01' * 32,
                  'short': '01010101',
                  'role': 'owner',
                  'muted': false,
                  'self': true,
                },
              ],
            },
      groupMemberAction: (group, action, peer, role) async {
        if (group == 'missing') return 'group not found';
        if (group == 'denied') return 'operation rejected by group policy';
        if (group == 'failed') return 'group mutation failed';
        if (group == 'exists') return 'member already exists';
        groupActions.add((group, action, peer, role));
        return null;
      },
      renameGroup: (group, name) async {
        if (group == 'missing') return 'group not found';
        if (group == 'denied') return 'operation rejected by group policy';
        renames.add((group, name));
        return null;
      },
      leaveGroup: (group) async {
        if (group == 'missing') return 'group not found';
        if (group == 'denied') return 'operation rejected by group policy';
        leaves.add(group);
        return null;
      },
      spaceChannels: (space) async => space == 'missing'
          ? null
          : [
              {
                'spaceId': space,
                'channelId': '01' * 32,
                'kind': 'text',
                'name': 'general',
                'default': true,
              },
            ],
      spacePosts: (space, limit, before) async => space == 'missing'
          ? null
          : {
              'posts': [
                {
                  'postId': '${'04' * 32}:0',
                  'spaceId': space,
                  'title': 'Update',
                  'body': 'community post',
                  'type': 'post',
                },
              ],
            },
      publishSpacePost: (space, title, body, type) async {
        if (space == 'denied') {
          return (error: 'post publication rejected', post: null);
        }
        spacePublications.add((space, title, body, type));
        return (
          error: null,
          post: <String, dynamic>{
            'spaceId': space,
            'title': title,
            'body': body,
            'type': type,
          },
        );
      },
      editSpacePost: (space, postId, title, body, type) async {
        if (space == 'denied') {
          return (error: 'post edit rejected', post: null);
        }
        spacePostEdits.add((space, postId, title, body, type));
        return (
          error: null,
          post: <String, dynamic>{
            'spaceId': space,
            'postId': postId,
            'title': title,
            'body': body,
            'type': type ?? 'post',
            'edited': true,
          },
        );
      },
      deleteSpacePost: (space, postId) async {
        if (space == 'denied') return 'post deletion rejected';
        spacePostDeletes.add((space, postId));
        return null;
      },
      reactToSpacePost: (space, postId, emoji) async {
        if (space == 'denied') return 'post reaction rejected';
        spacePostReactions.add((space, postId, emoji));
        return null;
      },
      spaceFeed: (limit, before) async => {
        'posts': [
          {'spaceId': 'aa', 'body': 'community post'},
        ],
      },
      setSpaceFeedEnabled: (space, enabled) async {
        if (space == 'missing') return 'space not found';
        subscriptions.add((space, enabled));
        return null;
      },
      setSpaceFeedPostHidden: (space, postId, hidden) async {
        if (space == 'missing') return 'space not found';
        feedPostPreferences.add((space, postId, hidden));
        return null;
      },
      spaceInvites: () async => [
        {
          'inviteId': 'ab' * 32,
          'spaceId': 'aa' * 32,
          'name': 'Invite lab',
          'accepted': false,
        },
      ],
      decideSpaceInvite: (inviteId, accept) async {
        spaceInviteDecisions.add((inviteId, accept));
        return null;
      },
      spaceJoinRequests: (space) async => {
        'outgoing': const [],
        if (space != null) ...{
          'spaceId': space,
          'joinCode': 'xveil://space/v1#test',
          'incoming': [
            {'requestId': 'cd' * 32, 'requester': 'ef' * 32},
          ],
        },
      },
      spaceJoinRequestAction: (action, space, requestId, code) async {
        spaceJoinActions.add((action, space, requestId, code));
        return (
          error: action == 'decline_bad' ? 'rejected' : null,
          code: action == 'create_link' ? 'xveil://space/v1#created' : null,
        );
      },
      spaceProfile: (space) async => space == 'missing'
          ? null
          : {
              'spaceId': space,
              'name': 'Field lab',
              'description': 'Initial summary',
              'visibility': 'secret',
              'discoverable': false,
            },
      updateSpaceDescription: (space, description) async {
        if (space == 'denied') return 'operation rejected by space policy';
        spaceDescriptions.add((space, description));
        return null;
      },
      spaceLifecycle: (space) async => space == 'missing'
          ? null
          : {
              'spaceId': space,
              'state': 'archived',
              'canArchive': false,
              'canRestore': true,
            },
      setSpaceLifecycle: (space, action) async {
        if (space == 'denied') return 'operation rejected by space policy';
        spaceLifecycleActions.add((space, action));
        return null;
      },
      spaceRetention: (space) async => space == 'missing'
          ? null
          : {
              'spaceId': space,
              'community': {'mode': 'deleteAfter', 'retentionMs': 7776000000},
              'localDevice': {'mode': 'keepForever'},
              'history': const [],
            },
      setSpaceRetention: (space, days, localDevice) async {
        if (space == 'denied') return 'operation rejected by space policy';
        spaceRetentionUpdates.add((space, days, localDevice));
        return null;
      },
      spaceRules: (space) async => space == 'missing'
          ? null
          : {
              'spaceId': space,
              'current': {
                'version': 1,
                'fullText': 'Respect privacy.',
                'summary': 'Privacy first.',
                'author': '01' * 32,
                'publishedAt': 100,
                'effectiveAt': 100,
              },
              'history': const [],
              'acceptanceRequired': true,
            },
      publishSpaceRules: (space, fullText, summary, effectiveAt) async {
        if (space == 'denied') return 'operation rejected by space policy';
        spaceRulesPublications.add((space, fullText, summary, effectiveAt));
        return null;
      },
      acceptSpaceRules: (space) async {
        if (space == 'missing') return 'space not found';
        spaceRulesAcceptances.add(space);
        return null;
      },
      spaceModerationAudit: (space) async => space == 'missing'
          ? null
          : [
              {
                'actionId': '${'01' * 32}:2',
                'kind': 'warning',
                'target': '02' * 32,
                'reason': 'signed warning',
                'active': true,
              },
            ],
      moderateSpace:
          (
            space,
            kind,
            target,
            scope,
            reason,
            channel,
            expiresAt,
            referenceKind,
            referenceId,
            referenceChannel,
          ) async {
            if (space == 'denied') {
              return (error: 'moderation action rejected', actionId: null);
            }
            spaceModerationActions.add((space, kind, target, scope, reason));
            return (error: null, actionId: '${'01' * 32}:2');
          },
      revokeSpaceModeration: (space, actionId, reason) async {
        if (space == 'denied') return 'moderation revocation rejected';
        spaceModerationRevocations.add((space, actionId, reason));
        return null;
      },
      createSpaceChannel:
          (
            space,
            name,
            kind,
            category,
            position,
            history,
            historySince,
            access,
            members,
          ) async {
            channelCreates.add((space, access, members));
            return space == 'denied'
                ? (error: 'channel mutation rejected', channelId: null)
                : (error: null, channelId: '02' * 32);
          },
      spaceChannelAction: (space, channel, action) async =>
          space == 'denied' ? 'channel mutation rejected' : null,
      setSpaceChannelMembers: (space, channel, members) async {
        channelAcls.add((space, channel, members));
        return space == 'denied' ? 'channel ACL mutation rejected' : null;
      },
      spaceChannelMessages: (space, channel, limit) async => space == 'missing'
          ? null
          : [
              {
                'id': '${'03' * 32}:1',
                'channelId': channel,
                'body': 'channel hi',
              },
            ],
      sendSpaceChannelMessage: (space, channel, body, replyTo) async {
        if (space == 'denied') return 'channel is not writable';
        channelPosts.add((space, channel, body, replyTo));
        return null;
      },
      groupMediaAvailable: groupMediaAvailable,
      startGroupCall: (group, media) async {
        if (group == '00' * 32) return 'group not found';
        if (groupCall != null) return 'group call unavailable';
        groupCall = {
          'groupId': group,
          'callId': 'call-1',
          'status': 'connecting',
          'media': media,
          'joined': true,
          'micOn': true,
          'cameraOn': media != 'audio',
          'screenOn': media == 'screen',
        };
        return null;
      },
      startSpaceVoiceSession: (space, channel, media) async {
        if (space == '00' * 32 || channel == '00' * 32) {
          return 'group call unavailable';
        }
        if (groupCall != null) return 'group call unavailable';
        groupCall = {
          'groupId': space,
          'channelId': channel,
          'callId': 'voice-session-1',
          'status': 'connecting',
          'media': media,
          'joined': true,
        };
        return null;
      },
      groupCallState: () => groupCall,
      groupCallAction: (action) async {
        if (groupCall == null) return 'group call action unavailable';
        if (action == 'end' && groupCall!['groupId'] == 'dd' * 32) {
          return 'operation rejected by group policy';
        }
        groupCall = {
          ...groupCall!,
          'status': action == 'join' ? 'active' : 'ended',
        };
        return null;
      },
      groupCallPosture: (mic, camera, screen) async {
        if (groupCall == null) return 'group call action unavailable';
        final next = <String, dynamic>{...groupCall!};
        if (mic != null) next['micOn'] = mic;
        if (camera != null) next['cameraOn'] = camera;
        if (screen != null) next['screenOn'] = screen;
        groupCall = next;
        return null;
      },
      groupCallsAvailable: groupCallsAvailable,
    );
  }

  Uri u(String p) => Uri.parse(p);

  test('every endpoint rejects a missing / wrong / malformed bearer', () async {
    final h = make();
    for (final auth in <String?>[
      null,
      'secret-token', // no "Bearer " prefix
      'Bearer wrong',
      'Bearer secret-toke', // shorter
      'Basic secret-token',
    ]) {
      expect(
        (await h.handle('GET', u('/v1/health'), auth)).status,
        401,
        reason: 'auth=$auth must be rejected',
      );
    }
  });

  test(
    'multiple tokens: each authenticates, per-token scope applies',
    () async {
      final h = ApiHandler(
        tokens: const [
          ApiToken(id: 'a', name: 'full', token: 'tok-full', readOnly: false),
          ApiToken(id: 'b', name: 'mon', token: 'tok-ro', readOnly: true),
        ],
        status: () => {'ok': true},
        contacts: () async => const [],
        send: (to, body) async => null,
        messages: (peer, limit) async => const [],
        sendFile: (to, path, name) async => null,
        loadFile: (fileId) async => null,
        placeCall: (to, media) async => null,
        callState: () => null,
        callAction: (action) async {},
        groups: () async => const [],
        createGroup: (_) async => 'gid',
        groupMessages: (_, _) async => const [],
        sendGroupMessage: (_, _, _) async => null,
        sendGroupFile: (_, _, _, _, _) async => (error: null, contentId: 'cid'),
        fetchGroupFile: (_, _) async => null,
        loadGroupFile: (_, _) async => (error: null, bytes: <int>[]),
        groupMembers: (_) async => const {},
        groupMemberAction: (_, _, _, _) async => null,
        renameGroup: (_, _) async => null,
        leaveGroup: (_) async => null,
        startGroupCall: (_, _) async => null,
        groupCallState: () => null,
        groupCallAction: (_) async => null,
        groupCallPosture: (_, _, _) async => null,
      );
      // An unknown token → 401.
      expect(
        (await h.handle('GET', u('/v1/health'), 'Bearer nope')).status,
        401,
      );
      // The full token can write.
      expect(
        (await h.handle(
          'POST',
          u('/v1/messages'),
          'Bearer tok-full',
          body: {'to': 'p', 'body': 'x'},
        )).status,
        200,
      );
      // The read-only token reads but its POST is 403.
      expect(
        (await h.handle('GET', u('/v1/health'), 'Bearer tok-ro')).status,
        200,
      );
      expect(
        (await h.handle(
          'POST',
          u('/v1/messages'),
          'Bearer tok-ro',
          body: {'to': 'p', 'body': 'x'},
        )).status,
        403,
      );
    },
  );

  test(
    'a read-only token allows reads but refuses every write with 403',
    () async {
      final h = make(readOnly: true);
      // Reads still work.
      expect(
        (await h.handle('GET', u('/v1/health'), 'Bearer secret-token')).status,
        200,
      );
      // Every write is 403 (not 200, not 401 — the token is valid but scoped).
      for (final w in <(String, Map<String, dynamic>)>[
        ('/v1/messages', {'to': 'p', 'body': 'x'}),
        ('/v1/files', {'to': 'p', 'path': '/x'}),
        ('/v1/calls', {'to': 'p'}),
        ('/v1/calls/hangup', {}),
        ('/v1/groups', {'name': 'G'}),
        ('/v1/groups/messages', {'group': 'g', 'body': 'x'}),
        ('/v1/groups/files', {'group': 'g', 'path': '/x'}),
        (
          '/v1/groups/files/fetch',
          {'group': 'g', 'messageId': '${'01' * 32}:1'},
        ),
        (
          '/v1/groups/members',
          {'group': 'g', 'action': 'add', 'peer': '01' * 32, 'role': 'member'},
        ),
        ('/v1/groups/name', {'group': 'g', 'name': 'G'}),
        ('/v1/groups/leave', {'group': 'g'}),
        ('/v1/spaces', {'name': 'S'}),
        ('/v1/spaces/profile', {'space': 's', 'description': 'new'}),
        ('/v1/spaces/posts', {'space': 's', 'body': 'x'}),
        ('/v1/spaces/subscription', {'space': 's', 'enabled': false}),
        (
          '/v1/feed/hidden',
          {'space': 's', 'postId': '${'01' * 32}:0', 'hidden': true},
        ),
        ('/v1/spaces/invites', {'inviteId': 'ab' * 32, 'action': 'accept'}),
        (
          '/v1/spaces/join-requests',
          {'action': 'request', 'code': 'xveil://space/v1#invalid'},
        ),
        (
          '/v1/spaces/channels',
          {'space': 's', 'name': 'general', 'kind': 'text'},
        ),
        (
          '/v1/spaces/channels/action',
          {'space': 's', 'channel': 'c', 'action': 'archive'},
        ),
        (
          '/v1/spaces/channels/messages',
          {'space': 's', 'channel': 'c', 'body': 'x'},
        ),
        ('/v1/groups/calls', {'group': 'aa' * 32, 'media': 'video'}),
        (
          '/v1/spaces/voice-sessions',
          {'space': 'aa' * 32, 'channel': 'bb' * 32, 'media': 'audio'},
        ),
        ('/v1/groups/calls/join', {}),
        ('/v1/groups/calls/decline', {}),
        ('/v1/groups/calls/leave', {}),
        ('/v1/groups/calls/end', {}),
        ('/v1/groups/calls/posture', {'mic': false}),
      ]) {
        final res = await h.handle(
          'POST',
          u(w.$1),
          'Bearer secret-token',
          body: w.$2,
        );
        expect(res.status, 403, reason: '${w.$1} must be read-only-refused');
      }
      final postId = '${'04' * 32}:0';
      expect(
        (await h.handle(
          'PATCH',
          u('/v1/spaces/posts'),
          'Bearer secret-token',
          body: {'space': 's', 'postId': postId},
        )).status,
        403,
      );
      expect(
        (await h.handle(
          'DELETE',
          u('/v1/spaces/posts?space=s&postId=$postId'),
          'Bearer secret-token',
        )).status,
        403,
      );
    },
  );

  test('an empty token rejects everything (API not provisioned)', () async {
    final h = make(token: '');
    expect((await h.handle('GET', u('/v1/health'), 'Bearer ')).status, 401);
    expect((await h.handle('GET', u('/v1/health'), null)).status, 401);
  });

  test('GET /v1/health returns node status with a valid token', () async {
    final res = await make().handle(
      'GET',
      u('/v1/health'),
      'Bearer secret-token',
    );
    expect(res.status, 200);
    expect((res.body as Map)['ok'], true);
    expect((res.body as Map)['nodeId'], 'abcd');
  });

  test('GET /v1/contacts returns accepted contacts', () async {
    final res = await make().handle(
      'GET',
      u('/v1/contacts'),
      'Bearer secret-token',
    );
    expect(res.status, 200);
    final list = (res.body as Map)['contacts'] as List;
    expect(list.single['nodeId'], 'beef');
  });

  test('contact request/accept/block routes validate and dispatch', () async {
    final h = make();
    expect(
      (await h.handle(
        'POST',
        u('/v1/contacts'),
        'Bearer secret-token',
        body: {'greeting': 'hi'},
      )).status,
      400,
    );
    expect(
      (await h.handle(
        'POST',
        u('/v1/contacts'),
        'Bearer secret-token',
        body: {'target': 'peer', 'greeting': 'hi'},
      )).status,
      200,
    );
    expect(sent.single, ('peer', 'hi'));
    expect(
      (await h.handle(
        'POST',
        u('/v1/contacts/accept'),
        'Bearer secret-token',
        body: {'peer': 'peer'},
      )).status,
      200,
    );
    expect(sent.last, ('peer', 'accept'));
    expect(
      (await h.handle(
        'POST',
        u('/v1/contacts/block'),
        'Bearer secret-token',
        body: {'peer': 'peer'},
      )).status,
      200,
    );
    expect(sent.last, ('peer', 'block'));
  });

  test(
    'POST /v1/messages sends; validates to+body; reports send errors',
    () async {
      final h = make();
      // Missing fields → 400.
      expect(
        (await h.handle(
          'POST',
          u('/v1/messages'),
          'Bearer secret-token',
          body: {'to': 'peer'},
        )).status,
        400,
      );
      // Valid → 200 and the send fn saw it.
      final ok = await h.handle(
        'POST',
        u('/v1/messages'),
        'Bearer secret-token',
        body: {'to': 'peer', 'body': 'hello'},
      );
      expect(ok.status, 200);
      expect(sent.single, ('peer', 'hello'));
      // Send-layer error → 400 with the message.
      final err = await h.handle(
        'POST',
        u('/v1/messages'),
        'Bearer secret-token',
        body: {'to': 'bad', 'body': 'x'},
      );
      expect(err.status, 400);
      expect((err.body as Map)['error'], 'invalid peer');
      // Unauthenticated POST is 401, never sends.
      expect(
        (await h.handle(
          'POST',
          u('/v1/messages'),
          null,
          body: {'to': 'peer', 'body': 'z'},
        )).status,
        401,
      );
      expect(sent.length, 1, reason: 'the 401 POST must not have sent');
    },
  );

  test('GET /v1/messages requires a peer and returns the log', () async {
    final h = make();
    expect(
      (await h.handle('GET', u('/v1/messages'), 'Bearer secret-token')).status,
      400,
    );
    final res = await h.handle(
      'GET',
      u('/v1/messages?peer=beef&limit=10'),
      'Bearer secret-token',
    );
    expect(res.status, 200);
    expect(((res.body as Map)['messages'] as List).single['id'], 'm1');
  });

  test('groups: list/create/read/post validate and dispatch', () async {
    final h = make();
    final listed = await h.handle(
      'GET',
      u('/v1/groups'),
      'Bearer secret-token',
    );
    expect(listed.status, 200);
    expect(((listed.body as Map)['groups'] as List).single['name'], 'Family');

    for (final name in ['', '   ', 'x' * 65]) {
      expect(
        (await h.handle(
          'POST',
          u('/v1/groups'),
          'Bearer secret-token',
          body: {'name': name},
        )).status,
        400,
      );
    }
    final created = await h.handle(
      'POST',
      u('/v1/groups'),
      'Bearer secret-token',
      body: {'name': '  Bots  '},
    );
    expect(created.status, 200);
    expect((created.body as Map)['groupId'], 'new-group');
    expect(
      (await h.handle(
        'POST',
        u('/v1/groups'),
        'Bearer secret-token',
        body: {'name': 'bad'},
      )).status,
      400,
    );

    expect(
      (await h.handle(
        'GET',
        u('/v1/groups/messages'),
        'Bearer secret-token',
      )).status,
      400,
    );
    final messages = await h.handle(
      'GET',
      u('/v1/groups/messages?group=aa&limit=10'),
      'Bearer secret-token',
    );
    expect(messages.status, 200);
    expect(
      ((messages.body as Map)['messages'] as List).single['id'],
      '${'ab' * 32}:1',
    );
    expect(
      (await h.handle(
        'GET',
        u('/v1/groups/messages?group=missing'),
        'Bearer secret-token',
      )).status,
      404,
    );
    expect(
      (await h.handle(
        'POST',
        u('/v1/groups/messages'),
        'Bearer secret-token',
        body: {'group': 'aa'},
      )).status,
      400,
    );
    expect(
      (await h.handle(
        'POST',
        u('/v1/groups/messages'),
        'Bearer secret-token',
        body: {'group': 'aa', 'body': 'я' * (300 * 1024)},
      )).status,
      413,
    );
    expect(
      (await h.handle(
        'POST',
        u('/v1/groups/messages'),
        'Bearer secret-token',
        body: {'group': 'aa', 'body': 'x', 'replyTo': 'not-a-ref'},
      )).status,
      400,
    );
    final posted = await h.handle(
      'POST',
      u('/v1/groups/messages'),
      'Bearer secret-token',
      body: {'group': 'aa', 'body': 'hello bot', 'replyTo': '${'ab' * 32}:1'},
    );
    expect(posted.status, 200);
    expect(groupPosts.single, ('aa', 'hello bot', '${'ab' * 32}:1'));
    expect(
      (await h.handle(
        'POST',
        u('/v1/groups/messages'),
        'Bearer secret-token',
        body: {'group': 'bad', 'body': 'x'},
      )).status,
      400,
    );
  });

  test(
    'spaces expose only nested channels and channel-scoped messages',
    () async {
      final h = make();
      final auth = 'Bearer secret-token';

      final listed = await h.handle('GET', u('/v1/spaces'), auth);
      expect(listed.status, 200);
      expect(((listed.body as Map)['spaces'] as List).single['name'], 'Family');
      final created = await h.handle(
        'POST',
        u('/v1/spaces'),
        auth,
        body: {
          'name': '  Veil  ',
          'description': '  Protocol builders  ',
          'visibility': 'secret',
        },
      );
      expect(created.status, 200);
      expect((created.body as Map)['spaceId'], 'new-space');
      expect(spaceCreates.single, ('Veil', 'Protocol builders', 'secret'));
      expect(
        (await h.handle(
          'POST',
          u('/v1/spaces'),
          auth,
          body: {'name': 'Bad visibility', 'visibility': 'world'},
        )).status,
        400,
      );

      final profile = await h.handle(
        'GET',
        u('/v1/spaces/profile?space=aa'),
        auth,
      );
      expect(profile.status, 200);
      expect((profile.body as Map)['description'], 'Initial summary');
      expect((profile.body as Map)['visibility'], 'secret');
      expect(
        (await h.handle(
          'POST',
          u('/v1/spaces/profile'),
          auth,
          body: {'space': 'aa', 'description': '  Updated summary  '},
        )).status,
        200,
      );
      expect(spaceDescriptions.single, ('aa', 'Updated summary'));

      final lifecycle = await h.handle(
        'GET',
        u('/v1/spaces/lifecycle?space=aa'),
        auth,
      );
      expect(lifecycle.status, 200);
      expect((lifecycle.body as Map)['state'], 'archived');
      expect(
        (await h.handle(
          'POST',
          u('/v1/spaces/lifecycle'),
          auth,
          body: {'space': 'aa', 'action': 'restore'},
        )).status,
        200,
      );
      expect(spaceLifecycleActions.single, ('aa', 'restore'));
      expect(
        (await h.handle(
          'POST',
          u('/v1/spaces/lifecycle'),
          auth,
          body: {'space': 'aa', 'action': 'delete'},
        )).status,
        200,
      );
      expect(spaceLifecycleActions.last, ('aa', 'delete'));
      expect(
        (await h.handle(
          'POST',
          u('/v1/spaces/lifecycle'),
          auth,
          body: {'space': 'aa', 'action': 'destroy'},
        )).status,
        400,
      );

      final retention = await h.handle(
        'GET',
        u('/v1/spaces/retention?space=aa'),
        auth,
      );
      expect(retention.status, 200);
      expect(
        ((retention.body as Map)['community'] as Map)['mode'],
        'deleteAfter',
      );
      expect(
        (await h.handle(
          'POST',
          u('/v1/spaces/retention'),
          auth,
          body: {'space': 'aa', 'scope': 'community', 'days': 90},
        )).status,
        200,
      );
      expect(spaceRetentionUpdates.single, ('aa', 90, false));

      final rules = await h.handle('GET', u('/v1/spaces/rules?space=aa'), auth);
      expect(rules.status, 200);
      expect(((rules.body as Map)['current'] as Map)['version'], 1);
      expect(
        (await h.handle(
          'POST',
          u('/v1/spaces/rules'),
          auth,
          body: {
            'space': 'aa',
            'fullText': '  Verify before sharing.  ',
            'summary': '  Verify.  ',
            'effectiveAt': 1234,
          },
        )).status,
        200,
      );
      expect(spaceRulesPublications.single, (
        'aa',
        'Verify before sharing.',
        'Verify.',
        1234,
      ));
      expect(
        (await h.handle(
          'POST',
          u('/v1/spaces/rules/accept'),
          auth,
          body: {'space': 'aa'},
        )).status,
        200,
      );
      expect(spaceRulesAcceptances.single, 'aa');

      final moderation = await h.handle(
        'GET',
        u('/v1/spaces/moderation?space=aa'),
        auth,
      );
      expect(moderation.status, 200);
      expect(((moderation.body as Map)['actions'] as List), hasLength(1));
      final actionId = '${'01' * 32}:2';
      expect(
        (await h.handle(
          'POST',
          u('/v1/spaces/moderation'),
          auth,
          body: {
            'space': 'aa',
            'kind': 'warning',
            'target': '02' * 32,
            'scope': 'space',
            'reason': '  signed warning  ',
          },
        )).status,
        200,
      );
      expect(spaceModerationActions.single, (
        'aa',
        'warning',
        '02' * 32,
        'space',
        'signed warning',
      ));
      expect(
        (await h.handle(
          'POST',
          u('/v1/spaces/moderation/revoke'),
          auth,
          body: {'space': 'aa', 'actionId': actionId, 'reason': '  reviewed  '},
        )).status,
        200,
      );
      expect(spaceModerationRevocations.single, ('aa', actionId, 'reviewed'));
      expect(
        (await h.handle(
          'POST',
          u('/v1/spaces/moderation'),
          auth,
          body: {
            'space': 'aa',
            'kind': 'warning',
            'target': '02' * 32,
            'reason': '   ',
          },
        )).status,
        400,
      );

      final invites = await h.handle('GET', u('/v1/spaces/invites'), auth);
      expect(invites.status, 200);
      expect(
        (((invites.body as Map)['invites'] as List).single as Map)['name'],
        'Invite lab',
      );
      expect(
        (await h.handle(
          'POST',
          u('/v1/spaces/invites'),
          auth,
          body: {'inviteId': 'ab' * 32, 'action': 'accept'},
        )).status,
        200,
      );
      expect(spaceInviteDecisions.single, ('ab' * 32, true));

      final joinRequests = await h.handle(
        'GET',
        u('/v1/spaces/join-requests?space=aa'),
        auth,
      );
      expect(joinRequests.status, 200);
      expect((joinRequests.body as Map)['joinCode'], 'xveil://space/v1#test');
      final createJoinLink = await h.handle(
        'POST',
        u('/v1/spaces/join-requests'),
        auth,
        body: {'action': 'create_link', 'space': 'aa'},
      );
      expect(createJoinLink.status, 200);
      expect((createJoinLink.body as Map)['code'], 'xveil://space/v1#created');
      expect(spaceJoinActions.single, ('create_link', 'aa', null, null));
      expect(
        (await h.handle(
          'POST',
          u('/v1/spaces/join-requests'),
          auth,
          body: {'action': 'approve', 'requestId': 'short'},
        )).status,
        400,
      );

      expect(
        (await h.handle('GET', u('/v1/spaces/channels'), auth)).status,
        400,
      );
      final channels = await h.handle(
        'GET',
        u('/v1/spaces/channels?space=aa'),
        auth,
      );
      expect(channels.status, 200);
      expect(
        ((channels.body as Map)['channels'] as List).single['name'],
        'general',
      );
      expect(
        (await h.handle(
          'GET',
          u('/v1/spaces/channels?space=missing'),
          auth,
        )).status,
        404,
      );

      final channel = await h.handle(
        'POST',
        u('/v1/spaces/channels'),
        auth,
        body: {
          'space': 'aa',
          'name': 'protocol',
          'kind': 'text',
          'position': 2,
          'history': 'full',
          'access': 'restricted',
          'members': ['03' * 32],
        },
      );
      expect(channel.status, 200);
      expect((channel.body as Map)['channelId'], '02' * 32);
      expect(channelCreates.single.$1, 'aa');
      expect(channelCreates.single.$2, 'restricted');
      expect(channelCreates.single.$3, orderedEquals(['03' * 32]));
      expect(
        (await h.handle(
          'POST',
          u('/v1/spaces/channels'),
          auth,
          body: {'space': 'aa', 'name': '', 'kind': 'text'},
        )).status,
        400,
      );

      expect(
        (await h.handle(
          'POST',
          u('/v1/spaces/channels/members'),
          auth,
          body: {
            'space': 'aa',
            'channel': 'cc',
            'members': ['03' * 32],
          },
        )).status,
        200,
      );
      expect(channelAcls.single.$1, 'aa');
      expect(channelAcls.single.$2, 'cc');
      expect(channelAcls.single.$3, orderedEquals(['03' * 32]));

      final roster = await h.handle(
        'GET',
        u('/v1/spaces/members?space=aa'),
        auth,
      );
      expect(roster.status, 200);
      expect((roster.body as Map)['spaceId'], 'aa');
      expect((roster.body as Map).containsKey('groupId'), isFalse);
      expect(((roster.body as Map)['members'] as List).single['role'], 'owner');
      expect(
        (await h.handle(
          'POST',
          u('/v1/spaces/members'),
          auth,
          body: {
            'space': 'aa',
            'action': 'invite',
            'peer': '04' * 32,
            'role': 'member',
          },
        )).status,
        200,
      );
      expect(groupActions.single, ('aa', 'invite', '04' * 32, 'member'));
      expect(
        (await h.handle(
          'POST',
          u('/v1/spaces/members'),
          auth,
          body: {'space': 'aa', 'action': 'transfer_owner', 'peer': '04' * 32},
        )).status,
        200,
      );
      expect(groupActions.last, ('aa', 'transfer_owner', '04' * 32, null));
      expect(
        (await h.handle(
          'POST',
          u('/v1/groups/members'),
          auth,
          body: {'group': 'aa', 'action': 'transfer_owner', 'peer': '04' * 32},
        )).status,
        400,
        reason: 'ownership transfer is Space-native, not a new legacy feature',
      );
      final denied = await h.handle(
        'POST',
        u('/v1/spaces/members'),
        auth,
        body: {'space': 'denied', 'action': 'remove', 'peer': '04' * 32},
      );
      expect(denied.status, 403);
      expect(
        (denied.body as Map)['error'],
        'operation rejected by space policy',
      );
      expect(
        (await h.handle(
          'POST',
          u('/v1/spaces/name'),
          auth,
          body: {'space': 'aa', 'name': '  Renamed community  '},
        )).status,
        200,
      );
      expect(renames.single, ('aa', 'Renamed community'));
      expect(
        (await h.handle(
          'POST',
          u('/v1/spaces/leave'),
          auth,
          body: {'space': 'aa'},
        )).status,
        200,
      );
      expect(leaves.single, 'aa');

      expect(
        (await h.handle(
          'POST',
          u('/v1/spaces/channels/action'),
          auth,
          body: {'space': 'aa', 'channel': 'cc', 'action': 'archive'},
        )).status,
        200,
      );
      expect(
        (await h.handle(
          'POST',
          u('/v1/spaces/channels/action'),
          auth,
          body: {'space': 'aa', 'channel': 'cc', 'action': 'delete'},
        )).status,
        400,
      );

      final messages = await h.handle(
        'GET',
        u('/v1/spaces/channels/messages?space=aa&channel=cc&limit=10'),
        auth,
      );
      expect(messages.status, 200);
      expect(
        ((messages.body as Map)['messages'] as List).single['channelId'],
        'cc',
      );
      final reply = '${'ab' * 32}:1';
      expect(
        (await h.handle(
          'POST',
          u('/v1/spaces/channels/messages'),
          auth,
          body: {
            'space': 'aa',
            'channel': 'cc',
            'body': 'hello',
            'replyTo': reply,
          },
        )).status,
        200,
      );
      expect(channelPosts.single, ('aa', 'cc', 'hello', reply));
    },
  );

  test(
    'Space publications, feed and local subscription validate/dispatch',
    () async {
      final h = make();
      const auth = 'Bearer secret-token';
      final posts = await h.handle(
        'GET',
        u('/v1/spaces/posts?space=aa&limit=10'),
        auth,
      );
      expect(posts.status, 200);
      expect(
        ((posts.body as Map)['posts'] as List).single['body'],
        'community post',
      );
      expect(
        (await h.handle(
          'GET',
          u('/v1/spaces/posts?space=missing'),
          auth,
        )).status,
        404,
      );
      expect(
        (await h.handle(
          'GET',
          u('/v1/spaces/posts?space=aa&before=broken'),
          auth,
        )).status,
        400,
      );

      final published = await h.handle(
        'POST',
        u('/v1/spaces/posts'),
        auth,
        body: {
          'space': 'aa',
          'title': 'Title',
          'body': 'Body',
          'type': 'article',
        },
      );
      expect(published.status, 200);
      expect(spacePublications.single, ('aa', 'Title', 'Body', 'article'));
      expect(
        (await h.handle(
          'POST',
          u('/v1/spaces/posts'),
          auth,
          body: {'space': 'aa', 'body': '', 'type': 'unknown'},
        )).status,
        400,
      );

      final postId = '${'04' * 32}:0';
      final edited = await h.handle(
        'PATCH',
        u('/v1/spaces/posts'),
        auth,
        body: {
          'space': 'aa',
          'postId': postId,
          'title': 'Corrected',
          'body': 'Revised',
          'type': 'post',
        },
      );
      expect(edited.status, 200);
      expect(spacePostEdits.single, (
        'aa',
        postId,
        'Corrected',
        'Revised',
        'post',
      ));
      expect(
        (await h.handle(
          'PATCH',
          u('/v1/spaces/posts'),
          auth,
          body: {'space': 'aa', 'postId': 'bad'},
        )).status,
        400,
      );
      expect(
        (await h.handle(
          'DELETE',
          u('/v1/spaces/posts?space=aa&postId=$postId'),
          auth,
        )).status,
        200,
      );
      expect(spacePostDeletes.single, ('aa', postId));
      expect(
        (await h.handle(
          'POST',
          u('/v1/spaces/posts/reactions'),
          auth,
          body: {'space': 'aa', 'postId': postId, 'emoji': '🔥'},
        )).status,
        200,
      );
      expect(spacePostReactions.single, ('aa', postId, '🔥'));
      expect(
        (await h.handle(
          'POST',
          u('/v1/spaces/posts/reactions'),
          auth,
          body: {'space': 'aa', 'postId': 'bad', 'emoji': '🔥'},
        )).status,
        400,
      );
      expect(
        (await h.handle(
          'DELETE',
          u('/v1/spaces/posts?space=aa&postId=bad'),
          auth,
        )).status,
        400,
      );

      final feed = await h.handle('GET', u('/v1/feed?limit=20'), auth);
      expect(feed.status, 200);
      expect(((feed.body as Map)['posts'] as List), hasLength(1));
      expect(
        (await h.handle(
          'POST',
          u('/v1/spaces/subscription'),
          auth,
          body: {'space': 'aa', 'enabled': false},
        )).status,
        200,
      );
      expect(subscriptions.single, ('aa', false));
      expect(
        (await h.handle(
          'POST',
          u('/v1/feed/hidden'),
          auth,
          body: {'space': 'aa', 'postId': postId, 'hidden': true},
        )).status,
        200,
      );
      expect(feedPostPreferences.single, ('aa', postId, true));
      expect(
        (await h.handle(
          'POST',
          u('/v1/feed/hidden'),
          auth,
          body: {'space': 'aa', 'postId': 'bad', 'hidden': true},
        )).status,
        400,
      );
    },
  );

  test('loopback API parses PATCH JSON for signed Space post edits', () async {
    final server = ApiServer(make(), const Stream.empty());
    final port = await server.start(0);
    final client = HttpClient();
    try {
      final postId = '${'04' * 32}:0';
      final request = await client.openUrl(
        'PATCH',
        Uri.parse('http://127.0.0.1:$port/v1/spaces/posts'),
      );
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer secret-token',
      );
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'space': 'aa',
          'postId': postId,
          'title': 'Socket edit',
          'body': 'Parsed body',
        }),
      );
      final response = await request.close();
      final decoded =
          jsonDecode(await utf8.decoder.bind(response).join()) as Map;
      expect(response.statusCode, 200);
      expect(decoded['ok'], isTrue);
      expect(spacePostEdits.single, (
        'aa',
        postId,
        'Socket edit',
        'Parsed body',
        null,
      ));
    } finally {
      client.close(force: true);
      await server.stop();
    }
  });

  test(
    'group files send, explicit fetch and scoped download validate/dispatch',
    () async {
      final h = make();
      final message = '${'ab' * 32}:1';

      expect(
        (await h.handle(
          'POST',
          u('/v1/groups/files'),
          'Bearer secret-token',
          body: {'group': 'aa'},
        )).status,
        400,
      );
      expect(
        (await h.handle(
          'POST',
          u('/v1/groups/files'),
          'Bearer secret-token',
          body: {'group': 'aa', 'path': '/tmp/x', 'replyTo': 'bad'},
        )).status,
        400,
      );
      expect(
        (await h.handle(
          'POST',
          u('/v1/groups/files'),
          'Bearer secret-token',
          body: {
            'group': 'aa',
            'path': '/tmp/x',
            'caption': 'я' * (300 * 1024),
          },
        )).status,
        413,
      );
      final sentFile = await h.handle(
        'POST',
        u('/v1/groups/files'),
        'Bearer secret-token',
        body: {
          'group': 'aa',
          'path': '/tmp/x',
          'name': 'clip.mp4',
          'caption': 'watch',
          'replyTo': message,
        },
      );
      expect(sentFile.status, 200);
      expect((sentFile.body as Map)['contentId'], 'group-content');
      expect(
        (await h.handle(
          'POST',
          u('/v1/groups/files'),
          'Bearer secret-token',
          body: {'group': 'large', 'path': '/tmp/x'},
        )).status,
        413,
      );

      expect(
        (await h.handle(
          'POST',
          u('/v1/groups/files/fetch'),
          'Bearer secret-token',
          body: {'group': 'aa', 'messageId': 'bad'},
        )).status,
        400,
      );
      expect(
        (await h.handle(
          'POST',
          u('/v1/groups/files/fetch'),
          'Bearer secret-token',
          body: {'group': 'aa', 'messageId': message},
        )).status,
        200,
      );
      expect(
        (await h.handle(
          'POST',
          u('/v1/groups/files/fetch'),
          'Bearer secret-token',
          body: {'group': 'missing', 'messageId': message},
        )).status,
        404,
      );

      expect(
        (await h.handle(
          'GET',
          u('/v1/groups/files/download?group=aa'),
          'Bearer secret-token',
        )).status,
        400,
      );
      final downloaded = await h.handle(
        'GET',
        u('/v1/groups/files/download?group=aa&messageId=$message'),
        'Bearer secret-token',
      );
      expect(downloaded.status, 200);
      expect(downloaded.bytes, [4, 5, 6]);
      expect(
        (await h.handle(
          'GET',
          u('/v1/groups/files/download?group=pending&messageId=$message'),
          'Bearer secret-token',
        )).status,
        409,
      );
      expect(
        (await h.handle(
          'GET',
          u('/v1/groups/files/download?group=missing&messageId=$message'),
          'Bearer secret-token',
        )).status,
        404,
      );
    },
  );

  test(
    'a host without group content reports its three routes as 501',
    () async {
      final h = make(groupMediaAvailable: false);
      final message = '${'ab' * 32}:1';
      expect(
        (await h.handle(
          'POST',
          u('/v1/groups/files'),
          'Bearer secret-token',
          body: {'group': 'aa', 'path': '/tmp/x'},
        )).status,
        501,
      );
      expect(
        (await h.handle(
          'POST',
          u('/v1/groups/files/fetch'),
          'Bearer secret-token',
          body: {'group': 'aa', 'messageId': message},
        )).status,
        501,
      );
      expect(
        (await h.handle(
          'GET',
          u('/v1/groups/files/download?group=aa&messageId=$message'),
          'Bearer secret-token',
        )).status,
        501,
      );
    },
  );

  test('a host without group core reports every group route as 501', () async {
    final base = make();
    final h = ApiHandler(
      tokens: base.tokens,
      status: base.status,
      contacts: base.contacts,
      send: base.send,
      messages: base.messages,
      sendFile: base.sendFile,
      loadFile: base.loadFile,
      placeCall: base.placeCall,
      callState: base.callState,
      callAction: base.callAction,
      groups: base.groups,
      createGroup: base.createGroup,
      groupMessages: base.groupMessages,
      sendGroupMessage: base.sendGroupMessage,
      sendGroupFile: base.sendGroupFile,
      fetchGroupFile: base.fetchGroupFile,
      loadGroupFile: base.loadGroupFile,
      groupMembers: base.groupMembers,
      groupMemberAction: base.groupMemberAction,
      renameGroup: base.renameGroup,
      leaveGroup: base.leaveGroup,
      groupsAvailable: false,
      groupMediaAvailable: false,
      startGroupCall: base.startGroupCall,
      groupCallState: base.groupCallState,
      groupCallAction: base.groupCallAction,
      groupCallPosture: base.groupCallPosture,
      groupCallsAvailable: false,
    );
    expect(
      (await h.handle('GET', u('/v1/groups'), 'Bearer secret-token')).status,
      501,
    );
    expect(
      (await h.handle(
        'POST',
        u('/v1/groups/messages'),
        'Bearer secret-token',
        body: {'group': 'g', 'body': 'x'},
      )).status,
      501,
    );
    expect(
      (await h.handle(
        'POST',
        u('/v1/groups/files'),
        'Bearer secret-token',
        body: {'group': 'g', 'path': '/x'},
      )).status,
      501,
    );
    expect(
      (await h.handle('GET', u('/v1/feed'), 'Bearer secret-token')).status,
      501,
    );
    expect(
      (await h.handle(
        'POST',
        u('/v1/feed/hidden'),
        'Bearer secret-token',
        body: {'space': 'aa', 'postId': '${'01' * 32}:0', 'hidden': true},
      )).status,
      501,
    );
  });

  test(
    'group roster and admin routes validate, dispatch and preserve policy',
    () async {
      final h = make();
      final peer = '02' * 32;

      expect(
        (await h.handle(
          'GET',
          u('/v1/groups/members'),
          'Bearer secret-token',
        )).status,
        400,
      );
      final roster = await h.handle(
        'GET',
        u('/v1/groups/members?group=aa'),
        'Bearer secret-token',
      );
      expect(roster.status, 200);
      expect((roster.body as Map)['selfRole'], 'owner');
      expect(((roster.body as Map)['members'] as List).single['role'], 'owner');
      expect(
        (await h.handle(
          'GET',
          u('/v1/groups/members?group=missing'),
          'Bearer secret-token',
        )).status,
        404,
      );

      for (final body in <Map<String, dynamic>>[
        {'group': 'aa', 'action': 'add', 'peer': peer}, // role required
        {'group': 'aa', 'action': 'remove', 'peer': peer, 'role': 'member'},
        {'group': 'aa', 'action': 'ban', 'peer': peer},
        {
          'group': 'aa',
          'action': 'add',
          'peer': 'not-a-node',
          'role': 'member',
        },
        {'group': 'aa', 'action': 'set_role', 'peer': peer, 'role': 'owner'},
      ]) {
        expect(
          (await h.handle(
            'POST',
            u('/v1/groups/members'),
            'Bearer secret-token',
            body: body,
          )).status,
          400,
          reason: '$body must be rejected before the group core',
        );
      }

      for (final action in ['add', 'set_role']) {
        final response = await h.handle(
          'POST',
          u('/v1/groups/members'),
          'Bearer secret-token',
          body: {
            'group': 'aa',
            'action': action,
            'peer': peer,
            'role': action == 'add' ? 'member' : 'admin',
          },
        );
        expect(response.status, 200);
      }
      for (final action in ['mute', 'unmute', 'remove']) {
        expect(
          (await h.handle(
            'POST',
            u('/v1/groups/members'),
            'Bearer secret-token',
            body: {'group': 'aa', 'action': action, 'peer': peer},
          )).status,
          200,
        );
      }
      expect(groupActions, [
        ('aa', 'add', peer, 'member'),
        ('aa', 'set_role', peer, 'admin'),
        ('aa', 'mute', peer, null),
        ('aa', 'unmute', peer, null),
        ('aa', 'remove', peer, null),
      ]);

      expect(
        (await h.handle(
          'POST',
          u('/v1/groups/members'),
          'Bearer secret-token',
          body: {'group': 'denied', 'action': 'remove', 'peer': peer},
        )).status,
        403,
      );
      expect(
        (await h.handle(
          'POST',
          u('/v1/groups/members'),
          'Bearer secret-token',
          body: {'group': 'missing', 'action': 'remove', 'peer': peer},
        )).status,
        404,
      );
      expect(
        (await h.handle(
          'POST',
          u('/v1/groups/members'),
          'Bearer secret-token',
          body: {'group': 'failed', 'action': 'remove', 'peer': peer},
        )).status,
        409,
      );
      expect(
        (await h.handle(
          'POST',
          u('/v1/groups/members'),
          'Bearer secret-token',
          body: {
            'group': 'exists',
            'action': 'add',
            'peer': peer,
            'role': 'member',
          },
        )).status,
        409,
      );

      expect(
        (await h.handle(
          'POST',
          u('/v1/groups/name'),
          'Bearer secret-token',
          body: {'group': 'aa', 'name': '  New name  '},
        )).status,
        200,
      );
      expect(
        (await h.handle(
          'POST',
          u('/v1/groups/name'),
          'Bearer secret-token',
          body: {'group': 'aa', 'name': 'x' * 65},
        )).status,
        400,
      );
      expect(
        (await h.handle(
          'POST',
          u('/v1/groups/leave'),
          'Bearer secret-token',
          body: {'group': 'denied'},
        )).status,
        403,
      );
      expect(
        (await h.handle(
          'POST',
          u('/v1/groups/leave'),
          'Bearer secret-token',
          body: {'group': 'aa'},
        )).status,
        200,
      );
    },
  );

  test(
    'group-call routes validate, expose state, posture and policy failures',
    () async {
      final h = make();
      final group = 'aa' * 32;

      final idle = await h.handle(
        'GET',
        u('/v1/groups/calls'),
        'Bearer secret-token',
      );
      expect(idle.status, 200);
      expect((idle.body as Map)['call'], isNull);

      for (final body in <Map<String, dynamic>>[
        {'group': 'bad'},
        {'group': group, 'media': 'hologram'},
      ]) {
        expect(
          (await h.handle(
            'POST',
            u('/v1/groups/calls'),
            'Bearer secret-token',
            body: body,
          )).status,
          400,
        );
      }
      expect(
        (await h.handle(
          'POST',
          u('/v1/groups/calls'),
          'Bearer secret-token',
          body: {'group': '00' * 32},
        )).status,
        404,
      );

      final started = await h.handle(
        'POST',
        u('/v1/groups/calls'),
        'Bearer secret-token',
        body: {'group': group, 'media': 'video'},
      );
      expect(started.status, 200);
      expect((started.body as Map)['call'], containsPair('groupId', group));
      expect(
        (await h.handle(
          'POST',
          u('/v1/groups/calls'),
          'Bearer secret-token',
          body: {'group': group},
        )).status,
        409,
      );

      expect(
        (await h.handle(
          'POST',
          u('/v1/groups/calls/posture'),
          'Bearer secret-token',
          body: const {},
        )).status,
        400,
      );
      final posture = await h.handle(
        'POST',
        u('/v1/groups/calls/posture'),
        'Bearer secret-token',
        body: {'mic': false, 'camera': false},
      );
      expect(posture.status, 200);
      expect((posture.body as Map)['call'], containsPair('micOn', false));
      expect((posture.body as Map)['call'], containsPair('cameraOn', false));

      final left = await h.handle(
        'POST',
        u('/v1/groups/calls/leave'),
        'Bearer secret-token',
      );
      expect(left.status, 200);
      expect((left.body as Map)['call'], containsPair('status', 'ended'));

      final noCall = make();
      expect(
        (await noCall.handle(
          'POST',
          u('/v1/groups/calls/join'),
          'Bearer secret-token',
        )).status,
        409,
      );

      final denied = make();
      expect(
        (await denied.handle(
          'POST',
          u('/v1/groups/calls'),
          'Bearer secret-token',
          body: {'group': 'dd' * 32},
        )).status,
        200,
      );
      expect(
        (await denied.handle(
          'POST',
          u('/v1/groups/calls/end'),
          'Bearer secret-token',
        )).status,
        403,
      );
    },
  );

  test('Space voice-session route requires both signed scope ids', () async {
    final h = make();
    final space = 'aa' * 32;
    final channel = 'bb' * 32;
    for (final body in <Map<String, dynamic>>[
      {'space': 'bad', 'channel': channel},
      {'space': space, 'channel': 'bad'},
      {'space': space, 'channel': channel, 'media': 'hologram'},
    ]) {
      expect(
        (await h.handle(
          'POST',
          u('/v1/spaces/voice-sessions'),
          'Bearer secret-token',
          body: body,
        )).status,
        400,
      );
    }

    final started = await h.handle(
      'POST',
      u('/v1/spaces/voice-sessions'),
      'Bearer secret-token',
      body: {'space': space, 'channel': channel},
    );
    expect(started.status, 200);
    expect((started.body as Map)['call'], containsPair('groupId', space));
    expect((started.body as Map)['call'], containsPair('channelId', channel));
  });

  test(
    'a host without group-call media reports group-call routes as 501',
    () async {
      final h = make(groupCallsAvailable: false);
      for (final request in <(String, String, Map<String, dynamic>?)>[
        ('GET', '/v1/groups/calls', null),
        ('POST', '/v1/groups/calls', {'group': 'aa' * 32}),
        ('POST', '/v1/groups/calls/join', null),
        ('POST', '/v1/groups/calls/posture', {'mic': false}),
      ]) {
        expect(
          (await h.handle(
            request.$1,
            u(request.$2),
            'Bearer secret-token',
            body: request.$3,
          )).status,
          501,
        );
      }
    },
  );

  test('POST /v1/files validates to+path; reports send errors', () async {
    final h = make();
    expect(
      (await h.handle(
        'POST',
        u('/v1/files'),
        'Bearer secret-token',
        body: {'to': 'peer'},
      )).status,
      400,
    );
    expect(
      (await h.handle(
        'POST',
        u('/v1/files'),
        'Bearer secret-token',
        body: {'to': 'peer', 'path': '/tmp/x'},
      )).status,
      200,
    );
    final err = await h.handle(
      'POST',
      u('/v1/files'),
      'Bearer secret-token',
      body: {'to': 'bad', 'path': '/tmp/x'},
    );
    expect(err.status, 400);
    expect((err.body as Map)['error'], 'invalid peer');
    expect(
      (await h.handle(
        'POST',
        u('/v1/files'),
        null,
        body: {'to': 'peer', 'path': '/tmp/x'},
      )).status,
      401,
    );
  });

  test(
    'GET /v1/files/download returns bytes for a known id, 404 otherwise',
    () async {
      final h = make();
      expect(
        (await h.handle(
          'GET',
          u('/v1/files/download'),
          'Bearer secret-token',
        )).status,
        400,
      ); // no fileId
      final miss = await h.handle(
        'GET',
        u('/v1/files/download?fileId=nope'),
        'Bearer secret-token',
      );
      expect(miss.status, 404);
      final hit = await h.handle(
        'GET',
        u('/v1/files/download?fileId=known'),
        'Bearer secret-token',
      );
      expect(hit.status, 200);
      expect(hit.bytes, [1, 2, 3]);
      expect(hit.contentType, 'application/octet-stream');
    },
  );

  test(
    'calls: place validates to; GET reflects state; actions clear it',
    () async {
      call = null;
      final h = make();
      // POST place requires `to`.
      expect(
        (await h.handle(
          'POST',
          u('/v1/calls'),
          'Bearer secret-token',
          body: <String, dynamic>{},
        )).status,
        400,
      );
      // A bad peer surfaces the placeCall error.
      final bad = await h.handle(
        'POST',
        u('/v1/calls'),
        'Bearer secret-token',
        body: {'to': 'bad'},
      );
      expect(bad.status, 400);
      // Place ok → 200 with the (test) call state.
      call = {'callId': 'c1', 'status': 'ringing'};
      final placed = await h.handle(
        'POST',
        u('/v1/calls'),
        'Bearer secret-token',
        body: {'to': 'peer', 'media': 'audio'},
      );
      expect(placed.status, 200);
      expect(((placed.body as Map)['call'] as Map)['callId'], 'c1');
      // GET reflects the current call.
      expect(
        ((await h.handle('GET', u('/v1/calls'), 'Bearer secret-token')).body
            as Map)['call'],
        isNotNull,
      );
      // Hangup clears it (the fake action nulls _call).
      final hung = await h.handle(
        'POST',
        u('/v1/calls/hangup'),
        'Bearer secret-token',
      );
      expect(hung.status, 200);
      expect((hung.body as Map)['call'], isNull);
      // Auth still enforced.
      expect((await h.handle('GET', u('/v1/calls'), null)).status, 401);
    },
  );

  test('a host without a media engine reports call routes as 501', () async {
    final h = make(callsAvailable: false);
    expect(
      (await h.handle('GET', u('/v1/calls'), 'Bearer secret-token')).status,
      501,
    );
    expect(
      (await h.handle(
        'POST',
        u('/v1/calls'),
        'Bearer secret-token',
        body: {'to': 'peer'},
      )).status,
      501,
    );
    expect(
      (await h.handle(
        'POST',
        u('/v1/calls/hangup'),
        'Bearer secret-token',
      )).status,
      501,
    );
  });

  test(
    'GET /v1/openapi.json returns a valid OpenAPI 3 doc with every path',
    () async {
      final res = await make().handle(
        'GET',
        u('/v1/openapi.json'),
        'Bearer secret-token',
      );
      expect(res.status, 200);
      final spec = res.body as Map<String, dynamic>;
      expect(spec['openapi'], startsWith('3.'));
      expect((spec['info'] as Map)['title'], isNotEmpty);
      final paths = (spec['paths'] as Map).keys.toSet();
      // Every implemented endpoint is documented (WS /events lives in the info).
      expect(
        paths,
        containsAll(<String>[
          '/health',
          '/contacts',
          '/contacts/accept',
          '/contacts/block',
          '/messages',
          '/spaces',
          '/spaces/profile',
          '/spaces/lifecycle',
          '/spaces/retention',
          '/spaces/rules',
          '/spaces/rules/accept',
          '/spaces/moderation',
          '/spaces/moderation/revoke',
          '/spaces/posts',
          '/spaces/posts/reactions',
          '/spaces/subscription',
          '/feed',
          '/feed/hidden',
          '/spaces/channels',
          '/spaces/channels/action',
          '/spaces/channels/messages',
          '/groups',
          '/groups/messages',
          '/groups/files',
          '/groups/files/fetch',
          '/groups/files/download',
          '/groups/members',
          '/groups/name',
          '/groups/leave',
          '/groups/calls',
          '/groups/calls/join',
          '/groups/calls/decline',
          '/groups/calls/leave',
          '/groups/calls/end',
          '/groups/calls/posture',
          '/files',
          '/files/download',
          '/calls',
          '/calls/hangup',
        ]),
      );
      final pathMap = spec['paths'] as Map;
      expect((pathMap['/contacts/accept'] as Map).keys, {'post'});
      expect((pathMap['/spaces/posts'] as Map).keys.toSet(), {
        'get',
        'post',
        'patch',
        'delete',
      });
      // The security scheme is declared so generated clients wire the token.
      expect(
        ((spec['components'] as Map)['securitySchemes'] as Map)['bearerAuth'],
        isNotNull,
      );
      // The spec itself is behind auth like every other route.
      expect(
        (await make().handle('GET', u('/v1/openapi.json'), null)).status,
        401,
      );
    },
  );

  test('an authenticated unknown route is 404, not 401', () async {
    final res = await make().handle(
      'GET',
      u('/v1/nope'),
      'Bearer secret-token',
    );
    expect(res.status, 404);
  });

  test('tokenOk (WS query-token auth) accepts only the exact token', () {
    final h = make();
    expect(h.tokenOk('secret-token'), isTrue);
    expect(h.tokenOk('secret-toke'), isFalse); // shorter
    expect(h.tokenOk('wrong-token!'), isFalse);
    expect(h.tokenOk(null), isFalse);
    expect(h.tokenOk(''), isFalse);
    expect(make(token: '').tokenOk(''), isFalse, reason: 'empty token rejects');
  });

  test('ApiConfig.copyWith + empty defaults; ApiToken JSON round-trip', () {
    expect(ApiConfig.empty.enabled, false);
    expect(ApiConfig.empty.tokens, isEmpty);
    final t = const ApiToken(id: 'i', name: 'n', token: 's', readOnly: true);
    final c = ApiConfig.empty.copyWith(enabled: true, tokens: [t]);
    expect(c.enabled, true);
    expect(c.tokens.single.token, 's');
    final rt = ApiToken.fromJson(t.toJson())!;
    expect(rt.id, 'i');
    expect(rt.readOnly, true);
    // copyWith keeps the webhook; withWebhook sets AND clears it.
    final w = c.withWebhook('http://127.0.0.1:9911/hook');
    expect(w.copyWith(enabled: false).webhookUrl, 'http://127.0.0.1:9911/hook');
    expect(w.withWebhook(null).webhookUrl, isNull);
  });

  test('webhookUrlError enforces loopback-only http(s)', () {
    expect(webhookUrlError('http://127.0.0.1:9911/hook'), isNull);
    expect(webhookUrlError('http://localhost:8080/x'), isNull);
    expect(webhookUrlError('https://127.0.0.1/x'), isNull);
    // Cleartext must not leave the machine (privacy canon).
    expect(webhookUrlError('http://192.168.1.10/x'), isNotNull);
    expect(webhookUrlError('http://example.com/x'), isNotNull);
    expect(webhookUrlError('ftp://127.0.0.1/x'), isNotNull);
    expect(webhookUrlError('not a url'), isNotNull);
  });

  test(
    'webhook routes: get/set/clear, validation, read-only refuses writes',
    () async {
      String? hook;
      ApiHandler withHook({bool readOnly = false}) => ApiHandler(
        tokens: [
          ApiToken(id: 't', name: 't', token: 'tok', readOnly: readOnly),
        ],
        status: () => const {'ok': true},
        contacts: () async => const [],
        send: (to, body) async => null,
        messages: (peer, limit) async => const [],
        sendFile: (to, path, name) async => null,
        loadFile: (fileId) async => null,
        placeCall: (to, media) async => null,
        callState: () => null,
        callAction: (action) async {},
        groups: () async => const [],
        createGroup: (_) async => 'gid',
        groupMessages: (_, _) async => const [],
        sendGroupMessage: (_, _, _) async => null,
        sendGroupFile: (_, _, _, _, _) async => (error: null, contentId: 'cid'),
        fetchGroupFile: (_, _) async => null,
        loadGroupFile: (_, _) async => (error: null, bytes: <int>[]),
        groupMembers: (_) async => const {},
        groupMemberAction: (_, _, _, _) async => null,
        renameGroup: (_, _) async => null,
        leaveGroup: (_) async => null,
        startGroupCall: (_, _) async => null,
        groupCallState: () => null,
        groupCallAction: (_) async => null,
        groupCallPosture: (_, _, _) async => null,
        webhook: () => hook,
        setWebhook: (url) async => hook = url,
      );
      final h = withHook();
      // Unset → null; set a loopback URL → stored; get reflects it.
      expect((await h.handle('GET', u('/v1/webhook'), 'Bearer tok')).body, {
        'url': null,
      });
      final set = await h.handle(
        'POST',
        u('/v1/webhook'),
        'Bearer tok',
        body: {'url': 'http://127.0.0.1:9911/hook'},
      );
      expect(set.status, 200);
      expect(hook, 'http://127.0.0.1:9911/hook');
      expect((await h.handle('GET', u('/v1/webhook'), 'Bearer tok')).body, {
        'url': 'http://127.0.0.1:9911/hook',
      });
      // A non-loopback target is refused and does not overwrite.
      final bad = await h.handle(
        'POST',
        u('/v1/webhook'),
        'Bearer tok',
        body: {'url': 'http://evil.example.com/x'},
      );
      expect(bad.status, 400);
      expect(hook, 'http://127.0.0.1:9911/hook');
      // DELETE clears.
      expect(
        (await h.handle('DELETE', u('/v1/webhook'), 'Bearer tok')).status,
        200,
      );
      expect(hook, isNull);
      // A read-only token can GET but neither POST nor DELETE (non-GET = write).
      hook = 'http://127.0.0.1:1/x';
      final ro = withHook(readOnly: true);
      expect(
        (await ro.handle('GET', u('/v1/webhook'), 'Bearer tok')).status,
        200,
      );
      expect(
        (await ro.handle(
          'POST',
          u('/v1/webhook'),
          'Bearer tok',
          body: {'url': 'http://127.0.0.1:2/y'},
        )).status,
        403,
      );
      expect(
        (await ro.handle('DELETE', u('/v1/webhook'), 'Bearer tok')).status,
        403,
      );
      expect(hook, 'http://127.0.0.1:1/x');
      // A host without the webhook wired (default fixture) 404s the route.
      expect(
        (await make().handle(
          'GET',
          u('/v1/webhook'),
          'Bearer secret-token',
        )).status,
        404,
      );
    },
  );

  test(
    'pushWebhookEvent POSTs the event JSON to a real loopback server',
    () async {
      final received = <(String?, String)>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        received.add((
          req.headers.value('X-XVeil-Event'),
          await utf8.decoder.bind(req).join(),
        ));
        req.response.statusCode = 200;
        await req.response.close();
      });
      addTearDown(() => server.close(force: true));
      final url = 'http://127.0.0.1:${server.port}/hook';
      final ok = await pushWebhookEvent(url, {
        'type': 'message',
        'from': 'aabb',
        'preview': 'hi',
        'isFile': false,
      });
      expect(ok, isTrue);
      expect(received, hasLength(1));
      expect(received.single.$1, 'message');
      expect(jsonDecode(received.single.$2), {
        'type': 'message',
        'from': 'aabb',
        'preview': 'hi',
        'isFile': false,
      });
      // An unreachable target reports failure (the caller's retry kicks in).
      await server.close(force: true);
      expect(
        await pushWebhookEvent(url, const {
          'type': 'message',
        }, timeout: const Duration(milliseconds: 500)),
        isFalse,
      );
    },
  );
}
