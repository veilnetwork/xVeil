import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

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
///   POST /unlock                 body: {"password":"..."} or raw password
///   GET /warmup_onion            construct messaging/onion stream services
///   GET /identity
///   GET /contacts
///   GET /wait_offer?cid=CONTENT_ID[&peer=NODE_HEX][&timeout_ms=120000]
///   `POST/GET /send_file?peer=NODE_HEX&path=SOURCE_PATH[&name=NAME]`
///   `POST/GET /download_file?peer=NODE_HEX|any&cid=CONTENT_ID&path=DEST_PATH
///      [&peers=NODE_HEX,NODE_HEX][&timeout_ms=1800000][&expect_size=BYTES]`
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
    final sw = Stopwatch()..start();
    devLog(() => 'xVeil[debug-hook]: ${req.method} ${req.uri}');
    try {
      switch (req.uri.path) {
        case '/health':
          await _json(req, {
            'ok': true,
            'phase': ref.read(appControllerProvider).phase.name,
            'ready': ref.read(appControllerProvider).phase == AppPhase.ready,
          });
          return;
        case '/wait_ready':
          await _waitReady(req);
          return;
        case '/unlock':
          await _unlock(req);
          return;
        case '/warmup_onion':
          await _warmupOnion(req);
          return;
        case '/identity':
          await _identity(req);
          return;
        case '/contacts':
          await _contacts(req);
          return;
        case '/wait_offer':
          await _waitOffer(req);
          return;
        case '/purge_files':
          await _purgeFiles(req);
          return;
        case '/send_file':
          await _sendFile(req);
          return;
        case '/download_file':
          await _downloadFile(req);
          return;
        default:
          await _json(req, {'ok': false, 'error': 'not found'}, status: 404);
          return;
      }
    } catch (e, st) {
      devLog(() => 'xVeil[debug-hook]: request failed: $e\n$st');
      try {
        return await _json(req, {'ok': false, 'error': '$e'}, status: 500);
      } catch (writeError) {
        devLog(
          () =>
              'xVeil[debug-hook]: failed to write error response after '
              '${sw.elapsedMilliseconds}ms: $writeError',
        );
        return;
      }
    } finally {
      devLog(
        () =>
            'xVeil[debug-hook]: ${req.method} ${req.uri.path} done '
            'in ${sw.elapsedMilliseconds}ms',
      );
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

  Future<void> _unlock(HttpRequest req) async {
    if (req.method != 'POST') {
      return _json(req, {'ok': false, 'error': 'POST required'}, status: 405);
    }
    final body = await utf8.decoder.bind(req).join();
    var password = body.trim();
    if (password.startsWith('{')) {
      final decoded = jsonDecode(password);
      if (decoded is Map<String, dynamic>) {
        password = (decoded['password'] as String?)?.trim() ?? '';
      }
    }
    if (password.isEmpty) {
      return _json(req, {
        'ok': false,
        'error': 'missing password',
      }, status: 400);
    }
    var state = ref.read(appControllerProvider);
    if (state.phase != AppPhase.ready) {
      await ref.read(appControllerProvider.notifier).unlock(password);
    }
    final timeoutMs =
        int.tryParse(req.uri.queryParameters['timeout_ms']?.trim() ?? '') ??
        120000;
    final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
    while (mounted && DateTime.now().isBefore(deadline)) {
      state = ref.read(appControllerProvider);
      if (state.phase == AppPhase.ready) {
        return _json(req, {
          'ok': true,
          'phase': state.phase.name,
          'identity': _identityJson(state),
        });
      }
      if (state.phase == AppPhase.locked && state.unlockError) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    state = ref.read(appControllerProvider);
    return _json(req, {
      'ok': false,
      'phase': state.phase.name,
      'unlockError': state.unlockError,
      'identity': _identityJson(state),
    }, status: 409);
  }

  Future<void> _warmupOnion(HttpRequest req) async {
    final ready = _requireReady(req);
    if (!ready) return;
    // Constructing MessagingService is enough to bind the anonymous stream hub
    // and start the native pinned-circuit background open. Keep this hook
    // debug-only and side-effect-light: no content offer, no file transfer, no
    // runtime circuit refresh while a transfer is active.
    ref.read(messagingServiceProvider);
    final state = ref.read(appControllerProvider);
    return _json(req, {
      'ok': true,
      'phase': state.phase.name,
      'identity': _identityJson(state),
    });
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

  Future<void> _waitOffer(HttpRequest req) async {
    final ready = _requireReady(req);
    if (!ready) return;
    // The hook is often the first receiver-side code touched by a headless soak.
    // Make sure the messaging service is constructed and subscribed to the
    // transport before we wait for a manifest to materialise as a stored offer.
    ref.read(messagingServiceProvider);
    final cid = _required(req, 'cid');
    if (cid == null) return;
    NodeId? peer;
    final rawPeer = req.uri.queryParameters['peer']?.trim();
    if (rawPeer != null &&
        rawPeer.isNotEmpty &&
        rawPeer.toLowerCase() != 'any') {
      try {
        peer = NodeId.fromHex(rawPeer);
      } catch (e) {
        return _json(req, {'ok': false, 'error': '$e'}, status: 400);
      }
    }
    final timeout = _timeout(req, defaultMs: 120000);
    final deadline = DateTime.now().add(timeout);
    var nextReofferAt = DateTime.now().add(const Duration(seconds: 2));
    var nextStreamProbeAt = DateTime.now().add(const Duration(seconds: 1));
    while (mounted && DateTime.now().isBefore(deadline)) {
      final found = await _findContentOffer(cid, peer: peer);
      if (found != null) {
        return _json(req, {
          'ok': true,
          'contentId': cid,
          'peer': found.peer.hex,
          'messageId': found.messageId,
          'downloaded': found.downloaded,
        });
      }
      final now = DateTime.now();
      if (peer != null && !now.isBefore(nextStreamProbeAt)) {
        if (await ref
            .read(messagingServiceProvider)
            .resolveContentOfferViaStream(peer, cid)) {
          final found = await _findContentOffer(cid, peer: peer);
          if (found != null) {
            return _json(req, {
              'ok': true,
              'contentId': cid,
              'peer': found.peer.hex,
              'messageId': found.messageId,
              'downloaded': found.downloaded,
              'via': 'stream_probe',
            });
          }
        }
        nextStreamProbeAt = now.add(const Duration(seconds: 10));
      }
      if (!now.isBefore(nextReofferAt)) {
        await _pokeContentReoffer(cid, peer: peer);
        nextReofferAt = now.add(const Duration(seconds: 5));
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return _json(req, {
      'ok': false,
      'contentId': cid,
      'peer': peer?.hex,
      'error': 'offer not observed before timeout',
    }, status: 504);
  }

  Future<({NodeId peer, String messageId, bool downloaded})?> _findContentOffer(
    String cid, {
    NodeId? peer,
  }) async {
    final storage = ref.read(storageProvider);
    if (await storage.hasFile(cid)) {
      return (
        peer: peer ?? NodeId(Uint8List(32)),
        messageId: cid,
        downloaded: true,
      );
    }
    final conversations = await storage.loadConversations();
    for (final conv in conversations) {
      if (peer != null && conv.peer.nodeId.hex != peer.hex) continue;
      for (final msg in await storage.loadMessages(conv.id)) {
        if (msg.fileContentId == cid || msg.fileId == cid) {
          return (
            peer: conv.peer.nodeId,
            messageId: msg.id,
            downloaded: msg.isDownloaded,
          );
        }
      }
    }
    return null;
  }

  Future<void> _pokeContentReoffer(String cid, {NodeId? peer}) async {
    final svc = ref.read(messagingServiceProvider);
    if (peer != null) {
      await svc.requestContentReoffer(peer, cid);
      return;
    }
    final conversations = await ref.read(storageProvider).loadConversations();
    for (final conv in conversations) {
      if (!conv.peer.canMessage) continue;
      await svc.requestContentReoffer(conv.peer.nodeId, cid);
    }
  }

  /// Bench relief: wholesale-erase the file-blob namespace so a long soak
  /// series cannot wedge the sender on HvException.IndexFull (per-record
  /// deletes never shrink the log index). Destroys every stored attachment /
  /// manifest / streamed piece of the CURRENT space — soak-bench only.
  Future<void> _purgeFiles(HttpRequest req) async {
    final ready = _requireReady(req);
    if (!ready) return;
    final storage = ref.read(storageProvider);
    final before = await storage.namespaceCounts();
    final erased = await storage.purgeFileStore();
    // The message log fills with filePost/status/tombstone rows one per run;
    // per-record tombstones never free index slots, so a multi-day soak series
    // eventually wedges every send on IndexFull. Wipe it too — bench chats are
    // disposable, contacts and seq cursors survive.
    final erasedLog = await storage.purgeMessageLog();
    final after = await storage.namespaceCounts();
    devLog(
      () =>
          'xVeil[debug-hook]: purge_files erased=$erased erasedLog=$erasedLog '
          'before=$before after=$after',
    );
    return _json(req, {
      'ok': true,
      'erased': erased,
      'erasedLog': erasedLog,
      'before': before,
      'after': after,
    });
  }

  Future<void> _sendFile(HttpRequest req) async {
    final ready = _requireReady(req);
    if (!ready) return;
    final peer = _peer(req);
    final path = _required(req, 'path');
    if (peer == null || path == null) return;
    final sw = Stopwatch()..start();
    devLog(
      () =>
          'xVeil[debug-hook]: send_file start peer=${peer.short} '
          'path=$path',
    );
    final file = File(path);
    if (!await file.exists()) {
      return _json(req, {
        'ok': false,
        'error': 'source not found',
      }, status: 404);
    }
    final size = await file.length();
    devLog(
      () =>
          'xVeil[debug-hook]: send_file source exists size=$size '
          'after ${sw.elapsedMilliseconds}ms',
    );
    final source = await veilSourceOpener(path);
    if (source == null) {
      return _json(req, {
        'ok': false,
        'error': 'source open failed',
      }, status: 409);
    }
    devLog(
      () =>
          'xVeil[debug-hook]: send_file source opened '
          'after ${sw.elapsedMilliseconds}ms',
    );
    final requestedName = req.uri.queryParameters['name']?.trim();
    final name = requestedName != null && requestedName.isNotEmpty
        ? requestedName
        : _basename(path);
    try {
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
      devLog(
        () =>
            'xVeil[debug-hook]: send_file finished cid=$cid '
            'after ${sw.elapsedMilliseconds}ms',
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
      devLog(
        () =>
            'xVeil[debug-hook]: send_file failed after '
            '${sw.elapsedMilliseconds}ms',
      );
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
    final expectedSize = _optionalNonnegativeInt(req, 'expect_size');
    if (expectedSize == -1) return;
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
    final tmp = File(
      '$path.part-${DateTime.now().microsecondsSinceEpoch}-${Isolate.current.hashCode}',
    );
    final raf = await tmp.open(mode: FileMode.write);
    var handedOff = false;
    var rafClosed = false;
    var committed = false;
    try {
      final wait = _waitDownload(svc, cid, timeout, savedPath: path);
      Future<void> write(int offset, Uint8List bytes) async {
        await raf.setPosition(offset);
        await raf.writeFrom(bytes);
      }

      Future<void> close() async {
        if (rafClosed) return;
        rafClosed = true;
        await raf.close();
        if (!await tmp.exists()) return;
        if (await out.exists()) {
          await out.delete();
        }
        await tmp.rename(path);
        committed = true;
      }

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
      final size = await _fileLengthIfExists(out);
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
          'size': size,
        }, status: done.timedOut ? 504 : 409);
      }
      if (expectedSize != null && size != expectedSize) {
        return _json(req, {
          'ok': false,
          'mode': 'plain-file',
          'result': result.name,
          'contentId': cid,
          'sources': [for (final p in peers) p.hex],
          'path': path,
          'error': 'destination size mismatch',
          'expectedSize': expectedSize,
          'size': size,
        }, status: 409);
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
        'size': size,
      });
    } finally {
      if (!handedOff) {
        try {
          if (!rafClosed) {
            rafClosed = true;
            await raf.close();
          }
        } catch (_) {}
        try {
          await tmp.delete();
        } catch (_) {}
        if (committed) {
          try {
            await out.delete();
          } catch (_) {}
        }
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

  int? _optionalNonnegativeInt(HttpRequest req, String key) {
    final raw = req.uri.queryParameters[key]?.trim();
    if (raw == null || raw.isEmpty) return null;
    final value = int.tryParse(raw);
    if (value == null || value < 0) {
      unawaited(
        _json(req, {
          'ok': false,
          'error': '$key must be a non-negative integer',
        }, status: 400),
      );
      return -1;
    }
    return value;
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
  int? lastDone;
  int? lastTotal;

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
    finish(_DownloadWait.done(done: lastDone, total: lastTotal));
  });
  progressSub = svc.contentProgress.listen((e) {
    if (e.contentId != cid) return;
    lastDone = e.done;
    lastTotal = e.total;
    // For encrypted/in-volume downloads, complete progress means the storage
    // layer has the verified blob. For plaintext-to-file downloads, progress is
    // only a liveness signal: success requires the final contentReceived event
    // carrying the exact savedPath after the sink has been closed.
    if (savedPath == null && e.total > 0 && e.done >= e.total) {
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
