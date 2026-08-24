// Local automation API (REST API epic, brick 1): a small, OFF-BY-DEFAULT HTTP
// surface on 127.0.0.1 so a bot/script in any language can drive the app. This
// productizes the debug hook into a stable, authenticated `/v1` contract.
//
// Privacy canon: a permanently-open port is discoverable, so the server is off
// until the user turns it on; every request needs a bearer token (generated in
// the deniable store, revocable); the socket binds LOOPBACK ONLY — an external
// interface is a separate, deliberate opt-in (not this brick). Cleartext HTTP is
// allowed here precisely because it never leaves 127.0.0.1.
//
// The request handling ([ApiHandler]) is split from the socket ([ApiServer]) so
// auth + routing are unit-tested without binding a port.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

import '../domain/group_message.dart';
import '../domain/space_abuse_report.dart';
import '../domain/space_moderation.dart';
import '../domain/space_post.dart';

/// The loopback port the automation API binds when enabled. Distinct from the
/// debug hook (38765/38766).
const int kApiPort = 8787;

bool _validFeedCursor(String value) => SpaceFeedCursor.decode(value) != null;
bool _validPostId(String value) =>
    RegExp(r'^[0-9a-f]{64}:[0-9]+$').hasMatch(value);

List<MediaObject>? _spacePostMedia(Object? value, {bool optional = false}) {
  if (value == null) return optional ? null : const <MediaObject>[];
  if (value is! List || value.length > kSpacePostMediaMax) return null;
  final media = value
      .map(MediaObject.fromReferenceJson)
      .whereType<MediaObject>()
      .toList(growable: false);
  if (media.length != value.length ||
      media.map((item) => item.contentId).toSet().length != media.length) {
    return null;
  }
  return media;
}

/// Why [url] is unusable as a webhook target, or null if it is fine.
/// Privacy canon: cleartext HTTP must never leave the machine, so the target
/// host is restricted to loopback — a bot on the same host. (An external
/// interface would be a separate, deliberate opt-in with real transport
/// security, not this brick.)
String? webhookUrlError(String url) {
  final Uri u;
  try {
    u = Uri.parse(url);
  } catch (_) {
    return 'invalid url';
  }
  if (u.scheme != 'http' && u.scheme != 'https') {
    return 'http(s) only';
  }
  const loopback = {'127.0.0.1', 'localhost', '::1', '[::1]'};
  if (!loopback.contains(u.host)) {
    return 'loopback host only (privacy: cleartext must not leave 127.0.0.1)';
  }
  return null;
}

/// What a host's `/v1` surface can actually answer.
///
/// A published contract that does not match the server is worse than a smaller
/// one: anyone generating a client from `xveil print-openapi` builds against
/// endpoints that will never answer and finds out at runtime. So the document
/// is FILTERED by this — [openApiSpec] and `GET /v1/openapi.json` describe THE
/// HOST THEY RUN ON rather than the union of every host.
///
/// Every flag mirrors a refusal [ApiHandler.handle] already makes (501
/// "unavailable on this host"), and [ApiHandler.capabilities] derives its value
/// from the callbacks a host actually wired — there is no second place to
/// declare it. `test/headless_api_contract_test.dart` holds the two together by
/// PROBING the router for every operation the document claims, rather than
/// trusting either side's word for it.
class ApiCapabilities {
  const ApiCapabilities({
    this.account = true,
    this.accountInvite = true,
    this.accountLock = true,
    this.identitySwitch = true,
    this.cloud = true,
    this.contactRequests = true,
    this.contactActions = true,
    this.calls = true,
    this.groups = true,
    this.groupMedia = true,
    this.groupCalls = true,
    this.spaceVoiceSessions = true,
    this.spacePostComments = true,
    this.webhook = true,
  });

  /// The daemon (`xveil run`), and therefore what `xveil print-openapi`
  /// publishes. Each `false` here is a capability the daemon genuinely cannot
  /// have, not one nobody got round to wiring:
  ///
  /// - `cloud`: the cloud surface is `CloudService`, which imports
  ///   `package:flutter/foundation.dart` and `package:flutter_riverpod`. The
  ///   daemon is a Flutter-free AOT binary (`test/headless_is_flutter_free_test`
  ///   is the gate) — there is no cloud backend on this host to serve from.
  /// - `calls`/`groupCalls`/`spaceVoiceSessions`: no audio/video engine. The
  ///   handler already answers 501 for these; only the document lagged.
  /// - `accountLock`: locking means "close the store and come back with the
  ///   password". The daemon has no unlock route — locking it could only mean
  ///   terminating the process, which is the supervisor's job and a different
  ///   capability wearing the same name.
  /// - `identitySwitch`: one container, one password, opened at start. The
  ///   daemon's own `/v1/account` reports `isMaster:false` and no identities,
  ///   so there is nothing to switch to.
  ///
  /// Everything else the daemon serves for real, Space post comments included.
  static const headless = ApiCapabilities(
    accountLock: false,
    identitySwitch: false,
    cloud: false,
    calls: false,
    groupCalls: false,
    spaceVoiceSessions: false,
  );

  /// `/v1/account*` at all (the router refuses the whole prefix without it).
  final bool account;
  final bool accountInvite;
  final bool accountLock;
  final bool identitySwitch;
  final bool cloud;

  /// `POST /v1/contacts` — asking to be let in somewhere.
  final bool contactRequests;

  /// `/v1/contacts/accept` and `/v1/contacts/block`.
  final bool contactActions;
  final bool calls;

  /// The group/Space/feed core. Off takes `/v1/groups`, `/v1/spaces` and
  /// `/v1/feed` with it, exactly as the router's own gate does.
  final bool groups;
  final bool groupMedia;
  final bool groupCalls;
  final bool spaceVoiceSessions;
  final bool spacePostComments;
  final bool webhook;

  /// Whether this host answers [method] (upper-case) on [path] (`/v1/…`) at
  /// all. False means the router refuses it as unavailable, so the document
  /// must not describe it.
  ///
  /// Ordered exactly like the router's own gates, narrow prefixes first:
  /// `/v1/groups/calls` is refused by the call gate before the group gate ever
  /// looks at it, and a reordering here would publish a different contract from
  /// the one served.
  bool serves(String method, String path) {
    if (path.startsWith('/v1/account')) {
      if (!account) return false;
      if (path == '/v1/account/invite') return accountInvite;
      if (path == '/v1/account/lock') return accountLock;
      if (path == '/v1/account/identity') return identitySwitch;
      return true;
    }
    if (path.startsWith('/v1/cloud')) return cloud;
    if (path == '/v1/contacts') return method != 'POST' || contactRequests;
    if (path == '/v1/contacts/accept' || path == '/v1/contacts/block') {
      return contactActions;
    }
    if (path.startsWith('/v1/calls')) return calls;
    if (path.startsWith('/v1/groups/calls')) return groups && groupCalls;
    if (path.startsWith('/v1/groups/files')) return groups && groupMedia;
    if (path == '/v1/spaces/voice-sessions') {
      return groups && groupCalls && spaceVoiceSessions;
    }
    if (path == '/v1/spaces/posts/comments') return groups && spacePostComments;
    if (path.startsWith('/v1/groups') ||
        path.startsWith('/v1/spaces') ||
        path.startsWith('/v1/feed')) {
      return groups;
    }
    if (path == '/v1/webhook') return webhook;
    return true;
  }

  /// The flags that are off, by name — what a failing gate should print.
  List<String> get missing => [
    for (final entry in _byName.entries)
      if (!entry.value) entry.key,
  ];

  Map<String, bool> get _byName => {
    'account': account,
    'accountInvite': accountInvite,
    'accountLock': accountLock,
    'identitySwitch': identitySwitch,
    'cloud': cloud,
    'contactRequests': contactRequests,
    'contactActions': contactActions,
    'calls': calls,
    'groups': groups,
    'groupMedia': groupMedia,
    'groupCalls': groupCalls,
    'spaceVoiceSessions': spaceVoiceSessions,
    'spacePostComments': spacePostComments,
    'webhook': webhook,
  };

