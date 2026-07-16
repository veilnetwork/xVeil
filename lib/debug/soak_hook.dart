import 'dart:async';
import 'dart:convert';
import 'dart:typed_data' show BytesBuilder, Uint8List;
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veil_flutter/veil_flutter.dart' as veil;

import '../core/ids.dart';
import '../core/log.dart';
import '../data/serve_source.dart';
import 'package:veil_media/veil_media.dart';

import '../state/thumbnail.dart' show makeRgbaThumbB64, makeInlineImageB64;
import '../domain/group_message.dart' show GroupAttachment;

import '../data/transport/veil_flutter_transport.dart';
import '../domain/call_signal.dart';
import '../domain/chat.dart';
import '../domain/content_manifest.dart' show ContentManifest;
import '../domain/device_sync.dart';
import '../domain/group.dart';
import '../domain/group_policy.dart';
import '../state/group_crypto.dart';
import '../state/group_service_providers.dart';
import '../state/group_call_service.dart';
import '../routing/router.dart';
import '../domain/call_log.dart';
import '../domain/cloud.dart';
import '../domain/cloud_collection_crdt.dart';
import '../domain/cloud_rich_text_crdt.dart';
import '../domain/cloud_document.dart';
import '../state/api_server.dart';
import '../state/app_controller.dart';
import '../state/call_log.dart';
import '../state/call_service.dart';
import '../state/mailbox_service.dart';
import '../state/cloud_service.dart';
import '../state/cloud_capability_service.dart';
import '../state/cloud_document_providers.dart';
import '../state/cloud_document_replication_service.dart';
import '../state/device_settings_sync.dart';
import '../state/locale_controller.dart';
import '../state/reactions_visibility_controller.dart';
import '../state/signature_policy_controller.dart';
import '../state/mac_media_permissions.dart';
import '../state/messaging.dart';
import '../state/nickname_peers.dart';
import '../state/veil_call_media.dart' show remoteVideoFrame;
import '../state/veil_group_call_media.dart';
import '../state/providers.dart';
import '../state/sticker_message.dart';
import '../state/sticker_store.dart';
import '../state/vnote_message.dart';
import '../state/vnote_record_controller.dart' show NativeVnoteRecorder;
import '../state/vnote_play_controller.dart';
import '../state/voice_message.dart';
import '../state/transcription_controller.dart';
import '../state/whisper_ffi.dart';
import '../state/voice_play_controller.dart';
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

