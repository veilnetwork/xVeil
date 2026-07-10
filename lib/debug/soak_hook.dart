import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veil_flutter/veil_flutter.dart' as veil;

import '../core/ids.dart';
import '../core/log.dart';
import '../data/serve_source.dart';
import 'package:veil_media/veil_media.dart';

import '../data/transport/veil_flutter_transport.dart';
import '../domain/call_signal.dart';
import '../routing/router.dart';
import '../state/app_controller.dart';
import '../state/call_service.dart';
import '../state/mac_media_permissions.dart';
import '../state/messaging.dart';
import '../state/nickname_peers.dart';
import '../state/veil_call_media.dart' show remoteVideoFrame;
import '../state/providers.dart';
import 'ui_driver.dart';

// Default-ON so a `flutter build macos` that forgets the --dart-define can no
// longer silently compile the hook out (a stand launched from such a build
// looks exactly like "the node won't bootstrap": health polling burns its
// full window, unlock never happens). Safe because the hook is additionally
// gated on [kDebugMode] at every use site — release/profile builds dead-code
// eliminate it regardless of this value. Explicit opt-out stays available
// via --dart-define=XVEIL_DEBUG_HOOK=false.
const _debugHookEnabled = bool.fromEnvironment(
  'XVEIL_DEBUG_HOOK',
  defaultValue: true,
);
// 0 = "define absent" (a real hook port is never 0): fall through to the
// stand's per-platform convention — desktop 38765, phone 38766 — so an APK
// built without the PORT define no longer silently binds the desktop port
// (adb forward tcp:38766 then reaches nothing, which reads as a dead phone).
const _debugHookPortDefine = int.fromEnvironment('XVEIL_DEBUG_HOOK_PORT');
int get _debugHookPort => _debugHookPortDefine != 0
    ? _debugHookPortDefine
    : ((Platform.isAndroid || Platform.isIOS) ? 38766 : 38765);

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
/// UI-driver endpoints (full remote control of the running UI):
///   GET  /screenshot[?scale=1.0]      → PNG (scale=1 → logical-pixel coords)
///   GET  /ui_tree                     → semantics tree, global logical rects
///   POST /tap?node=ID|label=TEXT[&index=N]|x=&y=  [&long=true]
///   POST /scroll?dx=&dy=[&x=&y=|&label=TEXT][&steps=16]
///   POST /enter_text?text=...[&node=ID|label=TEXT]   (or JSON body)
///   POST /navigate?path=/chat/HEX     GET /route     POST /back
///   GET  /messages?peer=NODE_HEX[&limit=50]
///   POST /send_message?peer=NODE_HEX&text=...        (or JSON body)
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
  final GlobalKey _screenshotKey = GlobalKey();
  UiDriver? _uiDriver;

  /// Open media datagram channels keyed by peer node hex (Phase 2 probe).
  final Map<String, int> _mediaChannels = {};

  UiDriver get _driver => _uiDriver ??= UiDriver(_screenshotKey);

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
    _uiDriver?.dispose();
    unawaited(_sub?.cancel());
    unawaited(_server?.close(force: true));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => kDebugMode && _debugHookEnabled
      ? RepaintBoundary(key: _screenshotKey, child: widget.child)
      : widget.child;

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
        case '/lock':
          await _lock(req);
          return;
        case '/warmup_onion':
          await _warmupOnion(req);
          return;
        case '/record_voice':
          await _recordVoice(req);
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
        case '/call_place':
          await _callPlace(req);
          return;
        case '/call_accept':
          await _callAction(req, (svc) => svc.accept());
          return;
        case '/call_reject':
          await _callAction(req, (svc) => svc.reject());
          return;
        case '/call_hangup':
          await _callAction(req, (svc) => svc.hangup());
          return;
        case '/call_state':
          await _callState(req);
          return;
        case '/media_open':
          await _mediaOpen(req);
          return;
        case '/media_send':
          await _mediaSend(req);
          return;
        case '/media_recv_count':
          await _mediaRecvCount(req);
          return;
        case '/media_close':
          await _mediaClose(req);
          return;
        case '/media_engine_version':
          await _mediaEngineVersion(req);
          return;
        case '/media_engine_selftest':
          await _mediaEngineSelftest(req);
          return;
        case '/media_last_frame':
          await _mediaLastFrame(req);
          break;
        case '/media_request_mic':
          await _mediaRequestMic(req);
          return;
        case '/screenshot':
          await _screenshot(req);
          return;
        case '/ui_tree':
          await _uiTree(req);
          return;
        case '/tap':
          await _tap(req);
          return;
        case '/scroll':
          await _scroll(req);
          return;
        case '/enter_text':
          await _enterText(req);
          return;
        case '/navigate':
          await _navigate(req);
          return;
        case '/back':
          await _back(req);
          return;
        case '/route':
          await _json(req, {'ok': true, 'route': _currentRoute()});
          return;
        case '/messages':
          await _messages(req);
          return;
        case '/send_message':
          await _sendMessage(req);
          return;
        case '/nickname_claim':
          await _nicknameClaim(req);
          return;
        case '/nickname_resolve':
          await _nicknameResolve(req);
          return;
        case '/nickname_recheck':
          await _nicknameRecheck(req);
          return;
        case '/delete_message':
          await _deleteMessage(req);
          return;
        case '/has_file':
          await _hasFile(req);
          return;
        case '/compact':
          await _compact(req);
          return;
        case '/settings_keys':
          await _settingsKeys(req);
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

  /// Lock the app (tear the session down, close the container). Smoke-driver
  /// counterpart of /unlock — enables automated lock→unlock cycling to chase
  /// the intermittent "won't unlock until restart" class (ROADMAP bug #9).
  Future<void> _lock(HttpRequest req) async {
    if (req.method != 'POST') {
      return _json(req, {'ok': false, 'error': 'POST required'}, status: 405);
    }
    await ref.read(appControllerProvider.notifier).lock();
    return _json(req, {
      'ok': true,
      'phase': ref.read(appControllerProvider).phase.name,
    });
  }

  /// Smoke-drive the native voice recorder end-to-end (Dart -> FFI -> native):
  /// record for `?ms=` (default 2000), then report the byte length, duration,
  /// packet count from the VOICE_OPUS header, and the waveform. Verifies brick
  /// 2 (bindings + controller) against the real mic without any UI.
  Future<void> _recordVoice(HttpRequest req) async {
    final ms = int.tryParse(req.uri.queryParameters['ms'] ?? '') ?? 2000;
    final rec = VeilAudioRecorder.create();
    if (rec == null) {
      return _json(req, {'ok': false, 'error': 'recorder unavailable'},
          status: 500);
    }
    // The mic prompt must be answered before StartRecording sees audio.
    await MacMediaPermissions.requestMicrophone().timeout(
      const Duration(seconds: 5),
      onTimeout: () => false,
    );
    if (!rec.start()) {
      rec.dispose();
      return _json(req, {'ok': false, 'error': 'start failed (permission?)'},
          status: 500);
    }
    await Future<void>.delayed(Duration(milliseconds: ms));
    final level = rec.level;
    final elapsed = rec.elapsedMs;
    final clip = rec.stop();
    rec.dispose();
    if (clip == null) {
      return _json(req, {
        'ok': false,
        'error': 'empty clip',
        'level': level,
        'elapsedMs': elapsed,
      });
    }
    // Parse the VOICE_OPUS header for verification.
    final b = clip.bytes;
    String magic = '';
    int channels = 0, sampleRate = 0, packetCount = 0;
    if (b.length >= 18 &&
        b[0] == 0x56 && b[1] == 0x4F && b[2] == 0x50 && b[3] == 0x31) {
      magic = 'VOP1';
      channels = b[5];
      sampleRate = b[6] | (b[7] << 8) | (b[8] << 16) | (b[9] << 24);
      packetCount = b[14] | (b[15] << 8) | (b[16] << 16) | (b[17] << 24);
    }
    return _json(req, {
      'ok': true,
      'bytes': b.length,
      'durationMs': clip.durationMs,
      'level': level,
      'magic': magic,
      'channels': channels,
      'sampleRate': sampleRate,
      'packetCount': packetCount,
      'waveform': clip.waveform.map((v) => (v * 100).round()).toList(),
    });
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
    // Clear the durable auto-resume registry too: a zombie download whose
    // holder is gone (dead ephemeral serve identity → never answers
    // content-GONE) otherwise lingers the whole 14-day window, re-opening
    // stream circuits that crowd out live transfers.
    final erasedPending = await ref
        .read(messagingServiceProvider)
        .clearPendingDownloads();
    // The wholesale erases above drop the CHUNK/LOG namespaces but leave their
    // per-content bookkeeping keys in settings; those keys are what eventually
    // wedge the settings B+ index on IndexFull. Sweep them in the same call.
    final sweptSettings = await storage.sweepSettingsGarbage(wholesale: true);
    final after = await storage.namespaceCounts();
    devLog(
      () =>
          'xVeil[debug-hook]: purge_files erased=$erased erasedLog=$erasedLog '
          'erasedPending=$erasedPending sweptSettings=$sweptSettings '
          'before=$before after=$after',
    );
    return _json(req, {
      'ok': true,
      'erased': erased,
      'erasedLog': erasedLog,
      'erasedPending': erasedPending,
      'sweptSettings': sweptSettings,
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

  // -------------------------------------------------------------- UI driver

  String _currentRoute() {
    try {
      return ref
          .read(routerProvider)
          .routerDelegate
          .currentConfiguration
          .uri
          .toString();
    } catch (e) {
      return 'unknown ($e)';
    }
  }

  Future<void> _screenshot(HttpRequest req) async {
    final scale =
        double.tryParse(req.uri.queryParameters['scale']?.trim() ?? '') ?? 1.0;
    final bytes = await _driver.screenshot(scale: scale.clamp(0.1, 4.0));
    if (bytes == null) {
      return _json(req, {
        'ok': false,
        'error': 'screenshot unavailable',
      }, status: 409);
    }
    req.response.statusCode = 200;
    req.response.headers.contentType = ContentType('image', 'png');
    req.response.contentLength = bytes.length;
    req.response.add(bytes);
    await req.response.close();
  }

  Future<void> _uiTree(HttpRequest req) async {
    final tree = await _driver.uiTree();
    final view = WidgetsBinding.instance.platformDispatcher.implicitView;
    final dpr = view?.devicePixelRatio ?? 1.0;
    final size = view == null ? null : view.physicalSize / dpr;
    return _json(req, {
      'ok': tree != null,
      'route': _currentRoute(),
      if (size != null)
        'screen': {'w': size.width, 'h': size.height, 'dpr': dpr},
      'tree': tree,
    }, status: tree == null ? 409 : 200);
  }

  /// Resolves the semantics node addressed by `node=ID` or `label=TEXT[&index=N]`
  /// query params. Writes the error response itself and returns null on failure.
  Future<SemanticsNode?> _resolveNode(HttpRequest req) async {
    final p = req.uri.queryParameters;
    final nodeId = int.tryParse(p['node'] ?? '');
    if (nodeId != null) {
      final node = await _driver.findById(nodeId);
      if (node == null) {
        unawaited(
          _json(req, {
            'ok': false,
            'error': 'node $nodeId not found',
          }, status: 404),
        );
      }
      return node;
    }
    final label = p['label']?.trim();
    if (label == null || label.isEmpty) {
      unawaited(
        _json(req, {
          'ok': false,
          'error': 'missing node/label/x,y',
        }, status: 400),
      );
      return null;
    }
    final matches = await _driver.findByLabel(label);
    if (matches.isEmpty) {
      unawaited(
        _json(req, {
          'ok': false,
          'error': 'label not found: $label',
        }, status: 404),
      );
      return null;
    }
    final index = int.tryParse(p['index'] ?? '') ?? 0;
    if (index < 0 || index >= matches.length) {
      unawaited(
        _json(req, {
          'ok': false,
          'error': 'index $index out of range (found ${matches.length})',
        }, status: 400),
      );
      return null;
    }
    return matches[index].node;
  }

  Future<void> _tap(HttpRequest req) async {
    final p = req.uri.queryParameters;
    final long = (p['long'] ?? '').toLowerCase() == 'true';
    final hold = long
        ? const Duration(milliseconds: 700)
        : const Duration(milliseconds: 80);
    final x = double.tryParse(p['x'] ?? '');
    final y = double.tryParse(p['y'] ?? '');
    if (x != null && y != null) {
      await _driver.tapAt(Offset(x, y), hold: hold);
      return _json(req, {'ok': true, 'method': 'pointer', 'x': x, 'y': y});
    }
    final target = await _resolveNode(req);
    if (target == null) return; // error response already written
    final action = long ? SemanticsAction.longPress : SemanticsAction.tap;
    if (target.getSemanticsData().hasAction(action)) {
      _driver.performAction(target, action);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      return _json(req, {'ok': true, 'method': 'semantics', 'node': target.id});
    }
    final rect = await _driver.globalRectOf(target);
    if (rect == null || rect.isEmpty) {
      return _json(req, {
        'ok': false,
        'error': 'node has no tappable rect',
      }, status: 409);
    }
    await _driver.tapAt(rect.center, hold: hold);
    return _json(req, {
      'ok': true,
      'method': 'pointer',
      'node': target.id,
      'x': rect.center.dx,
      'y': rect.center.dy,
    });
  }

  Future<void> _scroll(HttpRequest req) async {
    final p = req.uri.queryParameters;
    final dx = double.tryParse(p['dx'] ?? '') ?? 0;
    final dy = double.tryParse(p['dy'] ?? '') ?? 0;
    if (dx == 0 && dy == 0) {
      return _json(req, {'ok': false, 'error': 'missing dx/dy'}, status: 400);
    }
    Offset? start;
    final x = double.tryParse(p['x'] ?? '');
    final y = double.tryParse(p['y'] ?? '');
    if (x != null && y != null) {
      start = Offset(x, y);
    } else if ((p['label'] ?? '').trim().isNotEmpty || p['node'] != null) {
      final target = await _resolveNode(req);
      if (target == null) return;
      final rect = await _driver.globalRectOf(target);
      if (rect != null && !rect.isEmpty) start = rect.center;
    }
    if (start == null) {
      final view = WidgetsBinding.instance.platformDispatcher.implicitView;
      if (view == null) {
        return _json(req, {'ok': false, 'error': 'no view'}, status: 409);
      }
      final size = view.physicalSize / view.devicePixelRatio;
      start = Offset(size.width / 2, size.height / 2);
    }
    final steps = (int.tryParse(p['steps'] ?? '') ?? 16).clamp(1, 200);
    await _driver.drag(start, Offset(dx, dy), steps: steps);
    return _json(req, {
      'ok': true,
      'from': {'x': start.dx, 'y': start.dy},
      'delta': {'dx': dx, 'dy': dy},
    });
  }

  Future<void> _enterText(HttpRequest req) async {
    final params = await _mergedParams(req);
    final text = params['text'];
    if (text == null) {
      return _json(req, {'ok': false, 'error': 'missing text'}, status: 400);
    }
    // Optional target (query params only): tap it first to focus the field.
    final q = req.uri.queryParameters;
    if ((q['node'] ?? '').isNotEmpty || (q['label'] ?? '').trim().isNotEmpty) {
      final target = await _resolveNode(req);
      if (target == null) return;
      final rect = await _driver.globalRectOf(target);
      if (rect != null && !rect.isEmpty) {
        await _driver.tapAt(rect.center);
      }
    }
    if (_driver.enterText(text)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      return _json(req, {'ok': true, 'text': text});
    }
    return _json(req, {
      'ok': false,
      'error': 'no editable text field found',
    }, status: 409);
  }

  Future<void> _navigate(HttpRequest req) async {
    final path = _required(req, 'path');
    if (path == null) return;
    // Chat routes are ROOTED like the product does it (home under the chat →
    // the back button exists); a bare go() replaces the stack and smoke
    // screenshots silently diverge from what a user sees.
    if (path.startsWith('/chat/')) {
      ref.read(routerProvider)
        ..go('/home')
        ..push(path);
    } else {
      ref.read(routerProvider).go(path);
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
    return _json(req, {'ok': true, 'route': _currentRoute()});
  }

  Future<void> _back(HttpRequest req) async {
    final router = ref.read(routerProvider);
    if (!router.canPop()) {
      return _json(req, {
        'ok': false,
        'error': 'nothing to pop',
        'route': _currentRoute(),
      }, status: 409);
    }
    router.pop();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    return _json(req, {'ok': true, 'route': _currentRoute()});
  }

  Future<void> _messages(HttpRequest req) async {
    final ready = _requireReady(req);
    if (!ready) return;
    final peer = _peer(req);
    if (peer == null) return;
    final limit = (int.tryParse(req.uri.queryParameters['limit'] ?? '') ?? 50)
        .clamp(1, 1000);
    final all = await ref.read(storageProvider).loadMessages(peer.hex);
    final tail = all.length > limit ? all.sublist(all.length - limit) : all;
    return _json(req, {
      'ok': true,
      'peer': peer.hex,
      'total': all.length,
      'messages': [
        for (final m in tail)
          {
            'id': m.id,
            'direction': m.direction.name,
            'body': m.body,
            'timestamp': m.timestamp.toIso8601String(),
            'status': m.status.name,
            'edited': m.edited,
            if (m.fileName != null) 'fileName': m.fileName,
            if (m.fileSize != null) 'fileSize': m.fileSize,
            if (m.fileContentId != null) 'fileContentId': m.fileContentId,
            if (m.isFile) 'downloaded': m.isDownloaded,
            if (m.seq != null) 'seq': m.seq,
          },
      ],
    });
  }

  Future<void> _sendMessage(HttpRequest req) async {
    final ready = _requireReady(req);
    if (!ready) return;
    final params = await _mergedParams(req);
    final peerHex = params['peer']?.trim();
    final text = params['text'];
    if (peerHex == null || peerHex.isEmpty || text == null || text.isEmpty) {
      return _json(req, {
        'ok': false,
        'error': 'missing peer/text',
      }, status: 400);
    }
    final NodeId peer;
    try {
      peer = NodeId.fromHex(peerHex);
    } catch (e) {
      return _json(req, {'ok': false, 'error': '$e'}, status: 400);
    }
    await ref.read(messagingServiceProvider).sendText(peer, text);
    return _json(req, {'ok': true, 'peer': peer.hex, 'text': text});
  }

  /// POST/GET /nickname_claim?name=X[&max_hashes=N] — mine (bounded) + sign
  /// with the sovereign key + publish. Smoke driver for the nicknames epic:
  /// use LONG names in tests (low per-length floor → ms of mining).
  Future<void> _nicknameClaim(HttpRequest req) async {
    final ready = _requireReady(req);
    if (!ready) return;
    final params = await _mergedParams(req);
    final name = params['name']?.trim();
    if (name == null || name.isEmpty) {
      return _json(req, {'ok': false, 'error': 'missing name'}, status: 400);
    }
    final maxHashes = int.tryParse(params['max_hashes'] ?? '') ?? 50_000_000;
    try {
      final selfHex = await ref.read(messagingServiceProvider).savedSelfHex();
      final self = NodeId.fromHex(selfHex).bytes;
      final norm = veil.normalizeNickname(name);
      final floor = veil.nicknameLengthFloor(norm);
      // Current owner (if any) raises the bar: strictly-greater displaces.
      final current = await veil.resolveNicknameAsync(
        selfNodeId: self,
        name: norm,
        timeoutMs: 10 * 1000,
      );
      final target =
          current == null ? floor : (current.weight * 2).clamp(floor, 1 << 62);
      final mined = await veil.mineNicknameChunkAsync(
        name: norm,
        ownerNodeId: self,
        targetWeight: target,
        maxHashes: maxHashes,
      );
      if (!mined.hitTarget) {
        return _json(req, {
          'ok': false,
          'error': 'mining budget exhausted',
          'weight': mined.weight,
          'target': target,
          'hashes': mined.hashesDone,
        }, status: 409);
      }
      final seeds = mined.seeds;
      final weight = await veil.claimNicknameAsync(
        ownerNodeId: self,
        name: norm,
        seeds: seeds,
        timeoutMs: 15 * 1000,
      );
      return _json(req, {
        'ok': true,
        'name': norm,
        'weight': weight,
        'hashes': mined.hashesDone,
        'owner': selfHex,
      });
    } catch (e) {
      return _json(req, {'ok': false, 'error': '$e'}, status: 500);
    }
  }

  /// GET /nickname_resolve?name=X — verified resolve via the embedded node.
  Future<void> _nicknameResolve(HttpRequest req) async {
    final ready = _requireReady(req);
    if (!ready) return;
    final params = await _mergedParams(req);
    final name = params['name']?.trim();
    if (name == null || name.isEmpty) {
      return _json(req, {'ok': false, 'error': 'missing name'}, status: 400);
    }
    try {
      final selfHex = await ref.read(messagingServiceProvider).savedSelfHex();
      final self = NodeId.fromHex(selfHex).bytes;
      final resolved = await veil.resolveNicknameAsync(
        selfNodeId: self,
        name: name,
        timeoutMs: 10 * 1000,
      );
      if (resolved == null) {
        return _json(req, {'ok': true, 'found': false});
      }
      return _json(req, {
        'ok': true,
        'found': true,
        'owner': NodeId(resolved.ownerNodeId).hex,
        'weight': resolved.weight,
        'issuedAt': resolved.issuedAtUnix,
      });
    } catch (e) {
      return _json(req, {'ok': false, 'error': '$e'}, status: 500);
    }
  }

  /// GET/POST /nickname_recheck?peer=<hex> — force the 6h re-verify of a
  /// pinned peer↔@name binding NOW (smoke driver for the owner-changed
  /// badge): marks the binding stale, re-reads the provider (which resolves
  /// and compares the current owner to the pinned node id), returns it.
  Future<void> _nicknameRecheck(HttpRequest req) async {
    final ready = _requireReady(req);
    if (!ready) return;
    final params = await _mergedParams(req);
    final peer = params['peer']?.trim().toLowerCase();
    if (peer == null || peer.isEmpty) {
      return _json(req, {'ok': false, 'error': 'missing peer'}, status: 400);
    }
    try {
      final storage = ref.read(storageProvider);
      final had = await markPeerNicknameStale(storage, peer);
      if (!had) {
        return _json(req, {'ok': true, 'found': false});
      }
      ref.invalidate(peerNicknameProvider(peer));
      final binding = await ref.read(peerNicknameProvider(peer).future);
      if (binding == null) {
        return _json(req, {'ok': true, 'found': false});
      }
      return _json(req, {
        'ok': true,
        'found': true,
        'name': binding.name,
        'ownerChanged': binding.ownerChanged,
        'checkedAt': binding.checkedAtUnix,
      });
    } catch (e) {
      return _json(req, {'ok': false, 'error': '$e'}, status: 500);
    }
  }

  Future<void> _hasFile(HttpRequest req) async {
    final ready = _requireReady(req);
    if (!ready) return;
    final cid = _required(req, 'cid');
    if (cid == null) return;
    final storage = ref.read(storageProvider);
    return _json(req, {
      'ok': true,
      'cid': cid,
      'hasFile': await storage.hasFile(cid),
      'namespaces': await storage.namespaceCounts(),
    });
  }

  Future<void> _compact(HttpRequest req) async {
    final ready = _requireReady(req);
    if (!ready) return;
    final params = await _mergedParams(req);
    final password = params['password']?.trim() ?? '';
    if (password.isEmpty) {
      return _json(req, {
        'ok': false,
        'error': 'missing password',
      }, status: 400);
    }
    final ctrl = ref.read(appControllerProvider.notifier);
    if (!ctrl.canCompactStorage) {
      return _json(req, {
        'ok': false,
        'error': 'compaction unavailable for this identity',
      }, status: 409);
    }
    final r = await ctrl.compactStorage(password);
    // Wait for the app to come back to ready (compaction tears down + reopens).
    final deadline = DateTime.now().add(const Duration(seconds: 120));
    while (mounted && DateTime.now().isBefore(deadline)) {
      if (ref.read(appControllerProvider).phase == AppPhase.ready) break;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return _json(req, {
      'ok': true,
      'before': r.before,
      'after': r.after,
      'phase': ref.read(appControllerProvider).phase.name,
    });
  }

  /// Diagnostic: raw settings-namespace keys + a sweep dry-run summary, for
  /// auditing what occupies the B+ index budget on an aged store.
  Future<void> _settingsKeys(HttpRequest req) async {
    final ready = _requireReady(req);
    if (!ready) return;
    final keys = await ref.read(storageProvider).settingsKeys();
    final byClass = <String, int>{};
    for (final k in keys) {
      final parts = k.split(':');
      final klass = parts.length > 1 ? '${parts[0]}:${parts[1].length > 12 ? '#' : parts[1]}' : k;
      byClass[klass] = (byClass[klass] ?? 0) + 1;
    }
    return _json(req, {
      'ok': true,
      'count': keys.length,
      'byClass': byClass,
    });
  }

  Future<void> _deleteMessage(HttpRequest req) async {
    final ready = _requireReady(req);
    if (!ready) return;
    final id = _required(req, 'id');
    if (id == null) return;
    final forEveryone =
        (req.uri.queryParameters['for_everyone'] ?? '').toLowerCase() == 'true';
    final svc = ref.read(messagingServiceProvider);
    if (forEveryone) {
      await svc.deleteForEveryone(id);
    } else {
      await svc.deleteMessageLocally(id);
    }
    return _json(req, {'ok': true, 'id': id, 'forEveryone': forEveryone});
  }

  /// Query params merged with a JSON POST body (body wins on key conflict).
  Future<Map<String, String>> _mergedParams(HttpRequest req) async {
    final params = <String, String>{...req.uri.queryParameters};
    if (req.method == 'POST') {
      final body = await utf8.decoder.bind(req).join();
      final trimmed = body.trim();
      if (trimmed.startsWith('{')) {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map<String, dynamic>) {
          decoded.forEach((k, v) {
            if (v != null) params[k] = '$v';
          });
        }
      }
    }
    return params;
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

  // ---- call control (debug driver for the Phase-1 control plane) ----------

  Future<void> _callPlace(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final peer = _peer(req);
    if (peer == null) return;
    final media = req.uri.queryParameters['media']?.trim() ?? 'audio';
    await ref.read(callServiceProvider).placeCall(
          peer,
          CallMedia(
            audio: true,
            video: media == 'video',
            screen: media == 'screen',
          ),
        );
    await _callState(req);
  }

  Future<void> _callAction(
      HttpRequest req, Future<void> Function(CallService) action) async {
    if (!_requireReady(req)) return;
    await action(ref.read(callServiceProvider));
    await _callState(req);
  }

  Future<void> _callState(HttpRequest req) async {
    final c = ref.read(currentCallProvider);
    await _json(req, {
      'ok': true,
      'call': c == null
          ? null
          : {
              'callId': c.callId,
              'peer': c.peer.hex,
              'direction': c.direction.name,
              'status': c.status.name,
              'media': {
                'audio': c.media.audio,
                'video': c.media.video,
                'screen': c.media.screen,
              },
              'localPosture': c.localPosture.name,
              'peerPosture': c.peerPosture?.name,
              'transport': c.transport?.name,
              'endReason': c.endReason?.name,
            },
    });
  }

  // ---- media datagram probe (Phase 2: lossy RTP/RTCP over the anon circuit) --
  // Drives veil_media_* through the embedded VeilFlutterTransport. The RECEIVER
  // measures delivery via /media_recv_count (no callback needed — the native
  // inbound feed counts every media datagram from a peer). The SENDER opens a
  // channel (warms the circuit) then pumps N RTP-sized datagrams.

  VeilFlutterTransport? _mediaTransport(HttpRequest req) {
    final t = ref.read(veilTransportProvider);
    if (t is VeilFlutterTransport) return t;
    unawaited(_json(req,
        {'ok': false, 'error': 'media unavailable (no embedded transport)'},
        status: 400));
    return null;
  }

  Future<void> _mediaOpen(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final peer = _peer(req);
    if (peer == null) return;
    final t = _mediaTransport(req);
    if (t == null) return;
    final chan = await t.openMediaChannel(peer.bytes);
    _mediaChannels[peer.hex] = chan;
    await _json(req, {'ok': true, 'peer': peer.hex, 'chan': chan});
  }

  Future<void> _mediaSend(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final peer = _peer(req);
    if (peer == null) return;
    final t = _mediaTransport(req);
    if (t == null) return;
    final n = int.tryParse(req.uri.queryParameters['n'] ?? '') ?? 100;
    final size = int.tryParse(req.uri.queryParameters['size'] ?? '') ?? 200;
    final gapMs = int.tryParse(req.uri.queryParameters['gap_ms'] ?? '') ?? 5;
    var chan = _mediaChannels[peer.hex];
    if (chan == null) {
      chan = await t.openMediaChannel(peer.bytes);
      _mediaChannels[peer.hex] = chan;
    }
    // rc from sendMediaDatagram: 0 queued (accepted into the drain queue),
    // 1 dropped (queue full), -1 invalid. Actual on-wire delivery is measured
    // by the RECEIVER's /media_recv_count — the queue rarely rejects.
    var queued = 0, dropped = 0, invalid = 0;
    final payload = Uint8List(size);
    for (var i = 0; i < n; i++) {
      // 4-byte big-endian sequence header so a future callback probe can spot
      // gaps; the remainder is zero-filled RTP-sized padding.
      payload[0] = (i >> 24) & 0xff;
      payload[1] = (i >> 16) & 0xff;
      payload[2] = (i >> 8) & 0xff;
      payload[3] = i & 0xff;
      final rc = t.sendMediaDatagram(chan, payload);
      if (rc == 0) {
        queued++;
      } else if (rc == 1) {
        dropped++;
      } else {
        invalid++;
      }
      if (gapMs > 0 && i < n - 1) {
        await Future<void>.delayed(Duration(milliseconds: gapMs));
      }
    }
    await _json(req, {
      'ok': true,
      'peer': peer.hex,
      'chan': chan,
      'sent': n,
      'size': size,
      'gap_ms': gapMs,
      'queued': queued,
      'queue_dropped': dropped,
      'invalid': invalid,
    });
  }

  Future<void> _mediaRecvCount(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final peer = _peer(req);
    if (peer == null) return;
    final t = _mediaTransport(req);
    if (t == null) return;
    await _json(
        req, {'ok': true, 'peer': peer.hex, 'count': t.mediaRecvCount(peer.bytes)});
  }

  Future<void> _mediaClose(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final peer = _peer(req);
    if (peer == null) return;
    final t = _mediaTransport(req);
    if (t == null) return;
    final chan = _mediaChannels.remove(peer.hex);
    if (chan != null) t.closeMediaChannel(chan);
    await _json(req, {'ok': true, 'peer': peer.hex, 'closed': chan != null});
  }

  // ---- media engine (Phase 3: libwebrtc over the veil channel) -------------
  // Loads libveil_media.dylib via FFI. This endpoint just resolves the version
  // symbol — proves the dylib is bundled + loaded + the C ABI is callable.
  Future<void> _mediaEngineVersion(HttpRequest req) async {
    try {
      await _json(req, {'ok': true, 'version': VeilMediaEngine.version()});
    } catch (e) {
      await _json(req, {'ok': false, 'error': 'veil_media unavailable: $e'},
          status: 500);
    }
  }

  // Trigger the macOS microphone TCC prompt via AVCaptureDevice.requestAccess.
  Future<void> _mediaRequestMic(HttpRequest req) async {
    final before = await MacMediaPermissions.microphoneStatus();
    final granted = await MacMediaPermissions.requestMicrophone();
    final after = await MacMediaPermissions.microphoneStatus();
    await _json(req,
        {'ok': true, 'granted': granted, 'before': before, 'after': after});
  }

  // Construct the full engine (webrtc::Call + ADM + AudioState) and enumerate
  // audio devices — proves the WebRTC stack builds in the real app context.
  // No mic capture, so no TCC prompt. Uses a dummy channel (0).
  // Serve the latest decoded remote video frame as PNG — lets the stand verify
  // the decode+render path (I420 -> RGBA -> displayable) over veil without
  // eyeballing the device.
  Future<void> _mediaLastFrame(HttpRequest req) async {
    final f = remoteVideoFrame.value;
    if (f == null) {
      await _json(req, {'ok': false, 'error': 'no frame yet'}, status: 404);
      return;
    }
    try {
      final c = Completer<ui.Image>();
      ui.decodeImageFromPixels(
          f.rgba, f.width, f.height, ui.PixelFormat.rgba8888, c.complete);
      final img = await c.future;
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      img.dispose();
      if (png == null) {
        await _json(req, {'ok': false, 'error': 'png encode failed'},
            status: 500);
        return;
      }
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType('image', 'png')
        ..add(png.buffer.asUint8List());
      await req.response.close();
    } catch (ex) {
      await _json(req, {'ok': false, 'error': '$ex'}, status: 500);
    }
  }

  Future<void> _mediaEngineSelftest(HttpRequest req) async {
    try {
      final local = Uint8List(32)..[0] = 1;
      final peer = Uint8List(32)..[0] = 2;
      final e = VeilMediaEngine.create(veilChan: 0, localId: local, peerId: peer);
      if (e == null) {
        await _json(req, {'ok': false, 'error': 'engine create returned null'},
            status: 500);
        return;
      }
      final mics = e.listAudioInputs();
      final spk = e.listAudioOutputs();
      // Exercise the audio pipeline in isolation (no call/circuit): create ->
      // startAudio -> wait so the ADM records + the delayed send-stream stats
      // diag fires (see /tmp/veil_media_diag.log) -> stop -> dispose.
      final started = e.startAudio();
      // ?video=1 also exercises the VP8 video pipeline (create send/recv streams
      // + the built-in test source under VEIL_MEDIA_TEST_VIDEO) so a runtime
      // crash surfaces here without a peer. RTP goes to the dummy channel.
      final wantVideo = req.uri.queryParameters['video'] == '1';
      bool videoStarted = false;
      if (wantVideo) videoStarted = e.startVideo(send: true, recv: true);
      await Future<void>.delayed(const Duration(seconds: 5));
      if (wantVideo) e.stopVideo();
      e.stopAudio();
      e.dispose();
      await _json(req, {
        'ok': true,
        'created': true,
        'audio_started': started,
        'video_started': videoStarted,
        'mics': mics.length,
        'speakers': spk.length,
        'mic_labels': [for (final m in mics) m.label],
        'speaker_labels': [for (final s in spk) s.label],
      });
    } catch (ex, st) {
      await _json(req, {'ok': false, 'error': '$ex', 'stack': '$st'},
          status: 500);
    }
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