  @override
  bool operator ==(Object other) {
    if (other is! ApiCapabilities) return false;
    final mine = _byName;
    final theirs = other._byName;
    for (final key in mine.keys) {
      if (mine[key] != theirs[key]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(_byName.values);

  @override
  String toString() {
    final off = missing;
    return off.isEmpty
        ? 'ApiCapabilities(everything)'
        : 'ApiCapabilities(without ${off.join(", ")})';
  }
}

/// Which [ApiHandler] callbacks each optional capability owns, and which
/// booleans back the rest.
///
/// Data rather than prose because the gate reads it: a host that leaves a
/// callback out without turning its capability off is publishing a promise it
/// will not keep, and `test/headless_api_contract_test.dart` compares these
/// against the real constructor and the real headless wiring. A NEW optional
/// callback that headless does not wire belongs to no capability here, so the
/// gate fails until somebody decides which it is — wired, or declared absent.
const Map<String, List<String>> kApiCapabilityHandlers = {
  'account': ['account'],
  'accountInvite': ['accountInvite'],
  'accountLock': ['lockAccount'],
  'identitySwitch': ['switchIdentity'],
  'cloud': [
    'cloudItems',
    'cloudFolders',
    'cloudUsage',
    'cloudFile',
    'saveCloudNote',
    'deleteCloudItem',
  ],
  'contactRequests': ['requestContact'],
  'contactActions': ['contactAction'],
  'spaceVoiceSessions': ['startSpaceVoiceSession'],
  'spacePostComments': [
    'spacePostComments',
    'publishSpacePostComment',
    'editSpacePostComment',
    'deleteSpacePostComment',
  ],
  'webhook': ['webhook', 'setWebhook'],
};

/// The capabilities carried by a boolean rather than by the presence of a
/// callback. `groups` owns every nullable Space/group projection too: hosts
/// wire those as one block (`groupApi?.…`, `groupsAvailable: … != null`), so
/// the flag is the honest unit.
const Map<String, String> kApiCapabilityFlags = {
  'calls': 'callsAvailable',
  'groups': 'groupsAvailable',
  'groupMedia': 'groupMediaAvailable',
  'groupCalls': 'groupCallsAvailable',
};

/// The OpenAPI 3.0 contract for the implemented `/v1` surface, so a client can
/// be generated in any language (`openapi-generator -i .../v1/openapi.json`).
/// Hand-authored (small surface); kept in lockstep with [ApiHandler.handle].
/// The realtime `/v1/events` WebSocket is described in `info.description`
/// because OpenAPI 3.0 has no first-class WebSocket schema.
///
/// [capabilities] decides WHICH of it is published. The default is every
/// capability — the union, i.e. what a fully wired app host serves. A caller
/// that knows its host (the daemon, or [ApiHandler] answering
/// `/v1/openapi.json` about itself) passes its own, and the operations that
/// host would refuse are struck out rather than advertised.
Map<String, dynamic> openApiSpec({
  ApiCapabilities capabilities = const ApiCapabilities(),
}) {
  Map<String, dynamic> ok(Map<String, dynamic> schema) => {
    '200': {
      'description': 'OK',
      'content': {
        'application/json': {'schema': schema},
      },
    },
  };
  const obj = 'object';
  final mediaObjectSchema = <String, dynamic>{
    'type': obj,
    'required': ['cid', 'kind'],
    'properties': {
      'cid': {'type': 'string', 'pattern': r'^[0-9a-f]{64}$'},
      'kind': {'type': 'string', 'maxLength': 32},
      'name': {'type': 'string', 'maxLength': 255},
      'mime': {'type': 'string', 'maxLength': 128},
      'size': {'type': 'integer', 'format': 'int64', 'minimum': 1},
      'width': {'type': 'integer', 'minimum': 1},
      'height': {'type': 'integer', 'minimum': 1},
      'duration': {'type': 'integer', 'format': 'int64', 'minimum': 0},
    },
  };
  final spec = <String, dynamic>{
    'openapi': '3.0.3',
    'info': {
      'title': 'xVeil Automation API',
      'version': '1.0.0',
      'description':
          'Local, off-by-default, loopback-only API for bots/scripts. '
          'Every request needs `Authorization: Bearer <token>`. '
          'Realtime: connect a WebSocket to `/v1/events?token=<token>` to '
          'receive incoming-message events '
          '`{type:"message", from, preview, isFile}` — or register a '
          'loopback webhook (`POST /v1/webhook`) to have the same events '
          'POSTed to your local HTTP server. Group-call state changes use '
          '`{type:"group_call", call}`. '
          'A read-only token refuses every write (non-GET) with 403.',
    },
    'servers': [
      {'url': 'http://127.0.0.1:$kApiPort/v1'},
    ],
    'security': [
      {'bearerAuth': <dynamic>[]},
    ],
    'components': {
      'securitySchemes': {
        'bearerAuth': {'type': 'http', 'scheme': 'bearer'},
      },
      'schemas': {
        'Contact': {
          'type': obj,
          'properties': {
            'nodeId': {'type': 'string'},
            'short': {'type': 'string'},
            'name': {'type': 'string'},
            'status': {
              'type': 'string',
              'description':
                  'Pending requests are listed too — a client has no other way '
                  'to learn somebody asked to reach it.',
            },
            'canMessage': {'type': 'boolean'},
          },
        },
        'Message': {
          'type': obj,
          'description':
              'A file message carries `fileId`, `fileContentId`, or both. '
              'Pass `fileId ?? fileContentId` to GET /v1/files/download; when '
              '`fileDownloaded` is false, POST /v1/files/fetch first.',
          'properties': {
            'id': {'type': 'string'},
            'body': {'type': 'string'},
            'direction': {
              'type': 'string',
              'enum': ['incoming', 'outgoing'],
            },
            'sentAt': {'type': 'integer', 'format': 'int64'},
            'status': {'type': 'string'},
            'fileName': {'type': 'string'},
            'fileId': {
              'type': 'string',
              'description':
                  'Store key of a blob already held (small/inline file, or one '
                  'this node sent). Absent on a received large file until it '
                  'is fetched — use `fileContentId` there.',
            },
            'fileContentId': {
              'type': 'string',
              'description':
                  'Content hash of an OFFERED file — the handle to fetch and '
                  'then download it. Also the store key once fetched.',
            },
            'fileSize': {
              'type': 'integer',
              'format': 'int64',
              'description':
                  'Total bytes, known from the offer BEFORE any are '
                  'transferred, so a client can decide whether to fetch.',
            },
            'thumb': {
              'type': 'string',
              'description':
                  'base64 micro-thumbnail (PNG) of an image, carried in the '
                  'message itself. Present before the file is fetched.',
            },
            'fileDownloaded': {
              'type': 'boolean',
              'description':
                  'Present on file messages only. True when the blob is in '
                  'this node\'s store and GET /v1/files/download will serve '
                  'it; false when the file has only been offered.',
            },
          },
        },
        'Group': {
          'type': obj,
          'properties': {
            'groupId': {'type': 'string'},
            'name': {'type': 'string'},
            'unread': {'type': 'integer'},
            'postUnread': {'type': 'integer'},
            'muted': {'type': 'boolean'},
            'notificationMode': {
              'type': 'string',
              'enum': ['all', 'mentionsOnly', 'none'],
            },
            'notificationUntil': {
              'type': 'integer',
              'format': 'int64',
              'nullable': true,
            },
            'preview': {'type': 'string'},
            'lastTs': {'type': 'integer', 'format': 'int64'},
          },
        },
        'Space': {
          'type': obj,
          'properties': {
            'spaceId': {'type': 'string'},
            'name': {'type': 'string'},
            'description': {'type': 'string'},
            'visibility': {
              'type': 'string',
              'enum': ['public', 'private', 'secret'],
            },
            'discoverable': {'type': 'boolean'},
            'unread': {'type': 'integer'},
            'postUnread': {'type': 'integer'},
            'muted': {'type': 'boolean'},
            'notificationMode': {
              'type': 'string',
              'enum': ['all', 'mentionsOnly', 'none'],
            },
            'notificationUntil': {
              'type': 'integer',
              'format': 'int64',
              'nullable': true,
            },
            'preview': {'type': 'string'},
            'lastTs': {'type': 'integer', 'format': 'int64'},
          },
        },
        'PublicSpaceDiscovery': {
          'type': obj,
          'required': [
            'spaceId',
            'name',
            'description',
            'createdAt',
            'updatedAt',
            'revision',
            'authorityGeneration',
            'publicFeedRevision',
            'publicFeedUpdatedAt',
            'publicPostCount',
            'expiresAt',
            'joinCode',
            'independentHolders',
          ],
          'properties': {
            'spaceId': {'type': 'string', 'pattern': r'^[0-9a-f]{64}$'},
            'name': {'type': 'string', 'maxLength': 160},
            'description': {'type': 'string', 'maxLength': 4096},
            'avatarContentId': {'type': 'string', 'pattern': r'^[0-9a-f]{64}$'},
            'coverContentId': {'type': 'string', 'pattern': r'^[0-9a-f]{64}$'},
            'createdAt': {'type': 'integer', 'format': 'int64'},
            'updatedAt': {'type': 'integer', 'format': 'int64'},
            'revision': {'type': 'integer', 'minimum': 0},
            'authorityGeneration': {'type': 'integer', 'minimum': 0},
            'publicFeedRevision': {'type': 'integer', 'minimum': 0},
            'publicFeedUpdatedAt': {'type': 'integer', 'format': 'int64'},
            'publicPostCount': {'type': 'integer', 'minimum': 0},
            'expiresAt': {'type': 'integer', 'format': 'int64'},
            'joinCode': {'type': 'string'},
            'independentHolders': {'type': 'integer', 'minimum': 1},
          },
        },
        'PublicSpaceSubscription': {
          'type': obj,
          'required': [
            'spaceId',
            'name',
            'description',
            'verifiedAt',
            'stale',
            'authorityGeneration',
            'publicFeedRevision',
            'publicFeedUpdatedAt',
            'publicPostCount',
            'feedEnabled',
            'notificationsEnabled',
            'hiddenFromRecommendations',
            'updatedAt',
            'publicOnly',
          ],
          'properties': {
            'spaceId': {'type': 'string', 'pattern': r'^[0-9a-f]{64}$'},
            'name': {'type': 'string', 'maxLength': 160},
            'description': {'type': 'string', 'maxLength': 4096},
            'avatarContentId': {'type': 'string', 'pattern': r'^[0-9a-f]{64}$'},
            'coverContentId': {'type': 'string', 'pattern': r'^[0-9a-f]{64}$'},
            'verifiedAt': {'type': 'integer', 'format': 'int64'},
            'stale': {'type': 'boolean'},
            'authorityGeneration': {'type': 'integer', 'minimum': 0},
            'publicFeedRevision': {'type': 'integer', 'minimum': 0},
            'publicFeedUpdatedAt': {'type': 'integer', 'format': 'int64'},
            'publicPostCount': {'type': 'integer', 'minimum': 0},
            'feedEnabled': {'type': 'boolean'},
            'notificationsEnabled': {'type': 'boolean'},
            'hiddenFromRecommendations': {'type': 'boolean'},
            'updatedAt': {'type': 'integer', 'format': 'int64'},
            'publicOnly': {
              'type': 'boolean',
              'enum': [true],
            },
          },
        },
        'SpaceMembership': {
          'type': obj,
          'required': [
            'spaceId',
            'name',
            'visibility',
            'status',
            'source',
            'isMember',
            'canOpen',
            'changedAt',
          ],
          'properties': {
            'spaceId': {'type': 'string'},
            'name': {'type': 'string'},
            'visibility': {
              'type': 'string',
              'enum': ['public', 'private', 'secret'],
            },
            'status': {
              'type': 'string',
              'enum': ['pending', 'active', 'suspended', 'left', 'banned'],
            },
            'source': {
              'type': 'string',
              'enum': [
                'manifest',
                'controlLog',
                'moderation',
                'joinRequest',
                'invite',
              ],
            },
            'isMember': {'type': 'boolean'},
            'canOpen': {'type': 'boolean'},
            'changedAt': {'type': 'integer', 'format': 'int64'},
            'until': {'type': 'integer', 'format': 'int64'},
            'reason': {'type': 'string'},
            'sourceId': {'type': 'string'},
          },
        },
        'SpaceRulesVersion': {
          'type': obj,
          'required': [
            'version',
            'fullText',
            'summary',
            'author',
            'publishedAt',
            'effectiveAt',
          ],
          'properties': {
            'version': {'type': 'integer'},
            'fullText': {'type': 'string'},
            'summary': {'type': 'string'},
            'author': {'type': 'string'},
            'publishedAt': {'type': 'integer', 'format': 'int64'},
            'effectiveAt': {'type': 'integer', 'format': 'int64'},
            'previousVersion': {'type': 'integer'},
          },
        },
        'SpaceChannel': {
          'type': obj,
          'properties': {
            'spaceId': {'type': 'string'},
            'channelId': {'type': 'string'},
            'kind': {
              'type': 'string',
              'enum': ['text', 'voice', 'category'],
            },
            'name': {'type': 'string'},
            'description': {'type': 'string'},
            'categoryId': {'type': 'string'},
            'position': {'type': 'integer'},
            'default': {'type': 'boolean'},
            'archived': {'type': 'boolean'},
            'history': {
              'type': 'string',
              'enum': ['fromJoin', 'full', 'since'],
            },
            'historySince': {'type': 'integer', 'format': 'int64'},
            'access': {
              'type': 'string',
              // `secret` is a value of the domain enum but never a channel a
              // caller can create: the writer takes `restricted` and refuses
              // the rest, because nothing yet hides a channel's existence,
              // author, timing or size from a non-recipient. Advertising it
              // here would promise a channel this API cannot make.
              'enum': ['space', 'restricted'],
            },
          },
        },
        'MediaObject': mediaObjectSchema,
        'SpacePost': {
          'type': obj,
          'properties': {
            'postId': {'type': 'string'},
            'revisionId': {'type': 'string'},
            'spaceId': {'type': 'string'},
            'spaceName': {'type': 'string'},
            'author': {'type': 'string'},
            'type': {
              'type': 'string',
              'enum': [
                'post',
                'article',
                'video',
                'shortVideo',
                'audio',
                'voiceMessage',
              ],
            },
            'visibility': {
              'type': 'string',
              'enum': ['members', 'public'],
            },
            'title': {'type': 'string'},
            'body': {'type': 'string'},
            'publishedAt': {'type': 'integer', 'format': 'int64'},
            'updatedAt': {'type': 'integer', 'format': 'int64'},
            'edited': {'type': 'boolean'},
            'pinned': {'type': 'boolean'},
            'pinnedAt': {'type': 'integer', 'format': 'int64'},
            'reactions': {
              'type': obj,
              'additionalProperties': {
                'type': 'array',
                'items': {'type': 'string'},
              },
            },
            'cursor': {'type': 'string'},
            'media': {
              'type': 'array',
              'maxItems': kSpacePostMediaMax,
              'items': {r'$ref': '#/components/schemas/MediaObject'},
            },
          },
        },
        'ScheduledSpacePost': {
          'type': obj,
          'description':
              'Encrypted identity-local publication; not signed or replicated before its due time.',
          'required': [
            'id',
            'spaceId',
            'title',
            'body',
            'type',
            'queuedAt',
            'scheduledAt',
            'status',
          ],
          'properties': {
            'id': {'type': 'string'},
            'spaceId': {'type': 'string'},
            'title': {'type': 'string', 'maxLength': kSpacePostTitleMax},
            'body': {'type': 'string', 'maxLength': kSpacePostBodyMax},
            'type': {
              'type': 'string',
              'enum': [
                'post',
                'article',
                'video',
                'shortVideo',
                'audio',
                'voiceMessage',
              ],
            },
            'media': {
              'type': 'array',
              'maxItems': kSpacePostMediaMax,
              'items': {r'$ref': '#/components/schemas/MediaObject'},
            },
            'queuedAt': {'type': 'integer', 'format': 'int64'},
            'scheduledAt': {'type': 'integer', 'format': 'int64'},
            'status': {
              'type': 'string',
              'enum': ['pending', 'failed'],
            },
            'lastAttemptAt': {'type': 'integer', 'format': 'int64'},
          },
        },
        'GroupMessage': {
          'type': obj,
          'properties': {
            'id': {'type': 'string'},
            'channelId': {'type': 'string'},
            'postId': {'type': 'string'},
            'author': {'type': 'string'},
            'body': {'type': 'string'},
            'sentAt': {'type': 'integer', 'format': 'int64'},
            'edited': {'type': 'boolean'},
            'updatedAt': {'type': 'integer', 'format': 'int64'},
            'replyTo': {'type': 'string'},
            'media': {r'$ref': '#/components/schemas/MediaObject'},
            'attachment': {
              'type': obj,
              'description':
                  'Either `contentId` or `inline` is present, and each says '
                  'how to get the bytes: with a `contentId`, POST '
                  '/v1/groups/files/fetch then GET /v1/groups/files/download; '
                  'with `inline`, the bytes ride inside the signed message and '
                  'the download serves them straight away.',
              'properties': {
                'kind': {'type': 'string'},
                'width': {'type': 'integer'},
                'height': {'type': 'integer'},
                'name': {'type': 'string'},
                'contentId': {'type': 'string'},
                'inline': {'type': 'boolean'},
              },
            },
          },
        },
        'GroupMember': {
          'type': obj,
          'properties': {
            'nodeId': {'type': 'string'},
            'short': {'type': 'string'},
            'role': {
              'type': 'string',
              'enum': ['owner', 'admin', 'member'],
            },
            'muted': {'type': 'boolean'},
            'self': {'type': 'boolean'},
          },
        },
        'SpaceMember': {
          'type': obj,
          'properties': {
            'nodeId': {'type': 'string'},
            'short': {'type': 'string'},
            'role': {
              'type': 'string',
              'enum': ['owner', 'admin', 'member'],
            },
            'muted': {'type': 'boolean'},
            'self': {'type': 'boolean'},
          },
        },
        'GroupCallParticipant': {
          'type': obj,
          'properties': {
            'nodeId': {'type': 'string'},
            'self': {'type': 'boolean'},
            'audio': {'type': 'boolean'},
            'video': {'type': 'boolean'},
            'screen': {'type': 'boolean'},
          },
        },
        'GroupCall': {
          'type': obj,
          'properties': {
            'groupId': {'type': 'string'},
            'channelId': {'type': 'string', 'nullable': true},
            'callId': {'type': 'string'},
            'initiator': {'type': 'string'},
            'epoch': {'type': 'integer'},
            'status': {
              'type': 'string',
              'enum': ['ringing', 'connecting', 'active', 'ended'],
            },
            'media': {'type': obj},
            'participants': {
              'type': 'array',
              'items': {r'$ref': '#/components/schemas/GroupCallParticipant'},
            },
            'joined': {'type': 'boolean'},
            'micOn': {'type': 'boolean'},
            'cameraOn': {'type': 'boolean'},
            'screenOn': {'type': 'boolean'},
            'mediaAvailable': {'type': 'boolean'},
            'endReason': {'type': 'string', 'nullable': true},
          },
        },
      },
    },
    'paths': {
      // Served since the first brick, described since never: a client that
      // asked the host what it could do got an undocumented answer. It is in
      // the document now — and, because the host filters the document by its
      // own capabilities, this is also how a client learns what THIS host
      // dropped.
      '/openapi.json': {
        'get': {
          'summary': "This host's own OpenAPI document",
          'description':
              'The contract as THIS host serves it: operations the host '
              'cannot answer are absent rather than described and refused.',
          'responses': ok({'type': obj}),
        },
      },
      '/health': {
        'get': {
          'summary': 'Node / account status',
          'responses': ok({
            'type': obj,
            'properties': {
              'ok': {'type': 'boolean'},
              'nodeId': {'type': 'string'},
              'short': {'type': 'string'},
              'api': {'type': 'string'},
            },
          }),
        },
      },
      '/account': {
        'get': {
          'summary': 'Account, active identity and node status',
          'responses': ok({
            'type': obj,
            'properties': {
              'ok': {'type': 'boolean'},
              'phase': {'type': 'string'},
              'nodeId': {'type': 'string'},
              'short': {'type': 'string'},
              'isMaster': {'type': 'boolean'},
              'activeIdentity': {'type': 'string'},
              'identities': {
                'type': 'array',
                'items': {'type': 'string'},
              },
            },
          }),
        },
      },
      '/account/invite': {
        'get': {
          'summary':
              'This node\'s shareable bootstrap invite, so a person can add '
              'a running daemon as a contact',
          'responses': ok({
            'type': obj,
            'properties': {
              'invite': {'type': 'string'},
            },
          }),
        },
      },
      '/account/lock': {
        'post': {
          'summary':
              'Lock the account. The API stops with it, so expect this '
              'response and then no further answers.',
          'responses': ok({
            'type': obj,
            'properties': {
              'ok': {'type': 'boolean'},
              'locked': {'type': 'boolean'},
            },
          }),
        },
      },
      '/account/identity': {
        'post': {
          'summary': 'Switch the active identity of a master space',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['label'],
                  'properties': {
                    'label': {'type': 'string'},
                  },
                },
              },
            },
          },
          'responses': ok({
            'type': obj,
            'properties': {
              'ok': {'type': 'boolean'},
              'activeIdentity': {'type': 'string'},
            },
          }),
        },
      },
      '/cloud/items': {
        'get': {
          'summary': 'Personal-cloud index',
          'responses': ok({
            'type': obj,
            'properties': {
              'items': {
                'type': 'array',
                'items': {'type': obj},
              },
            },
          }),
        },
        'delete': {
          'summary': 'Delete one item by ?id=',
          'responses': ok({
            'type': obj,
            'properties': {
              'ok': {'type': 'boolean'},
            },
          }),
        },
      },
      '/cloud/folders': {
        'get': {
          'summary': 'Personal-cloud folders',
          'responses': ok({
            'type': obj,
            'properties': {
              'folders': {
                'type': 'array',
                'items': {'type': obj},
              },
            },
          }),
        },
      },
      '/cloud/usage': {
        'get': {
          'summary': 'What the cloud uses here, in total, and per device',
          'responses': ok({
            'type': obj,
            'properties': {
              'logicalItems': {'type': 'integer'},
              'logicalBytes': {'type': 'integer', 'format': 'int64'},
              'localItems': {'type': 'integer'},
              'localBytes': {'type': 'integer', 'format': 'int64'},
              'indexOnlyItems': {'type': 'integer'},
              'devices': {
                'type': 'array',
                'items': {'type': obj},
              },
            },
          }),
        },
      },
      '/cloud/file': {
        'get': {
          'summary':
              'Bytes of one item by ?id=, pulled from another device first '
              'when this one keeps only the index',
          'responses': {
            '200': {
              'description': 'OK',
              'content': {
                'application/octet-stream': {
                  'schema': {'type': 'string', 'format': 'binary'},
                },
              },
            },
          },
        },
      },
      '/cloud/notes': {
        'post': {
          'summary': 'Create or update a text note',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['title', 'body'],
                  'properties': {
                    'id': {'type': 'string'},
                    'title': {'type': 'string'},
                    'body': {'type': 'string'},
                    'folder': {'type': 'string'},
                  },
                },
              },
            },
          },
          'responses': ok({'type': obj}),
        },
      },
      '/contacts': {
        'get': {
          'summary': 'Accepted contacts',
          'responses': ok({
            'type': obj,
            'properties': {
              'contacts': {
                'type': 'array',
                'items': {r'$ref': '#/components/schemas/Contact'},
              },
            },
          }),
        },
        'post': {
          'summary': 'Send a contact request by node id or bootstrap invite',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['target'],
                  'properties': {
                    'target': {'type': 'string'},
                    'greeting': {'type': 'string'},
                  },
                },
              },
            },
          },
          'responses': ok({'type': obj}),
        },
      },
      '/contacts/accept': {
        'post': {
          'summary': 'Accept an incoming contact request',
          'responses': ok({'type': obj}),
        },
      },
      '/contacts/block': {
        'post': {
          'summary': 'Block or decline a contact',
          'responses': ok({'type': obj}),
        },
      },
      '/messages': {
        'get': {
          'summary': 'Recent messages of a conversation',
          'parameters': [
            {
              'name': 'peer',
              'in': 'query',
              'required': true,
              'schema': {'type': 'string'},
            },
            {
              'name': 'limit',
              'in': 'query',
              'schema': {'type': 'integer', 'default': 50},
            },
          ],
          'responses': ok({
            'type': obj,
            'properties': {
              'messages': {
                'type': 'array',
                'items': {r'$ref': '#/components/schemas/Message'},
              },
            },
          }),
        },
        'post': {
          'summary': 'Send a text message',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['to', 'body'],
                  'properties': {
                    'to': {'type': 'string'},
                    'body': {'type': 'string'},
                  },
                },
              },
            },
          },
          'responses': ok({
            'type': obj,
            'properties': {
              'ok': {'type': 'boolean'},
            },
          }),
        },
      },
      '/spaces': {
        'get': {
          'summary': 'Communities visible to the active identity',
          'responses': ok({
            'type': obj,
            'properties': {
              'spaces': {
                'type': 'array',
                'items': {r'$ref': '#/components/schemas/Space'},
              },
            },
          }),
        },
        'post': {
          'summary': 'Create a signed community owned by the active identity',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['name'],
                  'properties': {
                    'name': {'type': 'string', 'maxLength': 160},
                    'description': {'type': 'string', 'maxLength': 4096},
                    'visibility': {
                      'type': 'string',
                      'enum': ['public', 'private', 'secret'],
                      'default': 'private',
                    },
                  },
                },
              },
            },
          },
          'responses': ok({'type': obj}),
        },
      },
      '/spaces/memberships': {
        'get': {
          'summary':
              'Derived membership states from signed facts and durable proposals',
          'responses': ok({
            'type': obj,
            'properties': {
              'memberships': {
                'type': 'array',
                'items': {r'$ref': '#/components/schemas/SpaceMembership'},
              },
            },
          }),
        },
      },
      '/spaces/profile': {
        'get': {
          'summary': 'Current signed profile of one community',
          'parameters': [
            {
              'name': 'space',
              'in': 'query',
              'required': true,
              'schema': {'type': 'string'},
            },
          ],
          'responses': ok({r'$ref': '#/components/schemas/Space'}),
        },
        'post': {
          'summary': 'Update the signed community description',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['space', 'description'],
                  'properties': {
                    'space': {'type': 'string'},
                    'description': {'type': 'string', 'maxLength': 4096},
                  },
                },
              },
            },
          },
          'responses': ok({'type': obj}),
        },
      },
      '/spaces/lifecycle': {
        'get': {
          'summary': 'Read the owner-signed community lifecycle state',
          'parameters': [
            {
              'name': 'space',
              'in': 'query',
              'required': true,
              'schema': {'type': 'string'},
            },
          ],
          'responses': ok({'type': obj}),
        },
        'post': {
          'summary':
              'Archive, recoverably delete, or restore a community as its owner',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['space', 'action'],
                  'properties': {
                    'space': {'type': 'string'},
                    'action': {
                      'type': 'string',
                      'enum': ['archive', 'delete', 'restore'],
                    },
                  },
                },
              },
            },
          },
          'responses': ok({'type': obj}),
        },
      },
      '/spaces/retention': {
        'get': {
          'summary':
              'Read signed community/local retention or one visible channel',
          'parameters': [
            {
              'name': 'space',
              'in': 'query',
              'required': true,
              'schema': {'type': 'string'},
            },
            {
              'name': 'channel',
              'in': 'query',
              'required': false,
              'schema': {'type': 'string'},
            },
          ],
          'responses': ok({'type': obj}),
        },
        'post': {
          'summary': 'Set community, local-device or channel retention',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['space', 'scope'],
                  'properties': {
                    'space': {'type': 'string'},
                    'scope': {
                      'type': 'string',
                      'enum': ['community', 'device', 'channel'],
                    },
                    'channel': {'type': 'string'},
                    'inherit': {'type': 'boolean', 'default': false},
                    'mediaOnly': {'type': 'boolean', 'default': false},
                    'days': {
                      'type': 'integer',
                      'minimum': 1,
                      'maximum': 36500,
                      'nullable': true,
                    },
                  },
                },
              },
            },
          },
          'responses': ok({'type': obj}),
        },
      },
      '/spaces/rules': {
        'get': {
          'summary': 'Read current and historical signed community rules',
          'parameters': [
            {
              'name': 'space',
              'in': 'query',
              'required': true,
              'schema': {'type': 'string'},
            },
          ],
          'responses': ok({'type': obj}),
        },
        'post': {
          'summary': 'Publish the next immutable rules revision',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['space', 'fullText'],
                  'properties': {
                    'space': {'type': 'string'},
                    'fullText': {'type': 'string', 'maxLength': 65536},
                    'summary': {'type': 'string', 'maxLength': 4096},
                    'effectiveAt': {'type': 'integer', 'format': 'int64'},
                  },
                },
              },
            },
          },
          'responses': ok({'type': obj}),
        },
      },
      '/spaces/rules/accept': {
        'post': {
          'summary': 'Acknowledge the current rules as the active member',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['space'],
                  'properties': {
                    'space': {'type': 'string'},
                  },
                },
              },
            },
          },
          'responses': ok({'type': obj}),
        },
      },
      '/spaces/moderation': {
        'get': {
          'summary': 'Read the immutable signed community moderation audit',
          'parameters': [
            {
              'name': 'space',
              'in': 'query',
              'required': true,
              'schema': {'type': 'string'},
            },
          ],
          'responses': ok({'type': obj}),
        },
        'post': {
          'summary': 'Append a signed moderation action',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['space', 'kind', 'target', 'scope', 'reason'],
                  'properties': {
                    'space': {'type': 'string'},
                    'kind': {
                      'type': 'string',
                      'enum': [
                        'warning',
                        'deleteMessage',
                        'deletePost',
                        'restrictPublishing',
                        'restrictMessages',
                        'restrictVoice',
                        'mute',
                        'timeout',
                        'temporaryBan',
                        'permanentBan',
                      ],
                    },
                    'target': {'type': 'string'},
                    'scope': {
                      'type': 'string',
                      'enum': ['space', 'channel', 'posts', 'voice'],
                    },
                    'reason': {'type': 'string', 'maxLength': 4096},
                    'channelId': {'type': 'string'},
                    'expiresAt': {'type': 'integer', 'format': 'int64'},
                    'reference': {'type': obj},
                  },
                },
              },
            },
          },
          'responses': ok({'type': obj}),
        },
      },
      '/spaces/moderation/revoke': {
        'post': {
          'summary': 'Revoke a reversible signed moderation action',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['space', 'actionId', 'reason'],
                  'properties': {
                    'space': {'type': 'string'},
                    'actionId': {'type': 'string'},
                    'reason': {'type': 'string', 'maxLength': 4096},
                  },
                },
              },
            },
          },
          'responses': ok({'type': obj}),
        },
      },
      '/spaces/moderation/appeals': {
        'get': {
          'summary': 'List appealable actions and moderation appeal inboxes',
          'parameters': [
            {
              'name': 'space',
              'in': 'query',
              'required': false,
              'schema': {'type': 'string'},
            },
          ],
          'responses': ok({'type': obj}),
        },
        'post': {
          'summary': 'Submit or decide a signed moderation appeal',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['action'],
                  'properties': {
                    'action': {
                      'type': 'string',
                      'enum': ['appeal', 'reject', 'revoke', 'acknowledge'],
                    },
                    'space': {'type': 'string'},
                    'actionId': {'type': 'string'},
                    'appealId': {'type': 'string'},
                    'text': {'type': 'string', 'maxLength': 16384},
                    'reason': {'type': 'string', 'maxLength': 4096},
                  },
                },
              },
            },
          },
          'responses': ok({'type': obj}),
        },
      },
      '/spaces/moderation/reports': {
        'get': {
          'summary': 'List signed abuse report inboxes and outgoing statuses',
          'parameters': [
            {
              'name': 'space',
              'in': 'query',
              'required': false,
              'schema': {'type': 'string'},
            },
          ],
          'responses': ok({'type': obj}),
        },
        'post': {
          'summary': 'Submit or decide a signed Space abuse report',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['action'],
                  'properties': {
                    'action': {
                      'type': 'string',
                      'enum': ['report', 'dismiss', 'resolve', 'remove'],
                    },
                    'space': {'type': 'string'},
                    'postId': {'type': 'string'},
                    'commentId': {'type': 'string'},
                    'category': {
                      'type': 'string',
                      'enum': [
                        'spam',
                        'harassment',
                        'violence',
                        'sexualContent',
                        'illegalContent',
                        'misinformation',
                        'other',
                      ],
                    },
                    'details': {
                      'type': 'string',
                      'maxLength': kSpaceAbuseReportDetailsMaxBytes,
                    },
                    'reportId': {'type': 'string'},
                    'reason': {
                      'type': 'string',
                      'maxLength': kSpaceAbuseReportDecisionReasonMaxBytes,
                    },
                  },
                },
              },
            },
          },
          'responses': ok({'type': obj}),
        },
      },
      '/spaces/posts': {
        'get': {
          'summary': 'Chronological signed publication log of one community',
          'parameters': [
            {
              'name': 'space',
              'in': 'query',
              'required': true,
              'schema': {'type': 'string'},
            },
            {
              'name': 'before',
              'in': 'query',
              'schema': {'type': 'string'},
            },
            {
              'name': 'limit',
              'in': 'query',
              'schema': {'type': 'integer', 'minimum': 1, 'maximum': 200},
            },
          ],
          'responses': ok({
            'type': obj,
            'properties': {
              'posts': {
                'type': 'array',
                'items': {r'$ref': '#/components/schemas/SpacePost'},
              },
              'nextCursor': {'type': 'string'},
            },
          }),
        },
        'post': {
          'summary': 'Publish a separately signed Space post',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['space'],
                  'properties': {
                    'space': {'type': 'string'},
                    'title': {'type': 'string', 'maxLength': 300},
                    'body': {'type': 'string', 'maxLength': 262144},
                    'type': {
                      'type': 'string',
                      'enum': [
                        'post',
                        'article',
                        'video',
                        'shortVideo',
                        'audio',
                        'voiceMessage',
                      ],
                    },
                    'media': {
                      'type': 'array',
                      'maxItems': kSpacePostMediaMax,
                      'items': {r'$ref': '#/components/schemas/MediaObject'},
                    },
                  },
                },
              },
            },
          },
          'responses': ok({'type': obj}),
        },
        'patch': {
          'summary': 'Append an author-signed immutable post revision',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['space', 'postId'],
                  'properties': {
                    'space': {'type': 'string'},
                    'postId': {'type': 'string'},
                    'title': {'type': 'string', 'maxLength': 300},
                    'body': {'type': 'string', 'maxLength': 262144},
                    'type': {
                      'type': 'string',
                      'enum': [
                        'post',
                        'article',
                        'video',
                        'shortVideo',
                        'audio',
                        'voiceMessage',
                      ],
                    },
                    'media': {
                      'type': 'array',
                      'maxItems': kSpacePostMediaMax,
                      'items': {r'$ref': '#/components/schemas/MediaObject'},
                    },
                  },
                },
              },
            },
          },
          'responses': ok({'type': obj}),
        },
        'delete': {
          'summary': 'Append an irreversible author-signed post tombstone',
          'parameters': [
            {
              'name': 'space',
              'in': 'query',
              'required': true,
              'schema': {'type': 'string'},
            },
            {
              'name': 'postId',
              'in': 'query',
              'required': true,
              'schema': {'type': 'string'},
            },
          ],
          'responses': ok({'type': obj}),
        },
      },
      '/spaces/posts/draft': {
        'get': {
          'summary': 'Read the encrypted identity-local composer draft',
          'parameters': [
            {
              'name': 'space',
              'in': 'query',
              'required': true,
              'schema': {'type': 'string'},
            },
          ],
          'responses': ok({
            'type': obj,
            'properties': {
              'spaceId': {'type': 'string'},
              'draft': {
                'nullable': true,
                'type': obj,
                'properties': {
                  'v': {'type': 'integer'},
                  'sid': {'type': 'string'},
                  'title': {'type': 'string', 'maxLength': 300},
                  'body': {'type': 'string', 'maxLength': 262144},
                  'type': {
                    'type': 'string',
                    'enum': [
                      'post',
                      'article',
                      'video',
                      'shortVideo',
                      'audio',
                      'voiceMessage',
                    ],
                  },
                  'updatedAt': {'type': 'integer'},
                  'scheduledAt': {'type': 'integer', 'format': 'int64'},
                  'media': {
                    'type': 'array',
                    'maxItems': kSpacePostMediaMax,
                    'items': {r'$ref': '#/components/schemas/MediaObject'},
                  },
                },
              },
            },
          }),
        },
        'put': {
          'summary': 'Save or replace the encrypted identity-local draft',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['space'],
                  'properties': {
                    'space': {'type': 'string'},
                    'title': {'type': 'string', 'maxLength': 300},
                    'body': {'type': 'string', 'maxLength': 262144},
                    'type': {
                      'type': 'string',
                      'enum': [
                        'post',
                        'article',
                        'video',
                        'shortVideo',
                        'audio',
                        'voiceMessage',
                      ],
                    },
                    'media': {
                      'type': 'array',
                      'maxItems': kSpacePostMediaMax,
                      'items': {r'$ref': '#/components/schemas/MediaObject'},
                    },
                    'scheduledAt': {'type': 'integer', 'format': 'int64'},
                  },
                },
              },
            },
          },
          'responses': ok({'type': obj}),
        },
        'delete': {
          'summary': 'Delete the encrypted identity-local draft',
          'parameters': [
            {
              'name': 'space',
              'in': 'query',
              'required': true,
              'schema': {'type': 'string'},
            },
          ],
          'responses': ok({'type': obj}),
        },
      },
      '/spaces/posts/scheduled': {
        'get': {
          'summary': 'List encrypted identity-local scheduled publications',
          'parameters': [
            {
              'name': 'space',
              'in': 'query',
              'required': true,
              'schema': {'type': 'string'},
            },
          ],
          'responses': ok({
            'type': obj,
            'properties': {
              'scheduled': {
                'type': 'array',
                'items': {r'$ref': '#/components/schemas/ScheduledSpacePost'},
              },
            },
          }),
        },
        'post': {
          'summary':
              'Store a future publication encrypted locally without signing or replication',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['space', 'scheduledAt'],
                  'properties': {
                    'space': {'type': 'string'},
                    'title': {
                      'type': 'string',
                      'maxLength': kSpacePostTitleMax,
                    },
                    'body': {'type': 'string', 'maxLength': kSpacePostBodyMax},
                    'type': {
                      'type': 'string',
                      'enum': [
                        'post',
                        'article',
                        'video',
                        'shortVideo',
                        'audio',
                        'voiceMessage',
                      ],
                    },
                    'media': {
                      'type': 'array',
                      'maxItems': kSpacePostMediaMax,
                      'items': {r'$ref': '#/components/schemas/MediaObject'},
                    },
                    'scheduledAt': {'type': 'integer', 'format': 'int64'},
                  },
                },
              },
            },
          },
          'responses': {
            '201': {
              'description': 'Scheduled publication stored locally',
              'content': {
                'application/json': {
                  'schema': {
                    'type': obj,
                    'required': ['ok', 'scheduled'],
                    'properties': {
                      'ok': {'type': 'boolean'},
                      'scheduled': {
                        r'$ref': '#/components/schemas/ScheduledSpacePost',
                      },
                    },
                  },
                },
              },
            },
          },
        },
        'delete': {
          'summary': 'Cancel and remove one local scheduled publication',
          'parameters': [
            {
              'name': 'space',
              'in': 'query',
              'required': true,
              'schema': {'type': 'string'},
            },
            {
              'name': 'id',
              'in': 'query',
              'required': true,
              'schema': {'type': 'string'},
            },
          ],
          'responses': ok({'type': obj}),
        },
      },
      '/spaces/posts/scheduled/publish': {
        'post': {
          'summary': 'Revalidate and publish one scheduled publication now',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['space', 'id'],
                  'properties': {
                    'space': {'type': 'string'},
                    'id': {'type': 'string'},
                  },
                },
              },
            },
          },
          'responses': ok({'type': obj}),
        },
      },
      '/spaces/posts/comments': {
        'get': {
          'summary': 'List member-visible comments bound to one Space post',
          'parameters': [
            {
              'name': 'space',
              'in': 'query',
              'required': true,
              'schema': {'type': 'string'},
            },
            {
              'name': 'postId',
              'in': 'query',
              'required': true,
              'schema': {'type': 'string'},
            },
            {
              'name': 'limit',
              'in': 'query',
              'schema': {'type': 'integer', 'minimum': 1, 'maximum': 500},
            },
          ],
          'responses': ok({
            'type': obj,
            'properties': {
              'comments': {
                'type': 'array',
                'items': {r'$ref': '#/components/schemas/GroupMessage'},
              },
            },
          }),
        },
        'post': {
          'summary': 'Publish a signed, member-encrypted Space post comment',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['space', 'postId'],
                  'properties': {
                    'space': {'type': 'string'},
                    'postId': {'type': 'string'},
                    'body': {
                      'type': 'string',
                      'maxLength': kSpacePostCommentMaxBytes,
                    },
                    'replyTo': {'type': 'string'},
                    'media': {r'$ref': '#/components/schemas/MediaObject'},
                  },
                  'description':
                      'At least one of body or media must be present.',
                },
              },
            },
          },
          'responses': ok({'type': obj}),
        },
        'patch': {
          'summary':
              'Append an encrypted edit revision to an own Space post comment',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['space', 'postId', 'commentId', 'body'],
                  'properties': {
                    'space': {'type': 'string'},
                    'postId': {'type': 'string'},
                    'commentId': {'type': 'string'},
                    'body': {
                      'type': 'string',
                      'maxLength': kSpacePostCommentMaxBytes,
                    },
                  },
                },
              },
            },
          },
          'responses': ok({'type': obj}),
        },
        'delete': {
          'summary':
              'Append an encrypted tombstone for an own Space post comment',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['space', 'postId', 'commentId'],
                  'properties': {
                    'space': {'type': 'string'},
                    'postId': {'type': 'string'},
                    'commentId': {'type': 'string'},
                  },
                },
              },
            },
          },
          'responses': ok({'type': obj}),
        },
      },
      '/spaces/posts/reactions': {
        'post': {
          'summary': 'Toggle an encrypted reaction on a Space post',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['space', 'postId', 'emoji'],
                  'properties': {
                    'space': {'type': 'string'},
                    'postId': {'type': 'string'},
                    'emoji': {'type': 'string', 'maxLength': 64},
                  },
                },
              },
            },
          },
          'responses': ok({'type': obj}),
        },
      },
      '/spaces/posts/pin': {
        'post': {
          'summary': 'Append an admin-signed community post pin state',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['space', 'postId', 'pinned'],
                  'properties': {
                    'space': {'type': 'string'},
                    'postId': {'type': 'string'},
                    'pinned': {'type': 'boolean'},
                  },
                },
              },
            },
          },
          'responses': ok({'type': obj}),
        },
      },
      '/spaces/recommendations': {
        'get': {
          'summary': 'List signed community recommendation campaigns',
          'parameters': [
            {
              'name': 'space',
              'in': 'query',
              'required': true,
              'schema': {'type': 'string'},
            },
            {
              'name': 'includeRevoked',
              'in': 'query',
              'schema': {'type': 'boolean'},
            },
          ],
          'responses': ok({'type': obj}),
        },
        'post': {
          'summary': 'Create an admin-signed public recommendation campaign',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['space', 'text'],
                  'properties': {
                    'space': {'type': 'string'},
                    'text': {'type': 'string', 'maxLength': 1000},
                  },
                },
              },
            },
          },
          'responses': ok({'type': obj}),
        },
        'delete': {
          'summary': 'Revoke a signed recommendation campaign',
          'parameters': [
            {
              'name': 'space',
              'in': 'query',
              'required': true,
              'schema': {'type': 'string'},
            },
            {
              'name': 'campaignId',
              'in': 'query',
              'required': true,
              'schema': {'type': 'string'},
            },
          ],
          'responses': ok({'type': obj}),
        },
      },
      '/spaces/recommendations/share': {
        'post': {
          'summary': 'Explicitly share one campaign with one accepted contact',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['space', 'campaignId', 'recipient'],
                  'properties': {
                    'space': {'type': 'string'},
                    'campaignId': {'type': 'string'},
                    'recipient': {'type': 'string'},
                  },
                },
              },
            },
          },
          'responses': ok({'type': obj}),
        },
      },
      '/spaces/recommendations/policy': {
        'get': {
          'summary': 'Read the signed community recommendation policy',
          'parameters': [
            {
              'name': 'space',
              'in': 'query',
              'required': true,
              'schema': {'type': 'string'},
            },
          ],
          'responses': ok({'type': obj}),
        },
        'post': {
          'summary': 'Publish a signed community recommendation policy',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['space', 'expectedRevision', 'enabled'],
                  'properties': {
                    'space': {'type': 'string'},
                    'expectedRevision': {'type': 'integer', 'minimum': 0},
                    'enabled': {'type': 'boolean'},
                  },
                },
              },
            },
          },
          'responses': ok({'type': obj}),
        },
      },
      '/spaces/recommendations/shares': {
        'get': {
          'summary': 'List local sent-recommendation audit records',
          'parameters': [
            {
              'name': 'space',
              'in': 'query',
              'required': true,
              'schema': {'type': 'string'},
            },
          ],
          'responses': ok({'type': obj}),
        },
        'delete': {
          'summary': 'Durably revoke one already-sent recommendation',
          'parameters': [
            {
              'name': 'space',
              'in': 'query',
              'required': true,
              'schema': {'type': 'string'},
            },
            {
              'name': 'id',
              'in': 'query',
              'required': true,
              'schema': {'type': 'string', 'maxLength': 256},
            },
          ],
          'responses': ok({'type': obj}),
        },
      },
      '/spaces/observability': {
        'get': {
          'summary':
              'Read bounded runtime-only community counters, delivery timing '
              'exact missing-object totals, receipt latency and '
              'identifier-free estimated/confirmed replication aggregates',
          'responses': ok({'type': obj}),
        },
      },
      '/spaces/discovery': {
        'get': {
          'summary':
              'Search the verified public community index or resolve one exact '
              'community id',
          'parameters': [
            {
              'in': 'query',
              'name': 'query',
              'required': false,
              'schema': {'type': 'string', 'maxLength': 512},
              'description':
                  'Normalized client search; mutually exclusive with space',
            },
            {
              'in': 'query',
              'name': 'space',
              'required': false,
              'schema': {'type': 'string', 'pattern': r'^[0-9a-f]{64}$'},
              'description':
                  'Exact node id; mutually exclusive with query and requires '
                  'one verified holder',
            },
          ],
          'responses': ok({
            'oneOf': [
              {
                'type': obj,
                'required': ['status', 'results'],
                'properties': {
                  'status': {
                    'type': 'string',
                    'enum': ['available', 'partialQuorum', 'unavailable'],
                  },
                  'results': {
                    'type': 'array',
                    'items': {
                      r'$ref': '#/components/schemas/PublicSpaceDiscovery',
                    },
                  },
                },
              },
              {r'$ref': '#/components/schemas/PublicSpaceDiscovery'},
            ],
          }),
        },
      },
      '/spaces/public-subscriptions': {
        'get': {
          'summary': 'List verified device-local public-only subscriptions',
          'responses': ok({
            'type': 'array',
            'items': {r'$ref': '#/components/schemas/PublicSpaceSubscription'},
          }),
        },
        'post': {
          'summary':
              'Resolve an exact public community again and activate a '
              'read-only subscription',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['space'],
                  'additionalProperties': false,
                  'properties': {
                    'space': {'type': 'string', 'pattern': r'^[0-9a-f]{64}$'},
                  },
                },
              },
            },
          },
          'responses': ok({'type': obj}),
        },
        'delete': {
          'summary': 'Deactivate one device-local public-only subscription',
          'parameters': [
            {
              'in': 'query',
              'name': 'space',
              'required': true,
              'schema': {'type': 'string', 'pattern': r'^[0-9a-f]{64}$'},
            },
          ],
          'responses': ok({'type': obj}),
        },
      },
      '/spaces/subscription': {
        'get': {
          'summary': 'Read device-local community subscription preferences',
          'parameters': [
            {
              'in': 'query',
              'name': 'space',
              'required': true,
              'schema': {'type': 'string'},
            },
          ],
          'responses': ok({'type': obj}),
        },
        'post': {
          'summary': 'Update device-local community subscription preferences',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['space'],
                  'properties': {
                    'space': {'type': 'string'},
                    'feedEnabled': {'type': 'boolean'},
                    'notificationsEnabled': {'type': 'boolean'},
                    'commentNotifications': {
                      'type': 'string',
                      'enum': ['all', 'replies', 'none'],
                    },
                    'hiddenFromRecommendations': {'type': 'boolean'},
                  },
                },
              },
            },
          },
          'responses': ok({'type': obj}),
        },
      },
      '/feed/hidden': {
        'post': {
          'summary': 'Hide or restore one post in the local merged feed',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['space', 'postId', 'hidden'],
                  'properties': {
                    'space': {'type': 'string'},
                    'postId': {'type': 'string'},
                    'hidden': {'type': 'boolean'},
                  },
                },
              },
            },
          },
          'responses': ok({'type': obj}),
        },
      },
      '/feed/filter': {
        'get': {
          'summary': 'Read the local content-type filter for the merged feed',
          'responses': ok({
            'type': obj,
            'properties': {
              'types': {
                'type': 'array',
                'items': {'type': 'string'},
              },
            },
          }),
        },
        'post': {
          'summary': 'Set the local content-type filter for the merged feed',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['types'],
                  'properties': {
                    'types': {
                      'type': 'array',
                      'uniqueItems': true,
                      'items': {
                        'type': 'string',
                        'enum': [
                          'post',
                          'article',
                          'video',
                          'shortVideo',
                          'audio',
                          'voiceMessage',
                        ],
                      },
                    },
                  },
                },
              },
            },
          },
          'responses': ok({'type': obj}),
        },
      },
      '/feed': {
        'get': {
          'summary': 'Merged chronological feed of enabled communities',
          'parameters': [
            {
              'name': 'before',
              'in': 'query',
              'schema': {'type': 'string'},
            },
            {
              'name': 'limit',
              'in': 'query',
              'schema': {'type': 'integer', 'minimum': 1, 'maximum': 200},
            },
            {
              'name': 'pinned',
              'in': 'query',
              'schema': {'type': 'boolean'},
            },
          ],
          'responses': ok({
            'type': obj,
            'properties': {
              'posts': {
                'type': 'array',
                'items': {r'$ref': '#/components/schemas/SpacePost'},
              },
              'nextCursor': {'type': 'string'},
            },
          }),
        },
      },
      '/spaces/channels': {
        'get': {
          'summary': 'Signed child channels of one community',
          'parameters': [
            {
              'name': 'space',
              'in': 'query',
              'required': true,
              'schema': {'type': 'string'},
            },
          ],
          'responses': ok({
            'type': obj,
            'properties': {
              'channels': {
                'type': 'array',
                'items': {r'$ref': '#/components/schemas/SpaceChannel'},
              },
            },
          }),
        },
        'post': {
          'summary': 'Append a signed nested-channel control entry',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['space', 'name', 'kind'],
                  'properties': {
                    'space': {'type': 'string'},
                    'name': {'type': 'string', 'maxLength': 100},
                    'kind': {
                      'type': 'string',
                      'enum': ['text', 'voice', 'category'],
                    },
                    'categoryId': {'type': 'string'},
                    'position': {'type': 'integer'},
                    'history': {
                      'type': 'string',
                      'enum': ['fromJoin', 'full', 'since'],
                    },
                    'historySince': {'type': 'integer', 'format': 'int64'},
                    'access': {
                      'type': 'string',
                      'enum': ['space', 'restricted'],
                    },
                    'members': {
                      'type': 'array',
                      'items': {'type': 'string'},
                      'maxItems': 4096,
                    },
                  },
                },
              },
            },
          },
          'responses': ok({'type': obj}),
        },
        'patch': {
          'summary': 'Patch mutable signed channel properties',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['space', 'channel'],
                  'properties': {
                    'space': {'type': 'string'},
                    'channel': {'type': 'string'},
                    'name': {'type': 'string', 'maxLength': 100},
                    'description': {'type': 'string', 'maxLength': 1024},
                    'categoryId': {
                      'type': ['string', 'null'],
                      'description': 'Null moves the channel to the Space root',
                    },
                    'position': {'type': 'integer'},
                    'history': {
                      'type': 'string',
                      'enum': ['fromJoin', 'full', 'since'],
                    },
                    'historySince': {
                      'type': ['integer', 'null'],
                      'format': 'int64',
                    },
                  },
                },
              },
            },
          },
          'responses': ok({'type': obj}),
        },
      },
      '/spaces/members': {
        'get': {
          'summary': 'Validated roster and policy state of one community',
          'parameters': [
            {
              'name': 'space',
              'in': 'query',
              'required': true,
              'schema': {'type': 'string'},
            },
          ],
          'responses': ok({
            'type': obj,
            'properties': {
              'spaceId': {'type': 'string'},
              'name': {'type': 'string'},
              'epoch': {'type': 'integer'},
              'policyVersion': {'type': 'integer'},
              'selfRole': {
                'type': 'string',
                'enum': ['owner', 'admin', 'member'],
              },
              'members': {
                'type': 'array',
                'items': {r'$ref': '#/components/schemas/SpaceMember'},
              },
            },
          }),
        },
        'post': {
          'summary':
              'Invite contacts or manage existing members through the signed Space log',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['space', 'action', 'peer'],
                  'properties': {
                    'space': {'type': 'string'},
                    'action': {
                      'type': 'string',
                      'enum': [
                        'invite',
                        'remove',
                        'set_role',
                        'mute',
                        'unmute',
                        'transfer_owner',
                      ],
                    },
                    'peer': {'type': 'string'},
                    'role': {
                      'type': 'string',
                      'enum': ['admin', 'member'],
                    },
                  },
                },
              },
            },
          },
          'responses': ok({'type': obj}),
        },
      },
      '/spaces/access': {
        'get': {
          'summary':
              'Read signed scoped roles, participant groups and effective grants',
          'parameters': [
            {
              'name': 'space',
              'in': 'query',
              'required': true,
              'schema': {'type': 'string'},
            },
          ],
          'responses': ok({'type': obj}),
        },
        'post': {
          'summary':
              'Atomically edit the signed access policy at an expected revision; manageRoles delegates are limited to roles below their current capability ceiling',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['space', 'action', 'expectedRevision'],
                  'properties': {
                    'space': {'type': 'string'},
                    'action': {
                      'type': 'string',
                      'enum': [
                        'upsert_role',
                        'delete_role',
                        'upsert_group',
                        'delete_group',
                        'set_member_roles',
                      ],
                    },
                    'expectedRevision': {'type': 'integer', 'minimum': 0},
                    'roleId': {'type': 'string'},
                    'groupId': {'type': 'string'},
                    'peer': {'type': 'string'},
                    'name': {'type': 'string', 'maxLength': 80},
                    'permissions': {
                      'type': 'array',
                      'description':
                          'Legacy Space-wide allow list; use grants for scoped roles',
                      'uniqueItems': true,
                      'items': {
                        'type': 'string',
                        'enum': [
                          'view',
                          'distributeContent',
                          'publishMessages',
                          'publishPosts',
                          'managePosts',
                          'manageRecommendations',
                          'enterVoice',
                          'manageMembers',
                          'manageRoles',
                          'moderate',
                          'manageSettings',
                          'manageEncryption',
                          'manageStorage',
                          'manageChannels',
                        ],
                      },
                    },
                    'grants': {
                      'type': 'array',
                      'uniqueItems': true,
                      'items': {
                        'type': obj,
                        'required': ['permission', 'scope'],
                        'properties': {
                          'permission': {
                            'type': 'string',
                            'enum': [
                              'view',
                              'distributeContent',
                              'publishMessages',
                              'publishPosts',
                              'managePosts',
                              'manageRecommendations',
                              'enterVoice',
                              'manageMembers',
                              'manageRoles',
                              'moderate',
                              'manageSettings',
                              'manageEncryption',
                              'manageStorage',
                              'manageChannels',
                            ],
                          },
                          'scope': {
                            'type': obj,
                            'required': ['kind'],
                            'properties': {
                              'kind': {
                                'type': 'string',
                                'enum': [
                                  'space',
                                  'category',
                                  'channel',
                                  'posts',
                                  'moderation',
                                  'members',
                                  'roles',
                                  'settings',
                                  'encryption',
                                  'storage',
                                ],
                              },
                              'target': {'type': 'string'},
                            },
                          },
                        },
                      },
                    },
                    'members': {
                      'type': 'array',
                      'uniqueItems': true,
                      'items': {'type': 'string'},
                    },
                    'roles': {
                      'type': 'array',
                      'uniqueItems': true,
                      'items': {'type': 'string'},
                    },
                  },
                },
              },
            },
          },
          'responses': ok({'type': obj}),
        },
      },
      '/spaces/policies/audit': {
        'get': {
          'summary':
              'Read newest-first typed evidence for signed access and retention policy changes',
          'parameters': [
            {
              'name': 'space',
              'in': 'query',
              'required': true,
              'schema': {'type': 'string'},
            },
          ],
          'responses': ok({'type': obj}),
        },
      },
      '/spaces/invites': {
        'get': {
          'summary': 'Pending consent-first community invitations',
          'responses': ok({
            'type': 'array',
            'items': {'type': obj},
          }),
        },
        'post': {
          'summary': 'Explicitly accept or decline a community invitation',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['inviteId', 'action'],
                  'properties': {
                    'inviteId': {'type': 'string'},
                    'action': {
                      'type': 'string',
                      'enum': ['accept', 'decline'],
                    },
                  },
                },
              },
            },
          },
          'responses': ok({'type': obj}),
        },
      },
      '/spaces/join-requests': {
        'get': {
          'summary': 'List outgoing or Space-scoped public join requests',
          'parameters': [
            {
              'name': 'space',
              'in': 'query',
              'required': false,
              'schema': {'type': 'string'},
            },
          ],
          'responses': ok({'type': obj}),
        },
        'post': {
          'summary':
              'Request, approve, decline or manage a capability-bound Space join link',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['action'],
                  'properties': {
                    'action': {
                      'type': 'string',
                      'enum': [
                        'request',
                        'dismiss',
                        'approve',
                        'decline',
                        'create_link',
                        'revoke_link',
                      ],
                    },
                    'space': {'type': 'string'},
                    'requestId': {'type': 'string'},
                    'code': {'type': 'string', 'maxLength': 2048},
                  },
                },
              },
            },
          },
          'responses': ok({'type': obj}),
        },
      },
      '/spaces/name': {
        'post': {
          'summary': 'Rename a community through its signed control log',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['space', 'name'],
                  'properties': {
                    'space': {'type': 'string'},
                    'name': {'type': 'string', 'maxLength': 64},
                  },
                },
              },
            },
          },
          'responses': ok({'type': obj}),
        },
      },
      '/spaces/leave': {
        'post': {
          'summary': 'Leave a community as the active non-owner identity',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['space'],
                  'properties': {
                    'space': {'type': 'string'},
                  },
                },
              },
            },
          },
          'responses': ok({'type': obj}),
        },
      },
      '/spaces/channels/action': {
        'post': {
          'summary': 'Archive, restore or select a default nested channel',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['space', 'channel', 'action'],
                  'properties': {
                    'space': {'type': 'string'},
                    'channel': {'type': 'string'},
                    'action': {
                      'type': 'string',
                      'enum': ['archive', 'restore', 'default'],
                    },
                  },
                },
              },
            },
          },
          'responses': ok({'type': obj}),
        },
      },
      '/spaces/channels/members': {
        'post': {
          'summary': 'Rotate a protected channel ACL and epoch key',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['space', 'channel', 'members'],
                  'properties': {
                    'space': {'type': 'string'},
                    'channel': {'type': 'string'},
                    'members': {
                      'type': 'array',
                      'items': {'type': 'string'},
                      'maxItems': 4096,
                    },
                  },
                },
              },
            },
          },
          'responses': ok({'type': obj}),
        },
      },
      '/spaces/channels/messages': {
        'get': {
          'summary': 'Recent validated messages of one nested text channel',
          'parameters': [
            for (final name in ['space', 'channel'])
              {
                'name': name,
                'in': 'query',
                'required': true,
                'schema': {'type': 'string'},
              },
          ],
          'responses': ok({
            'type': obj,
            'properties': {
              'messages': {
                'type': 'array',
                'items': {r'$ref': '#/components/schemas/GroupMessage'},
              },
            },
          }),
        },
        'post': {
          'summary': 'Post a signed message to one nested text channel',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['space', 'channel', 'body'],
                  'properties': {
                    'space': {'type': 'string'},
                    'channel': {'type': 'string'},
                    'body': {'type': 'string', 'maxLength': 524288},
                    'replyTo': {'type': 'string'},
                  },
                },
              },
            },
          },
          'responses': ok({'type': obj}),
        },
      },
      '/groups': {
        'get': {
          'summary': 'User-visible groups for the active identity',
          'responses': ok({
            'type': obj,
            'properties': {
              'groups': {
                'type': 'array',
                'items': {r'$ref': '#/components/schemas/Group'},
              },
            },
          }),
        },
        'post': {
          'summary': 'Create an encrypted group owned by the active identity',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['name'],
                  'properties': {
                    'name': {'type': 'string', 'maxLength': 64},
                  },
                },
              },
            },
          },
          'responses': ok({
            'type': obj,
            'properties': {
              'ok': {'type': 'boolean'},
              'groupId': {'type': 'string'},
            },
          }),
        },
      },
      '/groups/messages': {
        'get': {
          'summary': 'Recent validated messages of one group',
          'parameters': [
            {
              'name': 'group',
              'in': 'query',
              'required': true,
              'schema': {'type': 'string'},
            },
            {
              'name': 'limit',
              'in': 'query',
              'schema': {'type': 'integer', 'default': 50},
            },
          ],
          'responses': ok({
            'type': obj,
            'properties': {
              'messages': {
                'type': 'array',
                'items': {r'$ref': '#/components/schemas/GroupMessage'},
              },
            },
          }),
        },
        'post': {
          'summary': 'Post a text message to a group',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['group', 'body'],
                  'properties': {
                    'group': {'type': 'string'},
                    'body': {'type': 'string', 'maxLength': 524288},
                    'replyTo': {'type': 'string'},
                  },
                },
              },
            },
          },
          'responses': ok({'type': obj}),
        },
      },
      '/groups/files': {
        'post': {
          'description':
              '`path` must resolve inside one of the folders granted to this '
              'token; otherwise the call is refused with 403.',
          'summary':
              'Post an any-size local file through the range-served group '
              'content path',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['group', 'path'],
                  'properties': {
                    'group': {'type': 'string'},
                    'path': {'type': 'string'},
                    'name': {'type': 'string', 'maxLength': 255},
                    'caption': {'type': 'string', 'maxLength': 524288},
                    'replyTo': {'type': 'string'},
                    // Say what the upload IS and the little a reader needs to
                    // lay it out. Omit them all and it posts as before.
                    'kind': {
                      'type': 'string',
                      'enum': ['file', 'image', 'video', 'voice', 'vnote'],
                    },
                    'width': {'type': 'integer', 'minimum': 1},
                    'height': {'type': 'integer', 'minimum': 1},
                    'durationMs': {'type': 'integer', 'minimum': 1},
                  },
                },
              },
            },
          },
          'responses': ok({
            'type': obj,
            'properties': {
              'ok': {'type': 'boolean'},
              'contentId': {'type': 'string'},
            },
          }),
        },
      },
      '/groups/files/fetch': {
        'post': {
          'summary':
              'Start a membership-authorized fetch for a group attachment',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['group', 'messageId'],
                  'properties': {
                    'group': {'type': 'string'},
                    'messageId': {'type': 'string'},
                  },
                },
              },
            },
          },
          'responses': ok({
            'type': obj,
            'properties': {
              'ok': {'type': 'boolean'},
              'started': {'type': 'boolean'},
            },
          }),
        },
      },
      '/groups/files/download': {
        'get': {
          'summary':
              'Read a downloaded group attachment after group/message validation',
          'parameters': [
            {
              'name': 'group',
              'in': 'query',
              'required': true,
              'schema': {'type': 'string'},
            },
            {
              'name': 'messageId',
              'in': 'query',
              'required': true,
              'schema': {'type': 'string'},
            },
          ],
          'responses': {
            '200': {
              'description': 'Attachment bytes',
              'content': {
                'application/octet-stream': {
                  'schema': {'type': 'string', 'format': 'binary'},
                },
              },
            },
            '404': {'description': 'Unknown group attachment'},
            '409': {'description': 'Attachment is not downloaded yet'},
          },
        },
      },
      '/groups/members': {
        'get': {
          'summary': 'Validated roster and policy state of one group',
          'parameters': [
            {
              'name': 'group',
              'in': 'query',
              'required': true,
              'schema': {'type': 'string'},
            },
          ],
          'responses': ok({
            'type': obj,
            'properties': {
              'groupId': {'type': 'string'},
              'name': {'type': 'string'},
              'epoch': {'type': 'integer'},
              'policyVersion': {'type': 'integer'},
              'selfRole': {
                'type': 'string',
                'enum': ['owner', 'admin', 'member'],
              },
              'members': {
                'type': 'array',
                'items': {r'$ref': '#/components/schemas/GroupMember'},
              },
            },
          }),
        },
        'post': {
          'summary':
              'Add/remove/moderate a member through the signed group log',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['group', 'action', 'peer'],
                  'properties': {
                    'group': {'type': 'string'},
                    'action': {
                      'type': 'string',
                      'enum': ['add', 'remove', 'set_role', 'mute', 'unmute'],
                    },
                    'peer': {'type': 'string'},
                    'role': {
                      'type': 'string',
                      'enum': ['admin', 'member'],
                    },
                  },
                },
              },
            },
          },
          'responses': ok({'type': obj}),
        },
      },
      '/groups/name': {
        'post': {
          'summary': 'Rename a group (admin or owner)',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['group', 'name'],
                  'properties': {
                    'group': {'type': 'string'},
                    'name': {'type': 'string', 'maxLength': 64},
                  },
                },
              },
            },
          },
          'responses': ok({'type': obj}),
        },
      },
      '/groups/leave': {
        'post': {
          'summary': 'Leave a group as the active non-owner identity',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['group'],
                  'properties': {
                    'group': {'type': 'string'},
                  },
                },
              },
            },
          },
          'responses': ok({'type': obj}),
        },
      },
      '/groups/calls': {
        'get': {
          'summary': 'Current or most recently ended group-call state',
          'responses': ok({
            'type': obj,
            'properties': {
              'call': {
                'allOf': [
                  {r'$ref': '#/components/schemas/GroupCall'},
                ],
                'nullable': true,
              },
            },
          }),
        },
        'post': {
          'summary': 'Start an encrypted group call',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['group'],
                  'properties': {
                    'group': {'type': 'string'},
                    'media': {
                      'type': 'string',
                      'enum': ['audio', 'video', 'screen'],
                      'default': 'audio',
                    },
                  },
                },
              },
            },
          },
          'responses': ok({'type': obj}),
        },
      },
      '/spaces/voice-sessions': {
        'post': {
          'summary':
              'Start an ephemeral voice session in a Space voice channel',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['space', 'channel'],
                  'properties': {
                    'space': {'type': 'string'},
                    'channel': {'type': 'string'},
                    'media': {
                      'type': 'string',
                      'enum': ['audio', 'video', 'screen'],
                      'default': 'audio',
                    },
                  },
                },
              },
            },
          },
          'responses': ok({'type': obj}),
        },
      },
      '/groups/calls/join': {
        'post': {
          'summary': 'Join the ringing group call',
          'responses': ok({'type': obj}),
        },
      },
      '/groups/calls/decline': {
        'post': {
          'summary': 'Decline the ringing group call locally',
          'responses': ok({'type': obj}),
        },
      },
      '/groups/calls/leave': {
        'post': {
          'summary': 'Leave the current group call',
          'responses': ok({'type': obj}),
        },
      },
      '/groups/calls/end': {
        'post': {
          'summary': 'End the current group call for everyone (admin)',
          'responses': ok({'type': obj}),
        },
      },
      '/groups/calls/posture': {
        'post': {
          'summary': 'Change local group-call microphone/camera/screen posture',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'properties': {
                    'mic': {'type': 'boolean'},
                    'camera': {'type': 'boolean'},
                    'screen': {'type': 'boolean'},
                  },
                },
              },
            },
          },
          'responses': ok({'type': obj}),
        },
      },
      '/files': {
        'post': {
          'summary':
              'Send a local file to a peer (streamed). `path` must resolve '
              'inside one of the folders granted to this token; otherwise the '
              'call is refused with 403 and nothing is read.',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['to', 'path'],
                  'properties': {
                    'to': {'type': 'string'},
                    'path': {'type': 'string'},
                    'name': {'type': 'string'},
                  },
                },
              },
            },
          },
          'responses': ok({
            'type': obj,
            'properties': {
              'ok': {'type': 'boolean'},
            },
          }),
        },
      },
      '/files/fetch': {
        'post': {
          'summary':
              'Start the opt-in download of a file OFFERED by a 1:1 message',
          'description':
              'A received large file arrives as an offer — name, size, content '
              'hash — and the bytes are only pulled when asked for. Identify '
              'it the way you identify a group attachment: by the conversation '
              'and the message, not by a bare content hash. Returns as soon as '
              'the fetch STARTS; poll GET /v1/files/download (or watch '
              '`fileDownloaded` on GET /v1/messages) for completion. Calling '
              'it for a file already held succeeds and does nothing. This does '
              'NOT need the local-file grant that POST /v1/files needs — '
              'nothing on the host\'s disk is read.',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['peer', 'messageId'],
                  'properties': {
                    'peer': {'type': 'string', 'pattern': r'^[0-9a-fA-F]{64}$'},
                    'messageId': {'type': 'string'},
                  },
                },
              },
            },
          },
          'responses': {
            '200': {
              'description': 'OK',
              'content': {
                'application/json': {
                  'schema': {
                    'type': obj,
                    'properties': {
                      'ok': {'type': 'boolean'},
                      'started': {'type': 'boolean'},
                    },
                  },
                },
              },
            },
            '404': {'description': 'No such message, or it carries no file'},
            '409': {'description': 'No source can serve the file right now'},
          },
        },
      },
      '/files/download': {
        'get': {
          'summary': 'Download a stored file blob by id',
          'parameters': [
            {
              'name': 'fileId',
              'in': 'query',
              'required': true,
              'description':
                  'The `fileId` or the `fileContentId` of a message — both are '
                  'store keys. A fetched file is stored under its content '
                  'hash, so `fileContentId` is what a received file uses.',
              'schema': {'type': 'string'},
            },
          ],
          'responses': {
            '200': {
              'description': 'File bytes',
              'content': {
                'application/octet-stream': {
                  'schema': {'type': 'string', 'format': 'binary'},
                },
              },
            },
            '404': {
              'description':
                  'Unknown file id, or the file has only been offered — POST '
                  '/v1/files/fetch and try again',
            },
          },
        },
      },
      '/calls': {
        'get': {
          'summary': 'Current call state (null when idle)',
          'responses': ok({
            'type': obj,
            'properties': {
              'call': {'type': obj, 'nullable': true},
            },
          }),
        },
        'post': {
          'summary': 'Place a call to a peer',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['to'],
                  'properties': {
                    'to': {'type': 'string'},
                    'media': {
                      'type': 'string',
                      'enum': ['audio', 'video', 'screen'],
                      'default': 'audio',
                    },
                  },
                },
              },
            },
          },
          'responses': ok({
            'type': obj,
            'properties': {
              'call': {'type': obj, 'nullable': true},
            },
          }),
        },
      },
      '/calls/hangup': {
        'post': {
          'summary': 'Hang up the current call',
          'responses': ok({'type': obj}),
        },
      },
      '/calls/accept': {
        'post': {
          'summary': 'Accept the incoming call',
          'responses': ok({'type': obj}),
        },
      },
      '/calls/reject': {
        'post': {
          'summary': 'Reject the incoming call',
          'responses': ok({'type': obj}),
        },
      },
      '/webhook': {
        'get': {
          'summary': 'The configured event webhook (null when none)',
          'responses': ok({
            'type': obj,
            'properties': {
              'url': {'type': 'string', 'nullable': true},
            },
          }),
        },
        'post': {
          'summary':
              'Set the event webhook — incoming events are POSTed to this '
              'LOOPBACK-ONLY url as {type,from,preview,isFile}',
          'requestBody': {
            'required': true,
            'content': {
              'application/json': {
                'schema': {
                  'type': obj,
                  'required': ['url'],
                  'properties': {
                    'url': {'type': 'string'},
                  },
                },
              },
            },
          },
          'responses': ok({
            'type': obj,
            'properties': {
              'ok': {'type': 'boolean'},
              'url': {'type': 'string'},
            },
          }),
        },
        'delete': {
          'summary': 'Clear the event webhook',
          'responses': ok({'type': obj}),
        },
      },
    },
  };
  _keepOnlyServed(spec, capabilities);
  return spec;
}

