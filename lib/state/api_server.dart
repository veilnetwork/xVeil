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
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ids.dart';
import '../data/serve_source.dart';
import '../domain/call_signal.dart' show CallMedia;
import '../domain/chat.dart';
import 'app_controller.dart';
import 'call_service.dart' show callServiceProvider, currentCallProvider;
import 'messaging.dart' show conversationsProvider, messagingServiceProvider;
import 'providers.dart';

/// The loopback port the automation API binds when enabled. Distinct from the
/// debug hook (38765/38766).
const int kApiPort = 8787;

const String _kEnabledKey = 'api.enabled';
const String _kTokensKey = 'api.tokens'; // JSON list of ApiToken
const String _kTokenKey = 'api.token'; // legacy single token (migrated)
const String _kReadOnlyKey = 'api.readonly'; // legacy single-token scope
const String _kWebhookKey = 'api.webhook'; // event push URL ('' = none)

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
              'POSTed to your local HTTP server. '
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
Future<bool> pushWebhookEvent(String url, Map<String, dynamic> event,
    {Duration timeout = const Duration(seconds: 5)}) async {
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

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'token': token, 'ro': readOnly};

  static ApiToken? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], name = j['name'], token = j['token'];
    if (id is! String || name is! String || token is! String) return null;
    return ApiToken(
        id: id, name: name, token: token, readOnly: j['ro'] == true);
  }
}

class ApiConfig {
  const ApiConfig(
      {required this.enabled, this.tokens = const [], this.webhookUrl});
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
  const ApiResponse.binary(this.bytes,
      {this.contentType = 'application/octet-stream'})
      : status = 200,
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
    required this.send,
    required this.messages,
    required this.sendFile,
    required this.loadFile,
    required this.placeCall,
    required this.callState,
    required this.callAction,
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

