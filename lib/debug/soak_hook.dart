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
///   `POST/GET /send_file?peer=NODE_HEX&path=SOURCE_PATH[&name=NAME]`
///   `POST/GET /download_file?peer=NODE_HEX|any&cid=CONTENT_ID&path=DEST_PATH
///      [&peers=NODE_HEX,NODE_HEX][&timeout_ms=1800000]`
///
/// If [path] is omitted for /download_file, the file is downloaded into the
/// encrypted app tier. If present, bytes are written unencrypted to that path.
/// `peer=any` uses all accepted contacts as candidate holders; `peers` can add
/// an explicit comma-separated/repeated holder list.
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
    final peers = await _downloadPeers(req);
    final cid = _required(req, 'cid');
    if (peers == null || cid == null) return;
    final primaryPeer = peers.first;
    final path = req.uri.queryParameters['path']?.trim();
    final timeout = _timeout(req, defaultMs: 30 * 60 * 1000);
    final svc = ref.read(messagingServiceProvider);
    if (path == null || path.isEmpty) {
      final alreadyHeld = await ref.read(storageProvider).hasFile(cid);
      final wait = alreadyHeld ? null : _waitDownload(svc, cid, timeout);
      final result = peers.length == 1
          ? await svc.downloadContent(primaryPeer, cid)
          : await svc.downloadContentFromAny(peers, cid);
      if (result == ContentDownloadResult.noOffer) {
        return _json(req, {
          'ok': false,
          'mode': 'encrypted',
          'result': result.name,
          'contentId': cid,
          'sources': [for (final p in peers) p.hex],
          'error': 'no live offer',
        }, status: 409);
      }
      final done = wait == null ? _DownloadWait.done() : await wait;
      if (!done.ok) {
        return _json(req, {
          'ok': false,
          'mode': 'encrypted',
          'result': result.name,
          'contentId': cid,
          'sources': [for (final p in peers) p.hex],
          'error': done.error,
          'done': done.done,
          'total': done.total,
        }, status: done.timedOut ? 504 : 409);
      }
      return _json(req, {
        'ok': true,
        'mode': 'encrypted',
        'result': result.name,
        'contentId': cid,
        'sources': [for (final p in peers) p.hex],
        'done': done.done,
        'total': done.total,
      });
    }

    final out = File(path);
    await out.parent.create(recursive: true);
    final raf = await out.open(mode: FileMode.write);
    var handedOff = false;
    try {
      final wait = _waitDownload(svc, cid, timeout, savedPath: path);
      Future<void> write(int offset, Uint8List bytes) async {
        await raf.setPosition(offset);
        await raf.writeFrom(bytes);
      }

      Future<void> close() => raf.close();

      final result = peers.length == 1
          ? await svc.downloadContentToFile(
              primaryPeer,
              cid,
              path,
              write: write,
              close: close,
            )
          : await svc.downloadContentToFileFromAny(
              peers,
              cid,
              path,
              write: write,
              close: close,
            );
      if (result == ContentDownloadResult.noOffer) {
        return _json(req, {
          'ok': false,
          'mode': 'plain-file',
          'result': result.name,
          'contentId': cid,
          'sources': [for (final p in peers) p.hex],
          'path': path,
          'error': 'no live offer',
        }, status: 409);
      }
      final done = await wait;
      if (!done.ok) {
        return _json(req, {
          'ok': false,
          'mode': 'plain-file',
          'result': result.name,
          'contentId': cid,
          'sources': [for (final p in peers) p.hex],
          'path': path,
          'error': done.error,
          'done': done.done,
          'total': done.total,
          'size': await _fileLengthIfExists(out),
        }, status: done.timedOut ? 504 : 409);
      }
      handedOff = true;
      return _json(req, {
        'ok': true,
        'mode': 'plain-file',
        'result': result.name,
        'contentId': cid,
        'sources': [for (final p in peers) p.hex],
        'path': path,
        'done': done.done,
        'total': done.total,
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

  Duration _timeout(HttpRequest req, {required int defaultMs}) {
    final ms =
        int.tryParse(req.uri.queryParameters['timeout_ms']?.trim() ?? '') ??
        defaultMs;
    return Duration(milliseconds: ms.clamp(1000, 24 * 60 * 60 * 1000));
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

  Future<List<NodeId>?> _downloadPeers(HttpRequest req) async {
    final explicit = <String>[];
    var includeAnyAccepted = false;

    final peer = req.uri.queryParameters['peer']?.trim();
    if (peer != null && peer.isNotEmpty) {
      if (peer.toLowerCase() == 'any') {
        includeAnyAccepted = true;
      } else {
        explicit.add(peer);
      }
    }
    for (final raw in req.uri.queryParametersAll['peers'] ?? const <String>[]) {
      for (final part in raw.split(',')) {
        final value = part.trim();
        if (value.isEmpty) continue;
        if (value.toLowerCase() == 'any') {
          includeAnyAccepted = true;
        } else {
          explicit.add(value);
        }
      }
    }
    if (!includeAnyAccepted && explicit.isEmpty) {
      unawaited(
        _json(req, {'ok': false, 'error': 'missing peer/peers'}, status: 400),
      );
      return null;
    }

    final out = <String, NodeId>{};
    if (includeAnyAccepted) {
      final conversations = await ref.read(storageProvider).loadConversations();
      for (final conv in conversations) {
        if (conv.peer.canMessage) {
          out[conv.peer.nodeId.hex] = conv.peer.nodeId;
        }
      }
    }
    for (final hex in explicit) {
      try {
        final id = NodeId.fromHex(hex);
        out[id.hex] = id;
      } catch (e) {
        unawaited(_json(req, {'ok': false, 'error': '$e'}, status: 400));
        return null;
      }
    }
    if (out.isEmpty) {
      unawaited(
        _json(req, {
          'ok': false,
          'error': 'no accepted download peers',
        }, status: 409),
      );
      return null;
    }
    return out.values.toList(growable: false);
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

Future<int> _fileLengthIfExists(File file) async {
  try {
    return await file.exists() ? await file.length() : 0;
  } catch (_) {
    return 0;
  }
}

class _DownloadWait {
  const _DownloadWait({
    required this.ok,
    this.error,
    this.done,
    this.total,
    this.timedOut = false,
  });

  factory _DownloadWait.done({int? done, int? total}) =>
      _DownloadWait(ok: true, done: done, total: total);

  final bool ok;
  final String? error;
  final int? done;
  final int? total;
  final bool timedOut;
}

Future<_DownloadWait> _waitDownload(
  MessagingService svc,
  String cid,
  Duration timeout, {
  String? savedPath,
}) {
  final completer = Completer<_DownloadWait>();
  StreamSubscription<({String contentId, String name, String? savedToPath})>?
  receivedSub;
  StreamSubscription<({String contentId, int done, int total})>? progressSub;
  StreamSubscription<String>? failedSub;
  Timer? timer;

  void finish(_DownloadWait result) {
    if (completer.isCompleted) return;
    completer.complete(result);
    unawaited(receivedSub?.cancel());
    unawaited(progressSub?.cancel());
    unawaited(failedSub?.cancel());
    timer?.cancel();
  }

  receivedSub = svc.contentReceived.listen((e) {
    if (e.contentId != cid) return;
    if (savedPath != null && e.savedToPath != savedPath) return;
    finish(_DownloadWait.done());
  });
  progressSub = svc.contentProgress.listen((e) {
    if (e.contentId != cid) return;
    if (e.total > 0 && e.done >= e.total) {
      finish(_DownloadWait.done(done: e.done, total: e.total));
    }
  });
  failedSub = svc.contentDownloadFailed.listen((failedCid) {
    if (failedCid == cid) {
      finish(const _DownloadWait(ok: false, error: 'download failed'));
    }
  });
  timer = Timer(timeout, () {
    finish(
      _DownloadWait(
        ok: false,
        error: 'download timed out after ${timeout.inMilliseconds}ms',
        timedOut: true,
      ),
    );
  });

  return completer.future;
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