/// Strike out of [spec] every operation [capabilities] says this host refuses,
/// and drop a path once nothing is left of it.
///
/// Per OPERATION, not per path: `POST /v1/contacts` can be absent from a host
/// that still lists its contacts, and describing the path while dropping the
/// verb is the difference between a smaller contract and a wrong one.
void _keepOnlyServed(
  Map<String, dynamic> spec,
  ApiCapabilities capabilities,
) {
  const verbs = {
    'get',
    'put',
    'post',
    'delete',
    'patch',
    'head',
    'options',
    'trace',
  };
  final paths = spec['paths'] as Map<String, dynamic>;
  for (final key in paths.keys.toList()) {
    final operations = paths[key] as Map<String, dynamic>;
    for (final verb in operations.keys.toList()) {
      if (!verbs.contains(verb)) continue;
      if (!capabilities.serves(verb.toUpperCase(), '/v1$key')) {
        operations.remove(verb);
      }
    }
    if (!operations.keys.any(verbs.contains)) paths.remove(key);
  }
}

/// POST one JSON [event] to the webhook [url] (`X-XVeil-Event` carries the
/// event type). True = delivered (any non-5xx response); false = try again.
/// Top-level so the actual HTTP push is testable against a real loopback
/// server, not just mocked.
/// [client] lets a caller that delivers many events reuse one connection pool
/// instead of building one per attempt. It then owns the teardown too: this
/// function only force-closes a client it created itself. See [WebhookPump],
/// which holds the client precisely so that a retarget has something to pull
/// the plug on.
Future<bool> pushWebhookEvent(
  String url,
  Map<String, dynamic> event, {
  Duration timeout = const Duration(seconds: 5),
  HttpClient? client,
}) async {
  final http = client ?? (HttpClient()..connectionTimeout = timeout);
  try {
    // ONE deadline over the whole exchange, not just the headers.
    //
    // The timeout used to cover `req.close()` and stop there, leaving
    // `res.drain()` unbounded: a server that answered promptly and then
    // dribbled a body forever held this future, its socket and its buffers
    // open indefinitely, and the webhook target is a URL the operator
    // configures — not necessarily one that is behaving (audit XV-09).
    //
    // A forced close is what actually severs the socket when the deadline
    // fires; the timeout is what makes the deadline exist. For a borrowed
    // [client] that close is the caller's to make — the pump does it on the
    // failure path, so a dribbling target still costs one socket at most.
    return await () async {
      final req = await http.postUrl(Uri.parse(url));
      req.headers.contentType = ContentType.json;
      req.headers.set('X-XVeil-Event', event['type']?.toString() ?? 'event');
      req.write(jsonEncode(event));
      final res = await req.close();
      await res.drain<void>();
      return res.statusCode < 500; // delivered (or client error — don't retry)
    }().timeout(timeout);
  } catch (_) {
    return false;
  } finally {
    if (client == null) http.close(force: true);
  }
}

/// Persisted API state: whether the server runs, and the bearer token clients
/// must present. The token lives in the deniable store, never in plaintext prefs.
/// One issued bearer token — a per-app credential with its own scope, revocable
/// independently. [readOnly] refuses every write (POST) with 403 (a monitoring
/// bot observes without being able to act).
class ApiToken {
  const ApiToken({
    required this.id,
    required this.name,
    required this.token,
    required this.readOnly,
    this.fileRoots = const <String>[],
  });
  final String id; // short handle for revocation (not secret)
  final String name; // human label ("bot", "monitor", …)
  final String token; // the secret bearer value
  final bool readOnly;

  /// Directories `POST /v1/files` may send a local file OUT of (audit XV-08).
  ///
  /// The write scope was one bit — [readOnly] — and `POST /v1/files` takes a
  /// PATH, so every token that could write could also hand any OS-readable
  /// file to any peer: keys, other apps' databases, the deniable container
  /// itself. Authentication was never the hole; one capability simply carried
  /// far more than sending a message needs.
  ///
  /// Empty is DENY, not "unrestricted" — an unrestricted state is deliberately
  /// unrepresentable here, so the hole cannot come back as a default. That
  /// also makes the absent-key case (every token issued before this field
  /// existed) fail closed on its own, with no migration step that could be
  /// skipped. See [resolveSendableFile] for what "inside a root" means.
  final List<String> fileRoots;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'token': token,
    'ro': readOnly,
    // Absent and empty mean the same thing (no local-file capability), so the
    // record of a token without roots stays byte-identical to what earlier
    // builds wrote.
    if (fileRoots.isNotEmpty) 'fr': fileRoots,
  };

  static ApiToken? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], name = j['name'], token = j['token'];
    if (id is! String || name is! String || token is! String) return null;
    final roots = j['fr'];
    return ApiToken(
      id: id,
      name: name,
      token: token,
      readOnly: j['ro'] == true,
      fileRoots: roots is! List
          ? const <String>[]
          : <String>[
              for (final root in roots)
                if (root is String && root.isNotEmpty) root,
            ],
    );
  }

  ApiToken withFileRoots(List<String> roots) => ApiToken(
    id: id,
    name: name,
    token: token,
    readOnly: readOnly,
    fileRoots: List<String>.unmodifiable(roots),
  );
}

/// The absolute, symlink-free path to send, or null if [path] is not something
/// a token holding [roots] is allowed to name.
///
/// ONE answer for every refusal — outside a root, missing, a directory, a
/// device node, a component we may not traverse. Distinguishing them would
/// leave the caller a filesystem-existence oracle: the same capability this is
/// removing, metered at one bit per request instead of whole files. (The
/// caller does report "no roots granted" separately, because that answer does
/// not depend on the path and an operator has to be able to see it.)
///
/// Symlinks are resolved BEFORE the comparison, so a link parked inside an
/// allowed folder cannot aim out of it, and the RESOLVED path is what comes
/// back — one fewer name to re-walk, and one fewer chance for a swapped
/// component downstream.
///
/// WHAT THIS DOES NOT DO, and the comment here used to claim it did: hand the
/// caller the bytes it checked. What comes back is a NAME. Every later open of
/// that name is a fresh lookup, and between the check and the open the name can
/// be pointed at something else — a `rename` of a directory component defeats
/// the resolution above without touching anything inside the root. Dart has no
/// `openat`, no `O_NOFOLLOW` and no `fstat`, so from here a path cannot be
/// bound to the inode it named a moment ago (audit X-02).
///
/// What narrows it is [veilOpenPinnedSource], which the senders open through:
/// it stamps the name's `(deviceId, inode)` immediately before and immediately
/// after the open and REFUSES on a change, before anything is offered. This
/// paragraph used to say the substitution was caught "by hashing", which named
/// the wrong mechanism — the manifest hash is taken over whatever was read, so
/// it agrees with itself no matter which file that was. The evidence is the
/// stamp, and until audit X-01 the first one was taken after the open, which
/// is to say after the moment it was meant to bracket.
///
/// So this is an AUTHORIZATION check — may this token name this file — and not
/// a handle. Read it as such.
Future<String?> resolveSendableFile(String path, List<String> roots) async {
  if (roots.isEmpty) return null;
  final String resolved;
  try {
    resolved = await File(path).resolveSymbolicLinks();
  } catch (_) {
    return null; // missing, or a directory we may not walk
  }
  // A regular file, checked on the resolved path. A FIFO inside an allowed
  // folder would otherwise park the send forever on a read that never returns,
  // and a device node would stream without end.
  if (await FileSystemEntity.type(resolved, followLinks: false) !=
      FileSystemEntityType.file) {
    return null;
  }
  for (final root in roots) {
    final String base;
    try {
      base = await Directory(root).resolveSymbolicLinks();
    } catch (_) {
      continue; // a root that no longer resolves grants nothing
    }
    if (_isInsideRoot(resolved, base)) return resolved;
  }
  return null;
}

