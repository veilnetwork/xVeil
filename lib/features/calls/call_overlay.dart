import 'dart:async';
import 'dart:io' show Platform;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/call.dart';
import '../../domain/call_signal.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_controller.dart';
import '../../state/call_audio_route.dart';
import '../../state/android_camera_capture.dart'
    show androidCallCameraPreviewController;
import '../../state/android_native_call_camera.dart';
import '../../state/android_native_call_video.dart';
import '../../state/call_service.dart';
import '../../state/veil_call_media.dart'
    show localVideoFrame, remoteVideoFrame;
import 'call_lifecycle_bridge.dart' show callPipMode;
import 'call_device_picker.dart';
import 'call_surface.dart';
import 'video_frame_view.dart';

/// Full-screen call UI that floats above every route. Mounted once from
/// [MaterialApp.router]'s `builder`, it watches [currentCallProvider] and shows
/// nothing until a call is live — then the incoming-ring / dialing / connecting
/// / in-call surface. Phase 1 is control-plane only: the media toggles are
/// present but inert (wired to real capture in Phases 3–5); End/Accept/Reject/
/// Cancel drive the [CallService] FSM.
enum _OverlayMode { full, mini, hidden }

bool _peerScreenSharing(Call call) => call.media.screen && !call.screenOn;

class CallOverlay extends ConsumerStatefulWidget {
  const CallOverlay({super.key});

  @override
  ConsumerState<CallOverlay> createState() => _CallOverlayState();
}