/// Text accepted by the group-post debug hook. `text` is the documented
/// automation spelling used by the other send hooks; `body` remains accepted
/// for compatibility with the original G1 device-verify recipe.
@visibleForTesting
String groupPostHookText(Uri uri) {
  final q = uri.queryParameters;
  return q['text'] ?? q['body'] ?? '';
}

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
  final ScreenshotOperationGate _screenshotGate = ScreenshotOperationGate();

  /// Open media datagram channels keyed by peer node hex (Phase 2 probe).
  final Map<String, int> _mediaChannels = {};
  final Map<
    String,
    ({
      VeilCapabilityEndpoint endpoint,
      StreamSubscription<Uint8List> subscription,
      int slot,
    })
  >
  _multiProviderProbes = {};

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
    for (final probe in _multiProviderProbes.values) {
      unawaited(probe.subscription.cancel());
      unawaited(probe.endpoint.close());
    }
    _multiProviderProbes.clear();
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
        case '/record_vnote':
          await _recordVnote(req);
          return;
        case '/send_vnote':
          await _sendVnote(req);
          return;
        case '/send_sticker':
          await _sendStickerHook(req);
          return;
        case '/import_sticker':
          await _importStickerHook(req);
          return;
        case '/share_pack':
          await _sharePackHook(req);
          return;
        case '/install_last_pack':
          await _installLastPackHook(req);
          return;
        case '/group_selftest':
          await _groupSelftestHook(req);
          return;
        case '/group_create':
          await _groupCreateHook(req);
          return;
        case '/group_op':
          await _groupOpHook(req);
          return;
        case '/group_post':
          await _groupPostHook(req);
          return;
        case '/group_post_image':
          await _groupPostImageHook(req);
          return;
        case '/group_post_reply':
          await _groupPostReplyHook(req);
          return;
        case '/group_leave':
          await _groupLeaveHook(req);
          return;
        case '/group_react':
          await _groupReactHook(req);
          return;
        case '/group_rename':
          await _groupRenameHook(req);
          return;
        case '/api_enable':
          await _apiEnableHook(req);
          return;
        case '/api_token':
          await _apiTokenHook(req);
          return;
        case '/api_token_add':
          await _apiTokenAddHook(req);
          return;
        case '/api_token_revoke':
          await _apiTokenRevokeHook(req);
          return;
        case '/group_post_sticker':
          await _groupPostStickerHook(req);
          return;
        case '/group_post_voice':
          await _groupPostVoiceHook(req);
          return;
        case '/group_post_ref':
          await _groupPostRefHook(req);
          return;
        case '/group_post_image_ref':
          await _groupPostImageRefHook(req);
          return;
        case '/group_post_vnote':
          await _groupPostVnoteHook(req);
          return;
        case '/group_play_vnote':
          await _groupPlayVnoteHook(req);
          return;
        case '/group_fetch_content':
          await _groupFetchContentHook(req);
          return;
        case '/group_request_content':
          await _groupRequestContentHook(req);
          return;
        case '/content_grants':
          await _contentGrantsHook(req);
          return;
        case '/content_served':
          await _contentServedHook(req);
          return;
        case '/group_unread':
          await _groupUnreadHook(req);
          return;
        case '/group_mute':
          await _groupMuteHook(req);
          return;
        case '/device_link':
          await _deviceLinkHook(req);
          return;
        case '/sovereign_probe':
          await _sovereignProbeHook(req);
          return;
        case '/device_adopt':
          await _deviceAdoptHook(req);
          return;
        case '/device_revoke':
          await _deviceRevokeHook(req);
          return;
        case '/devices':
          await _devicesHook(req);
          return;
        case '/device_post_event':
          await _devicePostEventHook(req);
          return;
        case '/device_events':
          await _deviceEventsHook(req);
          return;
        case '/cloud_put':
          await _cloudPutHook(req);
          return;
        case '/cloud_state':
          await _cloudStateHook(req);
          return;
        case '/cloud_note_save':
          await _cloudNoteSaveHook(req);
          return;
        case '/cloud_note_probe':
          await _cloudNoteProbeHook(req);
          return;
        case '/cloud_document_state':
          await _cloudDocumentStateHook(req);
          return;
        case '/cloud_document_outbox':
          await _cloudDocumentOutboxHook(req);
          return;
        case '/cloud_document_create':
          await _cloudDocumentCreateHook(req);
          return;
        case '/cloud_document_acl':
          await _cloudDocumentAclHook(req);
          return;
        case '/cloud_document_compact':
          await _cloudDocumentCompactHook(req);
          return;
        case '/cloud_document_quiesce':
          await _cloudDocumentQuiesceHook(req);
          return;
        case '/cloud_document_adopt':
          await _cloudDocumentAdoptHook(req);
          return;
        case '/cloud_document_rich':
          await _cloudDocumentRichHook(req);
          return;
        case '/cloud_document_collection':
          await _cloudDocumentCollectionHook(req);
          return;
        case '/cloud_fetch':
          await _cloudFetchHook(req);
          return;
        case '/cloud_verify':
          await _cloudVerifyHook(req);
          return;
        case '/cloud_delete':
          await _cloudDeleteHook(req);
          return;
        case '/cloud_profile':
          await _cloudProfileHook(req);
          return;
        case '/cloud_share':
          await _cloudShareHook(req);
          return;
        case '/cloud_public_create':
          await _cloudPublicCreateHook(req);
          return;
        case '/cloud_public_list':
          await _cloudPublicListHook(req);
          return;
        case '/cloud_public_revoke':
          await _cloudPublicRevokeHook(req);
          return;
        case '/cloud_public_download':
          await _cloudPublicDownloadHook(req);
          return;
        case '/cloud_capability_probe':
          await _cloudCapabilityProbeHook(req);
          return;
        case '/cloud_multi_provider_host':
          await _cloudMultiProviderHostHook(req);
          return;
        case '/cloud_multi_provider_request':
          await _cloudMultiProviderRequestHook(req);
          return;
        case '/cloud_multi_provider_close':
          await _cloudMultiProviderCloseHook(req);
          return;
        case '/conv_messages':
          await _convMessagesHook(req);
          return;
        case '/contact_set':
          await _contactSetHook(req);
          return;
        case '/contact_info':
          await _contactInfoHook(req);
          return;
        case '/pref_set':
          await _prefSetHook(req);
          return;
        case '/prefs':
          await _prefsHook(req);
          return;
        case '/call_log':
          await _callLogHook(req);
          return;
        case '/rt_trace':
          await _rtTraceHook(req);
          return;
        case '/call_log_add':
          await _callLogAddHook(req);
          return;
        case '/mirror_pull':
          await _mirrorPullHook(req);
          return;
        case '/read_conv':
          await _readConvHook(req);
          return;
        case '/contact_block':
          await _contactBlockHook(req);
          return;
        case '/add_peer':
          await _addPeerHook(req);
          return;
        case '/device_sync_now':
          await _deviceSyncNowHook(req);
          return;
        case '/group_sync_now':
          await _groupSyncNowHook(req);
          return;
        case '/group_compact':
          await _groupCompactHook(req);
          return;
        case '/read_state':
          await _readStateHook(req);
          return;
        case '/group_play_voice':
          await _groupPlayVoiceHook(req);
          return;
        case '/group_state':
          await _groupStateHook(req);
          return;
        case '/group_invite':
          await _groupInviteHook(req);
          return;
        case '/play_vnote':
          await _playVnoteHook(req);
          return;
        case '/vnote_state':
          await _vnoteStateHook(req);
          return;
        case '/send_voice':
          await _sendVoice(req);
          return;
        case '/play_voice':
          await _playVoiceHook(req);
          return;
        case '/seek_voice':
          await _seekVoiceHook(req);
          return;
        case '/voice_state':
          await _voiceStateHook(req);
          return;
        case '/voice_speed':
          await _voiceSpeedHook(req);
          return;
        case '/transcribe_voice':
          await _transcribeVoiceHook(req);
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
        case '/call_screen':
          await _callAction(
            req,
            (svc) =>
                svc.setScreenShareEnabled(req.uri.queryParameters['on'] != '0'),
          );
          return;
        case '/call_camera':
          await _callAction(
            req,
            (svc) =>
                svc.setCameraEnabled(req.uri.queryParameters['on'] != '0'),
          );
          return;
        case '/mailbox_pause':
          // Stand experiment switch: suspend/resume the periodic mailbox
          // drain to isolate its FETCH traffic from live call media.
          final svc = MailboxService.debugCurrent;
          if (svc != null) {
            svc.debugDrainPaused = req.uri.queryParameters['on'] != '0';
          }
          await _json(req, {
            'ok': svc != null,
            'paused': svc?.debugDrainPaused,
          });
          return;
        case '/call_state':
          await _callState(req);
          return;
        case '/group_call_start':
          await _groupCallStart(req);
          return;
        case '/group_call_join':
          await _groupCallAction(req, (service) => service.join());
          return;
        case '/group_call_leave':
          await _groupCallAction(req, (service) async {
            await service.leave();
            return true;
          });
          return;
        case '/group_call_end':
          await _groupCallAction(req, (service) => service.endForEveryone());
          return;
        case '/group_call_state':
          await _groupCallState(req);
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
        case '/media_request_camera':
          await _mediaRequestCamera(req);
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
  /// Record a video note for ?ms= (camera+mic where available) and report the
  /// VN01 header fields — verifies the whole native capture chain in-app.
  Future<void> _recordVnote(HttpRequest req) async {
    final ms = int.tryParse(req.uri.queryParameters['ms'] ?? '') ?? 2000;
    // NativeVnoteRecorder (not the raw FFI class) so Android runs the Dart
    // camera capturer — the hook exercises exactly what the UI does.
    final rec = NativeVnoteRecorder.create();
    if (rec == null) {
      return _json(req, {
        'ok': false,
        'error': 'recorder unavailable',
      }, status: 500);
    }
    await MacMediaPermissions.requestMicrophone().timeout(
      const Duration(seconds: 5),
      onTimeout: () => false,
    );
    await MacMediaPermissions.requestCamera().timeout(
      const Duration(seconds: 5),
      onTimeout: () => false,
    );
    if (!await rec.start()) {
      rec.dispose();
      return _json(req, {'ok': false, 'error': 'start failed'}, status: 500);
    }
    await Future<void>.delayed(Duration(milliseconds: ms));
    final preview = rec.frame();
    final clip = rec.stop();
    rec.dispose();
    if (clip == null) {
      return _json(req, {'ok': false, 'error': 'empty clip'});
    }
    final b = clip.bytes;
    final vn =
        b.length >= 24 &&
        b[0] == 0x56 &&
        b[1] == 0x4E &&
        b[2] == 0x30 &&
        b[3] == 0x31;
    return _json(req, {
      'ok': true,
      'bytes': b.length,
      'durationMs': clip.durationMs,
      'magic': vn ? 'VN01' : '',
      'flags': vn ? b[5] : 0,
      'width': vn ? (b[6] | (b[7] << 8)) : 0,
      'height': vn ? (b[8] | (b[9] << 8)) : 0,
      'frames': vn ? (b[20] | (b[21] << 8) | (b[22] << 16) | (b[23] << 24)) : 0,
      'previewW': preview?.width ?? 0,
    });
  }

  /// Play the most recent VIDEO NOTE via the play controller (bypasses tap
  /// geometry) — verifies bytes -> VNOTE1 player -> audio (voice path) +
  /// frame pulls end to end.
  Future<void> _playVnoteHook(HttpRequest req) async {
    final storage = ref.read(storageProvider);
    Message? last;
    for (final c in await storage.loadConversations()) {
      for (final m in await storage.loadMessages(c.id)) {
        if (isVnoteFileName(m.fileName) &&
            (m.fileId ?? m.fileContentId) != null) {
          last = m;
        }
      }
    }
    if (last == null) {
      return _json(req, {'ok': false, 'error': 'no video note'});
    }
    final fileKey = last.fileId ?? last.fileContentId!;
    final ctrl = ref.read(vnotePlayControllerProvider.notifier);
    await ctrl.toggle(last.id, fileKey);
    await Future<void>.delayed(const Duration(milliseconds: 700));
    final st = ref.read(vnotePlayControllerProvider);
    return _json(req, {
      'ok': st.isActive(last.id),
      'messageId': last.id,
      'durationMs': st.durationMs,
      'positionMs': st.positionMs,
      'playing': st.isPlaying(last.id),
      'frameW': ctrl.frame.value?.width ?? 0,
    });
  }

  /// Snapshot of the video-note play controller (poll to watch position).
  Future<void> _vnoteStateHook(HttpRequest req) async {
    final ctrl = ref.read(vnotePlayControllerProvider.notifier);
    final st = ref.read(vnotePlayControllerProvider);
    return _json(req, {
      'ok': true,
      'playingId': st.playingId,
      'durationMs': st.durationMs,
      'positionMs': st.positionMs,
      'paused': st.paused,
      'frameW': ctrl.frame.value?.width ?? 0,
    });
  }

  GroupService? _groupSvc() => ref.read(groupServiceProvider);

  /// Create a group named ?name= with the real identity; report id + members.
  Future<void> _groupCreateHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final svc = _groupSvc();
    if (svc == null) return _json(req, {'ok': false, 'error': 'no signer'});
    final name = req.uri.queryParameters['name']?.trim() ?? 'Group';
    final gid = await svc.createGroup(name);
    final st = await svc.stateOf(gid);
    return _json(req, {
      'ok': true,
      'groupId': gid.hex,
      'members': st?.members.length ?? 0,
      'epoch': st?.epoch ?? 0,
      'encrypted': st?.epochDescriptor != null,
    });
  }

  /// Apply a control op: ?group=&op=addMember&target=<hex>&role=member.
  Future<void> _groupOpHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final svc = _groupSvc();
    if (svc == null) return _json(req, {'ok': false, 'error': 'no signer'});
    final q = req.uri.queryParameters;
    final gidHex = q['group'];
    final op = ControlOp.fromName(q['op']);
    if (gidHex == null || op == null) {
      return _json(req, {'ok': false, 'error': 'bad group/op'});
    }
    NodeId? target;
    if (q['target'] != null) {
      try {
        target = NodeId.fromHex(q['target']!);
      } catch (_) {}
    }
    final role = GroupRole.fromName(q['role']);
    final gid = NodeId.fromHex(gidHex);
    final applied = await svc.addControlOp(gid, op, target: target, role: role);
    final st = await svc.stateOf(gid);
    return _json(req, {
      'ok': applied,
      'members': st?.members.length ?? 0,
      'epoch': st?.epoch ?? 0,
    });
  }

  /// Post a message: ?group=&text= (`body` is a legacy alias); reports
  /// success + total validated msgs.
  Future<void> _groupPostHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final svc = _groupSvc();
    if (svc == null) return _json(req, {'ok': false, 'error': 'no signer'});
    final q = req.uri.queryParameters;
    final gidHex = q['group'];
    if (gidHex == null) return _json(req, {'ok': false, 'error': 'no group'});
    final gid = NodeId.fromHex(gidHex);
    // ?silent=1 skips the delta fanout — a deterministic "lost delta" for
    // gap-fill verification (brick G1).
    final posted = await svc.postMessage(
      gid,
      groupPostHookText(req.uri),
      broadcast: q['silent'] != '1',
    );
    final msgs = await svc.messagesOf(gid);
    return _json(req, {'ok': posted, 'messages': msgs.length});
  }

  /// Toggle the automation API: ?on=1 enables (mints a token if none) + starts
  /// the loopback server; ?on=0 disables. Reports enabled/running/port.
  Future<void> _apiEnableHook(HttpRequest req) async {
    final ctrl = ref.read(apiServerControllerProvider.notifier);
    if (req.uri.queryParameters['on'] == '0') {
      await ctrl.disable();
    } else {
      await ctrl.enable();
    }
    final cfg = ref.read(apiServerControllerProvider);
    return _json(req, {
      'ok': true,
      'enabled': cfg.enabled,
      'running': ctrl.running,
      'port': kApiPort,
    });
  }

  /// Report the current automation-API bearer token (empty until enabled once).
  Future<void> _apiTokenHook(HttpRequest req) async {
    final cfg = ref.read(apiServerControllerProvider);
    var full = '';
    String? ro;
    for (final t in cfg.tokens) {
      if (t.readOnly) {
        ro ??= t.token;
      } else if (full.isEmpty) {
        full = t.token;
      }
    }
    if (full.isEmpty && cfg.tokens.isNotEmpty) full = cfg.tokens.first.token;
    return _json(req, {
      'ok': true,
      'token': full,
      if (ro != null) 'readonlyToken': ro,
      'tokens': [
        for (final t in cfg.tokens)
          {'id': t.id, 'name': t.name, 'readOnly': t.readOnly},
      ],
    });
  }

  /// Issue a new token: ?name=&ro=1 → returns its secret.
  Future<void> _apiTokenAddHook(HttpRequest req) async {
    final q = req.uri.queryParameters;
    final tok = await ref
        .read(apiServerControllerProvider.notifier)
        .addToken(q['name'] ?? 'hook', readOnly: q['ro'] == '1');
    return _json(req, {'ok': true, 'token': tok});
  }

  /// Revoke a token by ?id=.
  Future<void> _apiTokenRevokeHook(HttpRequest req) async {
    final id = req.uri.queryParameters['id'];
    if (id != null) {
      await ref.read(apiServerControllerProvider.notifier).revokeToken(id);
    }
    return _json(req, {'ok': true});
  }

  /// Leave ?group= — appends a self-leave op + broadcasts. Reports whether we
  /// still appear in our own (member-filtered) group list afterward.
  Future<void> _groupLeaveHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final svc = _groupSvc();
    if (svc == null) return _json(req, {'ok': false, 'error': 'no signer'});
    final gidHex = req.uri.queryParameters['group'];
    if (gidHex == null) return _json(req, {'ok': false, 'error': 'no group'});
    final gid = NodeId.fromHex(gidHex);
    final left = await svc.leaveGroup(gid);
    final listed = (await svc.listGroups()).any((g) => g.groupId == gid);
    return _json(req, {'ok': left, 'stillListed': listed});
  }

  /// Toggle a reaction ?emoji= on the LAST message of ?group=. Reports the
  /// aggregated reactions on that message so a 2-device test can confirm counts.
  Future<void> _groupReactHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final svc = _groupSvc();
    if (svc == null) return _json(req, {'ok': false, 'error': 'no signer'});
    final q = req.uri.queryParameters;
    final gidHex = q['group'];
    if (gidHex == null) return _json(req, {'ok': false, 'error': 'no group'});
    final gid = NodeId.fromHex(gidHex);
    final msgs = await svc.messagesOf(gid);
    if (msgs.isEmpty) {
      return _json(req, {'ok': false, 'error': 'nothing to react to'});
    }
    final ref = msgs.last.ref;
    // ?silent=1 stores the signed reaction WITHOUT the delta fanout — the
    // deterministic "lost reaction" for the gap-fill device-verify (mirrors
    // /group_post?silent=1).
    final ok = await svc.react(
      gid,
      ref,
      q['emoji'] ?? '👍',
      broadcast: q['silent'] != '1',
    );
    final agg = await svc.reactionsOf(gid);
    return _json(req, {
      'ok': ok,
      'target': ref,
      'reactions': {
        for (final e in (agg[ref] ?? const {}).entries) e.key: e.value.length,
      },
    });
  }

  /// Rename ?group= to ?name= (admins+ only). Reports the folded name back so a
  /// 2-device test can confirm the setName op propagated and folded on both ends.
  Future<void> _groupRenameHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final svc = _groupSvc();
    if (svc == null) return _json(req, {'ok': false, 'error': 'no signer'});
    final q = req.uri.queryParameters;
    final gidHex = q['group'];
    if (gidHex == null) return _json(req, {'ok': false, 'error': 'no group'});
    final gid = NodeId.fromHex(gidHex);
    final ok = await svc.renameGroup(gid, q['name'] ?? '');
    final st = await svc.stateOf(gid);
    return _json(req, {'ok': ok, 'name': st?.name});
  }

  /// Post a message replying to the LAST message in ?group= (?body=). Reports
  /// the reply ref so a 2-device test can confirm the quote resolves.
  Future<void> _groupPostReplyHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final svc = _groupSvc();
    if (svc == null) return _json(req, {'ok': false, 'error': 'no signer'});
    final q = req.uri.queryParameters;
    final gidHex = q['group'];
    if (gidHex == null) return _json(req, {'ok': false, 'error': 'no group'});
    final gid = NodeId.fromHex(gidHex);
    final existing = await svc.messagesOf(gid);
    if (existing.isEmpty) {
      return _json(req, {'ok': false, 'error': 'nothing to reply to'});
    }
    final target = existing.last;
    final posted = await svc.postMessage(
      gid,
      q['body'] ?? '',
      replyTo: target.ref,
    );
    return _json(req, {'ok': posted, 'replyTo': target.ref});
  }

  /// Post an inline image (groups media brick 1): ?group=&path=&body=; reads the
  /// file, downscales it into a size-capped inline attachment, posts, then
  /// reports the encoded dims + base64 length so a 2-device test can confirm the
  /// picture rode WHOLE inside the signed message (no content fetch).
  Future<void> _groupPostImageHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final svc = _groupSvc();
    if (svc == null) return _json(req, {'ok': false, 'error': 'no signer'});
    final q = req.uri.queryParameters;
    final gidHex = q['group'], path = q['path'];
    if (gidHex == null || path == null) {
      return _json(req, {'ok': false, 'error': 'need group+path'});
    }
    Uint8List bytes;
    try {
      bytes = await File(path).readAsBytes();
    } catch (_) {
      return _json(req, {'ok': false, 'error': 'unreadable path'});
    }
    final img = await makeInlineImageB64(bytes);
    if (img == null) {
      return _json(req, {'ok': false, 'error': 'not-image-or-too-large'});
    }
    final gid = NodeId.fromHex(gidHex);
    final posted = await svc.postMessage(
      gid,
      q['body'] ?? '',
      attachment: GroupAttachment(
        kind: 'image',
        dataB64: img.b64,
        w: img.w,
        h: img.h,
      ),
    );
    return _json(req, {
      'ok': posted,
      'w': img.w,
      'h': img.h,
      'b64len': img.b64.length,
    });
  }

  /// Post an inline STICKER (kind='sticker' → borderless render): ?group=&path=;
  /// reads the image file and posts it as a sticker attachment (no caption).
  Future<void> _groupPostStickerHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final svc = _groupSvc();
    if (svc == null) return _json(req, {'ok': false, 'error': 'no signer'});
    final q = req.uri.queryParameters;
    final gidHex = q['group'], path = q['path'];
    if (gidHex == null || path == null) {
      return _json(req, {'ok': false, 'error': 'need group+path'});
    }
    Uint8List bytes;
    try {
      bytes = await File(path).readAsBytes();
    } catch (_) {
      return _json(req, {'ok': false, 'error': 'unreadable path'});
    }
    final img = await makeInlineImageB64(bytes);
    if (img == null) {
      return _json(req, {'ok': false, 'error': 'not-image-or-too-large'});
    }
    final posted = await svc.postMessage(
      NodeId.fromHex(gidHex),
      '',
      attachment: GroupAttachment(
        kind: 'sticker',
        dataB64: img.b64,
        w: img.w,
        h: img.h,
      ),
    );
    return _json(req, {'ok': posted, 'w': img.w, 'h': img.h});
  }

  /// Record ?ms= (default 2000) from the REAL mic and post it to ?group= as an
  /// inline `voice` attachment — the same payload the composer mic produces.
  /// Reports the clip's duration, byte length and sha8 so the receiving device
  /// can prove byte-exactness via /group_state.
  Future<void> _groupPostVoiceHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final svc = _groupSvc();
    if (svc == null) return _json(req, {'ok': false, 'error': 'no signer'});
    final gidHex = req.uri.queryParameters['group'];
    if (gidHex == null) return _json(req, {'ok': false, 'error': 'no group'});
    final ms = int.tryParse(req.uri.queryParameters['ms'] ?? '') ?? 2000;
    final rec = VeilAudioRecorder.create();
    if (rec == null) {
      return _json(req, {
        'ok': false,
        'error': 'recorder unavailable',
      }, status: 500);
    }
    await MacMediaPermissions.requestMicrophone().timeout(
      const Duration(seconds: 5),
      onTimeout: () => false,
    );
    if (!rec.start()) {
      rec.dispose();
      return _json(req, {
        'ok': false,
        'error': 'start failed (permission?)',
      }, status: 500);
    }
    await Future<void>.delayed(Duration(milliseconds: ms));
    final clip = rec.stop();
    rec.dispose();
    if (clip == null || clip.bytes.isEmpty) {
      return _json(req, {'ok': false, 'error': 'empty clip'});
    }
    // ?ref=1 forces the content-path form — the composer's over-cap branch —
    // without recording 45+ seconds of real audio.
    final asRef = req.uri.queryParameters['ref'] == '1';
    String? cid;
    if (asRef) {
      cid = await ref
          .read(messagingServiceProvider)
          .registerGroupContent(clip.bytes, name: 'voice.vop1');
    }
    final posted = await svc.postMessage(
      NodeId.fromHex(gidHex),
      '',
      attachment: GroupAttachment(
        kind: 'voice',
        dataB64: asRef ? 'QQ==' : base64Encode(clip.bytes),
        w: clip.durationMs > 0 ? clip.durationMs : 1,
        h: 1,
        cid: cid,
      ),
    );
    return _json(req, {
      'ok': posted,
      'cid': ?cid,
      'durationMs': clip.durationMs,
      'bytes': clip.bytes.length,
      'sha8': _sha8(clip.bytes),
    });
  }

  /// Play the LAST inline voice clip of ?group= through the real playback
  /// controller (toggleBytes — no file-store key exists for inline clips),
  /// then report the live play state — proves decode + playback without ears.
  Future<void> _groupPlayVoiceHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final svc = _groupSvc();
    if (svc == null) return _json(req, {'ok': false, 'error': 'no signer'});
    final gidHex = req.uri.queryParameters['group'];
    if (gidHex == null) return _json(req, {'ok': false, 'error': 'no group'});
    final msgs = await svc.messagesOf(NodeId.fromHex(gidHex));
    var last = msgs.where((m) => m.attachment?.kind == 'voice').lastOrNull;
    if (last == null) {
      return _json(req, {'ok': false, 'error': 'no voice message'});
    }
    final refCid = last.attachment!.cid;
    final Uint8List bytes;
    if (refCid != null) {
      // Ref clip: play from the fetched file-store blob (its key = cid).
      final held = await ref.read(storageProvider).loadFile(refCid);
      if (held == null) {
        return _json(req, {
          'ok': false,
          'error': 'blob not held (fetch first)',
        });
      }
      bytes = held;
      await ref
          .read(voicePlayControllerProvider.notifier)
          .toggle(last.ref, refCid);
    } else {
      try {
        bytes = base64Decode(last.attachment!.dataB64);
      } catch (_) {
        return _json(req, {'ok': false, 'error': 'corrupt attachment'});
      }
      await ref
          .read(voicePlayControllerProvider.notifier)
          .toggleBytes(last.ref, bytes);
    }
    await Future<void>.delayed(const Duration(milliseconds: 700));
    final st = ref.read(voicePlayControllerProvider);
    return _json(req, {
      'ok': st.isActive(last.ref),
      'ref': last.ref,
      'cid': ?refCid,
      'durationMs': st.durationMs,
      'positionMs': st.positionMs,
      'playing': st.isPlaying(last.ref),
      'bytes': bytes.length,
      'sha8': _sha8(bytes),
    });
  }

  static String _sha8(Uint8List bytes) =>
      crypto.sha256.convert(bytes).toString().substring(0, 16);

  /// Post a message to ?group= carrying a content-path REF (?cid=) with a
  /// placeholder micro-thumb — the brick-2 verify helper (the real ref-send
  /// path lands with brick 3).
  Future<void> _groupPostRefHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final svc = _groupSvc();
    if (svc == null) return _json(req, {'ok': false, 'error': 'no signer'});
    final q = req.uri.queryParameters;
    final gidHex = q['group'], cid = q['cid'];
    if (gidHex == null || cid == null || cid.isEmpty) {
      return _json(req, {'ok': false, 'error': 'need group+cid'});
    }
    final posted = await svc.postMessage(
      NodeId.fromHex(gidHex),
      '',
      attachment: GroupAttachment(
        kind: 'image',
        dataB64: 'QUFBQQ==',
        w: 1,
        h: 1,
        cid: cid,
      ),
    );
    return _json(req, {'ok': posted, 'cid': cid});
  }

  /// Mint + sign + ship a membership-authorized fetch request for ?cid= of
  /// ?group= to ?holder= — drives the real wire path end to end.
  Future<void> _groupRequestContentHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final svc = _groupSvc();
    if (svc == null) return _json(req, {'ok': false, 'error': 'no signer'});
    final q = req.uri.queryParameters;
    final gidHex = q['group'], cid = q['cid'], holder = q['holder'];
    if (gidHex == null || cid == null || holder == null) {
      return _json(req, {'ok': false, 'error': 'need group+cid+holder'});
    }
    final ok = await svc.requestGroupContent(
      NodeId.fromHex(gidHex),
      cid,
      NodeId.fromHex(holder),
    );
    return _json(req, {'ok': ok, 'cid': cid});
  }

  /// The active membership serve grants (holder side) — brick-2 verify.
  Future<void> _contentGrantsHook(HttpRequest req) async {
    final grants = ref.read(messagingServiceProvider).debugGroupServeGrants();
    return _json(req, {'ok': true, 'grants': grants});
  }

  // ── Device group hooks (multi-device epic) ────────────────────────────────

  /// Device-safe crypto smoke: fresh phrase exists only in RAM, signs one
  /// fixed probe through the opaque handle, verifies, then closes/zeroizes.
  Future<void> _sovereignProbeHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    NativeSovereignGroupSigner? signer;
    NativeSovereignGroupSigner? recovered;
    try {
      final phrase = veil.generateMasterPhrase();
      final bundle = veil.createHybrid512SovereignBundle(phrase);
      signer = NativeSovereignGroupSigner.openBundle(bundle, phrase);
      final recoveryCode = veil.generateSovereignRecoveryCode();
      final certificate = veil.exportSovereignRecoveryCertificate(
        bundle,
        phrase,
        recoveryCode,
      );
      recovered = NativeSovereignGroupSigner.openRecoveryCertificate(
        certificate,
        recoveryCode,
      );
      final message = Uint8List.fromList(utf8.encode('xveil-sovereign-probe'));
      final signature = recovered.sign(message);
      final valid = veil.verifySovereignSignature(
        algorithm: recovered.algorithm,
        nodeId: recovered.nodeId.bytes,
        publicKey: recovered.publicKey,
        message: message,
        signature: signature,
      );
      final sameNode = recovered.nodeId == signer.nodeId;
      return _json(req, {
        'ok': valid && sameNode,
        'algorithm': recovered.algorithm,
        'node': recovered.nodeId.short,
        'sameNodeAfterRecovery': sameNode,
        'certificateBytes': certificate.length,
        'publicKeyBytes': recovered.publicKey.length,
        'signatureBytes': signature.length,
      });
    } catch (_) {
      return _json(req, {'ok': false, 'error': 'sovereign probe failed'});
    } finally {
      recovered?.close();
      signer?.close();
    }
  }

  /// Link ?peer= as one of MY devices (creates the device group on first use).
  Future<void> _deviceLinkHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final svc = _groupSvc();
    if (svc == null) return _json(req, {'ok': false, 'error': 'no signer'});
    final peer = req.uri.queryParameters['peer'];
    if (peer == null) return _json(req, {'ok': false, 'error': 'no peer'});
    final phrase = await utf8.decoder.bind(req).join();
    if (phrase.trim().isEmpty) {
      return _json(req, {'ok': false, 'error': 'phrase required'});
    }
    NativeSovereignGroupSigner? sovereign;
    var ok = false;
    try {
      sovereign = await svc.openLocalSovereign(phrase);
      ok = await svc.linkDevice(NodeId.fromHex(peer), sovereign: sovereign);
    } catch (_) {
      ok = false;
    } finally {
      sovereign?.close();
    }
    return _json(req, {'ok': ok, 'deviceGroup': await svc.deviceGroupIdHex()});
  }

  /// NEW device side of the handshake: adopt ?group= as MY device group (the
  /// id travels the QR channel in the real flow).
  Future<void> _deviceAdoptHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final svc = _groupSvc();
    if (svc == null) return _json(req, {'ok': false, 'error': 'no signer'});
    final gidHex = req.uri.queryParameters['group'];
    if (gidHex == null) return _json(req, {'ok': false, 'error': 'no group'});
    final ok = await svc.adoptDeviceGroup(NodeId.fromHex(gidHex));
    return _json(req, {'ok': ok, 'deviceGroup': ok ? gidHex : null});
  }

  /// Revoke device ?peer= (removeMember → the fold rotates the epoch).
  Future<void> _deviceRevokeHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final svc = _groupSvc();
    if (svc == null) return _json(req, {'ok': false, 'error': 'no signer'});
    final peer = req.uri.queryParameters['peer'];
    if (peer == null) return _json(req, {'ok': false, 'error': 'no peer'});
    final phrase = await utf8.decoder.bind(req).join();
    if (phrase.trim().isEmpty) {
      return _json(req, {'ok': false, 'error': 'phrase required'});
    }
    NativeSovereignGroupSigner? sovereign;
    var ok = false;
    try {
      sovereign = await svc.openLocalSovereign(phrase);
      ok = await svc.revokeDevice(NodeId.fromHex(peer), sovereign: sovereign);
    } catch (_) {
      ok = false;
    } finally {
      sovereign?.close();
    }
    return _json(req, {'ok': ok});
  }

  /// My device group's state: id + members + epoch (null id = not linked).
  Future<void> _devicesHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final svc = _groupSvc();
    if (svc == null) return _json(req, {'ok': false, 'error': 'no signer'});
    final hex = await svc.deviceGroupIdHex();
    if (hex == null) {
      return _json(req, {'ok': true, 'deviceGroup': null, 'members': []});
    }
    final gid = NodeId.fromHex(hex);
    final bundle = await svc.load(gid);
    final st = await svc.stateOf(gid);
    return _json(req, {
      'ok': true,
      'deviceGroup': hex,
      'sovereign': bundle?.manifest.isSovereignDevice ?? false,
      'sovereignOwner': bundle?.manifest.isSovereignDevice == true
          ? bundle!.manifest.owner.hex
          : null,
      'epoch': st?.epoch,
      'members': [
        for (final m in (st?.members ?? {}).values)
          if (bundle?.manifest.isSovereignDevice != true ||
              m.nodeId != bundle?.manifest.owner)
            {'id': m.nodeId.hex, 'short': m.nodeId.short, 'role': m.role.name},
      ],
    });
  }

  /// Append a sync event (?kind=&key=&v=) to my device group — brick verify.
  Future<void> _devicePostEventHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final svc = _groupSvc();
    if (svc == null) return _json(req, {'ok': false, 'error': 'no signer'});
    final q = req.uri.queryParameters;
    final kind = DeviceSyncKind.fromName(q['kind']);
    final key = q['key'];
    if (kind == null || key == null || key.isEmpty) {
      return _json(req, {'ok': false, 'error': 'need kind+key'});
    }
    // ?p= carries a RAW JSON payload (event-order test scenarios); the legacy
    // ?v= single-value form stays for the older bricks' verifies.
    Map<String, dynamic> payload = {'v': q['v'] ?? ''};
    final rawP = q['p'];
    if (rawP != null && rawP.isNotEmpty) {
      try {
        final d = jsonDecode(rawP);
        if (d is Map) payload = Map<String, dynamic>.from(d);
      } catch (_) {
        return _json(req, {'ok': false, 'error': 'bad p json'});
      }
    }
    final ok = await svc.postDeviceEvent(
      DeviceSyncEvent(
        kind: kind,
        key: key,
        tsMs: DateTime.now().millisecondsSinceEpoch,
        payload: payload,
      ),
    );
    return _json(req, {'ok': ok});
  }

  /// The folded device-sync state (kind|key → payload/ts) — brick verify.
  Future<void> _deviceEventsHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final svc = _groupSvc();
    if (svc == null) return _json(req, {'ok': false, 'error': 'no signer'});
    final folded = await svc.deviceSyncState();
    return _json(req, {
      'ok': true,
      'events': {
        for (final e in folded.entries)
          '${e.key.$1.name}|${e.key.$2}': {
            'ts': e.value.tsMs,
            'payload': e.value.payload,
          },
      },
    });
  }

  // ── Personal cloud hooks ────────────────────────────────────────────────

  /// Import deterministic in-memory bytes into the real deniable cloud path.
  /// Small and debug-only: this lets the two-device stand prove index + blob
  /// replication without writing a cleartext fixture to either device.
  Future<void> _cloudPutHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final service = ref.read(cloudServiceProvider);
    if (service == null) {
      return _json(req, {'ok': false, 'error': 'cloud unavailable'});
    }
    final q = req.uri.queryParameters;
    final size = int.tryParse(q['size'] ?? '') ?? 32768;
    final seed = int.tryParse(q['seed'] ?? '') ?? 17;
    if (size < 0 || size > 4 * 1024 * 1024) {
      return _json(req, {'ok': false, 'error': 'size must be 0..4194304'});
    }
    final name = (q['name']?.trim().isNotEmpty ?? false)
        ? q['name']!.trim()
        : 'cloud-probe-$seed.bin';
    final bytes = Uint8List.fromList([
      for (var i = 0; i < size; i++) (seed + i * 31) & 0xff,
    ]);
    try {
      final item = await service.importContent(
        name: name,
        size: bytes.length,
        readRange: (offset, length) async =>
            Uint8List.fromList(bytes.sublist(offset, offset + length)),
      );
      return _json(req, {
        'ok': true,
        'id': item.id,
        'cid': item.contentId,
        'size': item.size,
        'replicas': service.replicaCount(item),
      });
    } catch (e) {
      return _json(req, {
        'ok': false,
        'error': 'cloud import failed',
        'detail': '$e',
      });
    }
  }

  /// Materialized cloud index and verified local replica state.
  Future<void> _cloudStateHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final service = ref.read(cloudServiceProvider);
    if (service == null) {
      return _json(req, {'ok': false, 'error': 'cloud unavailable'});
    }
    final rows = await service.listItems(
      includeDeleted: req.uri.queryParameters['deleted'] == '1',
    );
    final items = <Map<String, Object?>>[];
    for (final item in rows) {
      items.add({
        'id': item.id,
        'name': item.name,
        'kind': item.kind.name,
        'cid': item.contentId,
        'size': item.size,
        'revision': item.revision,
        'heads': item.kind == CloudItemKind.note
            ? service.noteHeads(item).length
            : 1,
        'deleted': item.deleted,
        'local': await service.isLocal(item),
        'replicas': service.replicaCount(item),
      });
    }
    return _json(req, {
      'ok': true,
      'mode': service.profile.mode.name,
      'selected': service.profile.selectedItemIds.toList()..sort(),
      'items': items,
    });
  }

  /// Shared-document metadata only: no epoch keys, sealed envelopes,
  /// ciphertext or decrypted operation bytes ever leave the process.
  Future<void> _cloudDocumentStateHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final service = ref.read(cloudDocumentReplicationServiceProvider);
    final nodeBoot = ref.read(nodeBootStateProvider);
    if (service == null) {
      return _json(req, {'ok': false, 'error': 'documents unavailable'});
    }
    final documents = await service.listDocuments();
    final pending = await service.pendingInvites();
    return _json(req, {
      'ok': true,
      'canMutate': service.canMutate,
      'realTransport': ref.read(realStackProvider) != null,
      'node': nodeBoot == null
          ? null
          : {'phase': nodeBoot.phase.name, 'message': nodeBoot.message},
      'documents': [
        for (final document in documents)
          {
            'id': document.root.documentId.hex,
            'owner': document.root.owner.hex,
            'kind': document.root.kind.name,
            'codec': document.root.codec,
            'generation': document.root.generation,
            'epoch': document.currentEpoch,
            'role': document.localRole?.name,
            'members': {
              for (final member in document.members.entries)
                member.key: member.value.name,
            },
          },
      ],
      'pending': [
        for (final invite in pending)
          {
            'id': invite.frame.root.documentId.hex,
            'owner': invite.sender.hex,
            'kind': invite.frame.root.kind.name,
            'receivedAt': invite.receivedAtMs,
          },
      ],
    });
  }

  /// Durable shared-document frame metadata only. The exact wire payload is
  /// deliberately never exposed by the debug hook.
  Future<void> _cloudDocumentOutboxHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final documentId = req.uri.queryParameters['id'];
    final frames = (await ref.read(storageProvider).pendingOutboxFrames())
        .where(
          (frame) =>
              (frame.frameId.startsWith('doc:') ||
                  frame.frameId.startsWith('docc:')) &&
              (documentId == null || frame.frameId.contains(documentId)),
        )
        .toList(growable: false);
    return _json(req, {
      'ok': true,
      'count': frames.length,
      'frames': [
        for (final frame in frames)
          {'id': frame.frameId, 'peer': frame.peerHex},
      ],
    });
  }

  Future<void> _cloudDocumentCreateHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final service = ref.read(cloudDocumentReplicationServiceProvider);
    if (service == null || !service.canMutate) {
      return _json(req, {'ok': false, 'error': 'documents unavailable'});
    }
    final q = req.uri.queryParameters;
    final role =
        CloudDocumentRole.fromName(q['role']) ?? CloudDocumentRole.editor;
    if (role == CloudDocumentRole.owner) {
      return _json(req, {'ok': false, 'error': 'role must be editor/viewer'});
    }
    try {
      final kind = switch (q['kind']) {
        null || 'note' => CloudDocumentKind.note,
        'tasks' || 'taskList' => CloudDocumentKind.taskList,
        'calendar' => CloudDocumentKind.calendar,
        _ => null,
      };
      if (kind == null) {
        return _json(req, {'ok': false, 'error': 'bad kind'});
      }
      final codec = switch (kind) {
        CloudDocumentKind.note => cloudRichTextCodecV1,
        CloudDocumentKind.taskList => cloudTaskListCodecV1,
        CloudDocumentKind.calendar => cloudCalendarCodecV1,
      };
      final created = await service.createDocument(kind: kind, codec: codec);
      if (created == null) {
        return _json(req, {'ok': false, 'error': 'create rejected'});
      }
      CloudDocumentMutationResult? granted;
      final peerHex = q['peer'];
      if (peerHex != null) {
        granted = await service.grant(
          created.documentId,
          NodeId.fromHex(peerHex),
          role,
        );
      }
      return _json(req, {
        'ok': peerHex == null || granted != null,
        'id': created.documentId,
        'granted': granted != null,
        'fullyQueued': granted?.fullyQueued,
        'failed': granted?.failedRecipients.map((peer) => peer.hex).toList(),
      });
    } catch (error) {
      return _json(req, {'ok': false, 'error': '$error'});
    }
  }

  Future<void> _cloudDocumentAclHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final service = ref.read(cloudDocumentReplicationServiceProvider);
    final q = req.uri.queryParameters;
    final documentId = q['id'];
    final action = q['action'];
    if (service == null || documentId == null || action == null) {
      return _json(req, {'ok': false, 'error': 'need documents+id+action'});
    }
    try {
      CloudDocumentMutationResult? result;
      if (action == 'rotate') {
        result = await service.rotateEpoch(documentId);
      } else {
        final peerHex = q['peer'];
        if (peerHex == null) {
          return _json(req, {'ok': false, 'error': 'need peer'});
        }
        final peer = NodeId.fromHex(peerHex);
        switch (action) {
          case 'grant':
            final role = CloudDocumentRole.fromName(q['role']);
            if (role != CloudDocumentRole.editor &&
                role != CloudDocumentRole.viewer) {
              return _json(req, {'ok': false, 'error': 'bad role'});
            }
            result = await service.grant(documentId, peer, role!);
            break;
          case 'role':
            final role = CloudDocumentRole.fromName(q['role']);
            if (role != CloudDocumentRole.editor &&
                role != CloudDocumentRole.viewer) {
              return _json(req, {'ok': false, 'error': 'bad role'});
            }
            result = await service.setRole(documentId, peer, role!);
            break;
          case 'revoke':
            result = await service.revoke(documentId, peer);
            break;
          case 'resend':
            final ok = await service.resendInvite(documentId, peer);
            return _json(req, {'ok': ok, 'id': documentId});
          default:
            return _json(req, {'ok': false, 'error': 'bad action'});
        }
      }
      return _json(req, {
        'ok': result != null,
        'id': documentId,
        'fullyQueued': result?.fullyQueued,
        'failed': result?.failedRecipients.map((peer) => peer.hex).toList(),
      });
    } catch (error) {
      return _json(req, {'ok': false, 'error': '$error'});
    }
  }

  /// Owner-only physical compaction. The response is structural metadata;
  /// neither checkpoint cleartext nor encrypted payload bytes are exposed.
  Future<void> _cloudDocumentCompactHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final service = ref.read(cloudDocumentReplicationServiceProvider);
    final id = req.uri.queryParameters['id'];
    if (service == null || id == null) {
      return _json(req, {'ok': false, 'error': 'need documents+id'});
    }
    final result = await service.compactDocument(id);
    return _json(req, {
      'ok': result != null,
      'id': id,
      'generation': result?.generation,
      'controlsBefore': result?.controlsBefore,
      'operationsBefore': result?.operationsBefore,
      'envelopesBefore': result?.envelopesBefore,
      'payloadsBefore': result?.payloadsBefore,
      'operationsAfter': result?.operationsAfter,
      'fullyQueued': result?.fullyQueued,
      'failed': result?.failedRecipients.map((peer) => peer.hex).toList(),
    });
  }

  /// Starts the same signed convergence round used by automatic compaction.
  /// Only bounded structural counters are exposed on this loopback debug hook.
  Future<void> _cloudDocumentQuiesceHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final service = ref.read(cloudDocumentReplicationServiceProvider);
    final id = req.uri.queryParameters['id'];
    if (service == null || id == null) {
      return _json(req, {'ok': false, 'error': 'need documents+id'});
    }
    final started = await service.requestQuiescence(id, ignoreThreshold: true);
    final status = service.quiescenceStatus(id);
    return _json(req, {
      'ok': started,
      'id': id,
      'required': status?.requiredEditors.length,
      'acknowledged': status?.acknowledgedEditors.length,
      'complete': status?.complete,
    });
  }

  Future<void> _cloudDocumentAdoptHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final service = ref.read(cloudDocumentReplicationServiceProvider);
    final id = req.uri.queryParameters['id'];
    if (service == null || id == null) {
      return _json(req, {'ok': false, 'error': 'need documents+id'});
    }
    return _json(req, {'ok': await service.adopt(id), 'id': id});
  }

  /// Drives the encrypted rich-text layer while returning only length/digest
  /// metadata. Decrypted text exists in RAM for this loopback-only request and
  /// is never echoed or written to disk by the hook.
  Future<void> _cloudDocumentRichHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final service = ref.read(cloudDocumentReplicationServiceProvider);
    final q = req.uri.queryParameters;
    final id = q['id'];
    final action = q['action'] ?? 'probe';
    if (service == null || id == null) {
      return _json(req, {'ok': false, 'error': 'need documents+id'});
    }
    try {
      var state = await service.loadRichText(id);
      if (state == null) {
        return _json(req, {'ok': false, 'error': 'rich document unavailable'});
      }
      CloudDocumentMutationResult? mutation;
      if (action == 'save') {
        final text = q['text'];
        if (text == null) {
          return _json(req, {'ok': false, 'error': 'need text'});
        }
        final style = q['style'] == 'bold'
            ? const CloudRichTextStyle(bold: true)
            : const CloudRichTextStyle();
        mutation = await service.saveRichText(
          id,
          base: state.snapshot,
          text: text,
          styles: List.filled(text.characters.length, style),
        );
      } else if (action == 'delete') {
        mutation = await service.deleteRichTextDocument(
          id,
          parentOperationIds: state.snapshot.headOperationIds,
        );
      } else if (action != 'probe') {
        return _json(req, {'ok': false, 'error': 'bad action'});
      }
      if (action != 'probe' && mutation == null) {
        return _json(req, {'ok': false, 'error': 'mutation rejected'});
      }
      if (mutation != null) state = await service.loadRichText(id);
      if (state == null) {
        return _json(req, {'ok': false, 'error': 'reload failed'});
      }
      final bytes = utf8.encode(state.snapshot.text);
      return _json(req, {
        'ok': true,
        'id': id,
        'bytes': bytes.length,
        'sha256': crypto.sha256.convert(bytes).toString(),
        'heads': state.snapshot.headOperationIds.length,
        'epoch': state.currentEpoch,
        'role': state.localRole?.name,
        'deleted': state.snapshot.isDeleted,
        'recovered': state.snapshot.hasConcurrentRecovery,
        'invalid': state.snapshot.invalidOperationIds.length,
        'unavailable': state.snapshot.unavailableOperationIds.length,
        'fullyQueued': mutation?.fullyQueued,
      });
    } catch (error) {
      return _json(req, {'ok': false, 'error': '$error'});
    }
  }

  /// Drives encrypted task/calendar collections. Cleartext fields are accepted
  /// only on loopback, materialized only in RAM, and never echoed. The response
  /// contains bounded structural metadata plus a digest of canonical rows.
  Future<void> _cloudDocumentCollectionHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final service = ref.read(cloudDocumentReplicationServiceProvider);
    final q = req.uri.queryParameters;
    final id = q['id'];
    final action = q['action'] ?? 'probe';
    if (service == null || id == null) {
      return _json(req, {'ok': false, 'error': 'need documents+id'});
    }
    try {
      var state = await service.loadCollection(id);
      if (state == null) {
        return _json(req, {
          'ok': false,
          'error': 'collection document unavailable',
        });
      }
      CloudDocumentMutationResult? mutation;
      final heads = state.snapshot.headOperationIds;
      switch (action) {
        case 'probe':
          break;
        case 'task_create':
          if (state.kind != CloudDocumentKind.taskList) {
            return _json(req, {'ok': false, 'error': 'not tasks'});
          }
          final title = q['title']?.trim();
          if (title == null || title.isEmpty) {
            return _json(req, {'ok': false, 'error': 'need title'});
          }
          final entityId = service.newCollectionEntityId();
          mutation = await service.appendCollectionEdits(id, [
            CloudCollectionEdit.create(
              entityId,
              CloudTask(
                id: entityId,
                title: title,
                notes: q['notes'] ?? '',
                completed: false,
                dueAtMs: int.tryParse(q['due'] ?? ''),
                position: state.tasks.length,
              ).toFields(),
            ),
          ], parentOperationIds: heads);
          break;
        case 'task_toggle_first':
          if (state.kind != CloudDocumentKind.taskList || state.tasks.isEmpty) {
            return _json(req, {'ok': false, 'error': 'no task'});
          }
          final task = state.tasks.first;
          mutation = await service.appendCollectionEdits(id, [
            CloudCollectionEdit.patch(task.id, {'completed': !task.completed}),
          ], parentOperationIds: heads);
          break;
        case 'event_create':
          if (state.kind != CloudDocumentKind.calendar) {
            return _json(req, {'ok': false, 'error': 'not calendar'});
          }
          final title = q['title']?.trim();
          final start = int.tryParse(q['start'] ?? '');
          final end = int.tryParse(q['end'] ?? '');
          if (title == null ||
              title.isEmpty ||
              start == null ||
              end == null ||
              end < start) {
            return _json(req, {'ok': false, 'error': 'need title/start/end'});
          }
          final entityId = service.newCollectionEntityId();
          mutation = await service.appendCollectionEdits(id, [
            CloudCollectionEdit.create(
              entityId,
              CloudCalendarEvent(
                id: entityId,
                title: title,
                notes: q['notes'] ?? '',
                startAtMs: start,
                endAtMs: end,
                allDay: q['all_day'] == '1',
                location: q['location'] ?? '',
              ).toFields(),
            ),
          ], parentOperationIds: heads);
          break;
        case 'delete_first':
          final firstId = state.snapshot.rows.firstOrNull?.id;
          if (firstId == null) {
            return _json(req, {'ok': false, 'error': 'collection empty'});
          }
          mutation = await service.appendCollectionEdits(id, [
            CloudCollectionEdit.delete(firstId),
          ], parentOperationIds: heads);
          break;
        default:
          return _json(req, {'ok': false, 'error': 'bad action'});
      }
      if (action != 'probe' && mutation == null) {
        return _json(req, {'ok': false, 'error': 'mutation rejected'});
      }
      if (mutation != null) state = await service.loadCollection(id);
      if (state == null) {
        return _json(req, {'ok': false, 'error': 'reload failed'});
      }
      final canonical = Uint8List.fromList(
        utf8.encode(
          jsonEncode([
            for (final row in state.snapshot.rows)
              {
                'id': row.id,
                'fields': {
                  for (final key in row.fields.keys.toList()..sort())
                    key: row.fields[key],
                },
              },
          ]),
        ),
      );
      try {
        return _json(req, {
          'ok': true,
          'id': id,
          'kind': state.kind.name,
          'count': state.snapshot.rows.length,
          'sha256': crypto.sha256.convert(canonical).toString(),
          'heads': state.snapshot.headOperationIds.length,
          'epoch': state.currentEpoch,
          'role': state.localRole?.name,
          'invalid': state.snapshot.invalidOperationIds.length,
          'unavailable': state.snapshot.unavailableOperationIds.length,
          'fullyQueued': mutation?.fullyQueued,
        });
      } finally {
        canonical.fillRange(0, canonical.length, 0);
      }
    } catch (error) {
      return _json(req, {'ok': false, 'error': '$error'});
    }
  }

  Future<void> _cloudNoteSaveHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final service = ref.read(cloudServiceProvider);
    final q = req.uri.queryParameters;
    final title = q['title'];
    final body = q['body'];
    if (service == null || title == null || body == null) {
      return _json(req, {'ok': false, 'error': 'need cloud+title+body'});
    }
    try {
      final item = await service.saveTextNote(
        itemId: q['id'],
        expectedRevision: int.tryParse(q['revision'] ?? ''),
        expectedContentId: q['cid'],
        mergeParentContentIds: q['parents']
            ?.split(',')
            .where((value) => value.isNotEmpty),
        title: title,
        body: body,
      );
      return _json(req, {
        'ok': true,
        'id': item.id,
        'cid': item.contentId,
        'size': item.size,
        'revision': item.revision,
        'heads': service.noteHeads(item).length,
      });
    } on CloudEditConflict catch (conflict) {
      return _json(req, {
        'ok': false,
        'error': 'conflict',
        'revision': conflict.current.revision,
        'cid': conflict.current.contentId,
      });
    } catch (error) {
      return _json(req, {'ok': false, 'error': '$error'});
    }
  }

  /// Verify/decrypt a note entirely in RAM and return only a digest/length;
  /// the debug hook never writes or returns cleartext note content.
  Future<void> _cloudNoteProbeHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final service = ref.read(cloudServiceProvider);
    final id = req.uri.queryParameters['id'];
    if (service == null || id == null) {
      return _json(req, {'ok': false, 'error': 'need cloud+id'});
    }
    final item = (await service.listItems())
        .where((candidate) => candidate.id == id)
        .firstOrNull;
    if (item == null || item.kind != CloudItemKind.note) {
      return _json(req, {'ok': false, 'error': 'note not found'});
    }
    try {
      final body = await service.loadTextNote(item);
      final bytes = utf8.encode(body);
      return _json(req, {
        'ok': true,
        'id': item.id,
        'revision': item.revision,
        'heads': service.noteHeads(item).length,
        'bytes': bytes.length,
        'sha256': crypto.sha256.convert(bytes).toString(),
      });
    } catch (error) {
      return _json(req, {'ok': false, 'error': '$error'});
    }
  }

  Future<void> _cloudFetchHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final service = ref.read(cloudServiceProvider);
    final id = req.uri.queryParameters['id'];
    if (service == null || id == null) {
      return _json(req, {'ok': false, 'error': 'need cloud+id'});
    }
    final item = (await service.listItems())
        .where((row) => row.id == id)
        .firstOrNull;
    if (item == null) return _json(req, {'ok': false, 'error': 'not found'});
    final started = await service.ensureLocal(item);
    return _json(req, {
      'ok': started,
      'id': id,
      'local': await service.isLocal(item),
    });
  }

  Future<void> _cloudVerifyHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final service = ref.read(cloudServiceProvider);
    if (service == null) {
      return _json(req, {'ok': false, 'error': 'cloud unavailable'});
    }
    final result = await service.verifyAll(
      repair: req.uri.queryParameters['repair'] == '1',
    );
    return _json(req, {'ok': true, 'verified': result});
  }

  Future<void> _cloudDeleteHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final service = ref.read(cloudServiceProvider);
    final id = req.uri.queryParameters['id'];
    if (service == null || id == null) {
      return _json(req, {'ok': false, 'error': 'need cloud+id'});
    }
    await service.deleteItem(id);
    return _json(req, {'ok': true, 'id': id});
  }

  Future<void> _cloudProfileHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final service = ref.read(cloudServiceProvider);
    if (service == null) {
      return _json(req, {'ok': false, 'error': 'cloud unavailable'});
    }
    final raw = req.uri.queryParameters['mode'];
    final mode = CloudReplicationMode.values
        .where((candidate) => candidate.name == raw)
        .firstOrNull;
    if (mode == null) {
      return _json(req, {'ok': false, 'error': 'bad mode'});
    }
    await service.setProfile(
      CloudReplicationProfile(
        mode: mode,
        selectedItemIds: service.profile.selectedItemIds,
      ),
    );
    return _json(req, {'ok': true, 'mode': mode.name});
  }

  Future<void> _cloudShareHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final service = ref.read(cloudServiceProvider);
    final q = req.uri.queryParameters;
    final id = q['id'];
    final peer = q['peer'];
    if (service == null || id == null || peer == null) {
      return _json(req, {'ok': false, 'error': 'need cloud+id+peer'});
    }
    final item = (await service.listItems())
        .where((candidate) => candidate.id == id)
        .firstOrNull;
    if (item == null) return _json(req, {'ok': false, 'error': 'not found'});
    final ok = await service.shareWithContact(item, NodeId.fromHex(peer));
    return _json(req, {
      'ok': ok,
      'id': id,
      'cid': item.contentId,
      'peer': peer,
    });
  }

  Future<void> _cloudPublicCreateHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final cloud = ref.read(cloudServiceProvider);
    final capabilities = ref.read(cloudCapabilityServiceProvider);
    final id = req.uri.queryParameters['id'];
    if (cloud == null || capabilities == null || id == null) {
      return _json(req, {
        'ok': false,
        'error': 'need cloud capability service+id',
      });
    }
    final item = (await cloud.listItems())
        .where((candidate) => candidate.id == id)
        .firstOrNull;
    if (item == null) return _json(req, {'ok': false, 'error': 'not found'});
    try {
      final share = await capabilities.createShare(item);
      return _json(req, {
        'ok': true,
        'shareId': share.shareId,
        'itemId': share.itemId,
        'cid': share.contentId,
        'expiresAtMs': share.expiresAtMs,
        'link': share.link,
      });
    } catch (error) {
      return _json(req, {'ok': false, 'error': '$error'});
    }
  }

  Future<void> _cloudPublicListHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final service = ref.read(cloudCapabilityServiceProvider);
    if (service == null) {
      return _json(req, {'ok': false, 'error': 'unavailable'});
    }
    final shares = await service.listShares();
    return _json(req, {
      'ok': true,
      'shares': [
        for (final share in shares)
          {
            'shareId': share.shareId,
            'itemId': share.itemId,
            'cid': share.contentId,
            'expiresAtMs': share.expiresAtMs,
          },
      ],
    });
  }

  Future<void> _cloudPublicRevokeHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final service = ref.read(cloudCapabilityServiceProvider);
    final shareId = req.uri.queryParameters['share'];
    if (service == null || shareId == null) {
      return _json(req, {'ok': false, 'error': 'need service+share'});
    }
    return _json(req, {'ok': await service.revoke(shareId)});
  }

  Future<void> _cloudPublicDownloadHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final cloud = ref.read(cloudServiceProvider);
    final capabilities = ref.read(cloudCapabilityServiceProvider);
    final link = req.uri.queryParameters['link'];
    if (cloud == null || capabilities == null || link == null) {
      return _json(req, {
        'ok': false,
        'error': 'need cloud capability service+link',
      });
    }
    try {
      final capability = await capabilities.download(link);
      final item = await cloud.adoptCapability(capability);
      return _json(req, {
        'ok': true,
        'id': item.id,
        'cid': item.contentId,
        'size': item.size,
      });
    } catch (error) {
      return _json(req, {'ok': false, 'error': '$error'});
    }
  }

  /// Native CLOUD-2B F0 smoke: bind/register the same secret alias and identity
  /// on two endpoint ids. Both app id and service key must stay stable without
  /// depending on sovereign node id; seed buffers are always scrubbed.
  Future<void> _cloudCapabilityProbeHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final transport = ref.read(veilTransportProvider);
    if (transport is! VeilFlutterTransport) {
      return _json(req, {'ok': false, 'error': 'native transport unavailable'});
    }
    final random = Random.secure();
    if (req.uri.queryParameters['bind_only'] == '1') {
      final name =
          'probe-${List.generate(12, (_) => random.nextInt(256)).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join()}';
      final firstApp = await transport.bindCapabilityEndpoint(
        name: name,
        endpointId: 37,
      );
      final firstAppId = Uint8List.fromList(firstApp.appId);
      final secondApp = await transport.bindCapabilityEndpoint(
        name: name,
        endpointId: 39,
      );
      final stable = listEquals(firstAppId, secondApp.appId);
      await firstApp.close();
      await secondApp.close();
      return _json(req, {
        'ok': stable,
        'stableCapabilityAppId': stable,
        'capabilityAppId': firstAppId
            .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
            .join(),
      });
    }
    final seedMaterial = Uint8List.fromList([
      for (var i = 0; i < 32; i++) random.nextInt(256),
    ]);
    final firstSeed = Uint8List.fromList(seedMaterial);
    final secondSeed = Uint8List.fromList(seedMaterial);
    seedMaterial.fillRange(0, seedMaterial.length, 0);
    final name =
        'probe-${List.generate(12, (_) => random.nextInt(256)).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join()}';
    VeilCapabilityEndpoint? first;
    VeilCapabilityEndpoint? second;
    try {
      first = await transport.hostCapabilityEndpoint(
        identitySeed: firstSeed,
        name: name,
        endpointId: 50,
      );
      final firstPublicKey = Uint8List.fromList(first.servicePublicKey);
      final firstAppId = Uint8List.fromList(first.appId);
      second = await transport.hostCapabilityEndpoint(
        identitySeed: secondSeed,
        name: name,
        endpointId: 51,
      );
      final stableServiceKey = listEquals(
        firstPublicKey,
        second.servicePublicKey,
      );
      final stableCapabilityAppId = listEquals(firstAppId, second.appId);
      await first.close();
      await second.close();
      await second.close();
      return _json(req, {
        'ok': stableServiceKey && stableCapabilityAppId,
        'servicePublicKey': firstPublicKey
            .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
            .join(),
        'capabilityAppId': firstAppId
            .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
            .join(),
        'seedZeroized':
            firstSeed.every((byte) => byte == 0) &&
            secondSeed.every((byte) => byte == 0),
        'stableServiceKey': stableServiceKey,
        'stableCapabilityAppId': stableCapabilityAppId,
        'withdrawIdempotent': true,
      });
    } catch (error) {
      return _json(req, {
        'ok': false,
        'error': 'capability service probe failed',
        'detail': '$error',
        'seedZeroized':
            firstSeed.every((byte) => byte == 0) &&
            secondSeed.every((byte) => byte == 0),
      });
    } finally {
      firstSeed.fillRange(0, firstSeed.length, 0);
      secondSeed.fillRange(0, secondSeed.length, 0);
      await first?.close();
      await second?.close();
    }
  }

  /// Debug-only cross-device proof for the native provider-slot protocol.
  /// Every device derives the same ephemeral service identity and app id from
  /// a public test tag, but publishes it in its explicit distinct slot. The
  /// request/response stays anonymous and carries only the slot as proof; no
  /// sovereign identity or secret seed is returned or written to disk.
  Future<void> _cloudMultiProviderHostHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final transport = ref.read(veilTransportProvider);
    final tag = req.uri.queryParameters['tag'];
    final slot = int.tryParse(req.uri.queryParameters['slot'] ?? '');
    if (transport is! VeilFlutterTransport ||
        tag == null ||
        !RegExp(r'^[A-Za-z0-9_-]{1,48}$').hasMatch(tag) ||
        slot == null ||
        slot < 0 ||
        slot >= 8) {
      return _json(req, {
        'ok': false,
        'error': 'need transport+tag+slot(0..7)',
      });
    }
    await _closeMultiProviderProbe(tag);
    final seed = Uint8List.fromList(
      crypto.sha256.convert(utf8.encode('xveil-mp-seed-v1:$tag')).bytes,
    );
    VeilCapabilityEndpoint? endpoint;
    try {
      endpoint = await transport.hostCapabilityEndpoint(
        identitySeed: seed,
        name: 'xveil-mp-app-v1:$tag',
        endpointId: 52,
        providerSlot: slot,
      );
      final hosted = endpoint;
      final subscription = hosted.messages.listen((wire) async {
        try {
          final decoded = jsonDecode(utf8.decode(wire));
          if (decoded is! Map || decoded['tag'] != tag) return;
          final returnService = Uint8List.fromList(
            base64Url.decode(base64Url.normalize(decoded['return'] as String)),
          );
          final returnApp = Uint8List.fromList(
            base64Url.decode(base64Url.normalize(decoded['app'] as String)),
          );
          final returnEndpoint = decoded['endpoint'] as int;
          final nonce = decoded['nonce'] as String;
          if (returnService.length != 32 ||
              returnApp.length != 32 ||
              returnEndpoint <= 0 ||
              returnEndpoint > 0xffff ||
              nonce.length > 128) {
            return;
          }
          await hosted.sendAnonymous(
            servicePublicKey: returnService,
            targetAppId: returnApp,
            targetEndpointId: returnEndpoint,
            data: Uint8List.fromList(
              utf8.encode(
                jsonEncode({'tag': tag, 'nonce': nonce, 'slot': slot}),
              ),
            ),
          );
        } catch (_) {}
      });
      _multiProviderProbes[tag] = (
        endpoint: hosted,
        subscription: subscription,
        slot: slot,
      );
      return _json(req, {
        'ok': true,
        'tag': tag,
        'slot': slot,
        'service': base64Url.encode(hosted.servicePublicKey),
        'app': base64Url.encode(hosted.appId),
        'endpoint': hosted.endpointId,
        'seedZeroized': seed.every((byte) => byte == 0),
      });
    } catch (error) {
      await endpoint?.close();
      return _json(req, {'ok': false, 'error': '$error'});
    } finally {
      seed.fillRange(0, seed.length, 0);
    }
  }

  Future<void> _cloudMultiProviderRequestHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final transport = ref.read(veilTransportProvider);
    final q = req.uri.queryParameters;
    final tag = q['tag'];
    if (transport is! VeilFlutterTransport || tag == null) {
      return _json(req, {'ok': false, 'error': 'need transport+tag'});
    }
    VeilCapabilityEndpoint? endpoint;
    StreamSubscription<Uint8List>? subscription;
    final response = Completer<Map<String, dynamic>>();
    final random = Random.secure();
    final seed = Uint8List.fromList([
      for (var i = 0; i < 32; i++) random.nextInt(256),
    ]);
    try {
      final service = Uint8List.fromList(
        base64Url.decode(base64Url.normalize(q['service']!)),
      );
      final app = Uint8List.fromList(
        base64Url.decode(base64Url.normalize(q['app']!)),
      );
      final targetEndpoint = int.parse(q['endpoint']!);
      if (service.length != 32 || app.length != 32) {
        throw const FormatException('bad service/app key');
      }
      endpoint = await transport.hostTransientCapabilityEndpoint(
        identitySeed: seed,
        name: 'xveil-mp-return-${DateTime.now().microsecondsSinceEpoch}',
        endpointId: 53,
      );
      final nonce = base64Url.encode(
        Uint8List.fromList([for (var i = 0; i < 16; i++) random.nextInt(256)]),
      );
      subscription = endpoint.messages.listen((wire) {
        if (response.isCompleted) return;
        try {
          final decoded = jsonDecode(utf8.decode(wire));
          if (decoded is Map &&
              decoded['tag'] == tag &&
              decoded['nonce'] == nonce &&
              decoded['slot'] is int) {
            response.complete(Map<String, dynamic>.from(decoded));
          }
        } catch (_) {}
      });
      await endpoint.sendAnonymous(
        servicePublicKey: service,
        targetAppId: app,
        targetEndpointId: targetEndpoint,
        data: Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'tag': tag,
              'nonce': nonce,
              'return': base64Url.encode(endpoint.servicePublicKey),
              'app': base64Url.encode(endpoint.appId),
              'endpoint': endpoint.endpointId,
            }),
          ),
        ),
      );
      final received = await response.future.timeout(
        const Duration(seconds: 30),
      );
      return _json(req, {'ok': true, ...received});
    } catch (error) {
      return _json(req, {'ok': false, 'error': '$error'});
    } finally {
      seed.fillRange(0, seed.length, 0);
      await subscription?.cancel();
      await endpoint?.close();
    }
  }

  Future<void> _cloudMultiProviderCloseHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final tag = req.uri.queryParameters['tag'];
    if (tag == null) return _json(req, {'ok': false, 'error': 'need tag'});
    final existed = _multiProviderProbes.containsKey(tag);
    await _closeMultiProviderProbe(tag);
    return _json(req, {'ok': true, 'closed': existed});
  }

  Future<void> _closeMultiProviderProbe(String tag) async {
    final probe = _multiProviderProbes.remove(tag);
    if (probe == null) return;
    await probe.subscription.cancel();
    await probe.endpoint.close();
  }

  /// The stored 1:1 messages of conversation ?peer= (bodies + direction) —
  /// verifies the multi-device mirror landed a message this device never
  /// received natively.
  Future<void> _convMessagesHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final peer = req.uri.queryParameters['peer'];
    if (peer == null) return _json(req, {'ok': false, 'error': 'no peer'});
    final msgs = await ref.read(storageProvider).loadMessages(peer);
    return _json(req, {
      'ok': true,
      'count': msgs.length,
      'messages': [
        for (final m in msgs)
          {
            'id': m.id,
            'dir': m.direction.name,
            'body': m.body,
            if (m.fileContentId != null) 'cid': m.fileContentId,
            if (m.fileId != null) 'fileId': m.fileId,
            if (m.fileName != null) 'fname': m.fileName,
            if (m.fileSize != null) 'fsize': m.fileSize,
            if (m.thumb != null) 'hasThumb': true,
          },
      ],
    });
  }

  /// Pull mirrored attachment ?cid= from MY OTHER DEVICES over the
  /// membership-authorized content path (brick 4b) — the same hook the chat
  /// download button fires via [MessagingService.deviceContentPull].
  Future<void> _mirrorPullHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final cid = req.uri.queryParameters['cid'];
    if (cid == null) return _json(req, {'ok': false, 'error': 'no cid'});
    final pull = ref.read(messagingServiceProvider).deviceContentPull;
    if (pull == null) {
      return _json(req, {'ok': false, 'error': 'no bridge'});
    }
    await pull(cid);
    return _json(req, {'ok': true});
  }

  /// Set contact preferences of ?peer= — only the params present are applied
  /// (?name= ?pin=1|0 ?mute=1|0 ?arc=1|0 ?apd=1|0 ?ret=days) — exercises the
  /// REAL setter path, so a linked device should receive a contactUp event.
  Future<void> _contactSetHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final q = req.uri.queryParameters;
    final peerHex = q['peer'];
    if (peerHex == null) return _json(req, {'ok': false, 'error': 'no peer'});
    final peer = NodeId.fromHex(peerHex);
    final messaging = ref.read(messagingServiceProvider);
    if (q.containsKey('name')) {
      await messaging.setContactName(peer, q['name']);
    }
    if (q.containsKey('pin')) {
      await messaging.setContactPinned(peer, q['pin'] == '1');
    }
    if (q.containsKey('mute')) {
      await messaging.setContactMuted(peer, q['mute'] == '1');
    }
    if (q.containsKey('arc')) {
      await messaging.setContactArchived(peer, q['arc'] == '1');
    }
    if (q.containsKey('apd')) {
      await messaging.setContactAllowPeerDelete(peer, q['apd'] == '1');
    }
    if (q.containsKey('ret')) {
      await messaging.setContactRetention(peer, int.tryParse(q['ret'] ?? ''));
    }
    return _json(req, {'ok': true});
  }

  /// The FULL stored preference fields of contact ?peer= — brick-4 verify
  /// (the /contacts list stays lean).
  Future<void> _contactInfoHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final peerHex = req.uri.queryParameters['peer'];
    if (peerHex == null) return _json(req, {'ok': false, 'error': 'no peer'});
    final c = await ref
        .read(storageProvider)
        .getContact(NodeId.fromHex(peerHex));
    if (c == null) return _json(req, {'ok': false, 'error': 'unknown'});
    return _json(req, {
      'ok': true,
      'name': c.name,
      'status': c.status.name,
      'pinned': c.pinned,
      'archived': c.archived,
      'muted': c.muted,
      'mutedUntilMs': c.mutedUntil?.millisecondsSinceEpoch,
      'retentionDays': c.retentionDays,
      'allowPeerDelete': c.allowPeerDelete,
      'p2pOverride': c.p2pOverride.name,
    });
  }

  /// Set an allowlisted app preference ?key=&v= through its REAL controller
  /// (the same path a settings-screen toggle takes), so a linked device should
  /// receive a settingSet event.
  Future<void> _prefSetHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final q = req.uri.queryParameters;
    final v = q['v'] ?? '';
    switch (q['key']) {
      case kSyncShowReactions:
        await ref.read(showReactionsProvider.notifier).set(v == '1');
      case kSyncLocale:
        await ref
            .read(localeProvider.notifier)
            .setLocale(v.isEmpty ? null : ui.Locale(v));
      case kSyncSignaturePolicy:
        SignaturePolicy? policy;
        for (final p in SignaturePolicy.values) {
          if (p.name == v) policy = p;
        }
        if (policy == null) {
          return _json(req, {'ok': false, 'error': 'bad policy'});
        }
        await ref.read(signaturePolicyProvider.notifier).set(policy);
      default:
        return _json(req, {'ok': false, 'error': 'unknown key'});
    }
    return _json(req, {'ok': true});
  }

  /// The PERSISTED values of the synced app preferences (read straight from
  /// prefs, not controller state — survives the lazy controller build).
  Future<void> _prefsHook(HttpRequest req) async {
    final prefs = await ref.read(prefsProvider.future);
    return _json(req, {
      'ok': true,
      kSyncShowReactions: prefs.getBool(kSyncShowReactions),
      kSyncLocale: prefs.getString(kSyncLocale),
      kSyncSignaturePolicy: prefs.getString(kSyncSignaturePolicy),
    });
  }

  /// The persisted call journal, newest first — brick-4 verify.
  Future<void> _callLogHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final entries = await ref.read(callLogStoreProvider).list();
    return _json(req, {
      'ok': true,
      'count': entries.length,
      'entries': [for (final e in entries) e.toJson()],
    });
  }

  /// Append a LOCAL journal row (?peer= ?id= ?out=1|0 ?vid=1|0 ?outcome=
  /// ?dur=sec) through the real store, so the tap mirrors it to linked
  /// devices — a call FSM run is not needed to verify the sync path.
  Future<void> _callLogAddHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final q = req.uri.queryParameters;
    final peerHex = q['peer'];
    if (peerHex == null) return _json(req, {'ok': false, 'error': 'no peer'});
    final outcome =
        CallLogOutcome.fromName(q['outcome']) ?? CallLogOutcome.missed;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final wrote = await ref
        .read(callLogStoreProvider)
        .add(
          CallLogEntry(
            id: q['id'] ?? 'hook-$nowMs',
            peerHex: peerHex,
            outgoing: q['out'] == '1',
            video: q['vid'] == '1',
            outcome: outcome,
            atMs: nowMs,
            durationSec: int.tryParse(q['dur'] ?? '') ?? 0,
          ),
        );
    return _json(req, {'ok': wrote});
  }

  /// Toggle the embedded node's slow-inbound-dispatch trace (?on=1|0). While
  /// on, any single inbound dispatch stalling a session loop ≥25ms surfaces
  /// in the node log as `session.rt_trace.slow_dispatch` naming the frame
  /// family/size — the call-RTT-spike investigation's probe for inbound
  /// PROCESSING head-of-line ahead of REALTIME media.
  Future<void> _rtTraceHook(HttpRequest req) async {
    final on = req.uri.queryParameters['on'] == '1';
    try {
      veil.veilDebugSetRtTrace(on ? 1 : 0);
      return _json(req, {'ok': true, 'on': on});
    } catch (e) {
      return _json(req, {'ok': false, 'error': '$e'});
    }
  }

  /// Mark conversation ?peer= read through the REAL messaging path (what an
  /// opened chat screen does) — a linked device should receive a readMark.
  Future<void> _readConvHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final peer = req.uri.queryParameters['peer'];
    if (peer == null) return _json(req, {'ok': false, 'error': 'no peer'});
    await ref.read(messagingServiceProvider).markRead(peer);
    return _json(req, {
      'ok': true,
      'marker': await ref.read(storageProvider).readMarker(peer),
    });
  }

  /// Ship the FULL device-group snapshot to my other devices right now — the
  /// brick-4e catch-up nudge (normally fired once per boot by the bridge).
  Future<void> _deviceSyncNowHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final svc = _groupSvc();
    if (svc == null) return _json(req, {'ok': false, 'error': 'no signer'});
    final shipped = await svc.nudgeDeviceSync();
    return _json(req, {'ok': true, 'shipped': shipped});
  }

  /// Fan the sync VECTOR of every group (brick G1) — the boot catch-up,
  /// triggerable on demand for verification.
  Future<void> _groupSyncNowHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final svc = _groupSvc();
    if (svc == null) return _json(req, {'ok': false, 'error': 'no signer'});
    await svc.nudgeGroupSyncAll();
    return _json(req, {'ok': true});
  }

  /// Compact superseded state rows without touching ordinary chat history.
  Future<void> _groupCompactHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final svc = _groupSvc();
    if (svc == null) return _json(req, {'ok': false, 'error': 'no signer'});
    final gidHex = req.uri.queryParameters['group'];
    if (gidHex == null) return _json(req, {'ok': false, 'error': 'no group'});
    final result = await svc.compactStateLogs(NodeId.fromHex(gidHex));
    if (result == null) {
      return _json(req, {'ok': false, 'error': 'unknown group'});
    }
    return _json(req, {
      'ok': true,
      'changed': result.changed,
      'messages': [result.messagesBefore, result.messagesAfter],
      'control': [result.controlBefore, result.controlAfter],
      'reactions': [result.reactionsBefore, result.reactionsAfter],
    });
  }

  /// Redeem a bootstrap-peer invite ?uri= (url-encoded `veil:bootstrap?…`) on
  /// the RUNNING node — adds the peer + dials it over IPC, exactly like the
  /// scan/paste flow. Ops tooling: lets a stand swap in a temporary entry
  /// node at runtime (e.g. when the builtin seeds' hoster is down) without
  /// rebuilding or committing environment-specific descriptors.
  Future<void> _addPeerHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final uri = req.uri.queryParameters['uri'];
    if (uri == null || uri.isEmpty) {
      return _json(req, {'ok': false, 'error': 'no uri'});
    }
    final t = ref.read(veilTransportProvider);
    if (t is! VeilFlutterTransport) {
      return _json(req, {'ok': false, 'error': 'no embedded transport'});
    }
    try {
      await t.joinInvite(uri);
      return _json(req, {'ok': true});
    } catch (e) {
      return _json(req, {'ok': false, 'error': '$e'});
    }
  }

  /// Block (?on=1) or unblock (?on=0) contact ?peer= through the REAL
  /// messaging flow — a linked device should mirror the relationship change
  /// (brick 4d contact-list sync).
  Future<void> _contactBlockHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final peerHex = req.uri.queryParameters['peer'];
    if (peerHex == null) return _json(req, {'ok': false, 'error': 'no peer'});
    final peer = NodeId.fromHex(peerHex);
    final messaging = ref.read(messagingServiceProvider);
    if (req.uri.queryParameters['on'] == '1') {
      await messaging.blockContact(peer);
    } else {
      await messaging.unblockContact(peer);
    }
    final c = await ref.read(storageProvider).getContact(peer);
    return _json(req, {'ok': true, 'status': c?.status.name});
  }

  /// The stored read watermark of ?conv= (peer hex) or ?group= (gid hex) —
  /// brick-4c verify.
  Future<void> _readStateHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final conv = req.uri.queryParameters['conv'];
    final group = req.uri.queryParameters['group'];
    if (conv != null) {
      return _json(req, {
        'ok': true,
        'marker': await ref.read(storageProvider).readMarker(conv),
      });
    }
    if (group != null) {
      final raw = await ref
          .read(storageProvider)
          .getSetting('group.seen:$group');
      return _json(req, {'ok': true, 'marker': int.tryParse(raw ?? '') ?? 0});
    }
    return _json(req, {'ok': false, 'error': 'need conv or group'});
  }

  /// Toggle the LOCAL notification mute of ?group= (?on=1|0).
  Future<void> _groupMuteHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final svc = _groupSvc();
    if (svc == null) return _json(req, {'ok': false, 'error': 'no signer'});
    final gidHex = req.uri.queryParameters['group'];
    if (gidHex == null) return _json(req, {'ok': false, 'error': 'no group'});
    final on = req.uri.queryParameters['on'] == '1';
    final gid = NodeId.fromHex(gidHex);
    await svc.setGroupMuted(gid, on);
    return _json(req, {'ok': true, 'muted': await svc.isGroupMuted(gid)});
  }

  /// The unread count of ?group= (the badge's number) — brick verify.
  Future<void> _groupUnreadHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final svc = _groupSvc();
    if (svc == null) return _json(req, {'ok': false, 'error': 'no signer'});
    final gidHex = req.uri.queryParameters['group'];
    if (gidHex == null) return _json(req, {'ok': false, 'error': 'no group'});
    final unread = await svc.unreadOf(NodeId.fromHex(gidHex));
    return _json(req, {'ok': true, 'unread': unread});
  }

  /// What the serve gate would see for ?cid=: blob presence, manifest blob
  /// presence + parseability — the serve-side triage for content-path bricks.
  Future<void> _contentServedHook(HttpRequest req) async {
    final cid = req.uri.queryParameters['cid'];
    if (cid == null) return _json(req, {'ok': false, 'error': 'missing cid'});
    final storage = ref.read(storageProvider);
    final hasBlob = await storage.hasFile(cid);
    final mfBytes = await storage.loadFile('mf:$cid');
    Object? mfParsed;
    if (mfBytes != null) {
      try {
        final m = ContentManifest.fromJson(
          jsonDecode(utf8.decode(mfBytes)) as Map<String, dynamic>,
        );
        mfParsed = m == null
            ? 'PARSE-NULL'
            : {'id': m.contentId, 'size': m.size, 'pieces': m.pieceCount};
      } catch (e) {
        mfParsed = 'THROW: $e';
      }
    }
    return _json(req, {
      'ok': true,
      'hasBlob': hasBlob,
      'mfBytes': mfBytes?.length,
      'manifest': mfParsed,
    });
  }

  /// Record a REAL ?ms= video note (camera+mic) and post it to ?group= as a
  /// content-path REF — the composer camera's path. Reports cid/bytes/sha8.
  Future<void> _groupPostVnoteHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final svc = _groupSvc();
    if (svc == null) return _json(req, {'ok': false, 'error': 'no signer'});
    final gidHex = req.uri.queryParameters['group'];
    if (gidHex == null) return _json(req, {'ok': false, 'error': 'no group'});
    final ms = int.tryParse(req.uri.queryParameters['ms'] ?? '') ?? 2000;
    final rec = NativeVnoteRecorder.create();
    if (rec == null) {
      return _json(req, {
        'ok': false,
        'error': 'recorder unavailable',
      }, status: 500);
    }
    if (!await rec.start()) {
      rec.dispose();
      return _json(req, {
        'ok': false,
        'error': 'start failed (permission?)',
      }, status: 500);
    }
    await Future<void>.delayed(Duration(milliseconds: ms));
    final clip = rec.stop();
    rec.dispose();
    if (clip == null || clip.bytes.isEmpty) {
      return _json(req, {'ok': false, 'error': 'empty clip'});
    }
    final cid = await ref
        .read(messagingServiceProvider)
        .registerGroupContent(clip.bytes, name: 'vnote.vn01');
    final posted = await svc.postMessage(
      NodeId.fromHex(gidHex),
      '',
      attachment: GroupAttachment(
        kind: 'vnote',
        dataB64: 'QQ==',
        w: clip.durationMs > 0 ? clip.durationMs : 1,
        h: 1,
        cid: cid,
      ),
    );
    return _json(req, {
      'ok': posted,
      'cid': cid,
      'durationMs': clip.durationMs,
      'bytes': clip.bytes.length,
      'sha8': _sha8(clip.bytes),
    });
  }

  /// Play the LAST vnote ref of ?group= through the shared player (the
  /// fetched blob's file-store key is its cid) and report the live state.
  Future<void> _groupPlayVnoteHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final svc = _groupSvc();
    if (svc == null) return _json(req, {'ok': false, 'error': 'no signer'});
    final gidHex = req.uri.queryParameters['group'];
    if (gidHex == null) return _json(req, {'ok': false, 'error': 'no group'});
    final msgs = await svc.messagesOf(NodeId.fromHex(gidHex));
    final last = msgs
        .where(
          (m) => m.attachment?.kind == 'vnote' && m.attachment?.cid != null,
        )
        .lastOrNull;
    if (last == null) {
      return _json(req, {'ok': false, 'error': 'no vnote ref'});
    }
    final cid = last.attachment!.cid!;
    if (!await ref.read(storageProvider).hasFile(cid)) {
      return _json(req, {'ok': false, 'error': 'blob not held (fetch first)'});
    }
    await ref.read(vnotePlayControllerProvider.notifier).toggle(last.ref, cid);
    await Future<void>.delayed(const Duration(milliseconds: 900));
    final st = ref.read(vnotePlayControllerProvider);
    return _json(req, {
      'ok': st.isActive(last.ref),
      'ref': last.ref,
      'cid': cid,
      'durationMs': st.durationMs,
      'positionMs': st.positionMs,
      'playing': st.isPlaying(last.ref),
    });
  }

  /// Post a REAL image at ?path= to ?group= in REF form (register the full
  /// bytes for serving, ship only the thumb + cid) — the composer's path.
  Future<void> _groupPostImageRefHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final svc = _groupSvc();
    if (svc == null) return _json(req, {'ok': false, 'error': 'no signer'});
    final q = req.uri.queryParameters;
    final gidHex = q['group'], path = q['path'];
    if (gidHex == null || path == null) {
      return _json(req, {'ok': false, 'error': 'need group+path'});
    }
    Uint8List bytes;
    try {
      bytes = await File(path).readAsBytes();
    } catch (_) {
      return _json(req, {'ok': false, 'error': 'unreadable path'});
    }
    final thumb = await makeInlineImageB64(bytes, rawMax: 16000);
    if (thumb == null) {
      return _json(req, {'ok': false, 'error': 'not an image / no thumb rung'});
    }
    final cid = await ref
        .read(messagingServiceProvider)
        .registerGroupContent(bytes, name: path.split('/').last);
    final posted = await svc.postMessage(
      NodeId.fromHex(gidHex),
      '',
      attachment: GroupAttachment(
        kind: 'image',
        dataB64: thumb.b64,
        w: thumb.w,
        h: thumb.h,
        cid: cid,
      ),
    );
    return _json(req, {
      'ok': posted,
      'cid': cid,
      'bytes': bytes.length,
      'sha8': _sha8(bytes),
      'thumbB64Len': thumb.b64.length,
    });
  }

  /// Drive the member-side fetch of ?cid= from ?holder= for ?group= and poll
  /// the file store up to ~25s — reports whether the full bytes landed and
  /// their sha8 (byte-exactness against the poster's report).
  Future<void> _groupFetchContentHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final svc = _groupSvc();
    if (svc == null) return _json(req, {'ok': false, 'error': 'no signer'});
    final q = req.uri.queryParameters;
    final gidHex = q['group'], cid = q['cid'], holder = q['holder'];
    if (gidHex == null || cid == null || holder == null) {
      return _json(req, {'ok': false, 'error': 'need group+cid+holder'});
    }
    final started = await svc.fetchGroupContent(
      NodeId.fromHex(gidHex),
      cid,
      NodeId.fromHex(holder),
    );
    final storage = ref.read(storageProvider);
    for (var i = 0; i < 50; i++) {
      if (await storage.hasFile(cid)) {
        final bytes = await storage.loadFile(cid);
        return _json(req, {
          'ok': true,
          'started': started,
          'bytes': bytes?.length,
          'sha8': bytes == null ? null : _sha8(bytes),
        });
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return _json(req, {
      'ok': false,
      'started': started,
      'error': 'fetch did not complete',
    });
  }

  /// Add ?peer= as a member of ?group= and fan the snapshot out to all members
  /// — the real 2-device group path (the peer materializes the group).
  Future<void> _groupInviteHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final svc = _groupSvc();
    if (svc == null) return _json(req, {'ok': false, 'error': 'no signer'});
    final q = req.uri.queryParameters;
    final gidHex = q['group'], peerHex = q['peer'];
    if (gidHex == null || peerHex == null) {
      return _json(req, {'ok': false, 'error': 'need group+peer'});
    }
    final gid = NodeId.fromHex(gidHex);
    final peer = NodeId.fromHex(peerHex);
    final added = await svc.addControlOp(
      gid,
      ControlOp.addMember,
      target: peer,
      role: GroupRole.member,
    );
    final sent = await svc.broadcast(gid);
    final st = await svc.stateOf(gid);
    return _json(req, {
      'ok': added,
      'members': st?.members.length ?? 0,
      'delivered': sent,
      'epoch': st?.epoch ?? 0,
      'encrypted': st?.epochDescriptor != null,
    });
  }

  /// Snapshot: ?group= → members/epoch/policyVersion + validated msg bodies.
  Future<void> _groupStateHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final svc = _groupSvc();
    if (svc == null) return _json(req, {'ok': false, 'error': 'no signer'});
    final gidHex = req.uri.queryParameters['group'];
    if (gidHex == null) return _json(req, {'ok': false, 'error': 'no group'});
    final gid = NodeId.fromHex(gidHex);
    final st = await svc.stateOf(gid);
    if (st == null) return _json(req, {'ok': false, 'error': 'unknown group'});
    final msgs = await svc.messagesOf(gid);
    final reacts = await svc.reactionsOf(gid);
    final bundle = await svc.load(gid);
    return _json(req, {
      'ok': true,
      'name': st.name,
      'members': st.members.length,
      'epoch': st.epoch,
      'policyVersion': st.policyVersion,
      'encrypted': st.epochDescriptor != null,
      'descriptorEpoch': st.epochDescriptor?.epoch,
      'localKeyEpochs': bundle == null
          ? const <int>[]
          : (bundle.localEpochKeys.keys.toList()..sort()),
      'storedEncryptedMessages':
          bundle?.messages.where((message) => message.isEncrypted).length ?? 0,
      'storedClearMessages':
          bundle?.messages.where((message) => !message.isEncrypted).length ?? 0,
      'storedEncryptedReactions':
          bundle?.reactions.where((reaction) => reaction.isEncrypted).length ??
          0,
      'bodies': [for (final m in msgs) m.body],
      'images': [
        for (final m in msgs)
          if (m.attachment != null)
            {'w': m.attachment!.w, 'h': m.attachment!.h},
      ],
      // Inline voice clips: duration + byte length + sha8 of the decoded
      // bytes, so a 2-device run can prove the clip arrived byte-exact.
      'voice': [
        for (final m in msgs)
          if (m.attachment?.kind == 'voice')
            () {
              final b = base64Decode(m.attachment!.dataB64);
              return {
                'ms': m.attachment!.w,
                'bytes': b.length,
                'sha8': _sha8(b),
              };
            }(),
      ],
      'reactions': {
        for (final e in reacts.entries)
          e.key: {for (final r in e.value.entries) r.key: r.value.length},
      },
    });
  }

  /// End-to-end group crypto self-test with the REAL identity: mint a group
  /// with self as owner, sign an addMember control entry, verify it, fold it,
  /// then confirm a TAMPERED entry fails verification and is dropped by the
  /// fold. Proves the native ed25519 sign/verify + policy spine.
  Future<void> _groupSelftestHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final me = ref.read(appControllerProvider).identity?.nodeId;
    final toml = await ref.read(storageProvider).loadNodeConfig();
    if (me == null || toml == null) {
      return _json(req, {'ok': false, 'error': 'no identity'});
    }
    final other = NodeId(Uint8List.fromList(List.filled(32, 0xAB)));
    // Owner adds `other` as a member.
    final unsigned = ControlEntry(
      author: me,
      seq: 0,
      prevHash: '',
      op: ControlOp.addMember,
      target: other,
      role: GroupRole.member,
      policyVersion: 0,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
      signature: Uint8List(0),
    );
    final signed = signControlEntry(identityToml: toml, unsigned: unsigned);
    final verifyOk = verifyControlEntry(signed);

    // Tamper: change the target AFTER signing → signature must not verify.
    final tampered = ControlEntry(
      author: signed.author,
      seq: signed.seq,
      prevHash: signed.prevHash,
      op: signed.op,
      target: NodeId(Uint8List.fromList(List.filled(32, 0xCD))),
      role: signed.role,
      policyVersion: signed.policyVersion,
      createdAtMs: signed.createdAtMs,
      signature: signed.signature,
      authorPubKey: signed.authorPubKey,
    );
    final tamperRejected = !verifyControlEntry(tampered);

    final fold = foldControlLog(
      owner: me,
      entries: [signed],
      verify: (e) => verifyControlEntry(e),
    );
    final applied = fold.state.isMember(other);

    // A round-trip through JSON must preserve verifiability.
    final rt = ControlEntry.fromJson(signed.toJson());
    final jsonOk = rt != null && verifyControlEntry(rt);

    return _json(req, {
      'ok': verifyOk && tamperRejected && applied && jsonOk,
      'verify': verifyOk,
      'tamperRejected': tamperRejected,
      'applied': applied,
      'jsonRoundTrip': jsonOk,
      'members': fold.state.members.length,
      'pkLen': signed.authorPubKey.length,
    });
  }

  /// Share the default sticker pack to ?peer= (drives packToBlob +
  /// sendStickerPack, the panel'"'"'s share path).
  Future<void> _sharePackHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final peer = _peer(req);
    if (peer == null) return;
    final ctrl = ref.read(stickerControllerProvider.notifier);
    final blob = await ctrl.packToBlob('my');
    if (blob == null) {
      return _json(req, {'ok': false, 'error': 'empty/unknown pack'});
    }
    final bundle = decodeStickerPack(blob);
    await ref.read(messagingServiceProvider).sendStickerPack(peer, blob);
    return _json(req, {
      'ok': true,
      'bytes': blob.length,
      'items': bundle?.images.length ?? 0,
    });
  }

  /// Install the most recent received .stkpack into the library (drives
  /// installPack) — verifies the receive+install path without tap geometry.
  Future<void> _installLastPackHook(HttpRequest req) async {
    final storage = ref.read(storageProvider);
    Message? last;
    for (final c in await storage.loadConversations()) {
      for (final m in await storage.loadMessages(c.id)) {
        if (isStickerPackFileName(m.fileName) &&
            (m.fileId ?? m.fileContentId) != null) {
          last = m;
        }
      }
    }
    if (last == null) {
      return _json(req, {'ok': false, 'error': 'no pack message'});
    }
    final bytes = await storage.loadFile(last.fileId ?? last.fileContentId!);
    if (bytes == null) {
      return _json(req, {
        'ok': false,
        'error': 'blob missing (not downloaded)',
      });
    }
    final n = await ref
        .read(stickerControllerProvider.notifier)
        .installPack(bytes);
    final packs = ref.read(stickerControllerProvider).valueOrNull ?? const [];
    return _json(req, {
      'ok': n > 0,
      'installed': n,
      'packs': packs.length,
      'library': [for (final p in packs) ...p.items].length,
    });
  }

  /// Import the POST body (an image) into the sticker library — drives the
  /// normalize + store + manifest path the panel'"'"'s import uses.
  Future<void> _importStickerHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final builder = BytesBuilder(copy: false);
    await for (final chunk in req) {
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    if (bytes.isEmpty) {
      return _json(req, {'ok': false, 'error': 'empty body'}, status: 400);
    }
    final n = await ref.read(stickerControllerProvider.notifier).importImages([
      bytes,
    ]);
    final packs = ref.read(stickerControllerProvider).valueOrNull ?? const [];
    final items = [for (final p in packs) ...p.items];
    return _json(req, {'ok': n > 0, 'added': n, 'library': items.length});
  }

  /// Send the POST body (an image) as a STICKER to ?peer= — drives the
  /// sticker send path (thumb + .stkr content send) exactly like the panel.
  Future<void> _sendStickerHook(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final peer = _peer(req);
    if (peer == null) return;
    final builder = BytesBuilder(copy: false);
    await for (final chunk in req) {
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    if (bytes.isEmpty) {
      return _json(req, {'ok': false, 'error': 'empty body'}, status: 400);
    }
    await ref.read(messagingServiceProvider).sendSticker(peer, bytes);
    return _json(req, {'ok': true, 'bytes': bytes.length});
  }

  /// Record + SEND a video note to ?peer= — drives the full brick-4 path
  /// (record -> first-frame thumb -> sendVideoNote) exactly like the UI.
  Future<void> _sendVnote(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final peer = _peer(req);
    if (peer == null) return;
    final ms = int.tryParse(req.uri.queryParameters['ms'] ?? '') ?? 2500;
    final rec = NativeVnoteRecorder.create();
    if (rec == null) {
      return _json(req, {
        'ok': false,
        'error': 'recorder unavailable',
      }, status: 500);
    }
    await MacMediaPermissions.requestMicrophone().timeout(
      const Duration(seconds: 5),
      onTimeout: () => false,
    );
    await MacMediaPermissions.requestCamera().timeout(
      const Duration(seconds: 5),
      onTimeout: () => false,
    );
    if (!await rec.start()) {
      rec.dispose();
      return _json(req, {'ok': false, 'error': 'start failed'}, status: 500);
    }
    await Future<void>.delayed(Duration(milliseconds: ms));
    final clip = rec.stop();
    rec.dispose();
    if (clip == null) {
      return _json(req, {'ok': false, 'error': 'empty clip'});
    }
    String? thumb;
    final player = VeilVnotePlayer.create(clip.bytes);
    if (player != null) {
      try {
        final f = player.frameAt(0);
        if (f != null) {
          thumb = await makeRgbaThumbB64(f.rgba, f.width, f.height);
        }
      } finally {
        player.dispose();
      }
    }
    await ref
        .read(messagingServiceProvider)
        .sendVideoNote(peer, clip.bytes, clip.durationMs, thumbB64: thumb);
    return _json(req, {
      'ok': true,
      'bytes': clip.bytes.length,
      'durationMs': clip.durationMs,
      'thumbB64Len': thumb?.length ?? 0,
    });
  }

  Future<void> _recordVoice(HttpRequest req) async {
    final ms = int.tryParse(req.uri.queryParameters['ms'] ?? '') ?? 2000;
    final rec = VeilAudioRecorder.create();
    if (rec == null) {
      return _json(req, {
        'ok': false,
        'error': 'recorder unavailable',
      }, status: 500);
    }
    // The mic prompt must be answered before StartRecording sees audio.
    await MacMediaPermissions.requestMicrophone().timeout(
      const Duration(seconds: 5),
      onTimeout: () => false,
    );
    if (!rec.start()) {
      rec.dispose();
      return _json(req, {
        'ok': false,
        'error': 'start failed (permission?)',
      }, status: 500);
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
        b[0] == 0x56 &&
        b[1] == 0x4F &&
        b[2] == 0x50 &&
        b[3] == 0x31) {
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

  /// Record `?ms=` (default 2000) then send it as a voice message to `?peer=`.
  /// Smoke-drives brick 4 (sendVoice) end-to-end so the wire crossing + the
  /// receiver's voice bubble can be verified without the composer UI.
  Future<void> _sendVoice(HttpRequest req) async {
    final rawPeer = req.uri.queryParameters['peer']?.trim();
    if (rawPeer == null || rawPeer.isEmpty) {
      return _json(req, {'ok': false, 'error': 'peer required'}, status: 400);
    }
    NodeId peer;
    try {
      peer = NodeId.fromHex(rawPeer);
    } catch (e) {
      return _json(req, {'ok': false, 'error': '$e'}, status: 400);
    }
    final ms = int.tryParse(req.uri.queryParameters['ms'] ?? '') ?? 2000;
    final rec = VeilAudioRecorder.create();
    if (rec == null) {
      return _json(req, {
        'ok': false,
        'error': 'recorder unavailable',
      }, status: 500);
    }
    await MacMediaPermissions.requestMicrophone().timeout(
      const Duration(seconds: 5),
      onTimeout: () => false,
    );
    if (!rec.start()) {
      rec.dispose();
      return _json(req, {'ok': false, 'error': 'start failed'}, status: 500);
    }
    await Future<void>.delayed(Duration(milliseconds: ms));
    final clip = rec.stop();
    rec.dispose();
    if (clip == null) {
      return _json(req, {'ok': false, 'error': 'empty clip'});
    }
    await ref
        .read(messagingServiceProvider)
        .sendVoice(peer, clip.bytes, clip.durationMs, clip.waveform);
    return _json(req, {
      'ok': true,
      'peer': peer.hex,
      'bytes': clip.bytes.length,
      'durationMs': clip.durationMs,
    });
  }

  /// Play the most recent voice message via the play controller (bypasses tap
  /// geometry) — verifies the Dart -> controller -> native player -> playout
  /// path end-to-end. Reports whether it started + duration/position.
  Future<void> _playVoiceHook(HttpRequest req) async {
    final storage = ref.read(storageProvider);
    Message? last;
    for (final c in await storage.loadConversations()) {
      for (final m in await storage.loadMessages(c.id)) {
        if (isVoiceFileName(m.fileName) &&
            (m.fileId ?? m.fileContentId) != null) {
          last = m;
        }
      }
    }
    if (last == null) {
      return _json(req, {'ok': false, 'error': 'no voice message'});
    }
    final fileKey = last.fileId ?? last.fileContentId!;
    await ref
        .read(voicePlayControllerProvider.notifier)
        .toggle(last.id, fileKey);
    await Future<void>.delayed(const Duration(milliseconds: 700));
    final st = ref.read(voicePlayControllerProvider);
    return _json(req, {
      'ok': st.isActive(last.id),
      'messageId': last.id,
      'durationMs': st.durationMs,
      'positionMs': st.positionMs,
      'playing': st.isPlaying(last.id),
      'speed': st.speed,
    });
  }

  /// Seek the active voice clip to ?frac= (0..1) of its duration via the play
  /// controller — verifies the waveform-tap seek path without tap geometry.
  Future<void> _seekVoiceHook(HttpRequest req) async {
    final frac = double.tryParse(req.uri.queryParameters['frac'] ?? '');
    final active = ref.read(voicePlayControllerProvider).playingId;
    if (frac == null || active == null) {
      return _json(req, {'ok': false, 'error': 'no active clip / bad frac'});
    }
    await ref.read(voicePlayControllerProvider.notifier).seekTo(active, frac);
    final st = ref.read(voicePlayControllerProvider);
    return _json(req, {
      'ok': st.isActive(active),
      'durationMs': st.durationMs,
      'positionMs': st.positionMs,
      'playing': st.isPlaying(active),
    });
  }

  /// Cycle the playback speed chip (1x -> 1.5x -> 2x -> 1x) on the active clip.
  Future<void> _voiceSpeedHook(HttpRequest req) async {
    ref.read(voicePlayControllerProvider.notifier).cycleSpeed();
    final st = ref.read(voicePlayControllerProvider);
    return _json(req, {'ok': true, 'speed': st.speed});
  }

  /// Snapshot of the voice play controller state (poll to watch position).
  Future<void> _voiceStateHook(HttpRequest req) async {
    final st = ref.read(voicePlayControllerProvider);
    return _json(req, {
      'ok': true,
      'playingId': st.playingId,
      'durationMs': st.durationMs,
      'positionMs': st.positionMs,
      'paused': st.paused,
      'speed': st.speed,
    });
  }

  /// Transcribe the most recent voice message via the controller (Dart -> FFI
  /// decode16k -> whisper -> cache), verifying the on-device STT path end to
  /// end without tap geometry. Reports whether STT is available + the text.
  Future<void> _transcribeVoiceHook(HttpRequest req) async {
    final avail = await ref.read(transcriptionAvailableProvider.future);
    if (!avail) {
      return _json(req, {
        'ok': false,
        'error': 'stt unavailable',
        'model': WhisperTranscriber.modelPath(),
        'mediaOpen': WhisperTranscriber.debugCanOpen('veil_media'),
        'whisperOpen': WhisperTranscriber.debugCanOpen('veil_whisper'),
      });
    }
    final storage = ref.read(storageProvider);
    Message? last;
    for (final c in await storage.loadConversations()) {
      for (final m in await storage.loadMessages(c.id)) {
        if (isVoiceFileName(m.fileName) &&
            (m.fileId ?? m.fileContentId) != null) {
          last = m;
        }
      }
    }
    if (last == null) {
      return _json(req, {'ok': false, 'error': 'no voice message'});
    }
    final fileKey = last.fileId ?? last.fileContentId!;
    // Direct (cache-bypassing) transcribe with an optional forced language, for
    // diagnosing detection/config issues.
    final lang = req.uri.queryParameters['lang']?.trim();
    if (lang != null && lang.isNotEmpty) {
      final bytes = await ref.read(storageProvider).loadFile(fileKey);
      if (bytes == null) {
        return _json(req, {'ok': false, 'error': 'blob missing'});
      }
      final text = await ref.read(voiceTranscriberProvider)(bytes, lang: lang);
      return _json(req, {
        'ok': text != null,
        'messageId': last.id,
        'lang': lang,
        'text': text,
      });
    }
    final ctrl = ref.read(transcriptionControllerProvider.notifier);
    await ctrl.transcribe(
      last.id,
      fileKey,
      senderLang: decodeVoiceSidecar(last.thumb)?.lang,
    );
    final entry = ctrl.entryFor(last.id);
    return _json(req, {
      'ok': entry.isDone,
      'messageId': last.id,
      'phase': entry.phase.name,
      'text': entry.text,
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

  Future<void> _screenshot(HttpRequest req) =>
      _screenshotGate.run(() => _screenshotExclusive(req));

  Future<void> _screenshotExclusive(HttpRequest req) async {
    final scale =
        double.tryParse(req.uri.queryParameters['scale']?.trim() ?? '') ?? 1.0;
    final requestedScale = scale.clamp(0.1, 4.0);
    final shot = await _driver.screenshot(scale: requestedScale);
    if (shot == null) {
      return _json(req, {
        'ok': false,
        'error': 'screenshot unavailable',
      }, status: 409);
    }
    req.response.statusCode = 200;
    req.response.headers.contentType = ContentType('image', 'png');
    req.response.headers.set(
      'x-xveil-screenshot-scale',
      shot.scale.toStringAsFixed(4),
    );
    req.response.headers.set(
      'x-xveil-screenshot-capped',
      shot.scale < requestedScale ? 'true' : 'false',
    );
    req.response.contentLength = shot.bytes.length;
    req.response.add(shot.bytes);
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
      await _driver.releaseSemantics();
      await _driver.tapAt(Offset(x, y), hold: hold);
      return _json(req, {'ok': true, 'method': 'pointer', 'x': x, 'y': y});
    }
    final target = await _resolveNode(req);
    if (target == null) {
      await _driver.releaseSemantics();
      return; // error response already written
    }
    final rect = await _driver.globalRectOf(target);
    await _driver.releaseSemantics();
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
      if (target == null) {
        await _driver.releaseSemantics();
        return;
      }
      final rect = await _driver.globalRectOf(target);
      if (rect != null && !rect.isEmpty) start = rect.center;
      await _driver.releaseSemantics();
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
      if (target == null) {
        await _driver.releaseSemantics();
        return;
      }
      final rect = await _driver.globalRectOf(target);
      await _driver.releaseSemantics();
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
      final target = current == null
          ? floor
          : (current.weight * 2).clamp(floor, 1 << 62);
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
      final klass = parts.length > 1
          ? '${parts[0]}:${parts[1].length > 12 ? '#' : parts[1]}'
          : k;
      byClass[klass] = (byClass[klass] ?? 0) + 1;
    }
    return _json(req, {'ok': true, 'count': keys.length, 'byClass': byClass});
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
    await ref
        .read(callServiceProvider)
        .placeCall(
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
    HttpRequest req,
    Future<void> Function(CallService) action,
  ) async {
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
              'micOn': c.micOn,
              'cameraOn': c.cameraOn,
              'screenOn': c.screenOn,
              'mediaStats': ref.read(callServiceProvider).mediaDiagnostics,
            },
    });
  }

  // ---- group-call control plane (no key/body material in debug output) ----

  Future<void> _groupCallStart(HttpRequest req) async {
    if (!_requireReady(req)) return;
    final service = ref.read(groupCallServiceProvider);
    final groupHex = req.uri.queryParameters['group'];
    if (service == null || groupHex == null) {
      return _json(req, {
        'ok': false,
        'error': 'no service/group',
      }, status: 409);
    }
    final NodeId groupId;
    try {
      groupId = NodeId.fromHex(groupHex);
    } catch (_) {
      return _json(req, {'ok': false, 'error': 'bad group'}, status: 400);
    }
    final media = req.uri.queryParameters['media']?.trim() ?? 'audio';
    final ok = await service.startCall(
      groupId,
      CallMedia(
        audio: true,
        video: media == 'video' || media == 'screen',
        screen: media == 'screen',
      ),
    );
    await _groupCallState(req, actionOk: ok);
  }

  Future<void> _groupCallAction(
    HttpRequest req,
    Future<bool> Function(GroupCallService service) action,
  ) async {
    if (!_requireReady(req)) return;
    final service = ref.read(groupCallServiceProvider);
    if (service == null) {
      return _json(req, {'ok': false, 'error': 'no service'}, status: 409);
    }
    final ok = await action(service);
    await _groupCallState(req, actionOk: ok);
  }

  Future<void> _groupCallState(HttpRequest req, {bool? actionOk}) async {
    final service = ref.read(groupCallServiceProvider);
    final call = service?.current;
    final media = service?.mediaController;
    await _json(req, {
      'ok': actionOk ?? true,
      'call': call == null
          ? null
          : {
              'groupId': call.groupId.hex,
              'callId': call.callId,
              'initiator': call.initiator.hex,
              'epoch': call.membershipEpoch,
              'status': call.status.name,
              'media': {
                'audio': call.media.audio,
                'video': call.media.video,
                'screen': call.media.screen,
              },
              'participants': [
                for (final participant in call.participants.values)
                  {
                    'nodeId': participant.nodeId.hex,
                    'audio': participant.media.audio,
                    'video': participant.media.video,
                    'screen': participant.media.screen,
                  },
              ],
              'endReason': call.endReason?.name,
              'micOn': call.micOn,
              'cameraOn': call.cameraOn,
              'screenOn': call.screenOn,
              'mediaPlane': media is VeilGroupCallMediaController
                  ? {
                      'nativeAudio': media.audioRunning,
                      'nativeVideo': media.videoRunning,
                      'peerChannels': media.connectedPeerCount,
                      'rxPeers': media.receivingPeerCount,
                      'videoPeers': media.renderingPeerCount,
                      'localVideo': media.localVideoReady,
                    }
                  : null,
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
    unawaited(
      _json(req, {
        'ok': false,
        'error': 'media unavailable (no embedded transport)',
      }, status: 400),
    );
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
    await _json(req, {
      'ok': true,
      'peer': peer.hex,
      'count': t.mediaRecvCount(peer.bytes),
    });
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
      await _json(req, {
        'ok': false,
        'error': 'veil_media unavailable: $e',
      }, status: 500);
    }
  }

  // Trigger the platform microphone consent prompt through the app channel.
  Future<void> _mediaRequestMic(HttpRequest req) async {
    final before = await MacMediaPermissions.microphoneStatus();
    final granted = await MacMediaPermissions.requestMicrophone();
    final after = await MacMediaPermissions.microphoneStatus();
    await _json(req, {
      'ok': true,
      'granted': granted,
      'before': before,
      'after': after,
    });
  }

  Future<void> _mediaRequestCamera(HttpRequest req) async {
    final before = await MacMediaPermissions.cameraStatus();
    final granted = await MacMediaPermissions.requestCamera();
    final after = await MacMediaPermissions.cameraStatus();
    await _json(req, {
      'ok': true,
      'granted': granted,
      'before': before,
      'after': after,
    });
  }

  // Construct the full engine (webrtc::Call + ADM + AudioState), enumerate
  // audio devices and optionally drive camera capture. Uses a dummy channel
  // (0); permission prompts are explicit and bounded by the caller.
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
        f.rgba,
        f.width,
        f.height,
        ui.PixelFormat.rgba8888,
        c.complete,
      );
      final img = await c.future;
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      img.dispose();
      if (png == null) {
        await _json(req, {
          'ok': false,
          'error': 'png encode failed',
        }, status: 500);
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
      final e = VeilMediaEngine.create(
        veilChan: 0,
        localId: local,
        peerId: peer,
      );
      if (e == null) {
        await _json(req, {
          'ok': false,
          'error': 'engine create returned null',
        }, status: 500);
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
      final wantCamera = req.uri.queryParameters['camera'] == '1';
      bool videoStarted = false;
      if (wantVideo) videoStarted = e.startVideo(send: true, recv: true);
      final cameraGranted =
          !wantCamera ||
          await MacMediaPermissions.requestCamera().timeout(
            const Duration(seconds: 30),
            onTimeout: () => false,
          );
      final cameraStarted = wantCamera && cameraGranted && e.startCamera();
      await Future<void>.delayed(const Duration(seconds: 5));
      final cameraFrame = cameraStarted ? e.getLocalVideoFrame() : null;
      if (cameraStarted) e.stopCamera();
      if (wantVideo) e.stopVideo();
      e.stopAudio();
      e.dispose();
      await _json(req, {
        'ok': true,
        'created': true,
        'audio_started': started,
        'video_started': videoStarted,
        'camera_granted': cameraGranted,
        'camera_started': cameraStarted,
        'camera_frame': cameraFrame != null,
        'camera_width': cameraFrame?.width,
        'camera_height': cameraFrame?.height,
        'mics': mics.length,
        'speakers': spk.length,
        'mic_labels': [for (final m in mics) m.label],
        'speaker_labels': [for (final s in spk) s.label],
      });
    } catch (ex, st) {
      await _json(req, {
        'ok': false,
        'error': '$ex',
        'stack': '$st',
      }, status: 500);
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
