import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ids.dart';
import '../core/log.dart';
import '../data/serve_source.dart';
import '../state/app_controller.dart';
import '../state/messaging.dart';
import '../state/providers.dart';

const _debugHookEnabled = bool.fromEnvironment('XVEIL_DEBUG_HOOK');
const _debugHookPort = int.fromEnvironment(
  'XVEIL_DEBUG_HOOK_PORT',
  defaultValue: 38765,
);

/// Debug-only loopback HTTP hook for automated soak tests.
///
/// Disabled unless the app is launched with:
///
///   --dart-define=XVEIL_DEBUG_HOOK=true
///
/// Android access from the host:
///
///   adb forward tcp:38765 tcp:38765
///
/// Endpoints:
///   GET /health
///   GET /wait_ready[?timeout_ms=60000]
///   GET /identity
///   GET /contacts
///   `POST/GET /send_file?peer=<node-hex>&path=<source-path>[&name=<name>]`
///   `POST/GET /download_file?peer=<node-hex>&cid=<content-id>[&path=<dest>]`
///
/// If [path] is omitted for /download_file, the file is downloaded into the
/// encrypted app tier. If present, bytes are written unencrypted to that path.
class DebugSoakHookHost extends ConsumerStatefulWidget {
  const DebugSoakHookHost({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<DebugSoakHookHost> createState() => _DebugSoakHookHostState();
}

class _DebugSoakHookHostState extends ConsumerState<DebugSoakHookHost> {
  HttpServer? _server;
  StreamSubscription<HttpRequest>? _sub;

  @override
  void initState() {
    super.initState();
    if (kDebugMode && _debugHookEnabled) {
      unawaited(_start());
    }
  }

  Future<void> _start() async {
    try {
      final server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        _debugHookPort,
        shared: true,
      );
      _server = server;
      _sub = server.listen(_handle);
      devLog(
        () =>
            'xVeil[debug-hook]: listening on '
            '127.0.0.1:${server.port}',
      );
    } catch (e) {
      devLog(() => 'xVeil[debug-hook]: start failed: $e');
    }
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    unawaited(_server?.close(force: true));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;

  Future<void> _handle(HttpRequest req) async {
    try {
      switch (req.uri.path) {
        case '/health':
          return _json(req, {
            'ok': true,
            'phase': ref.read(appControllerProvider).phase.name,
            'ready': ref.read(appControllerProvider).phase == AppPhase.ready,
          });
        case '/wait_ready':
          return _waitReady(req);
        case '/identity':
          return _identity(req);
        case '/contacts':
          return _contacts(req);
        case '/send_file':
          return _sendFile(req);
        case '/download_file':
          return _downloadFile(req);
        default:
          return _json(req, {'ok': false, 'error': 'not found'}, status: 404);
      }
    } catch (e, st) {
      devLog(() => 'xVeil[debug-hook]: request failed: $e\n$st');
      return _json(req, {'ok': false, 'error': '$e'}, status: 500);
    }
  }

  Future<void> _waitReady(HttpRequest req) async {
    final timeoutMs =
        int.tryParse(req.uri.queryParameters['timeout_ms']?.trim() ?? '') ??
        60000;
    final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
    while (mounted && DateTime.now().isBefore(deadline)) {
      final state = ref.read(appControllerProvider);
      if (state.phase == AppPhase.ready) {
        return _json(req, {
          'ok': true,
          'phase': state.phase.name,
          'identity': _identityJson(state),
        });
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    final state = ref.read(appControllerProvider);
    return _json(req, {
      'ok': false,
      'error': 'app is not ready',
      'phase': state.phase.name,
      'identity': _identityJson(state),
    }, status: 409);
  }

  Future<void> _identity(HttpRequest req) async {
    final state = ref.read(appControllerProvider);
    return _json(req, {
      'ok': state.identity != null,
      'phase': state.phase.name,
      'identity': _identityJson(state),
    }, status: state.identity == null ? 409 : 200);
  }

  Future<void> _contacts(HttpRequest req) async {
    final ready = _requireReady(req);
    if (!ready) return;
    final conversations = await ref.read(storageProvider).loadConversations();
    return _json(req, {
      'ok': true,
      'contacts': [
        for (final c in conversations)
          {
            'nodeId': c.peer.nodeId.hex,
            'short': c.peer.nodeId.short,
            'name': c.peer.name,
            'label': c.peer.label,
            'status': c.peer.status.name,
            'canMessage': c.peer.canMessage,
            'unread': c.unread,
            'lastMessageId': c.lastMessage?.id,
            'lastMessageStatus': c.lastMessage?.status.name,
            'lastMessageFileName': c.lastMessage?.fileName,
            'lastMessageFileSize': c.lastMessage?.fileSize,
            'lastMessageContentId': c.lastMessage?.fileContentId,
            'lastMessageDownloaded': c.lastMessage?.isDownloaded,
          },
      ],
    });
  }

  Future<void> _sendFile(HttpRequest req) async {
    final ready = _requireReady(req);
    if (!ready) return;
    final peer = _peer(req);
    final path = _required(req, 'path');
    if (peer == null || path == null) return;
    final file = File(path);
    if (!await file.exists()) {
      return _json(req, {
        'ok': false,
        'error': 'source not found',
      }, status: 404);
    }
    final source = await veilSourceOpener(path);
    if (source == null) {
      return _json(req, {
        'ok': false,
        'error': 'source open failed',
      }, status: 409);
    }
    final requestedName = req.uri.queryParameters['name']?.trim();
    final name = requestedName != null && requestedName.isNotEmpty
        ? requestedName
        : _basename(path);
    try {
      final size = await file.length();
      final cid = await ref
          .read(messagingServiceProvider)
          .sendFileStreaming(
            peer,
            name,
            size,
            source.read,
            close: source.close,
            sourcePath: path,
          );
      return _json(req, {
        'ok': cid != null,
        'peer': peer.hex,
        'path': path,
        'name': name,
        'size': size,
        'contentId': cid,
      });
    } catch (_) {
      await source.close();
      rethrow;
    }
  }

  Future<void> _downloadFile(HttpRequest req) async {
    final ready = _requireReady(req);
    if (!ready) return;
    final peer = _peer(req);
    final cid = _required(req, 'cid');
    if (peer == null || cid == null) return;
    final path = req.uri.queryParameters['path']?.trim();
    final svc = ref.read(messagingServiceProvider);
    if (path == null || path.isEmpty) {
      final result = await svc.downloadContent(peer, cid);
      return _json(req, {
        'ok': true,
        'mode': 'encrypted',
        'result': result.name,
        'contentId': cid,
      });
    }

    final out = File(path);
    await out.parent.create(recursive: true);
    final raf = await out.open(mode: FileMode.write);
    var handedOff = false;
    try {
      final result = await svc.downloadContentToFile(
        peer,
        cid,
        path,
        write: (offset, bytes) async {
          await raf.setPosition(offset);
          await raf.writeFrom(bytes);
        },
        close: () async {
          await raf.close();
        },
      );
      handedOff = true;
      return _json(req, {
        'ok': true,
        'mode': 'plain-file',
        'result': result.name,
        'contentId': cid,
        'path': path,
        'size': await out.length(),
      });
    } finally {
      if (!handedOff) {
        try {
          await raf.close();
        } catch (_) {}
      }
    }
  }

  bool _requireReady(HttpRequest req) {
    final phase = ref.read(appControllerProvider).phase;
    if (phase == AppPhase.ready) return true;
    unawaited(
      _json(req, {
        'ok': false,
        'error': 'app is not ready',
        'phase': phase.name,
      }, status: 409),
    );
    return false;
  }

  NodeId? _peer(HttpRequest req) {
    final hex = _required(req, 'peer');
    if (hex == null) return null;
    try {
      return NodeId.fromHex(hex);
    } catch (e) {
      unawaited(_json(req, {'ok': false, 'error': '$e'}, status: 400));
      return null;
    }
  }

  String? _required(HttpRequest req, String key) {
    final value = req.uri.queryParameters[key]?.trim();
    if (value != null && value.isNotEmpty) return value;
    unawaited(_json(req, {'ok': false, 'error': 'missing $key'}, status: 400));
    return null;
  }
}

Map<String, Object?>? _identityJson(AppState state) {
  final identity = state.identity;
  if (identity == null) return null;
  return {
    'nodeId': identity.nodeId.hex,
    'short': identity.nodeId.short,
    'displayName': identity.displayName,
    'username': identity.username,
    'activeIdentity': state.activeIdentity,
    'isMaster': state.isMaster,
  };
}

Future<void> _json(
  HttpRequest req,
  Map<String, Object?> body, {
  int status = 200,
}) async {
  req.response.statusCode = status;
  req.response.headers.contentType = ContentType.json;
  req.response.write(jsonEncode(body));
  await req.response.close();
}

String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  final parts = normalized.split('/');
  return parts.isEmpty || parts.last.isEmpty ? 'file.bin' : parts.last;
}