/// Containment by path COMPONENT, never by string prefix: `/home/bot-data`
/// starts with `/home/bot` and is a different directory.
bool _isInsideRoot(String resolved, String root) {
  final sep = Platform.pathSeparator;
  var base = root;
  while (base.length > sep.length && base.endsWith(sep)) {
    base = base.substring(0, base.length - sep.length);
  }
  // Both sides came out of realpath, so the only normalisation left is case:
  // Windows resolves `C:\Users` and `c:\users` to the same directory.
  final a = Platform.isWindows ? resolved.toLowerCase() : resolved;
  final b = Platform.isWindows ? base.toLowerCase() : base;
  if (a == b) return false; // the root itself is a directory, not a file
  return a.startsWith(b.endsWith(sep) ? b : '$b$sep');
}

class ApiConfig {
  const ApiConfig({
    required this.enabled,
    this.tokens = const [],
    this.webhookUrl,
  });
  final bool enabled;

  /// The issued tokens (any of which authenticates; its own scope applies).
  final List<ApiToken> tokens;

  /// Where incoming events are POSTed (loopback-only), or null = no webhook.
  final String? webhookUrl;

  ApiConfig copyWith({bool? enabled, List<ApiToken>? tokens}) => ApiConfig(
    enabled: enabled ?? this.enabled,
    tokens: tokens ?? this.tokens,
    webhookUrl: webhookUrl,
  );

  /// [copyWith] can't clear a nullable field — this can.
  ApiConfig withWebhook(String? url) =>
      ApiConfig(enabled: enabled, tokens: tokens, webhookUrl: url);

  static const empty = ApiConfig(enabled: false);
}

/// An API response: either a JSON [body] or raw [bytes] (a file download).
/// Largest payload a whole-in-RAM [ApiResponse.binary] may carry.
///
/// Byte-array responses hold the blob in memory at least twice — once in the
/// handler's result and again in the socket's write queue — so an "any size"
/// byte path is an availability hole that needs no attacker: one ordinary
/// large file downloaded over a read-only token is enough. Anything that can
/// exceed this must be served through [ApiResponse.blob], which streams.
const int kMaxInlineBinaryResponseBytes = 8 * 1024 * 1024;

/// A blob the API can serve WITHOUT ever holding it whole in RAM.
///
/// [read] is a range reader — the same primitive the storage layer already
/// exposes as `readFileRange` — so the HTTP layer can walk the blob in bounded
/// chunks and honour a `Range` request instead of materialising the file to
/// answer one. [size] is the full length of the blob, independent of any range
/// actually requested.
class ApiBlobSource {
  const ApiBlobSource({
    required this.size,
    required this.read,
    this.contentType = 'application/octet-stream',
  });

  final int size;

  /// Reads at most [length] bytes at [offset]. Null means the blob became
  /// unreadable mid-stream (deleted, or a needed record is missing); the
  /// writer aborts rather than padding the response with zeros.
  final Future<Uint8List?> Function(int offset, int length) read;

  final String contentType;
}

/// Bytes the API reads per hop when streaming a [ApiBlobSource]. Bounds the
/// peak: one chunk in flight, not one file.
const int kBlobStreamChunkBytes = 64 * 1024;

/// A blob transfer abandoned because the socket stopped draining.
class _BlobWriteStalled implements Exception {
  const _BlobWriteStalled();
  @override
  String toString() => 'blob write stalled: the client stopped reading';
}

/// Raised when a blob stops being readable partway through a walk — deleted
/// under us, or a needed record is missing.
class BlobUnreadable implements Exception {
  const BlobUnreadable(this.offset);
  final int offset;
  @override
  String toString() => 'blob became unreadable at offset $offset';
}

/// Walk [total] bytes of [source] starting at [start], in hops of at most
/// [kBlobStreamChunkBytes].
///
/// The single place that knows how to traverse a blob, so both the socket
/// writer and [drainBlobSource] inherit the same two guarantees instead of
/// each re-deriving them: no hop exceeds the chunk bound, and the walk yields
/// EXACTLY [total] bytes even if a reader hands back more than it was asked
/// for. Overshooting matters because the writer has already promised a
/// `Content-Length`.
///
/// Throws [BlobUnreadable] rather than ending short: a caller must never be
/// able to mistake a truncated blob for a complete one.
Stream<Uint8List> blobChunks(ApiBlobSource source, int start, int total) async* {
  var sent = 0;
  while (sent < total) {
    final want = total - sent;
    // Clamped against the HOP's cap, not against `want` — see the twin in
    // `rangeChunks` for why that difference is the whole guarantee
    // (report9 X-06).
    final cap = want < kBlobStreamChunkBytes ? want : kBlobStreamChunkBytes;
    final chunk = await source.read(start + sent, cap);
    if (chunk == null || chunk.isEmpty) throw BlobUnreadable(start + sent);
    final take = chunk.length > cap
        ? Uint8List.sublistView(chunk, 0, cap)
        : chunk;
    yield take;
    sent += take.length;
  }
}

/// One resolved byte range, inclusive at both ends, or the "cannot satisfy"
/// verdict that must become a 416.
class ParsedByteRange {
  const ParsedByteRange(this.start, this.endInclusive) : unsatisfiable = false;
  const ParsedByteRange.unsatisfiable()
    : start = 0,
      endInclusive = -1,
      unsatisfiable = true;

  final int start;
  final int endInclusive;
  final bool unsatisfiable;

  int get length => endInclusive - start + 1;
}

/// Parse an HTTP `Range` header against a blob of [size] bytes (RFC 7233,
/// single-range subset — what a video seek actually sends).
///
/// Null means "serve the whole blob": the header is absent, uses a unit we do
/// not speak, asks for multiple ranges, or is malformed. Ignoring a range we
/// do not understand is allowed and is the safe direction — the client gets
/// more bytes than it asked for, never the wrong ones. A well-formed range
/// that falls outside the blob is NOT ignored: it returns
/// [ParsedByteRange.unsatisfiable] so the caller answers 416 instead of
/// quietly sending something else.
///
/// Pure so the whole matrix is testable without a socket.
ParsedByteRange? parseByteRange(String? header, int size) {
  if (header == null) return null;
  final raw = header.trim();
  if (!raw.startsWith('bytes=')) return null;
  final spec = raw.substring('bytes='.length).trim();
  // Multi-range would need a multipart/byteranges body; we serve one range or
  // the whole thing.
  if (spec.isEmpty || spec.contains(',')) return null;
  final dash = spec.indexOf('-');
  if (dash < 0) return null;
  final startText = spec.substring(0, dash).trim();
  final endText = spec.substring(dash + 1).trim();

  if (startText.isEmpty) {
    // Suffix form `-N`: the last N bytes.
    final n = int.tryParse(endText);
    if (n == null || n <= 0) return null;
    if (size <= 0) return const ParsedByteRange.unsatisfiable();
    final start = n >= size ? 0 : size - n;
    return ParsedByteRange(start, size - 1);
  }

  final start = int.tryParse(startText);
  if (start == null || start < 0) return null;
  // An empty size cannot satisfy any explicit start, including 0.
  if (size <= 0 || start > size - 1) return const ParsedByteRange.unsatisfiable();

  if (endText.isEmpty) return ParsedByteRange(start, size - 1);
  final end = int.tryParse(endText);
  if (end == null || end < 0) return null;
  if (end < start) return const ParsedByteRange.unsatisfiable();
  return ParsedByteRange(start, end > size - 1 ? size - 1 : end);
}

class ApiResponse {
  const ApiResponse(this.status, [this.body])
    : bytes = null,
      contentType = null,
      blob = null;

  /// Whole-in-RAM response. Only for payloads bounded well under
  /// [kMaxInlineBinaryResponseBytes] — use [ApiResponse.blob] otherwise.
  const ApiResponse.binary(
    this.bytes, {
    this.contentType = 'application/octet-stream',
  }) : status = 200,
       body = null,
       blob = null;

  /// Streamed response backed by a range reader. The bytes never exist whole
  /// in this process.
  ///
  /// [contentType] mirrors the source's so every response answers the question
  /// the same way, whether it streams or not — a caller should not have to
  /// know which kind it holds to learn what it is carrying.
  ApiResponse.blob(ApiBlobSource source)
    : status = 200,
      body = null,
      bytes = null,
      contentType = source.contentType,
      blob = source;

  final int status;
  final Object? body;
  final List<int>? bytes;
  final String? contentType;
  final ApiBlobSource? blob;
}

/// Pure request router — no socket, so tests exercise auth + endpoints directly.
class ApiHandler {
  ApiHandler({
    required this.tokens,
    required this.status,
    required this.contacts,
    this.requestContact,
    this.contactAction,
    required this.send,
    required this.messages,
    required this.sendFile,
    required this.fetchFile,
    required this.loadFile,
    required this.placeCall,
    required this.callState,
    required this.callAction,
    this.callsAvailable = true,
    required this.groups,
    this.spaces,
    this.spaceMemberships,
    required this.createGroup,
    this.createSpace,
    required this.groupMessages,
    required this.sendGroupMessage,
    required this.sendGroupFile,
    required this.fetchGroupFile,
    required this.loadGroupFile,
    required this.groupMembers,
    required this.groupMemberAction,
    this.spaceAccess,
    this.spaceAccessAction,
    this.spacePolicyAudit,
    this.spaceObservability,
    required this.renameGroup,
    required this.leaveGroup,
    this.spaceChannels,
    this.spacePosts,
    this.spacePostDraft,
    this.saveSpacePostDraft,
    this.clearSpacePostDraft,
    this.spaceScheduledPosts,
    this.scheduleSpacePost,
    this.cancelScheduledSpacePost,
    this.publishScheduledSpacePostNow,
    this.spacePostComments,
    this.publishSpacePostComment,
    this.editSpacePostComment,
    this.deleteSpacePostComment,
    this.publishSpacePost,
    this.editSpacePost,
    this.deleteSpacePost,
    this.setSpacePostPinned,
    this.reactToSpacePost,
    this.spaceRecommendationCampaigns,
    this.createSpaceRecommendationCampaign,
    this.revokeSpaceRecommendationCampaign,
    this.shareSpaceRecommendation,
    this.spaceRecommendationPolicy,
    this.setSpaceRecommendationPolicy,
    this.spaceRecommendationShares,
    this.revokeSpaceRecommendationShare,
    this.spaceFeed,
    this.spaceFeedTypeFilter,
    this.setSpaceFeedTypeFilter,
    this.publicSpaceDiscoverySearch,
    this.publicSpaceDiscoveryResolve,
    this.publicSpaceSubscriptions,
    this.subscribePublicSpace,
    this.unsubscribePublicSpace,
    this.spaceSubscription,
    this.updateSpaceSubscription,
    this.setSpaceFeedPostHidden,
    this.spaceInvites,
    this.decideSpaceInvite,
    this.spaceJoinRequests,
    this.spaceJoinRequestAction,
    this.spaceProfile,
    this.updateSpaceDescription,
    this.spaceLifecycle,
    this.setSpaceLifecycle,
    this.spaceRetention,
    this.setSpaceRetention,
    this.spaceChannelRetention,
    this.setSpaceChannelRetention,
    this.spaceRules,
    this.publishSpaceRules,
    this.acceptSpaceRules,
    this.spaceModerationAudit,
    this.moderateSpace,
    this.revokeSpaceModeration,
    this.spaceModerationAppeals,
    this.spaceModerationAppealAction,
    this.spaceAbuseReports,
    this.spaceAbuseReportAction,
    this.createSpaceChannel,
    this.updateSpaceChannel,
    this.spaceChannelAction,
    this.setSpaceChannelMembers,
    this.spaceChannelMessages,
    this.sendSpaceChannelMessage,
    this.groupsAvailable = true,
    this.groupMediaAvailable = true,
    required this.startGroupCall,
    this.startSpaceVoiceSession,
    required this.groupCallState,
    required this.groupCallAction,
    required this.groupCallPosture,
    this.groupCallsAvailable = true,
    this.webhook,
    this.setWebhook,
    this.account,
    this.accountInvite,
    this.lockAccount,
    this.switchIdentity,
    this.cloudItems,
    this.cloudFolders,
    this.cloudUsage,
    this.cloudFile,
    this.saveCloudNote,
    this.deleteCloudItem,
  });

  /// The issued tokens; the presented bearer must match one (whose scope then
  /// applies). Empty = reject everything (API not provisioned).
  final List<ApiToken> tokens;

  /// Node/account status for `GET /v1/health`.
  final Map<String, dynamic> Function() status;

  /// Accepted contacts for `GET /v1/contacts`.
  final Future<List<Map<String, dynamic>>> Function() contacts;

  /// Send a request to a node-id or bootstrap invite; null means success.
  final Future<String?> Function(String target, String greeting)?
  requestContact;

  /// Apply `accept` or `block` to a peer node id; null means success.
  final Future<String?> Function(String peer, String action)? contactAction;

  /// Send a text message to [toHex]; returns null on success or an error string.
  final Future<String?> Function(String toHex, String body) send;

  /// The most-recent [limit] messages of the conversation with [peerHex].
  final Future<List<Map<String, dynamic>>> Function(String peerHex, int limit)
  messages;

  /// Send the file at local [path] to [toHex]; null on success else an error.
  ///
  /// [roots] are the token's granted folders — the grant this send is made
  /// under. They travel with the durable offer so that a reopen hours later can
  /// ask whether the grant still holds, rather than assume the record's
  /// existence is its own authorization.
  final Future<String?> Function(
    String toHex,
    String path,
    String? name,
    List<String> roots,
  )
  sendFile;

  /// Start the opt-in download of the file OFFERED by [messageId] in the
  /// conversation with [peerHex]; null once a fetch is under way (or the bytes
  /// were already held), else an error string.
  ///
  /// The 1:1 twin of [fetchGroupFile]. A received large file is an OFFER —
  /// name, size, content hash — and nothing else until somebody asks for the
  /// bytes. Without this step `GET /v1/files/download` had nothing to find and
  /// every received file was a dead end over the API.
  final Future<String?> Function(String peerHex, String messageId) fetchFile;

  /// Load the bytes of a stored file by [fileId], or null if unknown.
  /// Opens a stored file as a streamable range source. Deliberately NOT
  /// `Future<List<int>?>`: that signature forced every caller to materialise
  /// the whole blob just to hand it to the socket.
  ///
  /// [fileId] is whichever handle the message carried — `fileId` for a blob
  /// already in the store, `fileContentId` for one fetched through the content
  /// path, which stores under the content hash. Both are store keys.
  final Future<ApiBlobSource?> Function(String fileId) loadFile;

  /// Place a call to [toHex] ([media] = audio|video|screen); null on success.
  final Future<String?> Function(String toHex, String media) placeCall;

  /// The current call as a JSON map, or null if there is none.
  final Map<String, dynamic>? Function() callState;

  /// Act on the current call: 'hangup' | 'accept' | 'reject'.
  final Future<void> Function(String action) callAction;

  /// Headless hosts have no media engine. Keeping the routes in the shared
  /// contract but returning 501 is honest and machine-detectable.
  final bool callsAvailable;

  /// Groups belong to the active identity just like contacts/messages. A host
  /// that cannot wire the group core keeps the stable routes but returns 501
  /// via [groupsAvailable].
  final Future<List<Map<String, dynamic>>> Function() groups;
  final Future<List<Map<String, dynamic>>> Function()? spaces;
  final Future<List<Map<String, dynamic>>> Function()? spaceMemberships;
  final Future<String?> Function(String name) createGroup;
  final Future<String?> Function(
    String name,
    String description,
    String visibility,
  )?
  createSpace;
  final Future<List<Map<String, dynamic>>?> Function(String groupHex, int limit)
  groupMessages;
  final Future<String?> Function(String groupHex, String body, String? replyTo)
  sendGroupMessage;
  /// Send the file at [path] into a group. [roots] are the token's granted
  /// folders — the grant this send is made under, recorded with the durable
  /// offer so a reopen can ask whether it still holds (audit XV-04).
  final Future<({String? error, String? contentId})> Function(
    String groupHex,
    String path,
    String? name,
    String caption,
    String? replyTo,
    List<String> roots, {
    String? kind,
    int? width,
    int? height,
    int? durationMs,
  })
  sendGroupFile;
  final Future<String?> Function(String groupHex, String messageRef)
  fetchGroupFile;
  final Future<({String? error, ApiBlobSource? source})> Function(
    String groupHex,
    String messageRef,
  )
  loadGroupFile;
  final Future<Map<String, dynamic>?> Function(String groupHex, bool isSpace)
  groupMembers;
  final Future<String?> Function(
    String groupHex,
    String action,
    String peerHex,
    String? role,
    bool isSpace,
  )
  groupMemberAction;
  final Future<Map<String, dynamic>?> Function(String spaceHex)? spaceAccess;
  final Future<String?> Function(String spaceHex, Map<String, dynamic> body)?
  spaceAccessAction;
  final Future<Map<String, dynamic>?> Function(String spaceHex)?
  spacePolicyAudit;
  final Future<Map<String, dynamic>> Function()? spaceObservability;
  final Future<String?> Function(String groupHex, String name, bool isSpace)
  renameGroup;
  final Future<String?> Function(String groupHex, bool isSpace) leaveGroup;
  final Future<List<Map<String, dynamic>>?> Function(String spaceHex)?
  spaceChannels;
  final Future<Map<String, dynamic>?> Function(
    String spaceHex,
    int limit,
    String? before,
  )?
  spacePosts;
  final Future<Map<String, dynamic>?> Function(String spaceHex)? spacePostDraft;
  final Future<String?> Function(
    String spaceHex,
    String title,
    String body,
    String type,
    List<MediaObject> media,
    int? scheduledAtMs,
  )?
  saveSpacePostDraft;
  final Future<String?> Function(String spaceHex)? clearSpacePostDraft;
  final Future<Map<String, dynamic>?> Function(String spaceHex)?
  spaceScheduledPosts;
  final Future<({String? error, Map<String, dynamic>? scheduled})> Function(
    String spaceHex,
    String title,
    String body,
    String type,
    List<MediaObject> media,
    int scheduledAtMs,
  )?
  scheduleSpacePost;
  final Future<String?> Function(String spaceHex, String id)?
  cancelScheduledSpacePost;
  final Future<String?> Function(String spaceHex, String id)?
  publishScheduledSpacePostNow;
  final Future<Map<String, dynamic>?> Function(
    String spaceHex,
    String postId,
    int limit,
  )?
  spacePostComments;
  final Future<String?> Function(
    String spaceHex,
    String postId,
    String body,
    String? replyTo,
    MediaObject? media,
  )?
  publishSpacePostComment;
  final Future<String?> Function(
    String spaceHex,
    String postId,
    String commentId,
    String body,
  )?
  editSpacePostComment;
  final Future<String?> Function(
    String spaceHex,
    String postId,
    String commentId,
  )?
  deleteSpacePostComment;
  final Future<({String? error, Map<String, dynamic>? post})> Function(
    String spaceHex,
    String title,
    String body,
    String type,
    List<MediaObject> media,
  )?
  publishSpacePost;
  final Future<({String? error, Map<String, dynamic>? post})> Function(
    String spaceHex,
    String postId,
    String title,
    String body,
    String? type,
    List<MediaObject>? media,
  )?
  editSpacePost;
  final Future<String?> Function(String spaceHex, String postId)?
  deleteSpacePost;
  final Future<String?> Function(String spaceHex, String postId, bool pinned)?
  setSpacePostPinned;
  final Future<String?> Function(String spaceHex, String postId, String emoji)?
  reactToSpacePost;
  final Future<Map<String, dynamic>?> Function(
    String spaceHex,
    bool includeRevoked,
  )?
  spaceRecommendationCampaigns;
  final Future<({String? error, Map<String, dynamic>? campaign})> Function(
    String spaceHex,
    String text,
  )?
  createSpaceRecommendationCampaign;
  final Future<String?> Function(String spaceHex, String campaignId)?
  revokeSpaceRecommendationCampaign;
  final Future<String?> Function(
    String spaceHex,
    String campaignId,
    String recipientHex,
  )?
  shareSpaceRecommendation;
  final Future<Map<String, dynamic>?> Function(String spaceHex)?
  spaceRecommendationPolicy;
  final Future<String?> Function(
    String spaceHex,
    int expectedRevision,
    bool enabled,
  )?
  setSpaceRecommendationPolicy;
  final Future<Map<String, dynamic>?> Function(String spaceHex)?
  spaceRecommendationShares;
  final Future<String?> Function(String spaceHex, String auditId)?
  revokeSpaceRecommendationShare;
  final Future<Map<String, dynamic>> Function(
    int limit,
    String? before,
    bool? pinned,
  )?
  spaceFeed;
  final Future<Map<String, dynamic>> Function()? spaceFeedTypeFilter;
  final Future<String?> Function(List<String> types)? setSpaceFeedTypeFilter;
  final Future<Map<String, dynamic>> Function(String query)?
  publicSpaceDiscoverySearch;
  final Future<Map<String, dynamic>?> Function(String spaceHex)?
  publicSpaceDiscoveryResolve;
  final Future<List<Map<String, dynamic>>> Function()? publicSpaceSubscriptions;
  final Future<String?> Function(String spaceHex)? subscribePublicSpace;
  final Future<String?> Function(String spaceHex)? unsubscribePublicSpace;
  final Future<Map<String, dynamic>?> Function(String spaceHex)?
  spaceSubscription;
  final Future<String?> Function(
    String spaceHex, {
    bool? feedEnabled,
    bool? notificationsEnabled,
    String? commentNotifications,
    bool? hiddenFromRecommendations,
  })?
  updateSpaceSubscription;
  final Future<String?> Function(String spaceHex, String postId, bool hidden)?
  setSpaceFeedPostHidden;
  final Future<List<Map<String, dynamic>>> Function()? spaceInvites;
  final Future<String?> Function(String inviteId, bool accept)?
  decideSpaceInvite;
  final Future<Map<String, dynamic>> Function(String? spaceHex)?
  spaceJoinRequests;
  final Future<({String? error, String? code})> Function(
    String action,
    String? spaceHex,
    String? requestId,
    String? code,
  )?
  spaceJoinRequestAction;
  final Future<Map<String, dynamic>?> Function(String spaceHex)? spaceProfile;
  final Future<String?> Function(String spaceHex, String description)?
  updateSpaceDescription;
  final Future<Map<String, dynamic>?> Function(String spaceHex)? spaceLifecycle;
  final Future<String?> Function(String spaceHex, String action)?
  setSpaceLifecycle;
  final Future<Map<String, dynamic>?> Function(String spaceHex)? spaceRetention;
  final Future<String?> Function(
    String spaceHex,
    int? days,
    bool localDevice, {
    required bool mediaOnly,
  })?
  setSpaceRetention;
  final Future<Map<String, dynamic>?> Function(
    String spaceHex,
    String channelHex,
  )?
  spaceChannelRetention;
  final Future<String?> Function(
    String spaceHex,
    String channelHex,
    int? days,
    bool inherit, {
    required bool mediaOnly,
  })?
  setSpaceChannelRetention;
  final Future<Map<String, dynamic>?> Function(String spaceHex)? spaceRules;
  final Future<String?> Function(
    String spaceHex,
    String fullText,
    String summary,
    int? effectiveAtMs,
  )?
  publishSpaceRules;
  final Future<String?> Function(String spaceHex)? acceptSpaceRules;
  final Future<List<Map<String, dynamic>>?> Function(String spaceHex)?
  spaceModerationAudit;
  final Future<({String? error, String? actionId})> Function(
    String spaceHex,
    String kind,
    String targetHex,
    String scope,
    String reason,
    String? channelHex,
    int? expiresAtMs,
    String? referenceKind,
    String? referenceId,
    String? referenceChannelHex,
  )?
  moderateSpace;
  final Future<String?> Function(
    String spaceHex,
    String actionId,
    String reason,
  )?
  revokeSpaceModeration;
  final Future<Map<String, dynamic>> Function(String? spaceHex)?
  spaceModerationAppeals;
  final Future<String?> Function(
    String action,
    String? spaceHex,
    String? actionId,
    String? appealId,
    String? text,
    String? reason,
  )?
  spaceModerationAppealAction;
  final Future<Map<String, dynamic>> Function(String? spaceHex)?
  spaceAbuseReports;
  final Future<String?> Function(
    String action,
    String? spaceHex,
    String? postId,
    String? commentId,
    String? category,
    String? details,
    String? reportId,
    String? reason,
  )?
  spaceAbuseReportAction;
  final Future<({String? error, String? channelId})> Function(
    String spaceHex,
    String name,
    String kind,
    String? categoryHex,
    int? position,
    String history,
    int? historySinceMs,
    String access,
    List<String> members,
  )?
  createSpaceChannel;
  final Future<String?> Function(
    String spaceHex,
    String channelHex,
    Map<String, Object?> patch,
  )?
  updateSpaceChannel;
  final Future<String?> Function(
    String spaceHex,
    String channelHex,
    String action,
  )?
  spaceChannelAction;
  final Future<String?> Function(
    String spaceHex,
    String channelHex,
    List<String> members,
  )?
  setSpaceChannelMembers;
  final Future<List<Map<String, dynamic>>?> Function(
    String spaceHex,
    String channelHex,
    int limit,
  )?
  spaceChannelMessages;
  final Future<String?> Function(
    String spaceHex,
    String channelHex,
    String body,
    String? replyTo,
  )?
  sendSpaceChannelMessage;
  final bool groupsAvailable;

  /// File refs, membership-authorized fetch, and encrypted-store reads. Kept
  /// as a separate capability so a future constrained host can expose text
  /// groups honestly while returning 501 for group content operations.
  final bool groupMediaAvailable;

  /// Group-call control and local media posture. Headless hosts keep the
  /// stable routes but return 501 because they have no audio/video engine.
  final Future<String?> Function(String groupHex, String media) startGroupCall;
  final Future<String?> Function(
    String spaceHex,
    String channelHex,
    String media,
  )?
  startSpaceVoiceSession;
  final Map<String, dynamic>? Function() groupCallState;
  final Future<String?> Function(String action) groupCallAction;
  final Future<String?> Function(bool? mic, bool? camera, bool? screen)
  groupCallPosture;
  final bool groupCallsAvailable;

  /// The configured webhook URL (null = none). Optional: hosts without the
  /// webhook feature wired just 404 the /v1/webhook routes.
  final String? Function()? webhook;

  /// Persist + apply a new webhook URL (null clears). URL is pre-validated.
  final Future<void> Function(String? url)? setWebhook;

  /// Account and node status: who is unlocked, which identity is active, which
  /// identities a master space manages, and how the node sees the network.
  /// Null on a host that does not expose the account surface — those 404.
  final Future<Map<String, dynamic>> Function()? account;

  /// Lock the account. The host decides WHEN: locking usually stops this very
  /// server, so it schedules the lock after the response is flushed and this
  /// returns as soon as the lock is committed to, not completed.
  final Future<void> Function()? lockAccount;

  /// This node's shareable bootstrap invite.
  ///
  /// A daemon had no way to say who it is in the form a person can act on. It
  /// could ASK for a contact but never be added by someone who has it running
  /// — an asymmetry that shows up the moment a bot is left running and its
  /// owner wants to add it. The invite is the public half by construction: it
  /// is what a QR code carries, and the app already shows it on a screen.
  final Future<String?> Function()? accountInvite;

  // There is deliberately no unlock here. The bearer tokens this router
  // authenticates against are themselves stored inside the encrypted volume,
  // so before it opens there is nobody to authenticate and no way to tell a
  // caller from anyone else. Serving unlock would mean moving the token store
  // outside the vault, which trades the property the vault exists for against
  // a convenience. Unlocking stays with whoever can reach the device.

  /// Switch the active identity of an unlocked master space.
  final Future<String?> Function(String label)? switchIdentity;

  /// Personal-cloud projections. Null on a host without a cloud — those 501.
  final Future<List<Map<String, dynamic>>> Function()? cloudItems;
  final Future<List<Map<String, dynamic>>> Function()? cloudFolders;
  final Future<Map<String, dynamic>> Function()? cloudUsage;

  /// Bytes of one item, pulled from another device first if need be. Null for
  /// an unknown id and for content that could not be had — one outcome, since
  /// the difference tells a caller about content it cannot read anyway.
  final Future<ApiBlobSource?> Function(String itemId)? cloudFile;

  final Future<({Map<String, dynamic>? item, String? error})> Function({
    String? id,
    required String title,
    required String body,
    String? folderId,
  })?
  saveCloudNote;

  final Future<String?> Function(String id)? deleteCloudItem;