  Future<ApiResponse> handle(String method, Uri uri, String? authHeader,
      {Map<String, dynamic>? body}) async {
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
    if (method == 'GET' && path == '/v1/messages') {
      final peer = uri.queryParameters['peer'];
      if (peer == null || peer.isEmpty) {
        return const ApiResponse(400, {'error': 'peer required'});
      }
      final limit = int.tryParse(uri.queryParameters['limit'] ?? '') ?? 50;
      return ApiResponse(
          200, {'messages': await messages(peer, limit.clamp(1, 500))});
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
    if (method == 'POST' && path == '/v1/files') {
      final to = body?['to'];
      final filePath = body?['path'];
      if (to is! String || to.isEmpty || filePath is! String ||
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
          } catch (_) {/* client gone mid-encode */}
        });
        unawaited(ws.done.whenComplete(sub.cancel));
      } catch (_) {/* upgrade failed */}
      return;
    }
    try {
      final auth = req.headers.value(HttpHeaders.authorizationHeader);
      Map<String, dynamic>? body;
      if (req.method == 'POST') {
        final raw = await utf8.decoder.bind(req).join();
        if (raw.isNotEmpty) {
          final decoded = jsonDecode(raw);
          if (decoded is Map<String, dynamic>) body = decoded;
        }
      }
      final res = await _handler.handle(req.method, req.uri, auth, body: body);
      req.response.statusCode = res.status;
      if (res.bytes != null) {
        req.response.headers.contentType =
            ContentType.parse(res.contentType ?? 'application/octet-stream');
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
class ApiServerController extends Notifier<ApiConfig> {
  ApiServer? _server;
  StreamSubscription<Map<String, dynamic>>? _webhookSub;

  @override
  ApiConfig build() {
    ref.onDispose(() {
      unawaited(_server?.stop());
      unawaited(_webhookSub?.cancel());
    });
    // The config lives in the (per-identity) deniable store, so it can only be
    // read once the store is UNLOCKED. Gate on the identity being ready — before
    // unlock the store is locked (getSetting throws) and there's nothing to
    // serve anyway. Re-runs when the identity appears (or switches) → reloads.
    final ready =
        ref.watch(appControllerProvider.select((s) => s.identity != null));
    if (ready) {
      unawaited(_load());
    } else {
      unawaited(_server?.stop());
      _server = null;
    }
    return ApiConfig.empty;
  }

  Future<void> _load() async {
    final st = ref.read(storageProvider);
    try {
      final enabled = (await st.getSetting(_kEnabledKey)) == '1';
      var tokens = <ApiToken>[];
      final raw = await st.getSetting(_kTokensKey);
      if (raw != null && raw.isNotEmpty) {
        final d = jsonDecode(raw);
        if (d is List) {
          tokens = d.map(ApiToken.fromJson).whereType<ApiToken>().toList();
        }
      } else {
        // Migrate the old single-token model (api.token + api.readonly).
        final old = await st.getSetting(_kTokenKey);
        if (old != null && old.isNotEmpty) {
          tokens = [
            ApiToken(
                id: _mintId(),
                name: 'default',
                token: old,
                readOnly: (await st.getSetting(_kReadOnlyKey)) == '1'),
          ];
          await st.putSetting(_kTokensKey,
              jsonEncode(tokens.map((t) => t.toJson()).toList()));
        }
      }
      final webhook = await st.getSetting(_kWebhookKey);
      state = ApiConfig(
          enabled: enabled,
          tokens: tokens,
          webhookUrl:
              (webhook == null || webhook.isEmpty) ? null : webhook);
      if (enabled && tokens.isNotEmpty) await _reconcile();
    } catch (e) {
      // Store not ready yet (e.g. mid-unlock) — a later identity change re-runs.
      debugPrint('xVeil[api]: config load deferred: $e');
    }
  }

  String _mintToken() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(32, (_) => rnd.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  Map<String, dynamic> _status() {
    final id = ref.read(appControllerProvider).identity?.nodeId;
    return {
      'ok': id != null,
      if (id != null) 'nodeId': id.hex,
      if (id != null) 'short': id.short,
      'api': 'v1',
    };
  }

  Future<List<Map<String, dynamic>>> _contacts() async {
    final convos =
        ref.read(conversationsProvider).valueOrNull ?? const <Conversation>[];
    return [
      for (final c in convos)
        if (c.peer.status == ContactStatus.accepted)
          {
            'nodeId': c.peer.nodeId.hex,
            'short': c.peer.nodeId.short,
            if (c.peer.name != null) 'name': c.peer.name,
          },
    ];
  }

  /// Send a text message to [toHex] via the messaging service. Returns null on
  /// success, or an error string (bad peer / send failure).
  Future<String?> _send(String toHex, String text) async {
    final NodeId peer;
    try {
      peer = NodeId.fromHex(toHex);
    } catch (_) {
      return 'invalid peer';
    }
    try {
      await ref.read(messagingServiceProvider).sendText(peer, text);
      return null;
    } catch (e) {
      return '$e';
    }
  }

  /// The most-recent [limit] messages of the conversation with [peerHex].
  Future<List<Map<String, dynamic>>> _messages(
      String peerHex, int limit) async {
    final NodeId peer;
    try {
      peer = NodeId.fromHex(peerHex);
    } catch (_) {
      return const [];
    }
    final msgs =
        await ref.read(storageProvider).loadMessages(peer.hex, limit: limit);
    return [
      for (final m in msgs)
        {
          'id': m.id,
          'body': m.body,
          'direction': m.direction.name,
          'sentAt': m.timestamp.millisecondsSinceEpoch,
          'status': m.status.name,
          if (m.fileName != null) 'fileName': m.fileName,
          // The id a bot passes to GET /v1/files/download to fetch the blob.
          if (m.fileId != null) 'fileId': m.fileId,
        },
    ];
  }

  /// Send the file at local [path] to [toHex] (streamed off disk, any size).
  /// Returns null on success or an error string.
  Future<String?> _sendFile(String toHex, String path, String? name) async {
    final NodeId peer;
    try {
      peer = NodeId.fromHex(toHex);
    } catch (_) {
      return 'invalid peer';
    }
    final file = File(path);
    if (!await file.exists()) return 'source not found';
    final size = await file.length();
    final source = await veilSourceOpener(path);
    if (source == null) return 'source open failed';
    final n = (name != null && name.isNotEmpty) ? name : path.split('/').last;
    try {
      final cid = await ref.read(messagingServiceProvider).sendFileStreaming(
            peer,
            n,
            size,
            source.read,
            close: source.close,
            sourcePath: path,
          );
      return cid == null ? 'peer not accepted' : null;
    } catch (e) {
      return '$e';
    }
  }

  Future<List<int>?> _loadFile(String fileId) =>
      ref.read(storageProvider).loadFile(fileId);

  Future<String?> _placeCall(String toHex, String media) async {
    final NodeId peer;
    try {
      peer = NodeId.fromHex(toHex);
    } catch (_) {
      return 'invalid peer';
    }
    try {
      await ref.read(callServiceProvider).placeCall(
            peer,
            CallMedia(
              audio: true,
              video: media == 'video',
              screen: media == 'screen',
            ),
          );
      return null;
    } catch (e) {
      return '$e';
    }
  }

  Map<String, dynamic>? _callState() {
    final c = ref.read(currentCallProvider);
    if (c == null) return null;
    return {
      'callId': c.callId,
      'peer': c.peer.hex,
      'direction': c.direction.name,
      'status': c.status.name,
      'media': {
        'audio': c.media.audio,
        'video': c.media.video,
        'screen': c.media.screen,
      },
      'micOn': c.micOn,
      'cameraOn': c.cameraOn,
    };
  }

  Future<void> _callAction(String action) async {
    final svc = ref.read(callServiceProvider);
    switch (action) {
      case 'hangup':
        await svc.hangup();
      case 'accept':
        await svc.accept();
      case 'reject':
        await svc.reject();
    }
  }

  /// Bring the socket in line with [state]: run (with a fresh handler carrying
  /// the current token) iff enabled + tokened, else stop. The webhook
  /// subscription follows the same lifecycle (active iff server runs + URL set).
  Future<void> _reconcile() async {
    await _server?.stop();
    _server = null;
    await _webhookSub?.cancel();
    _webhookSub = null;
    if (!state.enabled || state.tokens.isEmpty) return;
    final handler = ApiHandler(
      tokens: state.tokens,
      status: _status,
      contacts: _contacts,
      send: _send,
      messages: _messages,
      sendFile: _sendFile,
      loadFile: _loadFile,
      placeCall: _placeCall,
      callState: _callState,
      callAction: _callAction,
      webhook: () => state.webhookUrl,
      setWebhook: setWebhook,
    );
    // The bot event feed: incoming-message notices as JSON. `.map` on a
    // broadcast stream stays broadcast, so many WS clients can each subscribe.
    final events = ref.read(messagingServiceProvider).incoming.map(
          (n) => <String, dynamic>{
            'type': 'message',
            'from': n.from.hex,
            'preview': n.preview,
            'isFile': n.isFile,
          },
        );
    _server = ApiServer(handler, events);
    try {
      await _server!.start(kApiPort);
    } catch (e) {
      debugPrint('xVeil[api]: bind failed: $e');
      _server = null;
    }
    _rewireWebhook();
  }

  /// (Re)subscribe the webhook push to the incoming-event feed. Separate from
  /// [_reconcile] so changing the URL mid-request does NOT restart the socket —
  /// tearing the server down while it is serving the very POST /v1/webhook that
  /// changed the URL kills that connection before the response is written.
  void _rewireWebhook() {
    unawaited(_webhookSub?.cancel());
    _webhookSub = null;
    final hook = state.webhookUrl;
    if (!state.enabled || _server == null || hook == null) return;
    // Webhook push: the same events the WS feed carries, POSTed to a loopback
    // URL, for bots that would rather run a plain HTTP server than hold a
    // WebSocket open.
    _webhookSub = ref
        .read(messagingServiceProvider)
        .incoming
        .map(
          (n) => <String, dynamic>{
            'type': 'message',
            'from': n.from.hex,
            'preview': n.preview,
            'isFile': n.isFile,
          },
        )
        .listen((e) => unawaited(_pushWebhook(hook, e)));
  }

  /// POST one event to the webhook [url]: short timeout, one retry. Failures
  /// are logged and dropped — the webhook is a convenience feed; the durable
  /// record stays in the store (a bot can reconcile via GET /v1/messages).
  Future<void> _pushWebhook(String url, Map<String, dynamic> event) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      if (await pushWebhookEvent(url, event)) return;
      if (attempt == 0) {
        await Future<void>.delayed(const Duration(seconds: 2));
      } else {
        debugPrint('xVeil[api]: webhook push failed twice, dropped');
      }
    }
  }

  /// Persist + apply the webhook URL (null clears). The URL is validated at
  /// the API edge ([webhookUrlError]); this stores and rewires the push
  /// subscription only — never the socket (see [_rewireWebhook]).
  Future<void> setWebhook(String? url) async {
    await ref.read(storageProvider).putSetting(_kWebhookKey, url ?? '');
    state = state.withWebhook(url);
    _rewireWebhook();
  }

  String _mintId() =>
      base64Url.encode(List<int>.generate(6, (_) => Random.secure().nextInt(256)))
          .replaceAll(RegExp('[=_-]'), '')
          .substring(0, 6);

  Future<void> _persistTokens() => ref.read(storageProvider).putSetting(
      _kTokensKey, jsonEncode(state.tokens.map((t) => t.toJson()).toList()));

  /// Turn the API on: ensure at least one (full) token exists, persist, start.
  Future<void> enable() async {
    if (state.tokens.isEmpty) {
      state = state.copyWith(tokens: [
        ApiToken(
            id: _mintId(),
            name: 'default',
            token: _mintToken(),
            readOnly: false),
      ]);
      await _persistTokens();
    }
    await ref.read(storageProvider).putSetting(_kEnabledKey, '1');
    state = state.copyWith(enabled: true);
    await _reconcile();
  }

  /// Turn the API off (keeps the tokens so re-enabling is one tap).
  Future<void> disable() async {
    await ref.read(storageProvider).putSetting(_kEnabledKey, '0');
    state = state.copyWith(enabled: false);
    await _reconcile();
  }

  /// Issue a new token ([readOnly] = least-privilege); returns its secret.
  Future<String> addToken(String name, {bool readOnly = false}) async {
    final tok = ApiToken(
        id: _mintId(),
        name: name.trim().isEmpty ? 'token' : name.trim(),
        token: _mintToken(),
        readOnly: readOnly);
    state = state.copyWith(tokens: [...state.tokens, tok]);
    await _persistTokens();
    if (state.enabled) await _reconcile();
    return tok.token;
  }

  /// Revoke the token with [id] (that client immediately stops working).
  Future<void> revokeToken(String id) async {
    state = state
        .copyWith(tokens: state.tokens.where((t) => t.id != id).toList());
    await _persistTokens();
    if (state.enabled) await _reconcile();
  }

  bool get running => _server?.running ?? false;
}

final apiServerControllerProvider =
    NotifierProvider<ApiServerController, ApiConfig>(ApiServerController.new);