class _CallOverlayState extends ConsumerState<CallOverlay>
    with WidgetsBindingObserver {
  _OverlayMode _mode = _OverlayMode.full;
  Offset _miniOffset = const Offset(16, 92);
  Offset _selfPreviewOffset = Offset.zero;
  Size _selfPreviewSize = _SelfPreview.defaultSize;
  String? _callId;
  bool _selfPreviewHidden = false;
  bool _pipActive = false;
  bool _captureDevicesLoading = false;
  List<CallMediaDevice>? _captureDevices;

  Future<void> _openCaptureDevicePicker(
    CallService svc, {
    required bool includeCameras,
    required bool includeScreens,
  }) async {
    if (_captureDevicesLoading) return;
    setState(() => _captureDevicesLoading = true);
    final results = await Future.wait([
      if (includeCameras)
        svc.listCameras()
      else
        Future.value(const <CallMediaDevice>[]),
      svc.listMicrophones(),
      if (includeScreens)
        svc.listScreens()
      else
        Future.value(const <CallMediaDevice>[]),
    ]);
    if (!mounted) return;
    final devices = [...results[0], ...results[1], ...results[2]];
    setState(() {
      _captureDevicesLoading = false;
      // The settings sheet remains useful even without enumerable capture
      // devices: it also owns speaker/earpiece routing.
      _captureDevices = devices;
    });
  }

  Future<void> _selectCaptureDevice(
    CallService svc,
    CallMediaDevice device,
  ) async {
    setState(() => _captureDevices = null);
    final ok = switch (device.kind) {
      CallMediaDeviceKind.camera => await svc.selectCamera(device.id),
      CallMediaDeviceKind.microphone => await svc.selectMicrophone(device.id),
      CallMediaDeviceKind.screen => await svc.selectScreen(device.id),
    };
    if (!ok && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(AppL10n.of(context).callDeviceSwitchFailed)),
      );
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pipActive = callPipMode.value;
    callPipMode.addListener(_onPipModeChanged);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    callPipMode.removeListener(_onPipModeChanged);
    super.dispose();
  }

  void _onPipModeChanged() {
    if (!mounted) return;
    setState(() => _pipActive = callPipMode.value);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (Platform.isAndroid &&
        (state == AppLifecycleState.inactive ||
            state == AppLifecycleState.hidden ||
            state == AppLifecycleState.paused)) {
      return;
    }
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      if (mounted) setState(() => _mode = _OverlayMode.mini);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Only engage the call stack once the node is ready — reading the call
    // provider before unlock would eagerly spin up the messaging pipeline on
    // the splash/lock screens.
    final ready = ref.watch(
      appControllerProvider.select((s) => s.phase == AppPhase.ready),
    );
    if (!ready) return const SizedBox.shrink();
    final call = ref.watch(currentCallProvider);
    if (call == null || call.status == CallStatus.ended) {
      _callId = null;
      // The Android PiP window can outlive the call for a moment (the bridge
      // dismisses it asynchronously). Never let that window show the shrunk
      // app UI — the chat list floating over the launcher is both broken
      // layout and a privacy leak.
      if (_pipActive) return const Positioned.fill(child: _PipEndedCover());
      return const SizedBox.shrink();
    }
    final isNewCall = _callId != call.callId;
    if (isNewCall) {
      _callId = call.callId;
      final size = MediaQuery.sizeOf(context);
      _selfPreviewSize = _SelfPreview.defaultSizeFor(size);
      _selfPreviewOffset = Offset(
        size.width - _selfPreviewSize.width - 12,
        (size.height - _selfPreviewSize.height - 112).clamp(8.0, size.height),
      );
      _selfPreviewHidden = false;
      _captureDevices = null;
      _captureDevicesLoading = false;
      _mode = _OverlayMode.full;
    }
    final videoStage = _isVideoStage(call);
    final canMinimize =
        call.status == CallStatus.connecting ||
        call.status == CallStatus.active;
    if (_pipActive) {
      // In PiP the window is tiny: only the dedicated video surface (or a
      // plain cover for a non-video stage) may render — the regular layouts
      // overflow and expose whatever screen was open underneath. Material
      // ancestor: the frame view's text placeholders otherwise render with
      // the bare default style (yellow underline).
      if (videoStage) {
        return Positioned.fill(
          child: Material(color: Colors.black, child: _PipVideoView(call)),
        );
      }
      return const Positioned.fill(child: _PipEndedCover());
    }
    if (!canMinimize || _mode == _OverlayMode.full) {
      return Positioned.fill(
        child: Material(
          color: const Color(0xF20E1116),
          child: SafeArea(
            child: Stack(
              fit: StackFit.expand,
              children: [
                _CallBody(
                  call,
                  onShowDevices: (svc) => _openCaptureDevicePicker(
                    svc,
                    includeCameras: call.media.video,
                    includeScreens: call.media.video && Platform.isMacOS,
                  ),
                  onMinimize: canMinimize
                      ? () => setState(() => _mode = _OverlayMode.mini)
                      : null,
                  selfPreviewOffset: _selfPreviewOffset,
                  selfPreviewSize: _selfPreviewSize,
                  selfPreviewHidden: _selfPreviewHidden,
                  onSelfPreviewDrag: (delta) {
                    final size = MediaQuery.sizeOf(context);
                    setState(() {
                      _selfPreviewOffset = Offset(
                        (_selfPreviewOffset.dx + delta.dx).clamp(
                          8.0,
                          size.width - _selfPreviewSize.width - 8.0,
                        ),
                        (_selfPreviewOffset.dy + delta.dy).clamp(
                          8.0,
                          size.height - _selfPreviewSize.height - 8.0,
                        ),
                      );
                    });
                  },
                  onSelfPreviewResize: (delta) {
                    final viewSize = MediaQuery.sizeOf(context);
                    setState(() {
                      final next = _SelfPreview.clampSize(
                        _selfPreviewSize.width + delta.dx,
                      );
                      _selfPreviewSize = next;
                      _selfPreviewOffset = Offset(
                        _selfPreviewOffset.dx.clamp(
                          8.0,
                          viewSize.width - next.width - 8.0,
                        ),
                        _selfPreviewOffset.dy.clamp(
                          8.0,
                          viewSize.height - next.height - 8.0,
                        ),
                      );
                    });
                  },
                  onSelfPreviewHide: () {
                    setState(() => _selfPreviewHidden = true);
                  },
                  onSelfPreviewShow: () {
                    setState(() => _selfPreviewHidden = false);
                  },
                ),
                if (_captureDevicesLoading)
                  const Positioned(
                    right: 30,
                    bottom: 40,
                    child: CircularProgressIndicator(),
                  ),
                if (_captureDevices case final devices?)
                  CallDevicePickerPanel(
                    devices: devices,
                    onDismiss: () => setState(() => _captureDevices = null),
                    onSelect: (device) => _selectCaptureDevice(
                      ref.read(callServiceProvider),
                      device,
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }
    if (_mode == _OverlayMode.hidden) {
      return _HiddenCallTab(
        call: call,
        onShow: () => setState(() => _mode = _OverlayMode.mini),
      );
    }
    return _FloatingCallTile(
      call: call,
      offset: _miniOffset,
      onDrag: (delta) {
        final size = MediaQuery.sizeOf(context);
        setState(() {
          _miniOffset = Offset(
            (_miniOffset.dx + delta.dx).clamp(
              8.0,
              size.width - _FloatingCallTile._width - 8.0,
            ),
            (_miniOffset.dy + delta.dy).clamp(
              8.0,
              size.height - _FloatingCallTile._height - 8.0,
            ),
          );
        });
      },
      onExpand: () => setState(() => _mode = _OverlayMode.full),
      onHide: () => setState(() => _mode = _OverlayMode.hidden),
    );
  }

  static bool _isVideoStage(Call call) {
    final hasVideo = call.media.video || call.media.screen;
    return hasVideo &&
        (call.status == CallStatus.active ||
            call.status == CallStatus.connecting);
  }
}

class _CallBody extends ConsumerWidget {
  const _CallBody(
    this.call, {
    this.onMinimize,
    required this.selfPreviewOffset,
    required this.selfPreviewSize,
    required this.selfPreviewHidden,
    required this.onSelfPreviewDrag,
    required this.onSelfPreviewResize,
    required this.onSelfPreviewHide,
    required this.onSelfPreviewShow,
    required this.onShowDevices,
  });
  final Call call;
  final VoidCallback? onMinimize;
  final Offset selfPreviewOffset;
  final Size selfPreviewSize;
  final bool selfPreviewHidden;
  final ValueChanged<Offset> onSelfPreviewDrag;
  final ValueChanged<Offset> onSelfPreviewResize;
  final VoidCallback onSelfPreviewHide;
  final VoidCallback onSelfPreviewShow;
  final ValueChanged<CallService> onShowDevices;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final svc = ref.read(callServiceProvider);
    // Once a video/screen call is up, the remote frame fills the surface with
    // the peer info + controls floated over it; audio-only (and pre-connect)
    // stays with the centered avatar layout.
    final hasVideo = call.media.video || call.media.screen;
    final videoStage =
        hasVideo &&
        (call.status == CallStatus.active ||
            call.status == CallStatus.connecting);
    if (videoStage) return _videoLayout(context, l, svc);
    return _audioLayout(context, l, svc);
  }

  Widget _audioLayout(BuildContext context, AppL10n l, CallService svc) {
    return Column(
      children: [
        CallSurfaceHeader(
          title: call.peer.short,
          subtitle: _statusLabel(l, call.status),
          onMinimize: onMinimize,
          onSettings: () => onShowDevices(svc),
        ),
        const Spacer(),
        CircleAvatar(
          radius: 72,
          backgroundColor: const Color(0xFF171B22),
          child: Text(
            call.peer.short.characters.first.toUpperCase(),
            style: const TextStyle(fontSize: 48, color: Colors.white38),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          call.peer.short,
          style: Theme.of(context).textTheme.titleLarge,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 8),
        Text(
          _statusLabel(l, call.status),
          style: Theme.of(
            context,
          ).textTheme.bodyLarge?.copyWith(color: Colors.white70),
        ),
        const SizedBox(height: 12),
        _MediaChips(call.media),
        if (call.transport != null) ...[
          const SizedBox(height: 10),
          _TransportBadge(
            call.transport!,
            fallbackReason:
                call.transport == CallTransportKind.relay &&
                    svc.transportFallbackReason != null
                ? l.callPathNoDirectSession
                : null,
          ),
        ],
        const Spacer(),
        _Controls(call: call, svc: svc, l: l),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _videoLayout(BuildContext context, AppL10n l, CallService svc) {
    final peerScreen = _peerScreenSharing(call);
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(
          color: Colors.black,
          child: _RemoteCallVideoView(
            freshnessToken: (call.callId, peerScreen),
            waitingLabel: peerScreen ? l.callScreenWaiting : l.callVideoWaiting,
            staleLabel: l.callVideoPaused,
            placeholderIcon: peerScreen
                ? Icons.screen_share_outlined
                : Icons.videocam_outlined,
          ),
        ),
        // Scrims so the white text/controls stay legible over any frame.
        const _Scrim(top: true),
        const _Scrim(top: false),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: CallSurfaceHeader(
            title: call.peer.short,
            subtitle: _statusLabel(l, call.status),
            onMinimize: onMinimize,
            onSettings: () => onShowDevices(svc),
          ),
        ),
        if (call.transport != null)
          Positioned(
            top: 66,
            left: 16,
            right: 16,
            child: _TransportBadge(
              call.transport!,
              fallbackReason:
                  call.transport == CallTransportKind.relay &&
                      svc.transportFallbackReason != null
                  ? l.callPathNoDirectSession
                  : null,
            ),
          ),
        if (call.media.video && !selfPreviewHidden)
          Positioned(
            left: selfPreviewOffset.dx,
            top: selfPreviewOffset.dy,
            child: GestureDetector(
              onPanUpdate: (d) => onSelfPreviewDrag(d.delta),
              child: _SelfPreview(
                call: call,
                size: selfPreviewSize,
                onHide: onSelfPreviewHide,
                onResize: onSelfPreviewResize,
              ),
            ),
          ),
        if (call.media.video && selfPreviewHidden)
          Positioned(
            top: 64,
            right: 12,
            child: _ShowSelfPreviewButton(onTap: onSelfPreviewShow),
          ),
        Positioned(
          left: 12,
          right: 12,
          bottom: 18,
          child: _VideoControlsBar(call: call, svc: svc),
        ),
      ],
    );
  }

  static String _statusLabel(AppL10n l, CallStatus s) => switch (s) {
    CallStatus.dialing => l.callDialing,
    CallStatus.ringing => l.callIncoming,
    CallStatus.connecting => l.callConnecting,
    CallStatus.active => l.callActive,
    CallStatus.ended => l.callEnded,
  };
}

/// Minimal opaque fill for a PiP window whose call is gone or has no video
/// stage yet. Deliberately content-free: nothing from the app may leak into
/// the floating window.
class _PipEndedCover extends StatelessWidget {
  const _PipEndedCover();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Colors.black,
      child: Center(
        child: Icon(Icons.call_end, color: Colors.white38, size: 30),
      ),
    );
  }
}

class _RemoteCallVideoView extends StatelessWidget {
  const _RemoteCallVideoView({
    required this.freshnessToken,
    required this.waitingLabel,
    this.placeholderIcon = Icons.videocam_outlined,
    this.staleLabel,
  });

  final Object freshnessToken;
  final String waitingLabel;
  final IconData placeholderIcon;
  final String? staleLabel;

  @override
  Widget build(BuildContext context) {
    if (Platform.isAndroid) {
      return _AndroidNativeRemoteVideoView(
        freshnessToken: freshnessToken,
        waitingLabel: waitingLabel,
        fit: BoxFit.contain,
        placeholderIcon: placeholderIcon,
        staleLabel: staleLabel,
      );
    }
    return CallVideoFrameView(
      frameListenable: remoteVideoFrame,
      freshnessToken: freshnessToken,
      waitingLabel: waitingLabel,
      fit: BoxFit.contain,
      placeholderIcon: placeholderIcon,
      staleLabel: staleLabel,
    );
  }
}

class _AndroidNativeRemoteVideoView extends StatefulWidget {
  const _AndroidNativeRemoteVideoView({
    required this.freshnessToken,
    required this.waitingLabel,
    required this.fit,
    required this.placeholderIcon,
    required this.staleLabel,
  });

  final Object freshnessToken;
  final String waitingLabel;
  final BoxFit fit;
  final IconData placeholderIcon;
  final String? staleLabel;

  @override
  State<_AndroidNativeRemoteVideoView> createState() =>
      _AndroidNativeRemoteVideoViewState();
}

class _AndroidNativeRemoteVideoViewState
    extends State<_AndroidNativeRemoteVideoView> {
  int? _blockedThroughFrame;
  Timer? _staleTimer;

  @override
  void initState() {
    super.initState();
    androidNativeCallVideoTexture.addListener(_onTexture);
    if (widget.staleLabel != null) {
      _staleTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void didUpdateWidget(covariant _AndroidNativeRemoteVideoView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.freshnessToken != widget.freshnessToken) {
      _blockedThroughFrame = androidNativeCallVideoTexture.value?.frames ?? 0;
    }
    if ((oldWidget.staleLabel == null) != (widget.staleLabel == null)) {
      _staleTimer?.cancel();
      _staleTimer = widget.staleLabel == null
          ? null
          : Timer.periodic(const Duration(seconds: 1), (_) {
              if (mounted) setState(() {});
            });
    }
  }

  @override
  void dispose() {
    androidNativeCallVideoTexture.removeListener(_onTexture);
    _staleTimer?.cancel();
    super.dispose();
  }

  void _onTexture() {
    final value = androidNativeCallVideoTexture.value;
    final blocked = _blockedThroughFrame;
    if (blocked != null && value != null && value.frames > blocked) {
      _blockedThroughFrame = null;
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final value = androidNativeCallVideoTexture.value;
    final blocked = _blockedThroughFrame;
    if (value == null ||
        !value.hasFrame ||
        (blocked != null && value.frames <= blocked)) {
      return CallVideoFrameView(
        frameListenable: remoteVideoFrame,
        freshnessToken: widget.freshnessToken,
        waitingLabel: widget.waitingLabel,
        fit: widget.fit,
        placeholderIcon: widget.placeholderIcon,
        staleLabel: widget.staleLabel,
      );
    }
    final lastFrameAt = value.lastFrameAt;
    final stale =
        widget.staleLabel != null &&
        lastFrameAt != null &&
        DateTime.now().difference(lastFrameAt) >= const Duration(seconds: 4);
    final texture = ColoredBox(
      color: Colors.black,
      child: ClipRect(
        child: FittedBox(
          fit: widget.fit,
          child: SizedBox(
            width: value.width.toDouble(),
            height: value.height.toDouble(),
            child: Texture(
              textureId: value.textureId,
              filterQuality: FilterQuality.low,
            ),
          ),
        ),
      ),
    );
    if (!stale) return texture;
    return Stack(
      fit: StackFit.expand,
      children: [
        texture,
        ColoredBox(
          color: Colors.black54,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.pause_circle_outline,
                  color: Colors.white.withValues(alpha: 0.7),
                  size: 34,
                ),
                const SizedBox(height: 8),
                Text(
                  widget.staleLabel!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.8),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _PipVideoView extends StatelessWidget {
  const _PipVideoView(this.call);

  final Call call;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final peerScreen = _peerScreenSharing(call);
    return ColoredBox(
      color: Colors.black,
      child: _RemoteCallVideoView(
        freshnessToken: (call.callId, peerScreen),
        waitingLabel: peerScreen ? l.callScreenWaiting : l.callVideoWaiting,
        staleLabel: l.callVideoPaused,
        placeholderIcon: peerScreen
            ? Icons.screen_share_outlined
            : Icons.videocam_outlined,
      ),
    );
  }
}

class _MediaChips extends StatelessWidget {
  const _MediaChips(this.media);
  final CallMedia media;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (media.audio) _chip(Icons.mic, l.callAudio),
        if (media.video) _chip(Icons.videocam, l.callVideo),
        if (media.screen) _chip(Icons.screen_share, l.callScreen),
      ],
    );
  }

  Widget _chip(IconData icon, String label) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: Chip(
      avatar: Icon(icon, size: 16),
      label: Text(label),
      visualDensity: VisualDensity.compact,
    ),
  );
}

class _TransportBadge extends StatelessWidget {
  const _TransportBadge(this.kind, {this.fallbackReason});
  final CallTransportKind kind;

  /// Why the route is not the negotiated one (p2p → relay fallback), when it
  /// isn't — shown inline so "relay" answers "why not p2p?" at a glance.
  final String? fallbackReason;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final (IconData icon, String label, Color color) = switch (kind) {
      CallTransportKind.onion => (
        Icons.shield,
        l.callPathOnion,
        Colors.tealAccent,
      ),
      CallTransportKind.relay => (
        Icons.alt_route,
        l.callPathRelay,
        Colors.amberAccent,
      ),
      CallTransportKind.p2p => (
        Icons.bolt,
        l.callPathP2P,
        Colors.lightBlueAccent,
      ),
      CallTransportKind.unknown => (
        Icons.lock,
        l.callPathRelay,
        Colors.white54,
      ),
    };
    final reason = fallbackReason;
    final text = reason == null || reason.isEmpty ? label : '$label · $reason';
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
            style: TextStyle(color: color, fontSize: 13),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _FloatingCallTile extends ConsumerWidget {
  const _FloatingCallTile({
    required this.call,
    required this.offset,
    required this.onDrag,
    required this.onExpand,
    required this.onHide,
  });

  final Call call;
  final Offset offset;
  final ValueChanged<Offset> onDrag;
  final VoidCallback onExpand;
  final VoidCallback onHide;

  static const double _width = 188;
  static const double _height = 154;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final svc = ref.read(callServiceProvider);
    final l = AppL10n.of(context);
    final peerScreen = _peerScreenSharing(call);
    return Positioned(
      left: offset.dx,
      top: offset.dy,
      width: _width,
      height: _height,
      child: GestureDetector(
        onPanUpdate: (d) => onDrag(d.delta),
        child: Material(
          color: Colors.black.withValues(alpha: 0.88),
          elevation: 10,
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (call.media.video || call.media.screen)
                _RemoteCallVideoView(
                  freshnessToken: (call.callId, peerScreen),
                  waitingLabel: peerScreen
                      ? l.callScreenWaiting
                      : l.callVideoWaiting,
                  staleLabel: l.callVideoPaused,
                  placeholderIcon: peerScreen
                      ? Icons.screen_share_outlined
                      : Icons.videocam_outlined,
                )
              else
                Center(
                  child: CircleAvatar(
                    radius: 34,
                    backgroundColor: const Color(0xFF171B22),
                    child: Text(
                      call.peer.short.characters.first.toUpperCase(),
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 26,
                      ),
                    ),
                  ),
                ),
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.72),
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.36),
                      ],
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 4,
                right: 4,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _TileIconButton(icon: Icons.open_in_full, onTap: onExpand),
                    _TileIconButton(
                      icon: Icons.keyboard_arrow_down,
                      onTap: onHide,
                    ),
                  ],
                ),
              ),
              Positioned(
                left: 8,
                top: 8,
                right: 76,
                child: Text(
                  call.peer.short,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
              Positioned(
                left: 8,
                bottom: 8,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _TileIconButton(
                      icon: call.micOn ? Icons.mic : Icons.mic_off,
                      onTap: () {
                        svc.setMicEnabled(!call.micOn);
                      },
                    ),
                    _TileIconButton(
                      icon: call.cameraOn ? Icons.videocam : Icons.videocam_off,
                      onTap: () {
                        svc.setCameraEnabled(!call.cameraOn);
                      },
                    ),
                  ],
                ),
              ),
              Positioned(
                right: 8,
                bottom: 8,
                child: _TileIconButton(
                  icon: Icons.call_end,
                  color: Colors.redAccent,
                  onTap: () {
                    svc.hangup();
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HiddenCallTab extends StatelessWidget {
  const _HiddenCallTab({required this.call, required this.onShow});

  final Call call;
  final VoidCallback onShow;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 12,
      bottom: 92,
      child: Material(
        color: Colors.black.withValues(alpha: 0.86),
        elevation: 8,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onShow,
          child: SizedBox.square(
            dimension: 48,
            child: Icon(
              call.media.video ? Icons.videocam : Icons.call,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

class _TileIconButton extends StatelessWidget {
  const _TileIconButton({
    required this.icon,
    required this.onTap,
    this.color = Colors.white,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.28),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox.square(
          dimension: 30,
          child: Icon(icon, size: 17, color: color),
        ),
      ),
    );
  }
}

class _SelfPreview extends StatelessWidget {
  const _SelfPreview({
    required this.call,
    required this.size,
    required this.onHide,
    required this.onResize,
  });

  static const double _width = 118;
  static const double _height = 88;
  static const double _aspect = _width / _height;
  static const double _minWidth = 118;
  static const double _maxWidth = 320;
  static const Size defaultSize = Size(_width, _height);

  static Size defaultSizeFor(Size viewport) =>
      viewport.width >= 700 ? clampSize(220) : defaultSize;

  static Size clampSize(double width) {
    final w = width.clamp(_minWidth, _maxWidth).toDouble();
    return Size(w, w / _aspect);
  }

  final Call call;
  final Size size;
  final VoidCallback onHide;
  final ValueChanged<Offset> onResize;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Material(
      color: Colors.black.withValues(alpha: 0.88),
      elevation: 8,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (Platform.isAndroid && call.cameraOn && !call.screenOn)
              _AndroidCameraSelfPreview(waitingLabel: l.callVideoWaiting)
            else
              CallVideoFrameView(
                frameListenable: localVideoFrame,
                freshnessToken: (call.callId, call.screenOn),
                waitingLabel: call.screenOn
                    ? l.callScreenWaiting
                    : l.callVideoWaiting,
                placeholderIcon: call.screenOn
                    ? Icons.screen_share_outlined
                    : Icons.videocam_outlined,
                fit: BoxFit.cover,
              ),
            if (!call.cameraOn)
              const ColoredBox(
                color: Colors.black54,
                child: Center(
                  child: Icon(
                    Icons.videocam_off,
                    color: Colors.white70,
                    size: 28,
                  ),
                ),
              ),
            Positioned(
              top: 4,
              right: 4,
              child: _TileIconButton(
                icon: Icons.keyboard_arrow_down,
                onTap: onHide,
              ),
            ),
            Positioned(
              right: 0,
              bottom: 0,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanUpdate: (d) => onResize(d.delta),
                child: Container(
                  width: 32,
                  height: 32,
                  alignment: Alignment.bottomRight,
                  padding: const EdgeInsets.all(5),
                  child: Icon(
                    Icons.open_in_full,
                    color: Colors.white.withValues(alpha: 0.86),
                    size: 16,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AndroidCameraSelfPreview extends StatelessWidget {
  const _AndroidCameraSelfPreview({required this.waitingLabel});

  final String waitingLabel;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AndroidNativeCameraPreview?>(
      valueListenable: androidNativeCallCameraPreview,
      builder: (context, nativePreview, _) {
        if (nativePreview != null) {
          return _NativeAndroidCameraTexture(preview: nativePreview);
        }
        return _PluginAndroidCameraPreview(waitingLabel: waitingLabel);
      },
    );
  }
}

class _NativeAndroidCameraTexture extends StatelessWidget {
  const _NativeAndroidCameraTexture({required this.preview});

  final AndroidNativeCameraPreview preview;

  @override
  Widget build(BuildContext context) {
    final quarterTurns = preview.rotation ~/ 90;
    final swapsAxes = quarterTurns.isOdd;
    final displayWidth = swapsAxes ? preview.height : preview.width;
    final displayHeight = swapsAxes ? preview.width : preview.height;
    Widget texture = RotatedBox(
      quarterTurns: quarterTurns,
      child: Texture(
        textureId: preview.textureId,
        filterQuality: FilterQuality.low,
      ),
    );
    if (preview.mirror) texture = Transform.flip(flipX: true, child: texture);
    return ColoredBox(
      color: Colors.black,
      child: ClipRect(
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: displayWidth.toDouble(),
            height: displayHeight.toDouble(),
            child: texture,
          ),
        ),
      ),
    );
  }
}

class _PluginAndroidCameraPreview extends StatelessWidget {
  const _PluginAndroidCameraPreview({required this.waitingLabel});

  final String waitingLabel;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CameraController?>(
      valueListenable: androidCallCameraPreviewController,
      builder: (context, controller, _) {
        final size = controller?.value.previewSize;
        if (controller == null ||
            !controller.value.isInitialized ||
            size == null) {
          return CallVideoFrameView(
            frameListenable: localVideoFrame,
            freshnessToken: 'android-camera-starting',
            waitingLabel: waitingLabel,
            fit: BoxFit.cover,
          );
        }
        final portrait =
            MediaQuery.orientationOf(context) == Orientation.portrait;
        return ColoredBox(
          color: Colors.black,
          child: ClipRect(
            child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: portrait ? size.height : size.width,
                height: portrait ? size.width : size.height,
                child: CameraPreview(controller),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ShowSelfPreviewButton extends StatelessWidget {
  const _ShowSelfPreviewButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.72),
      elevation: 6,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: const SizedBox.square(
          dimension: 44,
          child: Icon(Icons.account_box, color: Colors.white, size: 22),
        ),
      ),
    );
  }
}

class _VideoControlsBar extends StatelessWidget {
  const _VideoControlsBar({required this.call, required this.svc});

  final Call call;
  final CallService svc;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return CallControlDock(
      children: [
        CallControlAction(
          key: const ValueKey('call-mic'),
          icon: call.micOn ? Icons.mic : Icons.mic_off,
          label: call.micOn ? l.callMicOn : l.callMicOff,
          onPressed: () => svc.setMicEnabled(!call.micOn),
        ),
        CallControlAction(
          key: const ValueKey('call-camera'),
          icon: call.cameraOn ? Icons.videocam : Icons.videocam_off,
          label: call.cameraOn ? l.callCameraOn : l.callCameraOff,
          onPressed: () => svc.setCameraEnabled(!call.cameraOn),
        ),
        if (Platform.isAndroid && call.cameraOn && !call.screenOn)
          CallControlAction(
            key: const ValueKey('call-switch-camera'),
            icon: Icons.cameraswitch,
            label: l.callSwitchCamera,
            onPressed: () async {
              final ok = await svc.switchCameraFacing();
              if (!ok && context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(l.callDeviceSwitchFailed)),
                );
              }
            },
          ),
        if (call.media.video &&
            (defaultTargetPlatform == TargetPlatform.macOS ||
                defaultTargetPlatform == TargetPlatform.android))
          CallControlAction(
            key: const ValueKey('call-screen'),
            icon: call.screenOn ? Icons.stop_screen_share : Icons.screen_share,
            label: call.screenOn ? l.callScreenOn : l.callScreenOff,
            onPressed: () => svc.setScreenShareEnabled(!call.screenOn),
          ),
        if (callAudioRouter.supportsPhoneRouting) const CallAudioRouteAction(),
        CallControlAction(
          key: const ValueKey('call-end'),
          icon: Icons.call_end,
          label: l.callEnd,
          destructive: true,
          onPressed: () => svc.hangup(),
        ),
      ],
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({required this.call, required this.svc, required this.l});
  final Call call;
  final CallService svc;
  final AppL10n l;

  @override
  Widget build(BuildContext context) {
    switch (call.status) {
      case CallStatus.ringing when call.isIncoming:
        return CallControlDock(
          children: [
            CallControlAction(
              key: const ValueKey('call-decline'),
              icon: Icons.call_end,
              label: l.callDecline,
              destructive: true,
              onPressed: () => svc.reject(),
            ),
            CallControlAction(
              key: const ValueKey('call-accept'),
              icon: Icons.call,
              label: l.callAccept,
              positive: true,
              onPressed: () => svc.accept(),
            ),
          ],
        );
      case CallStatus.dialing:
        return CallControlDock(
          children: [
            CallControlAction(
              key: const ValueKey('call-cancel'),
              icon: Icons.call_end,
              label: l.callCancel,
              destructive: true,
              onPressed: () => svc.cancel(),
            ),
          ],
        );
      default:
        return CallControlDock(
          children: [
            CallControlAction(
              key: const ValueKey('call-mic'),
              icon: call.micOn ? Icons.mic : Icons.mic_off,
              label: call.micOn ? l.callMicOn : l.callMicOff,
              onPressed: () => svc.setMicEnabled(!call.micOn),
            ),
            CallControlAction(
              key: const ValueKey('call-camera'),
              icon: call.cameraOn ? Icons.videocam : Icons.videocam_off,
              label: call.cameraOn ? l.callCameraOn : l.callCameraOff,
              onPressed: () => svc.setCameraEnabled(!call.cameraOn),
            ),
            if (call.media.video &&
                (defaultTargetPlatform == TargetPlatform.macOS ||
                    defaultTargetPlatform == TargetPlatform.android))
              CallControlAction(
                key: const ValueKey('call-screen'),
                icon: call.screenOn
                    ? Icons.stop_screen_share
                    : Icons.screen_share,
                label: call.screenOn ? l.callScreenOn : l.callScreenOff,
                onPressed: () => svc.setScreenShareEnabled(!call.screenOn),
              ),
            if (callAudioRouter.supportsPhoneRouting)
              const CallAudioRouteAction(),
            CallControlAction(
              key: const ValueKey('call-end'),
              icon: Icons.call_end,
              label: l.callEnd,
              destructive: true,
              onPressed: () => svc.hangup(),
            ),
          ],
        );
    }
  }
}

/// A top or bottom gradient scrim that keeps overlaid controls legible.
class _Scrim extends StatelessWidget {
  const _Scrim({required this.top});
  final bool top;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: top ? Alignment.topCenter : Alignment.bottomCenter,
      child: Container(
        height: 140,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: top ? Alignment.topCenter : Alignment.bottomCenter,
            end: top ? Alignment.bottomCenter : Alignment.topCenter,
            colors: [Colors.black.withValues(alpha: 0.55), Colors.transparent],
          ),
        ),
      ),
    );
  }
}