  /// What this host can answer, READ OFF the wiring rather than declared
  /// beside it.
  ///
  /// A separately declared capability set is a second answer to the same
  /// question, and the two would drift the first time somebody wired a handler
  /// without touching the declaration — which is exactly how the daemon came to
  /// publish `/v1/cloud/*` it refuses. Deriving it means the document a host
  /// serves cannot describe a callback that host did not pass.
  ///
  /// [ApiCapabilities.serves] then has to agree with the router's own gates.
  /// Nothing here can prove that, which is why the gate probes: see
  /// `test/headless_api_contract_test.dart`.
  ApiCapabilities get capabilities => ApiCapabilities(
    account: account != null,
    accountInvite: accountInvite != null,
    accountLock: lockAccount != null,
    identitySwitch: switchIdentity != null,
    cloud: cloudItems != null,
    contactRequests: requestContact != null,
    contactActions: contactAction != null,
    calls: callsAvailable,
    groups: groupsAvailable,
    groupMedia: groupMediaAvailable,
    groupCalls: groupCallsAvailable,
    spaceVoiceSessions: startSpaceVoiceSession != null,
    spacePostComments:
        spacePostComments != null &&
        publishSpacePostComment != null &&
        editSpacePostComment != null &&
        deleteSpacePostComment != null,
    webhook: webhook != null && setWebhook != null,
  );

