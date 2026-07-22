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
import 'dart:io';

import '../domain/group_message.dart';
import '../domain/space_post.dart';

/// The loopback port the automation API binds when enabled. Distinct from the
/// debug hook (38765/38766).
const int kApiPort = 8787;

bool _validFeedCursor(String value) => SpaceFeedCursor.decode(value) != null;
bool _validPostId(String value) =>
    RegExp(r'^[0-9a-f]{64}:[0-9]+$').hasMatch(value);

List<MediaObjectRef>? _spacePostMedia(Object? value, {bool optional = false}) {
  if (value == null) return optional ? null : const <MediaObjectRef>[];
  if (value is! List || value.length > kSpacePostMediaMax) return null;
  final media = value
      .map(MediaObjectRef.fromJson)
      .whereType<MediaObjectRef>()
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

/// The OpenAPI 3.0 contract for the implemented `/v1` surface, so a client can
/// be generated in any language (`openapi-generator -i .../v1/openapi.json`).
/// Hand-authored (small surface); kept in lockstep with [ApiHandler.handle].
/// The realtime `/v1/events` WebSocket is described in `info.description`
/// because OpenAPI 3.0 has no first-class WebSocket schema.
Map<String, dynamic> openApiSpec() {
  Map<String, dynamic> ok(Map<String, dynamic> schema) => {
    '200': {
      'description': 'OK',
      'content': {
        'application/json': {'schema': schema},
      },
    },
  };
  const obj = 'object';
  return {
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
          },
        },
        'Message': {
          'type': obj,
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
            'fileId': {'type': 'string'},
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
            'preview': {'type': 'string'},
            'lastTs': {'type': 'integer', 'format': 'int64'},
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
              'enum': ['space', 'restricted', 'secret'],
            },
          },
        },
        'MediaObjectRef': {
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
        },
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
              'items': {r'$ref': '#/components/schemas/MediaObjectRef'},
            },
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
            'replyTo': {'type': 'string'},
            'attachment': {'type': obj},
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
          'summary': 'Read signed community and local-device retention',
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
          'summary': 'Set community or local-device retention',
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
                      'enum': ['community', 'device'],
                    },
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
                      'items': {r'$ref': '#/components/schemas/MediaObjectRef'},
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
                      'items': {r'$ref': '#/components/schemas/MediaObjectRef'},
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
                  'media': {
                    'type': 'array',
                    'maxItems': kSpacePostMediaMax,
                    'items': {r'$ref': '#/components/schemas/MediaObjectRef'},
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
                      'items': {r'$ref': '#/components/schemas/MediaObjectRef'},
                    },
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
                  'required': ['space', 'postId', 'body'],
                  'properties': {
                    'space': {'type': 'string'},
                    'postId': {'type': 'string'},
                    'body': {
                      'type': 'string',
                      'maxLength': kSpacePostCommentMaxBytes,
                    },
                    'replyTo': {'type': 'string'},
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
                    'hiddenFromRecommendations': {'type': 'boolean'},
                    'enabled': {
                      'type': 'boolean',
                      'deprecated': true,
                      'description': 'Legacy alias for feedEnabled',
                    },
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
          'summary': 'Send a local file to a peer (streamed)',
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
      '/files/download': {
        'get': {
          'summary': 'Download a stored file blob by id',
          'parameters': [
            {
              'name': 'fileId',
              'in': 'query',
              'required': true,
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
            '404': {'description': 'Unknown file id'},
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
}

/// POST one JSON [event] to the webhook [url] (`X-XVeil-Event` carries the
/// event type). True = delivered (any non-5xx response); false = try again.
/// Top-level so the actual HTTP push is testable against a real loopback
/// server, not just mocked.
Future<bool> pushWebhookEvent(
  String url,
  Map<String, dynamic> event, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final req = await client.postUrl(Uri.parse(url));
    req.headers.contentType = ContentType.json;
    req.headers.set('X-XVeil-Event', event['type']?.toString() ?? 'event');
    req.write(jsonEncode(event));
    final res = await req.close().timeout(timeout);
    await res.drain<void>();
    return res.statusCode < 500; // delivered (or client error — don't retry)
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
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
  });
  final String id; // short handle for revocation (not secret)
  final String name; // human label ("bot", "monitor", …)
  final String token; // the secret bearer value
  final bool readOnly;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'token': token,
    'ro': readOnly,
  };

  static ApiToken? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], name = j['name'], token = j['token'];
    if (id is! String || name is! String || token is! String) return null;
    return ApiToken(
      id: id,
      name: name,
      token: token,
      readOnly: j['ro'] == true,
    );
  }
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
class ApiResponse {
  const ApiResponse(this.status, [this.body])
    : bytes = null,
      contentType = null;
  const ApiResponse.binary(
    this.bytes, {
    this.contentType = 'application/octet-stream',
  }) : status = 200,
       body = null;
  final int status;
  final Object? body;
  final List<int>? bytes;
  final String? contentType;
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
    required this.loadFile,
    required this.placeCall,
    required this.callState,
    required this.callAction,
    this.callsAvailable = true,
    required this.groups,
    this.spaces,
    required this.createGroup,
    this.createSpace,
    required this.groupMessages,
    required this.sendGroupMessage,
    required this.sendGroupFile,
    required this.fetchGroupFile,
    required this.loadGroupFile,
    required this.groupMembers,
    required this.groupMemberAction,
    required this.renameGroup,
    required this.leaveGroup,
    this.spaceChannels,
    this.spacePosts,
    this.spacePostDraft,
    this.saveSpacePostDraft,
    this.clearSpacePostDraft,
    this.spacePostComments,
    this.publishSpacePostComment,
    this.publishSpacePost,
    this.editSpacePost,
    this.deleteSpacePost,
    this.setSpacePostPinned,
    this.reactToSpacePost,
    this.spaceRecommendationCampaigns,
    this.createSpaceRecommendationCampaign,
    this.revokeSpaceRecommendationCampaign,
    this.shareSpaceRecommendation,
    this.spaceFeed,
    this.spaceFeedTypeFilter,
    this.setSpaceFeedTypeFilter,
    this.spaceSubscription,
    this.updateSpaceSubscription,
    this.setSpaceFeedEnabled,
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
    this.spaceRules,
    this.publishSpaceRules,
    this.acceptSpaceRules,
    this.spaceModerationAudit,
    this.moderateSpace,
    this.revokeSpaceModeration,
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
  final Future<String?> Function(String toHex, String path, String? name)
  sendFile;

