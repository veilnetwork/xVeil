import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_server.dart';
import '../core/ids.dart';
import '../data/serve_source.dart';
import '../data/transport/bootstrap_invite.dart';
import '../domain/call_signal.dart' show CallMedia;
import '../domain/chat.dart';
import 'app_controller.dart';
import 'call_service.dart' show callServiceProvider, currentCallProvider;
import 'messaging.dart' show conversationsProvider, messagingServiceProvider;
import 'providers.dart';

export '../api/api_server.dart';

const String _kEnabledKey = 'api.enabled';
const String _kTokensKey = 'api.tokens';
const String _kTokenKey = 'api.token';
const String _kReadOnlyKey = 'api.readonly';
const String _kWebhookKey = 'api.webhook';

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

  Future<String?> _requestContact(String target, String greeting) async {
    try {
      final NodeId peer;
      if (target.startsWith('veil:bootstrap?')) {
        final invite = BootstrapInvite.parse(target);
        peer = invite.nodeId;
        final stack = ref.read(realStackProvider);
        if (stack == null) return 'node unavailable';
        await stack.addContact(invite);
      } else {
        peer = NodeId.fromHex(target);
      }
      await ref.read(messagingServiceProvider).sendRequest(peer, greeting);
      return null;
    } catch (e) {
      return '$e';
    }
  }

  Future<String?> _contactAction(String peerHex, String action) async {
    try {
      final peer = NodeId.fromHex(peerHex);
      final messaging = ref.read(messagingServiceProvider);
      if (action == 'accept') {
        await messaging.acceptContact(peer);
      } else if (action == 'block') {
        await messaging.blockContact(peer);
      } else {
        return 'unsupported contact action';
      }
      return null;
    } catch (e) {
      return '$e';
    }
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
      requestContact: _requestContact,
      contactAction: _contactAction,
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