  /// Constant-time compare of a raw token (localhost, but no reason to leak
  /// length/prefix). Used directly by the WebSocket path (token in the query,
  /// since a browser/ws client can't set an Authorization header on upgrade).
  static bool _ctEq(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// The token matching raw bearer [raw] (whose scope applies), or null.
  ApiToken? _matchRaw(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    for (final t in tokens) {
      if (_ctEq(raw, t.token)) return t;
    }
    return null;
  }

  ApiToken? _matchHeader(String? header) {
    const prefix = 'Bearer ';
    if (header == null || !header.startsWith(prefix)) return null;
    return _matchRaw(header.substring(prefix.length));
  }

  /// True if [raw] matches any token — the WS path's query-token check.
  bool tokenOk(String? raw) => _matchRaw(raw) != null;

  /// The token behind a WS query parameter, or null.
  ///
  /// [tokenOk] answered only "yes", which is why an upgraded socket could not
  /// be attributed to anything afterwards (audit XV-10). The subscriber needs
  /// the identity of its token, not just the verdict, so it can be closed when
  /// that token goes away.
  ApiToken? tokenFor(String? raw) => _matchRaw(raw);

  /// True if an `Authorization:` header carries a token this server accepts.
  ///
  /// Exists so the transport can refuse an unauthenticated request BEFORE it
  /// reads a body from it. [handle] still re-checks: this is a gate in front of
  /// the parser, never a replacement for the one that guards the work.
  bool authHeaderOk(String? header) => _matchHeader(header) != null;

  /// The status to answer with WITHOUT reading a body, or null to proceed.
  ///
  /// Authentication moved in front of the body reader earlier; SCOPE did not,
  /// and that half was still open. A read-only token — the one handed out for
  /// monitoring, on the understanding that it cannot change anything — passed
  /// the auth gate, and its `POST` was then read in full, up to the 4 MiB cap,
  /// before [handle] returned 403. The refusal was already decided at the first
  /// byte; reading the rest was work the token holder was never entitled to ask
  /// for. Deciding here costs one map lookup and makes the read-only token cost
  /// what it claims to.
  ///
  /// Returns 401 for no/unknown token, 403 for a token whose scope excludes
  /// [method], null when the request may be read.
  int? preBodyRefusal(String? header, String method) {
    final auth = _matchHeader(header);
    if (auth == null) return 401;
    if (auth.readOnly && method != 'GET') return 403;
    return null;
  }

  /// The resolved path a caller may send, or the refusal to answer with.
  ///
  /// CAPABILITY, not traversal defence (audit XV-08). Authentication passed
  /// here and always did — the hole was that passing it bought the whole
  /// filesystem, because the only write scope was one boolean and the send
  /// routes take a PATH. A token now names the folders it may send out of,
  /// and a path becomes bytes only once it resolves inside one of them.
  ///
  /// The two refusals differ ON PURPOSE, and only in the direction that is
  /// safe: "no folders granted" does not depend on the path, so it leaks
  /// nothing about the disk while being the one message an operator with a
  /// pre-existing token needs to see. Everything else — outside, missing,
  /// not a regular file — collapses to one answer.
  Future<({String? path, ApiResponse? refusal})> _sendablePath(
    ApiToken auth,
    String requested,
  ) async {
    if (auth.fileRoots.isEmpty) {
      return (
        path: null,
        refusal: const ApiResponse(403, {
          'error': 'this token may not send local files',
        }),
      );
    }
    final resolved = await resolveSendableFile(requested, auth.fileRoots);
    if (resolved == null) {
      return (
        path: null,
        refusal: const ApiResponse(403, {
          'error': 'path is outside the folders allowed for this token',
        }),
      );
    }
    return (path: resolved, refusal: null);
  }

  Future<ApiResponse> handle(
    String method,
    Uri uri,
    String? authHeader, {
    Map<String, dynamic>? body,
  }) async {
    final auth = _matchHeader(authHeader);
    if (auth == null) {
      return const ApiResponse(401, {'error': 'unauthorized'});
    }
    // A read-only token refuses every write (anything but GET). Reads fall
    // through.
    if (auth.readOnly && method != 'GET') {
      return const ApiResponse(403, {'error': 'read-only token'});
    }
    final path = uri.path;
    if (method == 'GET' && path == '/v1/openapi.json') {
      // THIS host's contract, not the union of every host's. Anything this
      // handler would refuse as unavailable is absent from what it hands back.
      return ApiResponse(200, openApiSpec(capabilities: capabilities));
    }
    if (method == 'GET' && path == '/v1/health') {
      return ApiResponse(200, status());
    }
    if (path.startsWith('/v1/account') && account == null) {
      return const ApiResponse(501, {
        'error': 'account surface unavailable on this host',
      });
    }
    if (path.startsWith('/v1/cloud') && cloudItems == null) {
      return const ApiResponse(501, {
        'error': 'cloud unavailable on this host',
      });
    }
    if (method == 'GET' && path == '/v1/cloud/items') {
      return ApiResponse(200, {'items': await cloudItems!()});
    }
    if (method == 'GET' && path == '/v1/cloud/folders') {
      if (cloudFolders == null) {
        return const ApiResponse(501, {'error': 'folders unavailable'});
      }
      return ApiResponse(200, {'folders': await cloudFolders!()});
    }
    if (method == 'GET' && path == '/v1/cloud/usage') {
      if (cloudUsage == null) {
        return const ApiResponse(501, {'error': 'usage unavailable'});
      }
      return ApiResponse(200, await cloudUsage!());
    }
    if (method == 'GET' && path == '/v1/cloud/file') {
      if (cloudFile == null) {
        return const ApiResponse(501, {'error': 'download unavailable'});
      }
      final id = uri.queryParameters['id'];
      if (id == null || id.isEmpty) {
        return const ApiResponse(400, {'error': 'id required'});
      }
      final source = await cloudFile!(id);
      return source == null
          ? const ApiResponse(404, {'error': 'not available'})
          : ApiResponse.blob(source);
    }
    if (method == 'POST' && path == '/v1/cloud/notes') {
      if (saveCloudNote == null) {
        return const ApiResponse(501, {'error': 'notes unavailable'});
      }
      final title = body?['title'];
      final text = body?['body'];
      if (title is! String || text is! String) {
        return const ApiResponse(400, {'error': 'title + body required'});
      }
      final id = body?['id'];
      final folder = body?['folder'];
      final saved = await saveCloudNote!(
        id: id is String && id.isNotEmpty ? id : null,
        title: title,
        body: text,
        folderId: folder is String && folder.isNotEmpty ? folder : null,
      );
      final item = saved.item;
      return item == null
          ? ApiResponse(409, {'error': saved.error ?? 'note refused'})
          : ApiResponse(200, item);
    }
    if (method == 'DELETE' && path == '/v1/cloud/items') {
      if (deleteCloudItem == null) {
        return const ApiResponse(501, {'error': 'delete unavailable'});
      }
      final id = uri.queryParameters['id'];
      if (id == null || id.isEmpty) {
        return const ApiResponse(400, {'error': 'id required'});
      }
      final err = await deleteCloudItem!(id);
      return err == null
          ? const ApiResponse(200, {'ok': true})
          : ApiResponse(400, {'error': err});
    }
    if (method == 'GET' && path == '/v1/account') {
      return ApiResponse(200, await account!());
    }
    if (method == 'GET' && path == '/v1/account/invite') {
      if (accountInvite == null) {
        return const ApiResponse(501, {'error': 'invite unavailable'});
      }
      final invite = await accountInvite!();
      return invite == null
          ? const ApiResponse(503, {'error': 'node not ready'})
          : ApiResponse(200, {'invite': invite});
    }
    if (method == 'POST' && path == '/v1/account/lock') {
      if (lockAccount == null) {
        return const ApiResponse(501, {'error': 'lock unavailable'});
      }
      try {
        await lockAccount!();
      } catch (e) {
        // A teardown leg failed, so the boundary is not closed — and this
        // server is still answering, which is itself the tell. Reporting 200
        // here would be the one claim nothing else in the system makes.
        return ApiResponse(500, {
          'error': 'lock incomplete',
          'detail': '$e',
          'locked': false,
        });
      }
      // Deliberately not re-reading the account here: the host stops this
      // server as part of locking, so anything read now would describe a state
      // that is already gone.
      return const ApiResponse(200, {'ok': true, 'locked': true});
    }
    if (method == 'POST' && path == '/v1/account/identity') {
      if (switchIdentity == null) {
        return const ApiResponse(501, {'error': 'identity switch unavailable'});
      }
      final label = body?['label'];
      if (label is! String || label.isEmpty) {
        return const ApiResponse(400, {'error': 'label required'});
      }
      final err = await switchIdentity!(label);
      if (err != null) return ApiResponse(400, {'error': err});
      return ApiResponse(200, await account!());
    }
    if (method == 'GET' && path == '/v1/contacts') {
      return ApiResponse(200, {'contacts': await contacts()});
    }
    if (method == 'POST' && path == '/v1/contacts' && requestContact != null) {
      final target = body?['target'];
      final greeting = body?['greeting'];
      if (target is! String ||
          target.isEmpty ||
          (greeting != null && greeting is! String)) {
        return const ApiResponse(400, {'error': 'target required'});
      }
      final error = await requestContact!(target, greeting as String? ?? '');
      return error == null
          ? const ApiResponse(200, {'ok': true})
          : ApiResponse(400, {'error': error});
    }
    if (method == 'POST' &&
        (path == '/v1/contacts/accept' || path == '/v1/contacts/block') &&
        contactAction != null) {
      final peer = body?['peer'];
      if (peer is! String || peer.isEmpty) {
        return const ApiResponse(400, {'error': 'peer required'});
      }
      final error = await contactAction!(peer, path.split('/').last);
      return error == null
          ? const ApiResponse(200, {'ok': true})
          : ApiResponse(400, {'error': error});
    }
    if (method == 'GET' && path == '/v1/messages') {
      final peer = uri.queryParameters['peer'];
      if (peer == null || peer.isEmpty) {
        return const ApiResponse(400, {'error': 'peer required'});
      }
      final limit = int.tryParse(uri.queryParameters['limit'] ?? '') ?? 50;
      return ApiResponse(200, {
        'messages': await messages(peer, limit.clamp(1, 500)),
      });
    }
    if (method == 'POST' && path == '/v1/messages') {
      final to = body?['to'];
      final text = body?['body'];
      if (to is! String || to.isEmpty || text is! String || text.isEmpty) {
        return const ApiResponse(400, {'error': 'to + body required'});
      }
      final err = await send(to, text);
      return err == null
          ? const ApiResponse(200, {'ok': true})
          : ApiResponse(400, {'error': err});
    }
    if (path.startsWith('/v1/groups/calls') && !groupCallsAvailable) {
      return const ApiResponse(501, {
        'error': 'group calls unavailable on this host',
      });
    }
    if (path.startsWith('/v1/groups/files') && !groupMediaAvailable) {
      return const ApiResponse(501, {
        'error': 'group media unavailable on this host',
      });
    }
    if (path.startsWith('/v1/groups') && !groupsAvailable) {
      return const ApiResponse(501, {
        'error': 'groups unavailable on this host',
      });
    }
    if (path.startsWith('/v1/spaces') && !groupsAvailable) {
      return const ApiResponse(501, {
        'error': 'spaces unavailable on this host',
      });
    }
    if (path.startsWith('/v1/feed') && !groupsAvailable) {
      return const ApiResponse(501, {
        'error': 'community feed unavailable on this host',
      });
    }
    if (method == 'GET' && path == '/v1/spaces') {
      return ApiResponse(200, {'spaces': await (spaces ?? groups)()});
    }
    if (method == 'GET' && path == '/v1/spaces/memberships') {
      final handler = spaceMemberships;
      if (handler == null) {
        return const ApiResponse(501, {
          'error': 'Space membership projection unavailable',
        });
      }
      return ApiResponse(200, {'memberships': await handler()});
    }
    if (method == 'POST' && path == '/v1/spaces') {
      final handler = createSpace;
      if (handler == null) {
        return const ApiResponse(501, {'error': 'Space creation unavailable'});
      }
      final rawName = body?['name'];
      final name = rawName is String ? rawName.trim() : '';
      final description = body?['description'] ?? '';
      final visibility = body?['visibility'] ?? 'private';
      if (name.isEmpty ||
          name.length > 160 ||
          description is! String ||
          description.length > 4096 ||
          visibility is! String ||
          !const {'public', 'private', 'secret'}.contains(visibility)) {
        return const ApiResponse(400, {
          'error': 'valid name, description and visibility required',
        });
      }
      final spaceId = await handler(name, description.trim(), visibility);
      return spaceId == null
          ? const ApiResponse(400, {'error': 'space creation failed'})
          : ApiResponse(200, {'ok': true, 'spaceId': spaceId});
    }
    if (method == 'GET' && path == '/v1/spaces/profile') {
      final handler = spaceProfile;
      if (handler == null) {
        return const ApiResponse(501, {'error': 'Space profiles unavailable'});
      }
      final space = uri.queryParameters['space'];
      if (space == null || space.isEmpty) {
        return const ApiResponse(400, {'error': 'space required'});
      }
      final profile = await handler(space);
      return profile == null
          ? const ApiResponse(404, {'error': 'space not found'})
          : ApiResponse(200, profile);
    }
    if (method == 'POST' && path == '/v1/spaces/profile') {
      final handler = updateSpaceDescription;
      if (handler == null) {
        return const ApiResponse(501, {'error': 'Space profiles unavailable'});
      }
      final space = body?['space'];
      final description = body?['description'];
      if (space is! String ||
          space.isEmpty ||
          description is! String ||
          description.length > 4096) {
        return const ApiResponse(400, {
          'error': 'space + description required (max 4096)',
        });
      }
      return _spaceMutationResponse(await handler(space, description.trim()));
    }
    if (method == 'GET' && path == '/v1/spaces/lifecycle') {
      final handler = spaceLifecycle;
      if (handler == null) {
        return const ApiResponse(501, {'error': 'Space lifecycle unavailable'});
      }
      final space = uri.queryParameters['space'];
      if (space == null || space.isEmpty) {
        return const ApiResponse(400, {'error': 'space required'});
      }
      final lifecycle = await handler(space);
      return lifecycle == null
          ? const ApiResponse(404, {'error': 'space not found'})
          : ApiResponse(200, lifecycle);
    }
    if (method == 'POST' && path == '/v1/spaces/lifecycle') {
      final handler = setSpaceLifecycle;
      if (handler == null) {
        return const ApiResponse(501, {'error': 'Space lifecycle unavailable'});
      }
      final space = body?['space'];
      final action = body?['action'];
      if (space is! String ||
          space.isEmpty ||
          (action != 'archive' && action != 'delete' && action != 'restore')) {
        return const ApiResponse(400, {
          'error': 'valid space and lifecycle action required',
        });
      }
      return _spaceMutationResponse(await handler(space, action as String));
    }
    if (method == 'GET' && path == '/v1/spaces/retention') {
      final space = uri.queryParameters['space'];
      if (space == null || space.isEmpty) {
        return const ApiResponse(400, {'error': 'space required'});
      }
      final channel = uri.queryParameters['channel'];
      final retention = channel == null
          ? await spaceRetention?.call(space)
          : channel.isEmpty
          ? null
          : await spaceChannelRetention?.call(space, channel);
      if ((channel == null && spaceRetention == null) ||
          (channel != null && spaceChannelRetention == null)) {
        return const ApiResponse(501, {'error': 'Space retention unavailable'});
      }
      return retention == null
          ? const ApiResponse(404, {'error': 'space or channel not found'})
          : ApiResponse(200, retention);
    }
    if (method == 'POST' && path == '/v1/spaces/retention') {
      final handler = setSpaceRetention;
      final space = body?['space'];
      final scope = body?['scope'];
      final days = body?['days'];
      final channel = body?['channel'];
      final inherit = body?['inherit'] ?? false;
      final mediaOnly = body?['mediaOnly'] ?? false;
      if (space is! String ||
          space.isEmpty ||
          (scope != 'community' && scope != 'device' && scope != 'channel') ||
          inherit is! bool ||
          mediaOnly is! bool ||
          (scope == 'channel'
              ? channel is! String || channel.isEmpty
              : channel != null || inherit == true) ||
          (scope == 'channel' && inherit == true && days != null) ||
          (mediaOnly == true &&
              (scope == 'device' || inherit == true || days == null)) ||
          (days != null && (days is! int || days <= 0 || days > 36500))) {
        return const ApiResponse(400, {
          'error': 'valid space, scope, channel and optional days required',
        });
      }
      if (scope == 'channel') {
        final channelHandler = setSpaceChannelRetention;
        if (channelHandler == null) {
          return const ApiResponse(501, {
            'error': 'Space retention unavailable',
          });
        }
        return _spaceMutationResponse(
          await channelHandler(
            space,
            channel as String,
            days as int?,
            inherit,
            mediaOnly: mediaOnly,
          ),
        );
      }
      if (handler == null) {
        return const ApiResponse(501, {'error': 'Space retention unavailable'});
      }
      return _spaceMutationResponse(
        await handler(
          space,
          days as int?,
          scope == 'device',
          mediaOnly: mediaOnly,
        ),
      );
    }
    if (method == 'GET' && path == '/v1/spaces/rules') {
      final handler = spaceRules;
      if (handler == null) {
        return const ApiResponse(501, {'error': 'Space rules unavailable'});
      }
      final space = uri.queryParameters['space'];
      if (space == null || space.isEmpty) {
        return const ApiResponse(400, {'error': 'space required'});
      }
      final rules = await handler(space);
      return rules == null
          ? const ApiResponse(404, {'error': 'space not found'})
          : ApiResponse(200, rules);
    }
    if (method == 'POST' && path == '/v1/spaces/rules') {
      final handler = publishSpaceRules;
      if (handler == null) {
        return const ApiResponse(501, {'error': 'Space rules unavailable'});
      }
      final space = body?['space'];
      final fullText = body?['fullText'];
      final summary = body?['summary'] ?? '';
      final effectiveAt = body?['effectiveAt'];
      if (space is! String ||
          space.isEmpty ||
          fullText is! String ||
          fullText.trim().isEmpty ||
          fullText.length > 65536 ||
          summary is! String ||
          summary.length > 4096 ||
          (effectiveAt != null && (effectiveAt is! int || effectiveAt < 0))) {
        return const ApiResponse(400, {
          'error': 'valid space, fullText, summary and effectiveAt required',
        });
      }
      return _spaceMutationResponse(
        await handler(
          space,
          fullText.trim(),
          summary.trim(),
          effectiveAt as int?,
        ),
      );
    }
    if (method == 'POST' && path == '/v1/spaces/rules/accept') {
      final handler = acceptSpaceRules;
      if (handler == null) {
        return const ApiResponse(501, {'error': 'Space rules unavailable'});
      }
      final space = body?['space'];
      if (space is! String || space.isEmpty) {
        return const ApiResponse(400, {'error': 'space required'});
      }
      return _spaceMutationResponse(await handler(space));
    }
    if (method == 'GET' && path == '/v1/spaces/moderation') {
      final handler = spaceModerationAudit;
      if (handler == null) {
        return const ApiResponse(501, {
          'error': 'Space moderation unavailable',
        });
      }
      final space = uri.queryParameters['space'];
      if (space == null || space.isEmpty) {
        return const ApiResponse(400, {'error': 'space required'});
      }
      final records = await handler(space);
      return records == null
          ? const ApiResponse(404, {'error': 'space not found'})
          : ApiResponse(200, {'actions': records});
    }
    if (method == 'POST' && path == '/v1/spaces/moderation') {
      final handler = moderateSpace;
      if (handler == null) {
        return const ApiResponse(501, {
          'error': 'Space moderation unavailable',
        });
      }
      final space = body?['space'];
      final kind = body?['kind'];
      final target = body?['target'];
      final scope = body?['scope'] ?? 'space';
      final reason = body?['reason'];
      final channel = body?['channelId'];
      final expiresAt = body?['expiresAt'];
      final reference = body?['reference'];
      if (space is! String ||
          space.isEmpty ||
          kind is! String ||
          target is! String ||
          scope is! String ||
          reason is! String ||
          reason.trim().isEmpty ||
          reason.length > 4096 ||
          (channel != null && channel is! String) ||
          (expiresAt != null && (expiresAt is! int || expiresAt < 0)) ||
          (reference != null && reference is! Map) ||
          (reference is Map &&
              (reference['kind'] is! String ||
                  reference['id'] is! String ||
                  (reference['channelId'] != null &&
                      reference['channelId'] is! String)))) {
        return const ApiResponse(400, {'error': 'invalid moderation action'});
      }
      final result = await handler(
        space,
        kind,
        target,
        scope,
        reason.trim(),
        channel as String?,
        expiresAt as int?,
        reference is Map ? reference['kind'] as String : null,
        reference is Map ? reference['id'] as String : null,
        reference is Map ? reference['channelId'] as String? : null,
      );
      return result.error == null
          ? ApiResponse(200, {'ok': true, 'actionId': result.actionId})
          : ApiResponse(400, {'error': result.error});
    }
    if (method == 'POST' && path == '/v1/spaces/moderation/revoke') {
      final handler = revokeSpaceModeration;
      if (handler == null) {
        return const ApiResponse(501, {
          'error': 'Space moderation unavailable',
        });
      }
      final space = body?['space'];
      final actionId = body?['actionId'];
      final reason = body?['reason'];
      if (space is! String ||
          space.isEmpty ||
          actionId is! String ||
          !RegExp(r'^[0-9a-f]{64}:[0-9]+$').hasMatch(actionId) ||
          reason is! String ||
          reason.trim().isEmpty ||
          reason.length > 4096) {
        return const ApiResponse(400, {
          'error': 'valid space, actionId and reason required',
        });
      }
      return _spaceMutationResponse(
        await handler(space, actionId, reason.trim()),
      );
    }
    if (method == 'GET' && path == '/v1/spaces/moderation/appeals') {
      final handler = spaceModerationAppeals;
      if (handler == null) {
        return const ApiResponse(501, {
          'error': 'Space moderation appeals unavailable',
        });
      }
      final result = await handler(uri.queryParameters['space']);
      return result['error'] == null
          ? ApiResponse(200, result)
          : ApiResponse(400, result);
    }
    if (method == 'POST' && path == '/v1/spaces/moderation/appeals') {
      final handler = spaceModerationAppealAction;
      if (handler == null) {
        return const ApiResponse(501, {
          'error': 'Space moderation appeals unavailable',
        });
      }
      final action = body?['action'];
      final space = body?['space'];
      final actionId = body?['actionId'];
      final appealId = body?['appealId'];
      final text = body?['text'];
      final reason = body?['reason'];
      final validActionId =
          actionId is String &&
          RegExp(r'^[0-9a-f]{64}:[0-9]+$').hasMatch(actionId);
      final validAppealId =
          appealId is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(appealId);
      if (action is! String ||
          !const {
            'appeal',
            'reject',
            'revoke',
            'acknowledge',
          }.contains(action) ||
          (action == 'appeal' &&
              (space is! String ||
                  space.isEmpty ||
                  !validActionId ||
                  text is! String ||
                  text.trim().isEmpty ||
                  utf8.encode(text).length > kSpaceModerationAppealMax)) ||
          (action != 'appeal' &&
              (!validAppealId ||
                  reason is! String ||
                  reason.trim().isEmpty ||
                  utf8.encode(reason).length > kSpaceModerationReasonMax))) {
        return const ApiResponse(400, {
          'error': 'valid moderation appeal action required',
        });
      }
      return _spaceMutationResponse(
        await handler(
          action,
          space as String?,
          actionId as String?,
          appealId as String?,
          text is String ? text.trim() : null,
          reason is String ? reason.trim() : null,
        ),
      );
    }
    if (method == 'GET' && path == '/v1/spaces/moderation/reports') {
      final handler = spaceAbuseReports;
      if (handler == null) {
        return const ApiResponse(501, {
          'error': 'Space abuse reports unavailable',
        });
      }
      final result = await handler(uri.queryParameters['space']);
      return result['error'] == null
          ? ApiResponse(200, result)
          : ApiResponse(400, result);
    }
    if (method == 'POST' && path == '/v1/spaces/moderation/reports') {
      final handler = spaceAbuseReportAction;
      if (handler == null) {
        return const ApiResponse(501, {
          'error': 'Space abuse reports unavailable',
        });
      }
      final action = body?['action'];
      final space = body?['space'];
      final postId = body?['postId'];
      final commentId = body?['commentId'];
      final category = body?['category'];
      final details = body?['details'];
      final reportId = body?['reportId'];
      final reason = body?['reason'];
      final validContentId = RegExp(r'^[0-9a-f]{64}:[0-9]+$');
      final parsedCategory = category is String
          ? SpaceAbuseCategory.fromName(category)
          : null;
      final validReport =
          space is String &&
          space.isNotEmpty &&
          postId is String &&
          validContentId.hasMatch(postId) &&
          (commentId == null ||
              commentId is String && validContentId.hasMatch(commentId)) &&
          parsedCategory != null &&
          (details == null ||
              details is String &&
                  utf8.encode(details.trim()).length <=
                      kSpaceAbuseReportDetailsMaxBytes) &&
          (parsedCategory != SpaceAbuseCategory.other ||
              details is String && details.trim().isNotEmpty);
      final validDecision =
          reportId is String &&
          RegExp(r'^[0-9a-f]{64}$').hasMatch(reportId) &&
          reason is String &&
          reason.trim().isNotEmpty &&
          utf8.encode(reason).length <= kSpaceAbuseReportDecisionReasonMaxBytes;
      if (action is! String ||
          !const {'report', 'dismiss', 'resolve', 'remove'}.contains(action) ||
          (action == 'report' ? !validReport : !validDecision)) {
        return const ApiResponse(400, {
          'error': 'valid Space abuse report action required',
        });
      }
      return _spaceMutationResponse(
        await handler(
          action,
          space is String ? space : null,
          postId is String ? postId : null,
          commentId is String ? commentId : null,
          category is String ? category : null,
          details is String ? details.trim() : null,
          reportId is String ? reportId : null,
          reason is String ? reason.trim() : null,
        ),
      );
    }
    if (method == 'GET' && path == '/v1/spaces/posts') {
      final handler = spacePosts;
      if (handler == null) {
        return const ApiResponse(501, {'error': 'Space posts unavailable'});
      }
      final space = uri.queryParameters['space'];
      final before = uri.queryParameters['before'];
      if (space == null ||
          space.isEmpty ||
          (before != null && !_validFeedCursor(before))) {
        return const ApiResponse(400, {'error': 'valid space/cursor required'});
      }
      final limit = int.tryParse(uri.queryParameters['limit'] ?? '') ?? 50;
      final result = await handler(space, limit.clamp(1, 200), before);
      return result == null
          ? const ApiResponse(404, {'error': 'space not found'})
          : ApiResponse(200, result);
    }
    if (method == 'GET' && path == '/v1/spaces/posts/draft') {
      final handler = spacePostDraft;
      if (handler == null) {
        return const ApiResponse(501, {
          'error': 'Space post draft unavailable',
        });
      }
      final space = uri.queryParameters['space'];
      if (space == null || space.isEmpty) {
        return const ApiResponse(400, {'error': 'valid space required'});
      }
      final result = await handler(space);
      return result == null
          ? const ApiResponse(404, {'error': 'space not found'})
          : ApiResponse(200, result);
    }
    if (method == 'PUT' && path == '/v1/spaces/posts/draft') {
      final handler = saveSpacePostDraft;
      if (handler == null) {
        return const ApiResponse(501, {
          'error': 'Space post draft unavailable',
        });
      }
      final space = body?['space'];
      final title = body?['title'] ?? '';
      final text = body?['body'] ?? '';
      final type = body?['type'] ?? 'post';
      final media = _spacePostMedia(body?['media']);
      final scheduledAt = body?['scheduledAt'];
      if (space is! String ||
          space.isEmpty ||
          title is! String ||
          title.length > kSpacePostTitleMax ||
          text is! String ||
          utf8.encode(text).length > kSpacePostBodyMax ||
          type is! String ||
          SpacePostType.fromName(type) == null ||
          (scheduledAt != null && scheduledAt is! int) ||
          media == null) {
        return const ApiResponse(400, {'error': 'invalid Space post draft'});
      }
      return _spaceMutationResponse(
        await handler(space, title, text, type, media, scheduledAt as int?),
      );
    }
    if (method == 'DELETE' && path == '/v1/spaces/posts/draft') {
      final handler = clearSpacePostDraft;
      if (handler == null) {
        return const ApiResponse(501, {
          'error': 'Space post draft unavailable',
        });
      }
      final space = uri.queryParameters['space'];
      if (space == null || space.isEmpty) {
        return const ApiResponse(400, {'error': 'valid space required'});
      }
      return _spaceMutationResponse(await handler(space));
    }
    if (method == 'GET' && path == '/v1/spaces/posts/scheduled') {
      final handler = spaceScheduledPosts;
      if (handler == null) {
        return const ApiResponse(501, {
          'error': 'Scheduled Space posts unavailable',
        });
      }
      final space = uri.queryParameters['space'];
      if (space == null || space.isEmpty) {
        return const ApiResponse(400, {'error': 'valid space required'});
      }
      final result = await handler(space);
      return result == null
          ? const ApiResponse(404, {'error': 'space not found'})
          : ApiResponse(200, result);
    }
    if (method == 'POST' && path == '/v1/spaces/posts/scheduled') {
      final handler = scheduleSpacePost;
      if (handler == null) {
        return const ApiResponse(501, {
          'error': 'Scheduled Space posts unavailable',
        });
      }
      final space = body?['space'];
      final title = body?['title'] ?? '';
      final text = body?['body'] ?? '';
      final type = body?['type'] ?? 'post';
      final media = _spacePostMedia(body?['media']);
      final scheduledAt = body?['scheduledAt'];
      if (space is! String ||
          space.isEmpty ||
          title is! String ||
          title.length > kSpacePostTitleMax ||
          text is! String ||
          utf8.encode(text).length > kSpacePostBodyMax ||
          type is! String ||
          SpacePostType.fromName(type) == null ||
          media == null ||
          (title.trim().isEmpty && text.trim().isEmpty && media.isEmpty) ||
          scheduledAt is! int ||
          scheduledAt <= DateTime.now().millisecondsSinceEpoch) {
        return const ApiResponse(400, {
          'error': 'invalid scheduled Space post',
        });
      }
      final result = await handler(
        space,
        title.trim(),
        text.trim(),
        type,
        media,
        scheduledAt,
      );
      return result.error == null
          ? ApiResponse(201, {'ok': true, 'scheduled': result.scheduled})
          : ApiResponse(400, {'error': result.error});
    }
    if (method == 'DELETE' && path == '/v1/spaces/posts/scheduled') {
      final handler = cancelScheduledSpacePost;
      if (handler == null) {
        return const ApiResponse(501, {
          'error': 'Scheduled Space posts unavailable',
        });
      }
      final space = uri.queryParameters['space'];
      final id = uri.queryParameters['id'];
      if (space == null ||
          space.isEmpty ||
          id == null ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(id)) {
        return const ApiResponse(400, {'error': 'valid space + id required'});
      }
      return _spaceMutationResponse(await handler(space, id));
    }
    if (method == 'POST' && path == '/v1/spaces/posts/scheduled/publish') {
      final handler = publishScheduledSpacePostNow;
      if (handler == null) {
        return const ApiResponse(501, {
          'error': 'Scheduled Space posts unavailable',
        });
      }
      final space = body?['space'];
      final id = body?['id'];
      if (space is! String ||
          space.isEmpty ||
          id is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(id)) {
        return const ApiResponse(400, {'error': 'valid space + id required'});
      }
      return _spaceMutationResponse(await handler(space, id));
    }
    if (method == 'GET' && path == '/v1/spaces/posts/comments') {
      final handler = spacePostComments;
      if (handler == null) {
        return const ApiResponse(501, {
          'error': 'Space post comments unavailable',
        });
      }
      final space = uri.queryParameters['space'];
      final postId = uri.queryParameters['postId'];
      if (space == null ||
          space.isEmpty ||
          postId == null ||
          !_validPostId(postId)) {
        return const ApiResponse(400, {
          'error': 'valid space + postId required',
        });
      }
      final limit = int.tryParse(uri.queryParameters['limit'] ?? '') ?? 50;
      final result = await handler(space, postId, limit.clamp(1, 500));
      return result == null
          ? const ApiResponse(404, {'error': 'post not found'})
          : ApiResponse(200, result);
    }
    if (method == 'POST' && path == '/v1/spaces/posts/comments') {
      final handler = publishSpacePostComment;
      if (handler == null) {
        return const ApiResponse(501, {
          'error': 'Space post comments unavailable',
        });
      }
      final space = body?['space'];
      final postId = body?['postId'];
      final text = body?['body'] ?? '';
      final replyTo = body?['replyTo'];
      final hasMedia = body?.containsKey('media') ?? false;
      final media = hasMedia
          ? MediaObject.fromReferenceJson(body?['media'])
          : null;
      if (space is! String ||
          space.isEmpty ||
          postId is! String ||
          !_validPostId(postId) ||
          text is! String ||
          (text.trim().isEmpty && media == null) ||
          (hasMedia && media == null) ||
          utf8.encode(text).length > kSpacePostCommentMaxBytes ||
          (replyTo != null && (replyTo is! String || !_validPostId(replyTo)))) {
        return const ApiResponse(400, {'error': 'invalid Space post comment'});
      }
      return _spaceMutationResponse(
        await handler(space, postId, text.trim(), replyTo as String?, media),
      );
    }
    if (method == 'PATCH' && path == '/v1/spaces/posts/comments') {
      final handler = editSpacePostComment;
      if (handler == null) {
        return const ApiResponse(501, {
          'error': 'Space post comment editing unavailable',
        });
      }
      final space = body?['space'];
      final postId = body?['postId'];
      final commentId = body?['commentId'];
      final text = body?['body'];
      if (space is! String ||
          space.isEmpty ||
          postId is! String ||
          !_validPostId(postId) ||
          commentId is! String ||
          !_validPostId(commentId) ||
          text is! String ||
          utf8.encode(text).length > kSpacePostCommentMaxBytes) {
        return const ApiResponse(400, {
          'error': 'invalid Space post comment edit',
        });
      }
      return _spaceMutationResponse(
        await handler(space, postId, commentId, text.trim()),
      );
    }
    if (method == 'DELETE' && path == '/v1/spaces/posts/comments') {
      final handler = deleteSpacePostComment;
      if (handler == null) {
        return const ApiResponse(501, {
          'error': 'Space post comment deletion unavailable',
        });
      }
      final space = body?['space'];
      final postId = body?['postId'];
      final commentId = body?['commentId'];
      if (space is! String ||
          space.isEmpty ||
          postId is! String ||
          !_validPostId(postId) ||
          commentId is! String ||
          !_validPostId(commentId)) {
        return const ApiResponse(400, {
          'error': 'invalid Space post comment delete',
        });
      }
      return _spaceMutationResponse(await handler(space, postId, commentId));
    }
    if (method == 'POST' && path == '/v1/spaces/posts') {
      final handler = publishSpacePost;
      if (handler == null) {
        return const ApiResponse(501, {'error': 'Space posts unavailable'});
      }
      final space = body?['space'];
      final title = body?['title'] ?? '';
      final text = body?['body'] ?? '';
      final type = body?['type'] ?? 'post';
      final media = _spacePostMedia(body?['media']);
      const types = {
        'post',
        'article',
        'video',
        'shortVideo',
        'audio',
        'voiceMessage',
      };
      if (space is! String ||
          space.isEmpty ||
          title is! String ||
          title.length > 300 ||
          text is! String ||
          utf8.encode(text).length > 256 * 1024 ||
          media == null ||
          (title.trim().isEmpty && text.trim().isEmpty && media.isEmpty) ||
          type is! String ||
          !types.contains(type)) {
        return const ApiResponse(400, {'error': 'invalid Space post'});
      }
      final result = await handler(
        space,
        title.trim(),
        text.trim(),
        type,
        media,
      );
      return result.error == null
          ? ApiResponse(200, {'ok': true, 'post': result.post})
          : ApiResponse(400, {'error': result.error});
    }
    if (method == 'PATCH' && path == '/v1/spaces/posts') {
      final handler = editSpacePost;
      if (handler == null) {
        return const ApiResponse(501, {
          'error': 'Space post edits unavailable',
        });
      }
      final space = body?['space'];
      final postId = body?['postId'];
      final title = body?['title'] ?? '';
      final text = body?['body'] ?? '';
      final type = body?['type'];
      final hasMedia = body?.containsKey('media') ?? false;
      final media = hasMedia ? _spacePostMedia(body?['media']) : null;
      const types = {
        'post',
        'article',
        'video',
        'shortVideo',
        'audio',
        'voiceMessage',
      };
      if (space is! String ||
          space.isEmpty ||
          postId is! String ||
          !RegExp(r'^[0-9a-f]{64}:[0-9]+$').hasMatch(postId) ||
          title is! String ||
          title.length > 300 ||
          text is! String ||
          utf8.encode(text).length > 256 * 1024 ||
          (hasMedia && media == null) ||
          (type != null && (type is! String || !types.contains(type)))) {
        return const ApiResponse(400, {'error': 'invalid Space post edit'});
      }
      final result = await handler(
        space,
        postId,
        title.trim(),
        text.trim(),
        type as String?,
        media,
      );
      return result.error == null
          ? ApiResponse(200, {'ok': true, 'post': result.post})
          : ApiResponse(400, {'error': result.error});
    }
    if (method == 'DELETE' && path == '/v1/spaces/posts') {
      final handler = deleteSpacePost;
      if (handler == null) {
        return const ApiResponse(501, {
          'error': 'Space post deletion unavailable',
        });
      }
      final space = uri.queryParameters['space'];
      final postId = uri.queryParameters['postId'];
      if (space == null ||
          space.isEmpty ||
          postId == null ||
          !RegExp(r'^[0-9a-f]{64}:[0-9]+$').hasMatch(postId)) {
        return const ApiResponse(400, {'error': 'space + postId required'});
      }
      return _spaceMutationResponse(await handler(space, postId));
    }
    if (method == 'POST' && path == '/v1/spaces/posts/pin') {
      final handler = setSpacePostPinned;
      if (handler == null) {
        return const ApiResponse(501, {'error': 'Space post pins unavailable'});
      }
      final space = body?['space'];
      final postId = body?['postId'];
      final pinned = body?['pinned'];
      if (space is! String ||
          space.isEmpty ||
          postId is! String ||
          !RegExp(r'^[0-9a-f]{64}:[0-9]+$').hasMatch(postId) ||
          pinned is! bool) {
        return const ApiResponse(400, {
          'error': 'valid space + postId + pinned required',
        });
      }
      return _spaceMutationResponse(await handler(space, postId, pinned));
    }
    if (method == 'POST' && path == '/v1/spaces/posts/reactions') {
      final handler = reactToSpacePost;
      if (handler == null) {
        return const ApiResponse(501, {
          'error': 'Space post reactions unavailable',
        });
      }
      final space = body?['space'];
      final postId = body?['postId'];
      final emoji = body?['emoji'];
      if (space is! String ||
          space.isEmpty ||
          postId is! String ||
          !RegExp(r'^[0-9a-f]{64}:[0-9]+$').hasMatch(postId) ||
          emoji is! String ||
          emoji.isEmpty ||
          utf8.encode(emoji).length > 64) {
        return const ApiResponse(400, {
          'error': 'valid space + postId + emoji required',
        });
      }
      return _spaceMutationResponse(await handler(space, postId, emoji));
    }
    if (method == 'GET' && path == '/v1/spaces/recommendations') {
      final handler = spaceRecommendationCampaigns;
      final space = uri.queryParameters['space'];
      if (handler == null) {
        return const ApiResponse(501, {
          'error': 'Space recommendations unavailable',
        });
      }
      if (space == null || space.isEmpty) {
        return const ApiResponse(400, {'error': 'space required'});
      }
      final result = await handler(
        space,
        uri.queryParameters['includeRevoked'] == 'true',
      );
      return result == null
          ? const ApiResponse(404, {'error': 'space not found'})
          : ApiResponse(200, result);
    }
    if (method == 'POST' && path == '/v1/spaces/recommendations') {
      final handler = createSpaceRecommendationCampaign;
      final space = body?['space'];
      final text = body?['text'];
      if (handler == null) {
        return const ApiResponse(501, {
          'error': 'Space recommendations unavailable',
        });
      }
      if (space is! String ||
          space.isEmpty ||
          text is! String ||
          text.trim().isEmpty ||
          text.trim().length > 1000) {
        return const ApiResponse(400, {'error': 'valid space + text required'});
      }
      final result = await handler(space, text.trim());
      return result.error == null
          ? ApiResponse(200, {'ok': true, 'campaign': result.campaign})
          : ApiResponse(400, {'error': result.error});
    }
    if (method == 'DELETE' && path == '/v1/spaces/recommendations') {
      final handler = revokeSpaceRecommendationCampaign;
      final space = uri.queryParameters['space'];
      final campaignId = uri.queryParameters['campaignId'];
      if (handler == null) {
        return const ApiResponse(501, {
          'error': 'Space recommendations unavailable',
        });
      }
      if (space == null ||
          space.isEmpty ||
          campaignId == null ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(campaignId)) {
        return const ApiResponse(400, {
          'error': 'valid space + campaignId required',
        });
      }
      return _spaceMutationResponse(await handler(space, campaignId));
    }
    if (method == 'POST' && path == '/v1/spaces/recommendations/share') {
      final handler = shareSpaceRecommendation;
      final space = body?['space'];
      final campaignId = body?['campaignId'];
      final recipient = body?['recipient'];
      if (handler == null) {
        return const ApiResponse(501, {
          'error': 'Space recommendations unavailable',
        });
      }
      if (space is! String ||
          space.isEmpty ||
          campaignId is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(campaignId) ||
          recipient is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(recipient)) {
        return const ApiResponse(400, {
          'error': 'valid space + campaignId + recipient required',
        });
      }
      return _spaceMutationResponse(
        await handler(space, campaignId, recipient),
      );
    }
    if (method == 'GET' && path == '/v1/spaces/recommendations/policy') {
      final handler = spaceRecommendationPolicy;
      final space = uri.queryParameters['space'];
      if (handler == null) {
        return const ApiResponse(501, {
          'error': 'Space recommendation policy unavailable',
        });
      }
      if (space == null || space.isEmpty) {
        return const ApiResponse(400, {'error': 'space required'});
      }
      final result = await handler(space);
      return result == null
          ? const ApiResponse(404, {'error': 'space not found'})
          : ApiResponse(200, result);
    }
    if (method == 'POST' && path == '/v1/spaces/recommendations/policy') {
      final handler = setSpaceRecommendationPolicy;
      final space = body?['space'];
      final expectedRevision = body?['expectedRevision'];
      final enabled = body?['enabled'];
      if (handler == null) {
        return const ApiResponse(501, {
          'error': 'Space recommendation policy unavailable',
        });
      }
      if (space is! String ||
          space.isEmpty ||
          expectedRevision is! int ||
          expectedRevision < 0 ||
          enabled is! bool) {
        return const ApiResponse(400, {
          'error': 'valid space + expectedRevision + enabled required',
        });
      }
      return _spaceMutationResponse(
        await handler(space, expectedRevision, enabled),
      );
    }
    if (method == 'GET' && path == '/v1/spaces/recommendations/shares') {
      final handler = spaceRecommendationShares;
      final space = uri.queryParameters['space'];
      if (handler == null) {
        return const ApiResponse(501, {
          'error': 'Space recommendation shares unavailable',
        });
      }
      if (space == null || space.isEmpty) {
        return const ApiResponse(400, {'error': 'space required'});
      }
      final result = await handler(space);
      return result == null
          ? const ApiResponse(404, {'error': 'space not found'})
          : ApiResponse(200, result);
    }
    if (method == 'DELETE' && path == '/v1/spaces/recommendations/shares') {
      final handler = revokeSpaceRecommendationShare;
      final space = uri.queryParameters['space'];
      final auditId = uri.queryParameters['id'];
      if (handler == null) {
        return const ApiResponse(501, {
          'error': 'Space recommendation shares unavailable',
        });
      }
      if (space == null ||
          space.isEmpty ||
          auditId == null ||
          auditId.isEmpty ||
          auditId.length > 256) {
        return const ApiResponse(400, {'error': 'valid space + id required'});
      }
      return _spaceMutationResponse(await handler(space, auditId));
    }
    if (method == 'GET' && path == '/v1/spaces/observability') {
      final handler = spaceObservability;
      return handler == null
          ? const ApiResponse(501, {'error': 'Space observability unavailable'})
          : ApiResponse(200, await handler());
    }
    if (method == 'GET' && path == '/v1/spaces/discovery') {
      final query = uri.queryParameters['query'];
      final space = uri.queryParameters['space'];
      if ((query == null) == (space == null)) {
        return const ApiResponse(400, {
          'error': 'exactly one of query or space is required',
        });
      }
      if (query != null) {
        final handler = publicSpaceDiscoverySearch;
        if (handler == null) {
          return const ApiResponse(501, {
            'error': 'public Space discovery unavailable',
          });
        }
        if (query.trim().isEmpty || utf8.encode(query).length > 512) {
          return const ApiResponse(400, {'error': 'valid query required'});
        }
        return ApiResponse(200, await handler(query));
      }
      final handler = publicSpaceDiscoveryResolve;
      if (handler == null) {
        return const ApiResponse(501, {
          'error': 'public Space discovery unavailable',
        });
      }
      if (space == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(space)) {
        return const ApiResponse(400, {'error': 'valid space required'});
      }
      final result = await handler(space);
      return result == null
          ? const ApiResponse(404, {'error': 'public Space not found'})
          : ApiResponse(200, result);
    }
    if (method == 'GET' && path == '/v1/spaces/public-subscriptions') {
      final handler = publicSpaceSubscriptions;
      return handler == null
          ? const ApiResponse(501, {
              'error': 'public Space subscriptions unavailable',
            })
          : ApiResponse(200, await handler());
    }
    if (method == 'POST' && path == '/v1/spaces/public-subscriptions') {
      final handler = subscribePublicSpace;
      if (handler == null) {
        return const ApiResponse(501, {
          'error': 'public Space subscriptions unavailable',
        });
      }
      if (body == null ||
          body.length != 1 ||
          body['space'] is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(body['space'] as String)) {
        return const ApiResponse(400, {'error': 'valid space required'});
      }
      return _spaceMutationResponse(await handler(body['space'] as String));
    }
    if (method == 'DELETE' && path == '/v1/spaces/public-subscriptions') {
      final handler = unsubscribePublicSpace;
      final space = uri.queryParameters['space'];
      if (handler == null) {
        return const ApiResponse(501, {
          'error': 'public Space subscriptions unavailable',
        });
      }
      if (space == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(space)) {
        return const ApiResponse(400, {'error': 'valid space required'});
      }
      return _spaceMutationResponse(await handler(space));
    }
    if (method == 'GET' && path == '/v1/spaces/subscription') {
      final handler = spaceSubscription;
      final space = uri.queryParameters['space'];
      if (handler == null) {
        return const ApiResponse(501, {'error': 'subscriptions unavailable'});
      }
      if (space == null || space.isEmpty) {
        return const ApiResponse(400, {'error': 'space required'});
      }
      final value = await handler(space);
      return value == null
          ? const ApiResponse(404, {'error': 'space not found'})
          : ApiResponse(200, value);
    }
    if (method == 'POST' && path == '/v1/spaces/subscription') {
      final updateHandler = updateSpaceSubscription;
      final space = body?['space'];
      if (updateHandler == null) {
        return const ApiResponse(501, {'error': 'subscriptions unavailable'});
      }
      const allowed = {
        'space',
        'feedEnabled',
        'notificationsEnabled',
        'commentNotifications',
        'hiddenFromRecommendations',
      };
      if (body == null || body.keys.any((key) => !allowed.contains(key))) {
        return const ApiResponse(400, {'error': 'unknown subscription field'});
      }
      final explicitFeed = body['feedEnabled'];
      final notifications = body['notificationsEnabled'];
      final commentNotifications = body['commentNotifications'];
      final hidden = body['hiddenFromRecommendations'];
      if (space is! String ||
          space.isEmpty ||
          (body.containsKey('feedEnabled') && explicitFeed is! bool) ||
          (body.containsKey('notificationsEnabled') &&
              notifications is! bool) ||
          (body.containsKey('commentNotifications') &&
              (commentNotifications is! String ||
                  !const {
                    'all',
                    'replies',
                    'none',
                  }.contains(commentNotifications))) ||
          (body.containsKey('hiddenFromRecommendations') && hidden is! bool)) {
        return const ApiResponse(400, {
          'error': 'valid subscription fields required',
        });
      }
      final feed = explicitFeed is bool ? explicitFeed : null;
      if (feed == null &&
          notifications == null &&
          commentNotifications == null &&
          hidden == null) {
        return const ApiResponse(400, {
          'error': 'at least one subscription preference required',
        });
      }
      final error = await updateHandler(
        space,
        feedEnabled: feed,
        notificationsEnabled: notifications as bool?,
        commentNotifications: commentNotifications as String?,
        hiddenFromRecommendations: hidden as bool?,
      );
      return error == null
          ? const ApiResponse(200, {'ok': true})
          : ApiResponse(400, {'error': error});
    }
    if (method == 'GET' && path == '/v1/spaces/invites') {
      final handler = spaceInvites;
      if (handler == null) {
        return const ApiResponse(501, {'error': 'spaces unavailable'});
      }
      return ApiResponse(200, {'invites': await handler()});
    }
    if (method == 'POST' && path == '/v1/spaces/invites') {
      final handler = decideSpaceInvite;
      if (handler == null) {
        return const ApiResponse(501, {'error': 'spaces unavailable'});
      }
      final inviteId = body?['inviteId'];
      final action = body?['action'];
      if (inviteId is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(inviteId) ||
          (action != 'accept' && action != 'decline')) {
        return const ApiResponse(400, {
          'error': 'inviteId + accept/decline action required',
        });
      }
      return _spaceMutationResponse(
        await handler(inviteId, action == 'accept'),
      );
    }
    if (method == 'GET' && path == '/v1/spaces/join-requests') {
      final handler = spaceJoinRequests;
      if (handler == null) {
        return const ApiResponse(501, {'error': 'Space joins unavailable'});
      }
      final result = await handler(uri.queryParameters['space']);
      return result['error'] == null
          ? ApiResponse(200, result)
          : ApiResponse(404, result);
    }
    if (method == 'POST' && path == '/v1/spaces/join-requests') {
      final handler = spaceJoinRequestAction;
      if (handler == null) {
        return const ApiResponse(501, {'error': 'Space joins unavailable'});
      }
      final action = body?['action'];
      final space = body?['space'];
      final requestId = body?['requestId'];
      final code = body?['code'];
      if (action is! String ||
          !const {
            'request',
            'dismiss',
            'approve',
            'decline',
            'create_link',
            'revoke_link',
          }.contains(action) ||
          (space != null && space is! String) ||
          (requestId != null && requestId is! String) ||
          (code != null && (code is! String || code.length > 2048)) ||
          ((action == 'approve' ||
                  action == 'decline' ||
                  action == 'dismiss') &&
              (requestId is! String ||
                  !RegExp(r'^[0-9a-f]{64}$').hasMatch(requestId))) ||
          ((action == 'create_link' || action == 'revoke_link') &&
              (space is! String || space.isEmpty)) ||
          (action == 'request' && (code is! String || code.isEmpty))) {
        return const ApiResponse(400, {
          'error': 'valid Space join request action required',
        });
      }
      final result = await handler(action, space, requestId, code);
      return result.error == null
          ? ApiResponse(200, {
              'ok': true,
              if (result.code != null) 'code': result.code,
            })
          : ApiResponse(400, {'error': result.error});
    }
    if (method == 'GET' && path == '/v1/feed') {
      final handler = spaceFeed;
      if (handler == null) {
        return const ApiResponse(501, {'error': 'community feed unavailable'});
      }
      final before = uri.queryParameters['before'];
      if (before != null && !_validFeedCursor(before)) {
        return const ApiResponse(400, {'error': 'invalid feed cursor'});
      }
      final limit = int.tryParse(uri.queryParameters['limit'] ?? '') ?? 50;
      final pinnedValue = uri.queryParameters['pinned'];
      final bool? pinned = switch (pinnedValue) {
        null => null,
        'true' => true,
        'false' => false,
        _ => null,
      };
      if (pinnedValue != null && pinned == null) {
        return const ApiResponse(400, {'error': 'invalid pinned filter'});
      }
      return ApiResponse(
        200,
        await handler(limit.clamp(1, 200), before, pinned),
      );
    }
    if (method == 'GET' && path == '/v1/feed/filter') {
      final handler = spaceFeedTypeFilter;
      if (handler == null) {
        return const ApiResponse(501, {
          'error': 'feed type preferences unavailable',
        });
      }
      return ApiResponse(200, await handler());
    }
    if (method == 'POST' && path == '/v1/feed/filter') {
      final handler = setSpaceFeedTypeFilter;
      if (handler == null) {
        return const ApiResponse(501, {
          'error': 'feed type preferences unavailable',
        });
      }
      final rawTypes = body?['types'];
      if (rawTypes is! List || rawTypes.any((type) => type is! String)) {
        return const ApiResponse(400, {'error': 'valid types list required'});
      }
      final error = await handler(rawTypes.cast<String>());
      return error == null
          ? const ApiResponse(200, {'ok': true})
          : ApiResponse(400, {'error': error});
    }
    if (method == 'POST' && path == '/v1/feed/hidden') {
      final handler = setSpaceFeedPostHidden;
      if (handler == null) {
        return const ApiResponse(501, {
          'error': 'feed post preferences unavailable',
        });
      }
      final space = body?['space'];
      final postId = body?['postId'];
      final hidden = body?['hidden'];
      if (space is! String ||
          space.isEmpty ||
          postId is! String ||
          !RegExp(r'^[0-9a-f]{64}:[0-9]+$').hasMatch(postId) ||
          hidden is! bool) {
        return const ApiResponse(400, {
          'error': 'valid space + postId + hidden required',
        });
      }
      final error = await handler(space, postId, hidden);
      return error == null
          ? const ApiResponse(200, {'ok': true})
          : ApiResponse(400, {'error': error});
    }
    if (method == 'GET' && path == '/v1/spaces/channels') {
      final space = uri.queryParameters['space'];
      if (space == null || space.isEmpty) {
        return const ApiResponse(400, {'error': 'space required'});
      }
      final handler = spaceChannels;
      if (handler == null) {
        return const ApiResponse(501, {'error': 'Space channels unavailable'});
      }
      final channels = await handler(space);
      return channels == null
          ? const ApiResponse(404, {'error': 'space not found'})
          : ApiResponse(200, {'channels': channels});
    }
    if (method == 'POST' && path == '/v1/spaces/channels') {
      final handler = createSpaceChannel;
      if (handler == null) {
        return const ApiResponse(501, {'error': 'Space channels unavailable'});
      }
      final space = body?['space'];
      final rawName = body?['name'];
      final name = rawName is String ? rawName.trim() : '';
      final kind = body?['kind'] ?? 'text';
      final category = body?['categoryId'];
      // No `?? 0`. An omitted position means the caller had no opinion, and
      // the service then places the channel after its siblings; a 0 here would
      // be an opinion nobody expressed, colliding with the default channel.
      final position = body?['position'];
      final history = body?['history'] ?? 'fromJoin';
      final historySince = body?['historySince'];
      final access = body?['access'] ?? 'space';
      final members = body?['members'] ?? const <Object>[];
      if (space is! String ||
          space.isEmpty ||
          name.isEmpty ||
          name.length > 100 ||
          kind is! String ||
          (category != null && category is! String) ||
          (position != null && position is! int) ||
          history is! String ||
          access is! String ||
          members is! List ||
          members.any((member) => member is! String) ||
          (historySince != null && historySince is! int)) {
        return const ApiResponse(400, {'error': 'invalid channel properties'});
      }
      final result = await handler(
        space,
        name,
        kind,
        category as String?,
        position as int?,
        history,
        historySince as int?,
        access,
        List<String>.from(members),
      );
      return result.error == null
          ? ApiResponse(200, {'ok': true, 'channelId': result.channelId})
          : ApiResponse(400, {'error': result.error});
    }
    if (method == 'PATCH' && path == '/v1/spaces/channels') {
      final handler = updateSpaceChannel;
      if (handler == null) {
        return const ApiResponse(501, {'error': 'Space channels unavailable'});
      }
      final space = body?['space'];
      final channel = body?['channel'];
      const mutableKeys = {
        'name',
        'description',
        'categoryId',
        'position',
        'history',
        'historySince',
      };
      if (space is! String ||
          space.isEmpty ||
          channel is! String ||
          channel.isEmpty ||
          body!.keys.any(
            (key) =>
                key != 'space' &&
                key != 'channel' &&
                !mutableKeys.contains(key),
          )) {
        return const ApiResponse(400, {'error': 'invalid channel properties'});
      }
      final patch = <String, Object?>{
        for (final key in mutableKeys)
          if (body.containsKey(key)) key: body[key],
      };
      if (patch.isEmpty) {
        return const ApiResponse(400, {'error': 'invalid channel properties'});
      }
      final error = await handler(space, channel, patch);
      return error == null
          ? const ApiResponse(200, {'ok': true})
          : ApiResponse(400, {'error': error});
    }
    if (method == 'POST' && path == '/v1/spaces/channels/action') {
      final handler = spaceChannelAction;
      final space = body?['space'];
      final channel = body?['channel'];
      final action = body?['action'];
      if (handler == null) {
        return const ApiResponse(501, {'error': 'Space channels unavailable'});
      }
      if (space is! String ||
          space.isEmpty ||
          channel is! String ||
          channel.isEmpty ||
          action is! String ||
          !const {'archive', 'restore', 'default'}.contains(action)) {
        return const ApiResponse(400, {'error': 'invalid channel action'});
      }
      final error = await handler(space, channel, action);
      return error == null
          ? const ApiResponse(200, {'ok': true})
          : ApiResponse(400, {'error': error});
    }
    if (method == 'POST' && path == '/v1/spaces/channels/members') {
      final handler = setSpaceChannelMembers;
      final space = body?['space'];
      final channel = body?['channel'];
      final members = body?['members'];
      if (handler == null) {
        return const ApiResponse(501, {'error': 'Space channels unavailable'});
      }
      if (space is! String ||
          space.isEmpty ||
          channel is! String ||
          channel.isEmpty ||
          members is! List ||
          members.length > 4096 ||
          members.any((member) => member is! String)) {
        return const ApiResponse(400, {'error': 'invalid channel members'});
      }
      final error = await handler(space, channel, List<String>.from(members));
      return error == null
          ? const ApiResponse(200, {'ok': true})
          : ApiResponse(400, {'error': error});
    }
    if (method == 'GET' && path == '/v1/spaces/channels/messages') {
      final handler = spaceChannelMessages;
      final space = uri.queryParameters['space'];
      final channel = uri.queryParameters['channel'];
      if (handler == null) {
        return const ApiResponse(501, {
          'error': 'Channel messages unavailable',
        });
      }
      if (space == null ||
          space.isEmpty ||
          channel == null ||
          channel.isEmpty) {
        return const ApiResponse(400, {'error': 'space + channel required'});
      }
      final limit = int.tryParse(uri.queryParameters['limit'] ?? '') ?? 50;
      final messages = await handler(space, channel, limit.clamp(1, 500));
      return messages == null
          ? const ApiResponse(404, {'error': 'channel not found'})
          : ApiResponse(200, {'messages': messages});
    }
    if (method == 'POST' && path == '/v1/spaces/channels/messages') {
      final handler = sendSpaceChannelMessage;
      final space = body?['space'];
      final channel = body?['channel'];
      final text = body?['body'];
      final replyTo = body?['replyTo'];
      if (handler == null) {
        return const ApiResponse(501, {
          'error': 'Channel messages unavailable',
        });
      }
      if (space is! String ||
          space.isEmpty ||
          channel is! String ||
          channel.isEmpty ||
          text is! String ||
          text.isEmpty ||
          (replyTo != null &&
              (replyTo is! String ||
                  !RegExp(r'^[0-9a-fA-F]{64}:[0-9]+$').hasMatch(replyTo)))) {
        return const ApiResponse(400, {
          'error': 'space + channel + body required',
        });
      }
      if (utf8.encode(text).length > 512 * 1024) {
        return const ApiResponse(413, {'error': 'channel body too large'});
      }
      final error = await handler(space, channel, text, replyTo as String?);
      return error == null
          ? const ApiResponse(200, {'ok': true})
          : ApiResponse(400, {'error': error});
    }
    if (method == 'GET' && path == '/v1/groups') {
      return ApiResponse(200, {'groups': await groups()});
    }
    if (method == 'POST' && path == '/v1/groups') {
      final rawName = body?['name'];
      final name = rawName is String ? rawName.trim() : '';
      if (name.isEmpty || name.length > 64) {
        return const ApiResponse(400, {'error': 'name required (max 64)'});
      }
      final groupId = await createGroup(name);
      return groupId == null
          ? const ApiResponse(400, {'error': 'group creation failed'})
          : ApiResponse(200, {'ok': true, 'groupId': groupId});
    }
    if (method == 'GET' && path == '/v1/groups/messages') {
      final group = uri.queryParameters['group'];
      if (group == null || group.isEmpty) {
        return const ApiResponse(400, {'error': 'group required'});
      }
      final limit = int.tryParse(uri.queryParameters['limit'] ?? '') ?? 50;
      final messages = await groupMessages(group, limit.clamp(1, 500));
      return messages == null
          ? const ApiResponse(404, {'error': 'group not found'})
          : ApiResponse(200, {'messages': messages});
    }
    if (method == 'POST' && path == '/v1/groups/messages') {
      final group = body?['group'];
      final text = body?['body'];
      final replyTo = body?['replyTo'];
      if (group is! String ||
          group.isEmpty ||
          text is! String ||
          text.isEmpty ||
          (replyTo != null &&
              (replyTo is! String ||
                  !RegExp(r'^[0-9a-fA-F]{64}:[0-9]+$').hasMatch(replyTo)))) {
        return const ApiResponse(400, {'error': 'group + body required'});
      }
      if (utf8.encode(text).length > 512 * 1024) {
        return const ApiResponse(413, {'error': 'group body too large'});
      }
      final err = await sendGroupMessage(group, text, replyTo as String?);
      return err == null
          ? const ApiResponse(200, {'ok': true})
          : ApiResponse(400, {'error': err});
    }
    if (method == 'POST' && path == '/v1/groups/files') {
      final group = body?['group'];
      final filePath = body?['path'];
      final name = body?['name'];
      final caption = body?['caption'] ?? '';
      final replyTo = body?['replyTo'];
      if (group is! String ||
          group.isEmpty ||
          filePath is! String ||
          filePath.isEmpty ||
          (name != null && name is! String) ||
          caption is! String ||
          (replyTo != null &&
              (replyTo is! String ||
                  !RegExp(r'^[0-9a-fA-F]{64}:[0-9]+$').hasMatch(replyTo)))) {
        return const ApiResponse(400, {
          'error': 'group + path required; optional name/caption/replyTo',
        });
      }
      if (utf8.encode(caption).length > 512 * 1024) {
        return const ApiResponse(413, {'error': 'group caption too large'});
      }
      // Optional authoring metadata: what this upload IS, and the little a
      // reader needs to lay it out. Absent, the host keeps its old guess.
      final kind = body?['kind'];
      final width = body?['width'];
      final height = body?['height'];
      final durationMs = body?['durationMs'];
      if ((kind != null && kind is! String) ||
          (width != null && width is! int) ||
          (height != null && height is! int) ||
          (durationMs != null && durationMs is! int)) {
        return const ApiResponse(400, {
          'error': 'kind must be a string; width/height/durationMs ints',
        });
      }
      // Same capability as the 1:1 send (audit XV-08). The finding named
      // `/v1/files`, but this route takes a path too and reaches a wider
      // audience — closing one and leaving the other would be theatre.
      final sendable = await _sendablePath(auth, filePath);
      if (sendable.refusal != null) return sendable.refusal!;
      final result = await sendGroupFile(
        group,
        sendable.path!,
        name as String?,
        caption,
        replyTo as String?,
        auth.fileRoots,
        kind: kind as String?,
        width: width as int?,
        height: height as int?,
        durationMs: durationMs as int?,
      );
      return result.error == null
          ? ApiResponse(200, {'ok': true, 'contentId': result.contentId})
          : _groupFileError(result.error!);
    }
    if (method == 'POST' && path == '/v1/groups/files/fetch') {
      final group = body?['group'];
      final message = body?['messageId'];
      if (group is! String ||
          group.isEmpty ||
          message is! String ||
          !RegExp(r'^[0-9a-fA-F]{64}:[0-9]+$').hasMatch(message)) {
        return const ApiResponse(400, {'error': 'group + messageId required'});
      }
      final error = await fetchGroupFile(group, message);
      return error == null
          ? const ApiResponse(200, {'ok': true, 'started': true})
          : _groupFileError(error);
    }
    if (method == 'GET' && path == '/v1/groups/files/download') {
      final group = uri.queryParameters['group'];
      final message = uri.queryParameters['messageId'];
      if (group == null ||
          group.isEmpty ||
          message == null ||
          !RegExp(r'^[0-9a-fA-F]{64}:[0-9]+$').hasMatch(message)) {
        return const ApiResponse(400, {'error': 'group + messageId required'});
      }
      final result = await loadGroupFile(group, message);
      return result.error == null
          ? ApiResponse.blob(result.source!)
          : _groupFileError(result.error!);
    }
    if (method == 'GET' &&
        (path == '/v1/spaces/members' || path == '/v1/groups/members')) {
      final isSpace = path == '/v1/spaces/members';
      final scope = uri.queryParameters[isSpace ? 'space' : 'group'];
      if (scope == null || scope.isEmpty) {
        return ApiResponse(400, {
          'error': isSpace ? 'space required' : 'group required',
        });
      }
      final roster = await groupMembers(scope, isSpace);
      if (roster == null) {
        return ApiResponse(404, {
          'error': isSpace ? 'space not found' : 'group not found',
        });
      }
      if (!isSpace) return ApiResponse(200, roster);
      final spaceRoster = Map<String, dynamic>.from(roster);
      spaceRoster['spaceId'] = spaceRoster.remove('groupId');
      return ApiResponse(200, spaceRoster);
    }
    if (method == 'POST' &&
        (path == '/v1/spaces/members' || path == '/v1/groups/members')) {
      final isSpace = path == '/v1/spaces/members';
      final scope = body?[isSpace ? 'space' : 'group'];
      final action = body?['action'];
      final peer = body?['peer'];
      final role = body?['role'];
      final actions = {
        if (isSpace) 'invite' else 'add',
        'remove',
        'set_role',
        'mute',
        'unmute',
        if (isSpace) 'transfer_owner',
      };
      const roles = {'admin', 'member'};
      final roleRequired =
          action == 'invite' || action == 'add' || action == 'set_role';
      if (scope is! String ||
          scope.isEmpty ||
          action is! String ||
          !actions.contains(action) ||
          peer is! String ||
          !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(peer) ||
          (roleRequired && (role is! String || !roles.contains(role))) ||
          (!roleRequired && role != null)) {
        return ApiResponse(400, {
          'error': isSpace
              ? 'space + action + peer required; role for invite/set_role'
              : 'group + action + peer required; role for add/set_role',
        });
      }
      final error = await groupMemberAction(
        scope,
        action,
        peer,
        role as String?,
        isSpace,
      );
      return isSpace
          ? _spaceMutationResponse(error)
          : _groupMutationResponse(error);
    }
    if (method == 'GET' && path == '/v1/spaces/access') {
      if (spaceAccess == null) {
        return const ApiResponse(501, {'error': 'Space access unavailable'});
      }
      final space = uri.queryParameters['space'];
      if (space == null || space.isEmpty) {
        return const ApiResponse(400, {'error': 'space required'});
      }
      final policy = await spaceAccess!(space);
      return policy == null
          ? const ApiResponse(404, {'error': 'space not found'})
          : ApiResponse(200, policy);
    }
    if (method == 'POST' && path == '/v1/spaces/access') {
      if (spaceAccessAction == null) {
        return const ApiResponse(501, {'error': 'Space access unavailable'});
      }
      final space = body?['space'];
      if (space is! String || space.isEmpty || body == null) {
        return const ApiResponse(400, {
          'error': 'space + action + expectedRevision required',
        });
      }
      final error = await spaceAccessAction!(
        space,
        Map<String, dynamic>.from(body),
      );
      return _spaceMutationResponse(error);
    }
    if (method == 'GET' && path == '/v1/spaces/policies/audit') {
      if (spacePolicyAudit == null) {
        return const ApiResponse(501, {
          'error': 'Space policy audit unavailable',
        });
      }
      final space = uri.queryParameters['space'];
      if (space == null || space.isEmpty) {
        return const ApiResponse(400, {'error': 'space required'});
      }
      final audit = await spacePolicyAudit!(space);
      return audit == null
          ? const ApiResponse(404, {'error': 'space not found'})
          : ApiResponse(200, audit);
    }
    if (method == 'POST' &&
        (path == '/v1/spaces/name' || path == '/v1/groups/name')) {
      final isSpace = path == '/v1/spaces/name';
      final scope = body?[isSpace ? 'space' : 'group'];
      final rawName = body?['name'];
      final name = rawName is String ? rawName.trim() : '';
      if (scope is! String ||
          scope.isEmpty ||
          name.isEmpty ||
          name.length > 64) {
        return ApiResponse(400, {
          'error': isSpace
              ? 'space + name required (name max 64)'
              : 'group + name required (name max 64)',
        });
      }
      final error = await renameGroup(scope, name, isSpace);
      return isSpace
          ? _spaceMutationResponse(error)
          : _groupMutationResponse(error);
    }
    if (method == 'POST' &&
        (path == '/v1/spaces/leave' || path == '/v1/groups/leave')) {
      final isSpace = path == '/v1/spaces/leave';
      final scope = body?[isSpace ? 'space' : 'group'];
      if (scope is! String || scope.isEmpty) {
        return ApiResponse(400, {
          'error': isSpace ? 'space required' : 'group required',
        });
      }
      final error = await leaveGroup(scope, isSpace);
      return isSpace
          ? _spaceMutationResponse(error)
          : _groupMutationResponse(error);
    }
    if (method == 'GET' && path == '/v1/groups/calls') {
      return ApiResponse(200, {'call': groupCallState()});
    }
    if (method == 'POST' && path == '/v1/groups/calls') {
      final group = body?['group'];
      final media = body?['media'] ?? 'audio';
      const mediaKinds = {'audio', 'video', 'screen'};
      if (group is! String ||
          !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(group) ||
          media is! String ||
          !mediaKinds.contains(media)) {
        return const ApiResponse(400, {
          'error': '64-hex group + audio|video|screen media required',
        });
      }
      return _groupCallResponse(await startGroupCall(group, media));
    }
    if (method == 'POST' && path == '/v1/spaces/voice-sessions') {
      final start = startSpaceVoiceSession;
      if (start == null || !groupCallsAvailable) {
        return const ApiResponse(501, {
          'error': 'group calls unavailable on this host',
        });
      }
      final space = body?['space'];
      final channel = body?['channel'];
      final media = body?['media'] ?? 'audio';
      const mediaKinds = {'audio', 'video', 'screen'};
      final id = RegExp(r'^[0-9a-fA-F]{64}$');
      if (space is! String ||
          !id.hasMatch(space) ||
          channel is! String ||
          !id.hasMatch(channel) ||
          media is! String ||
          !mediaKinds.contains(media)) {
        return const ApiResponse(400, {
          'error': '64-hex space + channel and audio|video|screen required',
        });
      }
      return _groupCallResponse(await start(space, channel, media));
    }
    if (method == 'POST' &&
        (path == '/v1/groups/calls/join' ||
            path == '/v1/groups/calls/decline' ||
            path == '/v1/groups/calls/leave' ||
            path == '/v1/groups/calls/end')) {
      return _groupCallResponse(await groupCallAction(path.split('/').last));
    }
    if (method == 'POST' && path == '/v1/groups/calls/posture') {
      final mic = body?['mic'];
      final camera = body?['camera'];
      final screen = body?['screen'];
      if ((mic == null && camera == null && screen == null) ||
          (mic != null && mic is! bool) ||
          (camera != null && camera is! bool) ||
          (screen != null && screen is! bool)) {
        return const ApiResponse(400, {
          'error': 'at least one boolean mic|camera|screen required',
        });
      }
      return _groupCallResponse(
        await groupCallPosture(mic as bool?, camera as bool?, screen as bool?),
      );
    }
    if (method == 'POST' && path == '/v1/files') {
      final to = body?['to'];
      final filePath = body?['path'];
      if (to is! String ||
          to.isEmpty ||
          filePath is! String ||
          filePath.isEmpty) {
        return const ApiResponse(400, {'error': 'to + path required'});
      }
      final sendable = await _sendablePath(auth, filePath);
      if (sendable.refusal != null) return sendable.refusal!;
      final name = body?['name'];
      // The RESOLVED path goes downstream — a NAME, not a handle. The send
      // opens that name again, so what it opens is what the name means THEN,
      // not what was checked here. This leg AUTHORIZES; the open is bracketed
      // by identity stamps in `veilOpenPinnedSource`, which refuses a name
      // that changed under it before anything is offered (audit X-01), and
      // what is left of the window is detected across the read (X-02).
      final err = await sendFile(
        to,
        sendable.path!,
        name is String ? name : null,
        auth.fileRoots,
      );
      return err == null
          ? const ApiResponse(200, {'ok': true})
          : ApiResponse(400, {'error': err});
    }
    // The missing middle step, mirroring `/v1/groups/files/fetch`: a received
    // file is an OFFER until somebody asks for the bytes, and a bot had no way
    // to ask. Keyed by (peer, messageId) rather than a bare content hash for
    // the same reason the group route is — see [fetchFile].
    if (method == 'POST' && path == '/v1/files/fetch') {
      final peer = body?['peer'];
      final message = body?['messageId'];
      if (peer is! String ||
          !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(peer) ||
          message is! String ||
          message.isEmpty) {
        return const ApiResponse(400, {'error': 'peer + messageId required'});
      }
      final error = await fetchFile(peer, message);
      return error == null
          ? const ApiResponse(200, {'ok': true, 'started': true})
          : _directFileError(error);
    }
    if (method == 'GET' && path == '/v1/files/download') {
      final fileId = uri.queryParameters['fileId'];
      if (fileId == null || fileId.isEmpty) {
        return const ApiResponse(400, {'error': 'fileId required'});
      }
      final source = await loadFile(fileId);
      return source == null
          ? const ApiResponse(404, {'error': 'not found'})
          : ApiResponse.blob(source);
    }
    if (path.startsWith('/v1/calls') && !callsAvailable) {
      return const ApiResponse(501, {
        'error': 'calls unavailable on this host',
      });
    }
    if (method == 'GET' && path == '/v1/calls') {
      return ApiResponse(200, {'call': callState()});
    }
    if (method == 'POST' && path == '/v1/calls') {
      final to = body?['to'];
      if (to is! String || to.isEmpty) {
        return const ApiResponse(400, {'error': 'to required'});
      }
      final media = body?['media'];
      final err = await placeCall(to, media is String ? media : 'audio');
      return err == null
          ? ApiResponse(200, {'call': callState()})
          : ApiResponse(400, {'error': err});
    }
    if (method == 'POST' &&
        (path == '/v1/calls/hangup' ||
            path == '/v1/calls/accept' ||
            path == '/v1/calls/reject')) {
      await callAction(path.split('/').last);
      return ApiResponse(200, {'call': callState()});
    }
    // Webhook: push incoming events to a LOOPBACK URL (the bot's local
    // server) instead of holding a WebSocket open.
    if (path == '/v1/webhook' && webhook != null && setWebhook != null) {
      if (method == 'GET') {
        return ApiResponse(200, {'url': webhook!()});
      }
      if (method == 'POST') {
        final url = body?['url'];
        if (url is! String || url.isEmpty) {
          return const ApiResponse(400, {'error': 'url required'});
        }
        final err = webhookUrlError(url);
        if (err != null) return ApiResponse(400, {'error': err});
        await setWebhook!(url);
        return ApiResponse(200, {'ok': true, 'url': url});
      }
      if (method == 'DELETE') {
        await setWebhook!(null);
        return const ApiResponse(200, {'ok': true});
      }
    }
    return const ApiResponse(404, {'error': 'not found'});
  }

  ApiResponse _groupMutationResponse(String? error) {
    if (error == null) return const ApiResponse(200, {'ok': true});
    final status = switch (error) {
      'group not found' => 404,
      'member not found' => 404,
      'operation rejected by group policy' => 403,
      'member already exists' => 409,
      'group mutation failed' => 409,
      _ => 400,
    };
    return ApiResponse(status, {'error': error});
  }

  ApiResponse _spaceMutationResponse(String? error) {
    if (error == null) return const ApiResponse(200, {'ok': true});
    final status = switch (error) {
      'group not found' || 'space not found' => 404,
      'member not found' => 404,
      'operation rejected by group policy' ||
      'operation rejected by space policy' => 403,
      'member already exists' => 409,
      'group mutation failed' || 'space mutation failed' => 409,
      _ => 400,
    };
    final spaceError = switch (error) {
      'group not found' => 'space not found',
      'operation rejected by group policy' =>
        'operation rejected by space policy',
      'group mutation failed' => 'space mutation failed',
      _ => error,
    };
    return ApiResponse(status, {'error': spaceError});
  }

  ApiResponse _groupFileError(String error) {
    final status = switch (error) {
      'group not found' => 404,
      'group message attachment not found' => 404,
      'source not found' => 404,
      'not a writable group member' => 403,
      'group file too large' => 413,
      'group mutation failed' => 409,
      'group content fetch unavailable' => 409,
      'group content fetch failed' => 500,
      'group content not downloaded' => 409,
      'group content load failed' => 500,
      'content registration failed' => 500,
      _ => 400,
    };
    return ApiResponse(status, {'error': error});
  }

  /// Status for a 1:1 file-fetch failure. The same three shapes the group pair
  /// uses: a handle that names nothing is 404, a fetch with no reachable source
  /// is 409 (ask again later — the sender may come back), a broken store is
  /// 500.
  ApiResponse _directFileError(String error) {
    final status = switch (error) {
      'message attachment not found' => 404,
      'file fetch unavailable' => 409,
      'message attachment load failed' => 500,
      'file fetch failed' => 500,
      _ => 400,
    };
    return ApiResponse(status, {'error': error});
  }

  ApiResponse _groupCallResponse(String? error) {
    if (error == null) return ApiResponse(200, {'call': groupCallState()});
    final status = switch (error) {
      'group not found' => 404,
      'operation rejected by group policy' => 403,
      'group call unavailable' => 409,
      'group call action unavailable' => 409,
      'group call media unavailable' => 409,
      'screen share unavailable' => 409,
      _ => 400,
    };
    return ApiResponse(status, {'error': error});
  }
}

/// Binds [ApiHandler] to a loopback HTTP socket. [_events] is a broadcast
/// stream of JSON-able events pushed to every authenticated `/v1/events`
/// WebSocket subscriber (the bot event feed).
/// Outcome of reading a request body: the text, or the status to answer with.
///
/// Kept apart rather than collapsed into a nullable string, because 413 and 408
/// mean different things to the caller — the old `null` could only say "too
/// large", which would be a lie for a body that simply never finished arriving.
class _BodyOutcome {
  const _BodyOutcome._(this.text, this.status);

