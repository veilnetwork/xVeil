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
import '../domain/chat.dart';
import 'app_controller.dart';
import 'messaging.dart' show conversationsProvider, messagingServiceProvider;
import 'providers.dart';

/// The loopback port the automation API binds when enabled. Distinct from the
/// debug hook (38765/38766).
const int kApiPort = 8787;

const String _kEnabledKey = 'api.enabled';
const String _kTokenKey = 'api.token';

/// Persisted API state: whether the server runs, and the bearer token clients
/// must present. The token lives in the deniable store, never in plaintext prefs.
class ApiConfig {
  const ApiConfig({required this.enabled, required this.token});
  final bool enabled;
  final String token;

  ApiConfig copyWith({bool? enabled, String? token}) =>
      ApiConfig(enabled: enabled ?? this.enabled, token: token ?? this.token);

  static const empty = ApiConfig(enabled: false, token: '');
}

/// A JSON response: an HTTP status + a JSON-encodable body.
class ApiResponse {
  const ApiResponse(this.status, [this.body]);
  final int status;
  final Object? body;
}

/// Pure request router — no socket, so tests exercise auth + endpoints directly.
class ApiHandler {
  ApiHandler({
    required this.token,
    required this.status,
    required this.contacts,
    required this.send,
    required this.messages,
  });

  /// The bearer token every request must present (empty = reject everything).
  final String token;

  /// Node/account status for `GET /v1/health`.
  final Map<String, dynamic> Function() status;

  /// Accepted contacts for `GET /v1/contacts`.
  final Future<List<Map<String, dynamic>>> Function() contacts;

  /// Send a text message to [toHex]; returns null on success or an error string.
  final Future<String?> Function(String toHex, String body) send;

  /// The most-recent [limit] messages of the conversation with [peerHex].
  final Future<List<Map<String, dynamic>>> Function(String peerHex, int limit)
      messages;

  /// Constant-time token compare (localhost, but no reason to leak length/prefix).
  bool _authOk(String? header) {
    if (token.isEmpty) return false;
    const prefix = 'Bearer ';
    if (header == null || !header.startsWith(prefix)) return false;
    final got = header.substring(prefix.length);
    if (got.length != token.length) return false;
    var diff = 0;
    for (var i = 0; i < token.length; i++) {
      diff |= got.codeUnitAt(i) ^ token.codeUnitAt(i);
    }
    return diff == 0;
  }

  Future<ApiResponse> handle(String method, Uri uri, String? authHeader,
      {Map<String, dynamic>? body}) async {
    if (!_authOk(authHeader)) {
      return const ApiResponse(401, {'error': 'unauthorized'});
    }
    final path = uri.path;
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
    return const ApiResponse(404, {'error': 'not found'});
  }
}

/// Binds [ApiHandler] to a loopback HTTP socket.
class ApiServer {
  ApiServer(this._handler);
  final ApiHandler _handler;
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
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(res.body ?? const {}));
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

  @override
  ApiConfig build() {
    ref.onDispose(() => unawaited(_server?.stop()));
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
      final token = (await st.getSetting(_kTokenKey)) ?? '';
      state = ApiConfig(enabled: enabled, token: token);
      if (enabled && token.isNotEmpty) {
        await _reconcile();
      }
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
        },
    ];
  }

  /// Bring the socket in line with [state]: run (with a fresh handler carrying
  /// the current token) iff enabled + tokened, else stop.
  Future<void> _reconcile() async {
    await _server?.stop();
    _server = null;
    if (!state.enabled || state.token.isEmpty) return;
    final handler = ApiHandler(
      token: state.token,
      status: _status,
      contacts: _contacts,
      send: _send,
      messages: _messages,
    );
    _server = ApiServer(handler);
    try {
      await _server!.start(kApiPort);
    } catch (e) {
      debugPrint('xVeil[api]: bind failed: $e');
      _server = null;
    }
  }

  /// Turn the API on: mint a token if none exists, persist, start the socket.
  Future<void> enable() async {
    final token = state.token.isEmpty ? _mintToken() : state.token;
    final st = ref.read(storageProvider);
    await st.putSetting(_kTokenKey, token);
    await st.putSetting(_kEnabledKey, '1');
    state = state.copyWith(enabled: true, token: token);
    await _reconcile();
  }

  /// Turn the API off (keeps the token so re-enabling is one tap).
  Future<void> disable() async {
    await ref.read(storageProvider).putSetting(_kEnabledKey, '0');
    state = state.copyWith(enabled: false);
    await _reconcile();
  }

  /// Revoke the current token and mint a new one (existing clients break).
  Future<String> regenerateToken() async {
    final token = _mintToken();
    await ref.read(storageProvider).putSetting(_kTokenKey, token);
    state = state.copyWith(token: token);
    if (state.enabled) await _reconcile();
    return token;
  }

  bool get running => _server?.running ?? false;
}

final apiServerControllerProvider =
    NotifierProvider<ApiServerController, ApiConfig>(ApiServerController.new);