  /// Load the bytes of a stored file by [fileId], or null if unknown.
  final Future<List<int>?> Function(String fileId) loadFile;

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
  final Future<({String? error, String? contentId})> Function(
    String groupHex,
    String path,
    String? name,
    String caption,
    String? replyTo,
  )
  sendGroupFile;
  final Future<String?> Function(String groupHex, String messageRef)
  fetchGroupFile;
  final Future<({String? error, List<int>? bytes})> Function(
    String groupHex,
    String messageRef,
  )
  loadGroupFile;
  final Future<Map<String, dynamic>?> Function(String groupHex) groupMembers;
  final Future<String?> Function(
    String groupHex,
    String action,
    String peerHex,
    String? role,
  )
  groupMemberAction;
  final Future<String?> Function(String groupHex, String name) renameGroup;
  final Future<String?> Function(String groupHex) leaveGroup;
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
    List<MediaObjectRef> media,
  )?
  saveSpacePostDraft;
  final Future<String?> Function(String spaceHex)? clearSpacePostDraft;
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
  )?
  publishSpacePostComment;
  final Future<({String? error, Map<String, dynamic>? post})> Function(
    String spaceHex,
    String title,
    String body,
    String type,
    List<MediaObjectRef> media,
  )?
  publishSpacePost;
  final Future<({String? error, Map<String, dynamic>? post})> Function(
    String spaceHex,
    String postId,
    String title,
    String body,
    String? type,
    List<MediaObjectRef>? media,
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
  final Future<Map<String, dynamic>> Function(
    int limit,
    String? before,
    bool? pinned,
  )?
  spaceFeed;
  final Future<Map<String, dynamic>> Function()? spaceFeedTypeFilter;
  final Future<String?> Function(List<String> types)? setSpaceFeedTypeFilter;
  final Future<Map<String, dynamic>?> Function(String spaceHex)?
  spaceSubscription;
  final Future<String?> Function(
    String spaceHex, {
    bool? feedEnabled,
    bool? notificationsEnabled,
    bool? hiddenFromRecommendations,
  })?
  updateSpaceSubscription;
  final Future<String?> Function(String spaceHex, bool enabled)?
  setSpaceFeedEnabled;
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
  final Future<String?> Function(String spaceHex, int? days, bool localDevice)?
  setSpaceRetention;
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
  final Future<({String? error, String? channelId})> Function(
    String spaceHex,
    String name,
    String kind,
    String? categoryHex,
    int position,
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
      return ApiResponse(200, openApiSpec());
    }
    if (method == 'GET' && path == '/v1/health') {
      return ApiResponse(200, status());
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
      final handler = spaceRetention;
      if (handler == null) {
        return const ApiResponse(501, {'error': 'Space retention unavailable'});
      }
      final space = uri.queryParameters['space'];
      if (space == null || space.isEmpty) {
        return const ApiResponse(400, {'error': 'space required'});
      }
      final retention = await handler(space);
      return retention == null
          ? const ApiResponse(404, {'error': 'space not found'})
          : ApiResponse(200, retention);
    }
    if (method == 'POST' && path == '/v1/spaces/retention') {
      final handler = setSpaceRetention;
      if (handler == null) {
        return const ApiResponse(501, {'error': 'Space retention unavailable'});
      }
      final space = body?['space'];
      final scope = body?['scope'];
      final days = body?['days'];
      if (space is! String ||
          space.isEmpty ||
          (scope != 'community' && scope != 'device') ||
          (days != null && (days is! int || days <= 0 || days > 36500))) {
        return const ApiResponse(400, {
          'error': 'valid space, scope and optional days required',
        });
      }
      return _spaceMutationResponse(
        await handler(space, days as int?, scope == 'device'),
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
      if (space is! String ||
          space.isEmpty ||
          title is! String ||
          title.length > kSpacePostTitleMax ||
          text is! String ||
          utf8.encode(text).length > kSpacePostBodyMax ||
          type is! String ||
          SpacePostType.fromName(type) == null ||
          media == null) {
        return const ApiResponse(400, {'error': 'invalid Space post draft'});
      }
      return _spaceMutationResponse(
        await handler(space, title, text, type, media),
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
      final text = body?['body'];
      final replyTo = body?['replyTo'];
      if (space is! String ||
          space.isEmpty ||
          postId is! String ||
          !_validPostId(postId) ||
          text is! String ||
          text.trim().isEmpty ||
          utf8.encode(text).length > kSpacePostCommentMaxBytes ||
          (replyTo != null && (replyTo is! String || !_validPostId(replyTo)))) {
        return const ApiResponse(400, {'error': 'invalid Space post comment'});
      }
      return _spaceMutationResponse(
        await handler(space, postId, text.trim(), replyTo as String?),
      );
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
      final legacyHandler = setSpaceFeedEnabled;
      final space = body?['space'];
      if (updateHandler == null && legacyHandler == null) {
        return const ApiResponse(501, {'error': 'subscriptions unavailable'});
      }
      const allowed = {
        'space',
        'enabled',
        'feedEnabled',
        'notificationsEnabled',
        'hiddenFromRecommendations',
      };
      if (body == null || body.keys.any((key) => !allowed.contains(key))) {
        return const ApiResponse(400, {'error': 'unknown subscription field'});
      }
      final legacyFeed = body['enabled'];
      final explicitFeed = body['feedEnabled'];
      final notifications = body['notificationsEnabled'];
      final hidden = body['hiddenFromRecommendations'];
      if (space is! String ||
          space.isEmpty ||
          (body.containsKey('enabled') && legacyFeed is! bool) ||
          (body.containsKey('feedEnabled') && explicitFeed is! bool) ||
          (body.containsKey('notificationsEnabled') &&
              notifications is! bool) ||
          (body.containsKey('hiddenFromRecommendations') && hidden is! bool) ||
          (legacyFeed is bool &&
              explicitFeed is bool &&
              legacyFeed != explicitFeed)) {
        return const ApiResponse(400, {
          'error': 'valid subscription fields required',
        });
      }
      final feed = explicitFeed is bool
          ? explicitFeed
          : legacyFeed is bool
          ? legacyFeed
          : null;
      if (feed == null && notifications == null && hidden == null) {
        return const ApiResponse(400, {
          'error': 'at least one subscription preference required',
        });
      }
      final error = updateHandler != null
          ? await updateHandler(
              space,
              feedEnabled: feed,
              notificationsEnabled: notifications as bool?,
              hiddenFromRecommendations: hidden as bool?,
            )
          : notifications != null || hidden != null
          ? 'subscription preference unavailable'
          : await legacyHandler!(space, feed!);
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
      final position = body?['position'] ?? 0;
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
          position is! int ||
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
        position,
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
      final result = await sendGroupFile(
        group,
        filePath,
        name as String?,
        caption,
        replyTo as String?,
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
          ? ApiResponse.binary(result.bytes!)
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
      final roster = await groupMembers(scope);
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
      );
      return isSpace
          ? _spaceMutationResponse(error)
          : _groupMutationResponse(error);
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
      final error = await renameGroup(scope, name);
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
      final error = await leaveGroup(scope);
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
      final name = body?['name'];
      final err = await sendFile(to, filePath, name is String ? name : null);
      return err == null
          ? const ApiResponse(200, {'ok': true})
          : ApiResponse(400, {'error': err});
    }
    if (method == 'GET' && path == '/v1/files/download') {
      final fileId = uri.queryParameters['fileId'];
      if (fileId == null || fileId.isEmpty) {
        return const ApiResponse(400, {'error': 'fileId required'});
      }
      final bytes = await loadFile(fileId);
      return bytes == null
          ? const ApiResponse(404, {'error': 'not found'})
          : ApiResponse.binary(bytes);
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
class ApiServer {
  ApiServer(this._handler, this._events);
  final ApiHandler _handler;
  final Stream<Map<String, dynamic>> _events;
  HttpServer? _server;

  bool get running => _server != null;
  int? get port => _server?.port;

  Future<int?> start(int port) async {
    if (_server != null) return _server!.port;
    final s = await HttpServer.bind(
      InternetAddress.loopbackIPv4, // LOOPBACK ONLY (privacy canon)
      port,
      shared: true,
    );
    _server = s;
    unawaited(s.forEach(_onRequest));
    return s.port;
  }

  Future<void> _onRequest(HttpRequest req) async {
    // Bot event feed: an authenticated WebSocket streams incoming-message
    // events. The token rides in the query (?token=) because a WS client can't
    // set an Authorization header on the upgrade handshake.
    if (WebSocketTransformer.isUpgradeRequest(req) &&
        req.uri.path == '/v1/events') {
      if (!_handler.tokenOk(req.uri.queryParameters['token'])) {
        req.response.statusCode = 401;
        await req.response.close();
        return;
      }
      try {
        final ws = await WebSocketTransformer.upgrade(req);
        final sub = _events.listen((e) {
          try {
            ws.add(jsonEncode(e));
          } catch (_) {
            /* client gone mid-encode */
          }
        });
        unawaited(ws.done.whenComplete(sub.cancel));
      } catch (_) {
        /* upgrade failed */
      }
      return;
    }
    try {
      final auth = req.headers.value(HttpHeaders.authorizationHeader);
      Map<String, dynamic>? body;
      if (const {'POST', 'PATCH', 'DELETE'}.contains(req.method)) {
        final raw = await utf8.decoder.bind(req).join();
        if (raw.isNotEmpty) {
          final decoded = jsonDecode(raw);
          if (decoded is Map<String, dynamic>) body = decoded;
        }
      }
      final res = await _handler.handle(req.method, req.uri, auth, body: body);
      req.response.statusCode = res.status;
      if (res.bytes != null) {
        req.response.headers.contentType = ContentType.parse(
          res.contentType ?? 'application/octet-stream',
        );
        req.response.add(res.bytes!);
      } else {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(res.body ?? const {}));
      }
    } catch (_) {
      req.response.statusCode = 500;
    } finally {
      await req.response.close();
    }
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    if (s != null) await s.close(force: true);
  }
}

/// Owns the API lifecycle: loads the persisted config, starts/stops the socket
/// when toggled, and mints/revokes the bearer token. Kept alive by an app-tree
/// bridge so the server survives navigation.