  const _BodyOutcome.text(String value) : this._(value, null);

  /// The caller sent more than the cap.
  static const tooLarge = _BodyOutcome._(null, 413);

  /// The caller did not finish inside the deadline.
  static const timedOut = _BodyOutcome._(null, 408);

  final String? text;

  /// Null when the body was read; the HTTP status to refuse with otherwise.
  final int? status;
}

/// One `/v1/events` subscriber, and the token that authorised it.
///
/// The socket used to be anonymous once upgraded (audit XV-10): nothing tied
/// it back to a token, so revoking that token, switching off the API or moving
/// to another identity left it connected and being fed. Binding it to the
/// token id is what makes "close what this token opened" expressible at all.
/// A [Socket] that counts the RAW BYTES a peer pushes at us and destroys the
/// connection past [ceiling] (audit XV-M2).
///
/// ## Why the count has to live down here
///
/// The event feed already charges a subscriber for what it sends, but it does
/// so in the `ws.listen` callback — which `dart:io` reaches only after it has
/// JOINED every frame of a message. `websocket_impl.dart` assembles into a
/// `BytesBuilder(copy: false)` with no length check anywhere on the path, and
/// `WebSocketTransformer.upgrade` exposes no size parameter to supply one. So
/// one message that never ends — FIN=0, then continuation frames forever —
/// allocates without bound, and no counting the handler can do happens in
/// time, because the allocation is what delivers the message.
///
/// A counter on the SOCKET has no such ordering problem. The assembly buffer
/// can only ever hold bytes that crossed the socket, so bounding those bounds
/// it, and it does so without knowing anything about framing: no opcode, no
/// length field, no continuation state to be wrong about.
///
/// Past the ceiling the connection is DESTROYED rather than closed politely. A
/// WebSocket close is a handshake, and a peer that is mid-message and not
/// listening is exactly the peer that will not complete one; waiting for it
/// would mean holding the buffer we are trying to drop.
///
/// The overriding is deliberately one method wide. `dart:io` touches the
/// socket only as a stream (`transformer.bind`), and through `addStream`,
/// `close` and `destroy` on the way out — all of which delegate untouched, so
/// this class changes what the socket ADMITS and nothing about what it is.
class _CappedSocket extends Stream<Uint8List> implements Socket {
  _CappedSocket(this._inner, this.ceiling);

  final Socket _inner;

  /// Raw bytes this peer may send before the connection is destroyed.
  final int ceiling;

  int _read = 0;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _inner.listen(
      (chunk) {
        _read += chunk.length;
        if (_read > ceiling) {
          // NOT FORWARDED, and that is the whole point: the chunk that crosses
          // the line is the one that must not reach the assembly buffer. The
          // destroy below fires `onDone` through the inner stream, so the
          // WebSocket above still learns the connection is over and the
          // subscription slot comes back through the ordinary path.
          _inner.destroy();
          return;
        }
        onData?.call(chunk);
      },
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  Encoding get encoding => _inner.encoding;
  @override
  set encoding(Encoding value) => _inner.encoding = value;
  @override
  void add(List<int> data) => _inner.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);
  @override
  Future<void> addStream(Stream<List<int>> stream) => _inner.addStream(stream);
  @override
  Future<void> flush() => _inner.flush();
  @override
  Future<void> close() => _inner.close();
  @override
  Future<void> get done => _inner.done;
  @override
  void write(Object? object) => _inner.write(object);
  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      _inner.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => _inner.writeCharCode(charCode);
  @override
  void writeln([Object? object = '']) => _inner.writeln(object);
  @override
  void destroy() => _inner.destroy();
  @override
  bool setOption(SocketOption option, bool enabled) =>
      _inner.setOption(option, enabled);
  @override
  Uint8List getRawOption(RawSocketOption option) =>
      _inner.getRawOption(option);
  @override
  void setRawOption(RawSocketOption option) => _inner.setRawOption(option);
  @override
  InternetAddress get address => _inner.address;
  @override
  int get port => _inner.port;
  @override
  InternetAddress get remoteAddress => _inner.remoteAddress;
  @override
  int get remotePort => _inner.remotePort;
}

class _LiveSocket {
  _LiveSocket(this.socket, this.tokenId);

  final WebSocket socket;
  final String tokenId;
  StreamSubscription<Map<String, dynamic>>? events;
  StreamController<String>? queue;

  /// The `addStream` that pumps [queue] into [socket]. Held because a
  /// `WebSocket` still bound to an `addStream` REFUSES to close — measured:
  /// `close()` throws `StateError: StreamSink is bound to a stream`, and
  /// closing the queue is not enough on its own, the pump has to have noticed.
  Future<void>? pump;

  /// The one shutdown in flight, so a second caller joins it instead of
  /// starting another. Two of the three ways in — an overflowing queue and a
  /// subscriber that will not stop talking — fire from inside a stream
  /// callback that can be re-entered before the first pass has cancelled
  /// anything, and a second pass would race the first over the same sink.
  Future<void>? _closing;

  /// Stop feeding this subscriber, then close it. Idempotent.
  ///
  /// CANCEL FIRST, close second. The close handshake needs the peer to play
  /// along; cancelling the event subscription does not. On revoke the property
  /// that matters is that no further event reaches this socket, so it must not
  /// depend on the other end being cooperative.
  Future<void> shutdown(int code, String reason) =>
      _closing ??= _shutdown(code, reason);

  Future<void> _shutdown(int code, String reason) async {
    final sub = events;
    events = null;
    await sub?.cancel();
    final q = queue;
    queue = null;
    await q?.close();
    final inFlight = pump;
    pump = null;
    try {
      await inFlight?.timeout(const Duration(seconds: 2));
    } catch (_) {
      /* the pump already failed; the sink is free either way */
    }
    try {
      await socket.close(code, reason).timeout(const Duration(seconds: 2));
    } catch (_) {
      // A peer that will not complete the handshake still stops receiving,
      // which is the half that carries the guarantee.
    }
  }
}

class ApiServer {
  /// [bodyDeadline], [maxInFlight], [maxLiveSockets] and [maxQueuedEvents] are
  /// overridable for tests only.
  ///
  /// All four defend against a caller who is patient rather than large, and
  /// all four are unreachable in a test at their production values — a
  /// 30-second wait per assertion, 33 sockets held open at once, 17 event
  /// feeds, or half a thousand events stalled behind a reader that has to be
  /// genuinely back-pressured for them to pile up at all. Injecting them keeps
  /// the limits covered instead of merely described.
  ApiServer(
    this._handler,
    this._events, {
    Duration? bodyDeadline,
    Duration? writeIdleDeadline,
    int? maxInFlight,
    int? maxLiveSockets,
    int? maxQueuedEvents,
  })  : _bodyDeadline = bodyDeadline ?? _defaultBodyDeadline,
        _writeIdleDeadline = writeIdleDeadline ?? _defaultWriteIdleDeadline,
        _maxInFlight = maxInFlight ?? _defaultMaxInFlight,
        _maxLiveSockets = maxLiveSockets ?? _defaultMaxLiveSockets,
        _maxQueuedEvents = maxQueuedEvents ?? _defaultMaxQueuedEvents;

  final ApiHandler _handler;
  final Stream<Map<String, dynamic>> _events;
  HttpServer? _server;

  /// Whether [stop] has run. A stopped server stays stopped.
  ///
  /// `stop` can only close what [start] has already adopted, and binding is not
  /// instant: a stop that lands between the bind returning and the socket being
  /// adopted found nothing to close, and the adoption then went ahead. The
  /// result was a listening socket that belonged to nobody — still answering
  /// with the tokens it was built with, while the controller that would have
  /// torn it down had already cleared its reference to it.
  bool _stopped = false;

  /// Awaited between binding the socket and adopting it. Null in production;
  /// a test uses it to hold that window open, and it is cleared on use so only
  /// the first bind waits.
  ///
  /// Static because the instance under test is the one the controller builds
  /// for itself, which a test never gets to touch before it starts.
  static Future<void> Function()? debugAdoptGate;

  bool get running => _server != null;
  int? get port => _server?.port;

  /// Requests being read or served at once.
  ///
  /// A cap on body SIZE bounds one request; nothing bounded how many a caller
  /// could have in flight, so the real ceiling was `_maxBodyBytes` × however
  /// many sockets they cared to open. Loopback callers are this app's own
  /// tooling and bots; a handful of concurrent calls is generous, and past it
  /// the honest answer is 503 rather than accepting work we will queue behind
  /// everything else.
  static const _defaultMaxInFlight = 32;
  final int _maxInFlight;

  /// How long one chunk of a blob may fail to move before the transfer is
  /// abandoned.
  ///
  /// `flush()` is the backpressure that keeps a big file out of memory, and it
  /// resolves as the socket drains — so a client that simply stops reading
  /// makes it never resolve, and the in-flight slot is held for as long as
  /// that client cares to wait. `_maxInFlight` of them wedges the whole local
  /// API, and a read-only token is enough to do it: the reads are ordinary
  /// GETs.
  ///
  /// Idle rather than total: a legitimately slow reader that keeps taking
  /// bytes is never cut off however long the file is. This fires only when
  /// NOTHING moves.
  static const _defaultWriteIdleDeadline = Duration(seconds: 30);
  final Duration _writeIdleDeadline;
  int _inFlight = 0;

  /// Concurrent `/v1/events` subscriptions (audit XV-14).
  ///
  /// Separate from the request cap because these are long-lived by design:
  /// counting them together would let a few idle feeds starve ordinary calls,
  /// and not counting them at all is what let a token holder exhaust
  /// descriptors.
  static const _defaultMaxLiveSockets = 16;
  final int _maxLiveSockets;
  int _liveSockets = 0;

  /// The subscribers currently connected, each bound to the token that opened
  /// it (audit XV-10). Small by construction — [_maxLiveSockets] bounds it.
  final _live = <_LiveSocket>[];

  /// Awaited between the subscription check and the upgrade. Null in
  /// production; a test uses it to hold that window open.
  ///
  /// The window is the whole finding, and it is INVISIBLE to an ordinary test:
  /// on loopback a handshake finishes before the next request is dispatched,
  /// so the interleaving that broke the cap in production never occurs in a
  /// suite, and a race test written without this passes against the bug. The
  /// seam makes "the upgrade takes time" something the test states rather than
  /// something it hopes the scheduler provides.
  Future<void> Function()? debugUpgradeGate;

  /// Events one subscriber may leave un-taken before it is disconnected.
  /// `WebSocket.add` buffers without bound, so a client that stops reading is
  /// otherwise a heap leak driven by someone else's traffic.
  static const _defaultMaxQueuedEvents = 512;
  final int _maxQueuedEvents;

  /// Close code for a subscriber dropped for falling behind.
  ///
  /// 1013 ("try again later") is the code this means, and dart:io WILL NOT
  /// SEND IT — measured: `WebSocket.close(1013, …)` fails with
  /// `WebSocketException: Reserved status code 1013`, because dart:io refuses
  /// 1012-1014 outright. So the drop had TWO ways of not happening, and fixing
  /// only the `StateError` half would have left the socket just as connected.
  ///
  /// The private range (4000-4999) is the one dart:io will carry, and 4013
  /// keeps the meaning legible. It must not be folded into the 1008 used for
  /// a revoked token: those two call for OPPOSITE reactions — a bot that fell
  /// behind should reconnect, and a bot whose token is gone should not — so a
  /// shared code would teach the well-behaved bot to give up its feed for
  /// good.
  static const kEventFeedTooSlowCloseCode = 4013;

  /// Bytes a subscriber may send US before it is hung up (audit X-08).
  ///
  /// The `/v1/events` feed is one-way: a well-behaved client sends nothing at
  /// all after the handshake, and dart:io answers pings itself without them
  /// reaching the handler. So this is not a quota anyone has to fit inside —
  /// it is slack, generous enough that no ordinary client could trip it and
  /// small enough that nobody can rent the process's memory through a channel
  /// that has no use for what they send.
  ///
  /// ## What this budget does NOT bound, and why
  ///
  /// It is counted AFTER each message is materialised, so ONE message larger
  /// than the whole budget is allocated in full before it is ever charged.
  /// That is not an oversight and it is not fixable HERE: `dart:io` exposes no
  /// per-message ceiling on a `WebSocket`. It joins every frame of a message
  /// into one `String`/`List<int>` and only then delivers it, so any counting
  /// this class can do necessarily happens downstream of the allocation. What
  /// the budget bounds is the SUM across messages, which is what stops a drip
  /// feed.
  ///
  /// A single endless message is bounded a layer DOWN, by
  /// [kEventFeedRawSocketCeiling] — see `_CappedSocket`. That is why this one
  /// gets to stay the precise rule: it is the one that says what a subscriber
  /// may send, and the raw ceiling only says what it may make us hold while
  /// saying it.
  ///
  /// What took the teeth out of the remainder in the meantime is compression
  /// being OFF (see the upgrade below). The danger was amplification — a few
  /// kilobytes of zeros on the wire inflating to gigabytes in here, with no
  /// ratio limit — and without deflate a peer now has to actually send every
  /// byte it wants us to hold.
  ///
  /// ## Why the inbound stream is listened to at all
  ///
  /// The audit's remedy was to replace this with a one-way event stream, so
  /// there would be no inbound side to bound. DECLINED, for the reason
  /// recorded further down at `ws.listen`: on a SERVER-side socket `ws.done`
  /// does not complete when the peer disconnects — measured — and the inbound
  /// stream is the only thing that reports it. Dropping the listener puts the
  /// subscription cap back to counting only upwards, which is the bug where
  /// sixteen ordinary bot reconnects wedged the feed at 503 until the app was
  /// restarted. The inbound stream is not read for its data. It is the
  /// disconnect signal, and there is no other.
  static const kEventFeedInboundByteBudget = 64 * 1024;

  /// Raw bytes a subscriber may push across the SOCKET before the connection
  /// is destroyed (audit XV-M2). The backstop under
  /// [kEventFeedInboundByteBudget], enforced by `_CappedSocket`.
  ///
  /// STRICTLY ABOVE the app-level budget, and the order matters more than
  /// either number. A subscriber that sends too much should be answered by the
  /// rule that is written down — a 1008 close saying the feed is not an upload
  /// — not by having its connection torn out from under it. Set this below 64
  /// KiB and the raw cap starts firing first, so honest clients meet the blunt
  /// instrument and the documented budget becomes unreachable.
  ///
  /// 256 KiB leaves room for the budget plus frame headers, masks and the
  /// slack of a peer that sends its last message in one piece. It does not
  /// need tuning: nothing legitimate sends anything here at all.
  static const kEventFeedRawSocketCeiling = 256 * 1024;

  /// RFC 6455's handshake constant, concatenated with the client's key and
  /// hashed to prove we understood the request.
  static const _webSocketGuid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

  /// The upgrade `WebSocketTransformer.upgrade` would do, with the socket
  /// wrapped in a byte cap on the way past (audit XV-M2).
  ///
  /// By hand because there is no seam: the transformer detaches the socket and
  /// hands it to the `WebSocket` in one step, with nothing in between to wrap
  /// and no size parameter to pass instead. The steps below mirror
  /// `websocket_impl.dart` exactly — 101, `Connection: Upgrade`, `Upgrade:
  /// websocket`, and `Sec-WebSocket-Accept` over the client's key.
  ///
  /// Nothing is validated here because `WebSocketTransformer.isUpgradeRequest`
  /// already did it at the gate: method, both handshake headers, version 13
  /// and the presence of the key. Re-checking would be a second opinion on the
  /// same headers; the `!` below is that check's guarantee, not an assumption.
  ///
  /// No `Sec-WebSocket-Extensions` goes out, which is how deflate stays off —
  /// the same outcome `CompressionOptions.compressionOff` bought before, now
  /// by simply never agreeing to it.
  Future<WebSocket> _upgradeCapped(HttpRequest req) async {
    final key = req.headers.value('Sec-WebSocket-Key')!;
    final accept = base64Encode(
      crypto.sha1.convert(utf8.encode('$key$_webSocketGuid')).bytes,
    );
    final res = req.response
      ..statusCode = HttpStatus.switchingProtocols
      ..headers.add(HttpHeaders.connectionHeader, 'Upgrade')
      ..headers.add(HttpHeaders.upgradeHeader, 'websocket')
      ..headers.add('Sec-WebSocket-Accept', accept);
    res.headers.contentLength = 0;
    final sock = await res.detachSocket();
    return WebSocket.fromUpgradedSocket(
      _CappedSocket(sock, kEventFeedRawSocketCeiling),
      // SERVER SIDE. Left off, the socket masks everything it sends — which is
      // what a CLIENT does — and every subscriber drops the feed as a protocol
      // error.
      serverSide: true,
      compression: CompressionOptions.compressionOff,
    );
  }

  Future<int?> start(int port) async {
    if (_server != null) return _server!.port;
    // EXCLUSIVE bind. `shared: true` maps to SO_REUSEPORT, which load-balances
    // new connections across every socket bound to the port — including one
    // opened by another process of the same user. That process would receive a
    // share of the client's requests, bearer token and all, and could answer
    // them. A local control plane must fail loudly on a busy port instead of
    // quietly splitting traffic with whoever got there first.
    final s = await HttpServer.bind(
      InternetAddress.loopbackIPv4, // LOOPBACK ONLY (privacy canon)
      port,
      shared: false,
    );
    final gate = debugAdoptGate;
    if (gate != null) {
      debugAdoptGate = null;
      await gate();
    }
    if (_stopped) {
      // Stopped while this bind was in flight. `stop` had nothing to close, so
      // adopting now would leave a socket listening that nobody holds.
      await s.close(force: true);
      return null;
    }
    _server = s;
    unawaited(s.forEach(_onRequest));
    return s.port;
  }

  /// Every request body this API accepts is a small JSON object — even the
  /// any-size file endpoints take a local PATH, never bytes. 4 MiB is far above
  /// anything legitimate and still a hard ceiling on what one caller can make
  /// the app hold.
  static const _maxBodyBytes = 4 * 1024 * 1024;

  /// The body as text, or null if the caller sent more than [_maxBodyBytes].
  ///
  /// Counted as it arrives rather than trusted from `Content-Length`: a chunked
  /// request declares no length, and a declared one is the caller's claim, not
  /// a limit on what they then send.
  ///
  /// Past the cap it keeps consuming but stops KEEPING, which is the part that
  /// mattered — memory stays flat while the sender wastes their own bandwidth.
  /// Abandoning the stream instead would be cheaper still and unusable: the
  /// unread remainder makes Dart tear the connection down, and the caller sees
  /// "connection closed before full header" rather than the refusal.
  /// How long an AUTHENTICATED caller gets to finish sending a body.
  ///
  /// The cap bounded memory; nothing bounded TIME. A token holder could open a
  /// chunked request, send a byte a minute, and hold a socket, a file
  /// descriptor and a pending future for as long as they liked — under the
  /// size cap the whole way, so no limit ever fired. Loopback JSON of at most
  /// 4 MiB does not need thirty seconds; anything slower is not a client.
  static const _defaultBodyDeadline = Duration(seconds: 30);
  final Duration _bodyDeadline;

  /// The body as text, or a refusal.
  ///
  /// Counted as it arrives rather than trusted from `Content-Length`: a chunked
  /// request declares no length, and a declared one is the caller's claim, not
  /// a limit on what they then send.
  ///
  /// Past the cap it keeps consuming but stops KEEPING, which is the part that
  /// mattered — memory stays flat while the sender wastes their own bandwidth.
  /// Abandoning the stream instead would be cheaper still and unusable: the
  /// unread remainder makes Dart tear the connection down, and the caller sees
  /// "connection closed before full header" rather than the refusal. That drain
  /// is now bounded by [_bodyDeadline], so the concession costs at most one
  /// deadline per request instead of being open-ended.
  Future<_BodyOutcome> _readBoundedBody(HttpRequest req) async {
    var chunks = <List<int>>[];
    var total = 0;
    var overflowed = false;
    final done = Completer<_BodyOutcome>();

    _BodyOutcome finish() {
      if (overflowed) return _BodyOutcome.tooLarge;
      return _BodyOutcome.text(
        utf8.decode(
          chunks.expand((chunk) => chunk).toList(growable: false),
          allowMalformed: true,
        ),
      );
    }

    // Driven by an explicit subscription rather than `await for` + `.timeout`,
    // because a timeout on the FUTURE leaves the subscription running: the
    // stream is still being consumed while the refusal is written, and the
    // response fails mid-flight (observed as a 500 in place of the 408).
    // Cancelling is what makes the deadline mean "stop reading" rather than
    // just "stop waiting".
    late StreamSubscription<List<int>> sub;
    final timer = Timer(_bodyDeadline, () {
      if (done.isCompleted) return;
      unawaited(sub.cancel());
      done.complete(_BodyOutcome.timedOut);
    });
    sub = req.listen(
      (chunk) {
        total += chunk.length;
        if (!overflowed && total > _maxBodyBytes) {
          overflowed = true;
          chunks = <List<int>>[]; // release what was already held
        }
        if (!overflowed) chunks.add(chunk);
      },
      onDone: () {
        if (!done.isCompleted) done.complete(finish());
      },
      onError: (Object _) {
        // The caller hung up mid-send. Same class of failure as running out of
        // time: there is no body to parse either way.
        if (!done.isCompleted) done.complete(_BodyOutcome.timedOut);
      },
      cancelOnError: true,
    );

    final outcome = await done.future;
    timer.cancel();
    return outcome;
  }

  /// How long an unauthenticated caller gets to finish a body we are only
  /// reading in order to throw away. Generous for a local client on loopback,
  /// and short enough that holding sockets open is not a strategy.
  static const _discardDeadline = Duration(seconds: 5);

  /// Consume and discard, so a refusal can still be delivered on the same
  /// connection. Used for callers rejected before their body is worth parsing.
  ///
  /// BOUNDED. Draining without a deadline is a slowloris the other way round:
  /// a local process opens many chunked requests, never finishes one, and each
  /// costs a socket, a file descriptor and a pending future for as long as it
  /// likes — while never presenting a token. Past the deadline we stop waiting
  /// and answer anyway; the caller may see a truncated response, which is the
  /// correct outcome for one that would not finish its request.
  Future<void> _discardBody(HttpRequest req) async {
    try {
      await req.drain<void>().timeout(_discardDeadline);
    } on TimeoutException {
      // Deliberate: stop reading, let the refusal go out, drop the socket.
    } catch (_) {
      // The caller hung up mid-send; nothing left to answer to.
    }
  }

  Future<void> _onRequest(HttpRequest req) async {
    // Bot event feed: an authenticated WebSocket streams incoming-message
    // events. The token rides in the query (?token=) because a WS client can't
    // set an Authorization header on the upgrade handshake.
    if (WebSocketTransformer.isUpgradeRequest(req) &&
        req.uri.path == '/v1/events') {
      final auth = _handler.tokenFor(req.uri.queryParameters['token']);
      if (auth == null) {
        req.response.statusCode = 401;
        await req.response.close();
        return;
      }
      // COUNTED (audit XV-14). This returned before the in-flight cap, so a
      // token holder could open subscriptions without limit — each one a
      // socket, a descriptor and a stream listener held for as long as it
      // liked. The request cap below bounded everything EXCEPT the one path
      // that stays open indefinitely, which is the wrong way round.
      //
      // Its own budget rather than the request one: a long-lived subscription
      // is not a request, and charging them to the same pool would let a
      // handful of idle feeds starve ordinary calls.
      if (_liveSockets >= _maxLiveSockets) {
        req.response.statusCode = 503;
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode({'error': 'too many event subscriptions'}),
        );
        await req.response.close();
        return;
      }
      // RESERVED, not merely checked (audit XV-10). The count used to rise
      // AFTER the awaited upgrade, so every subscription that arrived while
      // the first one was still shaking hands read the same pre-upgrade total
      // and passed — the cap held only for callers polite enough to connect
      // one at a time. Taking the slot before the await makes the check and
      // the claim one step, so the ceiling is the ceiling.
      _liveSockets++;
      var released = false;
      void release() {
        if (released) return;
        released = true;
        _liveSockets--;
      }

      final WebSocket ws;
      try {
        await debugUpgradeGate?.call();
        // COMPRESSION OFF (audit X-08). The default is
        // `compressionDefault`, which negotiates permessage-deflate, and
        // dart:io then joins a whole message before inflating it with no
        // ceiling on the output and no limit on the expansion ratio. A few
        // kilobytes of zeros on the wire become gigabytes in this process —
        // and the token that buys the right to try is one a local process can
        // hold while being allowed nothing else.
        //
        // It costs nothing to give up. This feed is one-way and its messages
        // are small JSON notices; deflate was never buying anything here, so
        // the whole class goes away rather than being bounded.
        //
        // BY HAND (audit XV-M2), so the socket can be wrapped in a raw byte
        // cap before the `WebSocket` starts assembling from it. See
        // `_upgradeCapped`: the transformer offers no seam and no ceiling, so
        // one endless message could allocate without bound under a token that
        // is allowed nothing else.
        ws = await _upgradeCapped(req);
      } catch (_) {
        release(); // an upgrade that failed must not hold a slot forever
        return;
      }
      final live = _LiveSocket(ws, auth.id);
      _live.add(live);

      // BOUNDED QUEUE with real backpressure (audit XV-14). `WebSocket.add`
      // buffers without limit when the peer stops reading, so a slow client
      // turned the event feed into a heap allocation driven by OTHER
      // people's traffic, with nothing watching it grow.
      //
      // `addStream` pulls from this queue only as the socket accepts data,
      // so `queued` is a true count of events the client has not taken.
      // Past the ceiling the subscriber is the problem, so the subscriber is
      // what gets dropped — dropping events instead would leave a bot
      // silently missing messages, which is worse than a reconnect.
      final queue = StreamController<String>();
      var queued = 0;
      live.queue = queue;
      live.events = _events.listen((e) {
        try {
          if (queued >= _maxQueuedEvents) {
            // THROUGH shutdown, not `ws.close` (audit XV-09). This socket is
            // bound to the `addStream` below, and `close()` on a bound sink
            // throws `StateError` instead of closing anything — synchronously,
            // straight into the `catch` on the next line. So the drop never
            // happened: the subscriber stayed connected holding one of the
            // sixteen slots, and simply stopped receiving. That is the outcome
            // the paragraph above calls worse than a reconnect, arrived at by
            // the code meant to avoid it.
            //
            // `shutdown` frees the sink before closing, which is what makes
            // the close possible at all; the slot then comes back through the
            // same `done` wiring that `closeLiveSockets` relies on.
            unawaited(
              live.shutdown(kEventFeedTooSlowCloseCode, 'client too slow'),
            );
            return;
          }
          queued++;
          queue.add(jsonEncode(e));
        } catch (_) {
          /* client gone mid-encode */
        }
      });
      live.pump = ws
          .addStream(queue.stream.map((line) {
            queued--;
            return line;
          }))
          .catchError((Object _) {/* socket died mid-send */});
      // A subscriber that hangs up is noticed through the INBOUND stream.
      //
      // The release used to hang off `ws.done`, which on a server-side socket
      // does NOT complete when the peer disconnects — measured: only the
      // inbound stream reports it, and nothing was listening to that. So the
      // cap only ever counted UP: sixteen ordinary bot reconnects and the feed
      // answered 503 until the app was restarted. A cap that never gives a
      // slot back is worse than no cap, because it fails the honest client and
      // not the abusive one.
      var inbound = 0;
      ws.listen(
        // The feed is one-way, so nothing a client sends is read — but it is
        // COUNTED (audit X-08). Ignoring bytes is not the same as refusing
        // them: dart:io joins each message in memory before it ever reaches
        // this callback, so a subscriber that uploads is spending our heap
        // whatever we do with the result. On a channel that has no use for
        // inbound traffic at all, any measurable amount of it is already
        // misuse, and the honest answer is to hang up rather than to keep
        // reading and discarding.
        (Object? frame) {
          inbound += switch (frame) {
            String s => s.length,
            List<int> b => b.length,
            _ => 0,
          };
          if (inbound > kEventFeedInboundByteBudget) {
            unawaited(live.shutdown(1008, 'event feed is not an upload'));
          }
        },
        onDone: () => unawaited(_releaseLive(live, release)),
        onError: (Object _) => unawaited(_releaseLive(live, release)),
        cancelOnError: true,
      );
      // Still wired, for the closes we initiate ourselves. Idempotent.
      unawaited(ws.done.whenComplete(() => _releaseLive(live, release)));
      return;
    }
    if (_inFlight >= _maxInFlight) {
      req.response.persistentConnection = false;
      req.response.statusCode = 503;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({'error': 'too many concurrent requests'}));
      await req.response.close();
      return;
    }
    _inFlight++;
    try {
      final auth = req.headers.value(HttpHeaders.authorizationHeader);
      Map<String, dynamic>? body;
      if (const {'POST', 'PATCH', 'DELETE'}.contains(req.method)) {
        // AUTH AND SCOPE BEFORE BODY. The token check used to live inside
        // handle(), which runs after the body has been fully joined into one
        // string — so an unauthenticated local process could hold the request
        // open and stream until the app ran out of memory. Auth moved out
        // first; SCOPE followed, because a read-only token passed the auth gate
        // and had its write body read in full before handle() refused it.
        final refusal = _handler.preBodyRefusal(auth, req.method);
        if (refusal != null) {
          await _discardBody(req);
          // Do not keep the socket alive for a caller we just refused: one
          // that is collecting connections should have to pay for a new one
          // every time.
          req.response.persistentConnection = false;
          req.response.statusCode = refusal;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({
            'error': refusal == 403 ? 'read-only token' : 'unauthorized',
          }));
          await req.response.close();
          return;
        }
        final read = await _readBoundedBody(req);
        final refusedStatus = read.status;
        if (refusedStatus == 408) {
          // No status goes out here, and that is not a shortcut. A request
          // whose body was abandoned mid-stream cannot carry a response:
          // `HttpServer` drops the bytes and closes the connection instead of
          // sending them (measured — the client receives nothing either way).
          // So the honest action is the one that frees the resource. Dropping
          // the socket IS the answer to a caller that would not finish.
          try {
            (await req.response.detachSocket(writeHeaders: false)).destroy();
          } catch (_) {
            /* already gone */
          }
          return;
        }
        if (refusedStatus != null) {
          // Over the cap. This stream WAS consumed to the end — that is what
          // the drain-but-do-not-keep loop buys — so a real refusal can go
          // out. Not on a reusable connection though: a caller collecting
          // connections should pay for a new one every time.
          req.response.persistentConnection = false;
          req.response.statusCode = refusedStatus;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({'error': 'body too large'}));
          await req.response.close();
          return;
        }
        final raw = read.text ?? '';
        if (raw.isNotEmpty) {
          // A BAD BODY IS THE CALLER'S FAULT, AND IT IS TOLD SO (audit X-16).
          // `jsonDecode` sat bare inside the try below, so a stray comma came
          // back as 500 — a status that says "this server broke", sending a
          // bot to retry, alert or open an issue about a request only it can
          // fix. And a body that parsed but was not an object (`[1,2]`, `"x"`,
          // `5`, `null`) fell through the `is Map` test in SILENCE: the
          // request went on to the handler as though nothing had been sent,
          // which is the worst of the three outcomes, because the caller gets
          // a plausible answer to a question it did not ask.
          final Object? decoded;
          try {
            decoded = jsonDecode(raw);
          } on FormatException {
            await _refuse(req, 400, 'malformed JSON body');
            return;
          }
          if (decoded is! Map<String, dynamic>) {
            await _refuse(req, 400, 'body must be a JSON object');
            return;
          }
          body = decoded;
        }
      }
      final res = await _handler.handle(req.method, req.uri, auth, body: body);
      final blob = res.blob;
      if (blob != null) {
        await _writeBlob(req, blob);
      } else if (res.bytes != null) {
        req.response.statusCode = res.status;
        req.response.headers.contentType = ContentType.parse(
          res.contentType ?? 'application/octet-stream',
        );
        req.response.add(res.bytes!);
      } else {
        req.response.statusCode = res.status;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(res.body ?? const {}));
      }
    } catch (_) {
      // Headers may already be on the wire for a streamed blob, in which case
      // the status can no longer be changed — swallow that rather than let it
      // mask the original failure.
      try {
        req.response.statusCode = 500;
      } catch (_) {}
    } finally {
      _inFlight--;
      // A blob cut short leaves fewer bytes than the promised Content-Length,
      // so close() throws by design. The connection still tears down, which is
      // the signal the client needs.
      try {
        await req.response.close();
      } catch (_) {}
    }
  }

  /// Stream a blob to the socket in [kBlobStreamChunkBytes] hops, honouring a
  /// single-range `Range` request.
  ///
  /// `await response.add(...)` is what supplies backpressure: it resolves as
  /// the socket drains, so a slow reader slows the READS instead of letting
  /// the whole blob pile up in the write queue. That is the difference between
  /// bounded memory and a byte-array response, which has the entire file
  /// resident before the first byte goes out.
  Future<void> _writeBlob(HttpRequest req, ApiBlobSource blob) async {
    final range = parseByteRange(req.headers.value(HttpHeaders.rangeHeader), blob.size);
    // Advertised unconditionally so a client knows it may seek at all.
    req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');

    if (range != null && range.unsatisfiable) {
      req.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      req.response.headers
        ..set(HttpHeaders.contentRangeHeader, 'bytes */${blob.size}')
        ..contentType = ContentType.json;
      req.response.write(jsonEncode({'error': 'range not satisfiable'}));
      return;
    }

    final start = range?.start ?? 0;
    final total = range?.length ?? blob.size;
    req.response.statusCode = range == null
        ? HttpStatus.ok
        : HttpStatus.partialContent;
    req.response.headers.contentType = ContentType.parse(blob.contentType);
    req.response.headers.contentLength = total;
    if (range != null) {
      req.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-${range.endInclusive}/${blob.size}',
      );
    }

    try {
      await for (final chunk in blobChunks(blob, start, total)) {
        req.response.add(chunk);
        // This await is the backpressure: it resolves as the socket drains, so
        // a slow reader slows the READS rather than letting the whole blob
        // queue up in memory.
        //
        // Bounded, because the same property is what a client can abuse: stop
        // reading and this never resolves, holding an in-flight slot for as
        // long as they like. See `_writeIdleDeadline`.
        await req.response.flush().timeout(
          _writeIdleDeadline,
          onTimeout: () => throw const _BlobWriteStalled(),
        );
      }
    } on _BlobWriteStalled {
      // Same reasoning as an unreadable blob: Content-Length is already on the
      // wire, so the only honest end is a failed transfer. Not a persistent
      // connection either — this socket has proven it does not drain.
      req.response.persistentConnection = false;
    } on BlobUnreadable {
      // Content-Length is already on the wire, so there is no honest way to
      // finish. Stop writing and let the short body fail the transfer — a
      // client must never be able to mistake a truncated file for a whole one,
      // which is exactly what closing cleanly here would produce.
      req.response.persistentConnection = false;
    }
  }

  /// Give back one subscriber's slot and stop its feed. Idempotent: it runs
  /// from the inbound stream, from `done`, and after an explicit close, and
  /// whichever gets there first must make the rest harmless.
  Future<void> _releaseLive(_LiveSocket live, void Function() release) async {
    release();
    _live.remove(live);
    final sub = live.events;
    live.events = null;
    await sub?.cancel();
    final q = live.queue;
    live.queue = null;
    live.pump = null;
    await q?.close();
  }

  /// Refuse [req] with [status] and a JSON `{"error": …}` body.
  ///
  /// Not on a reusable connection: a caller sending us rubbish should pay for
  /// a new socket each time, the same rule the size and auth refusals follow.
  Future<void> _refuse(HttpRequest req, int status, String error) async {
    req.response.persistentConnection = false;
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode({'error': error}));
    await req.response.close();
  }

  /// Disconnect live event subscribers — all of them, or only the ones a
  /// given [tokenId] opened (audit XV-10).
  ///
  /// Targeted rather than "drop everything" because revoking one token must
  /// not knock the other bots off their feeds; a revocation is not an outage.
  Future<void> closeLiveSockets({
    String? tokenId,
    int code = 1001,
    String reason = 'server stopping',
  }) async {
    final doomed = <_LiveSocket>[
      for (final live in _live)
        if (tokenId == null || live.tokenId == tokenId) live,
    ];
    for (final live in doomed) {
      _live.remove(live);
      await live.shutdown(code, reason);
    }
  }

  /// How many `/v1/events` subscribers are connected right now. Exposed so a
  /// test can see the registry shrink, not just the socket die.
  int get liveSocketCount => _live.length;

  Future<void> stop() async {
    _stopped = true;
    final s = _server;
    _server = null;
    // Upgraded WebSockets are NOT part of what `HttpServer.close` tears down —
    // measured, not assumed: after `close(force: true)` the socket is still
    // open AND still writable from this side. So a subscriber outlived every
    // teardown there is, including the one that matters most for deniability,
    // an identity switch: a feed authorised under one identity stayed attached
    // while the app moved to another. Disable and revoke run through here too.
    await closeLiveSockets(code: 1001, reason: 'server stopping');
    if (s != null) await s.close(force: true);
  }
}

/// Owns the API lifecycle: loads the persisted config, starts/stops the socket
/// when toggled, and mints/revokes the bearer token. Kept alive by an app-tree
/// bridge so the server survives navigation.
