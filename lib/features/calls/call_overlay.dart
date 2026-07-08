import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veil_media/veil_media.dart' show VeilVideoFrame;

import '../../domain/call.dart';
import '../../domain/call_signal.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_controller.dart';
import '../../state/call_service.dart';
import '../../state/veil_call_media.dart' show remoteVideoFrame;

/// Full-screen call UI that floats above every route. Mounted once from
/// [MaterialApp.router]'s `builder`, it watches [currentCallProvider] and shows
/// nothing until a call is live — then the incoming-ring / dialing / connecting
/// / in-call surface. Phase 1 is control-plane only: the media toggles are
/// present but inert (wired to real capture in Phases 3–5); End/Accept/Reject/
/// Cancel drive the [CallService] FSM.
class CallOverlay extends ConsumerWidget {
  const CallOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Only engage the call stack once the node is ready — reading the call
    // provider before unlock would eagerly spin up the messaging pipeline on
    // the splash/lock screens.
    final ready = ref.watch(
        appControllerProvider.select((s) => s.phase == AppPhase.ready));
    if (!ready) return const SizedBox.shrink();
    final call = ref.watch(currentCallProvider);
    if (call == null || call.status == CallStatus.ended) {
      return const SizedBox.shrink();
    }
    return Positioned.fill(
      child: Material(
        color: const Color(0xF20E1116),
        child: SafeArea(child: _CallBody(call)),
      ),
    );
  }
}

class _CallBody extends ConsumerWidget {
  const _CallBody(this.call);
  final Call call;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final svc = ref.read(callServiceProvider);
    // Once a video/screen call is up, the remote frame fills the surface with
    // the peer info + controls floated over it; audio-only (and pre-connect)
    // stays with the centered avatar layout.
    final hasVideo = call.media.video || call.media.screen;
    final videoStage = hasVideo &&
        (call.status == CallStatus.active ||
            call.status == CallStatus.connecting);
    if (videoStage) return _videoLayout(context, l, svc);
    return _audioLayout(context, l, svc);
  }

  Widget _audioLayout(BuildContext context, AppL10n l, CallService svc) {
    return Column(
      children: [
        const Spacer(),
        CircleAvatar(
          radius: 44,
          child: Text(
            call.peer.short.characters.first.toUpperCase(),
            style: const TextStyle(fontSize: 34),
          ),
        ),
        const SizedBox(height: 16),
        Text(call.peer.short,
            style: Theme.of(context).textTheme.titleLarge,
            overflow: TextOverflow.ellipsis),
        const SizedBox(height: 8),
        Text(_statusLabel(l, call.status),
            style: Theme.of(context)
                .textTheme
                .bodyLarge
                ?.copyWith(color: Colors.white70)),
        const SizedBox(height: 12),
        _MediaChips(call.media),
        if (call.transport != null) ...[
          const SizedBox(height: 10),
          _TransportBadge(call.transport!),
        ],
        const Spacer(),
        _Controls(call: call, svc: svc, l: l),
        const SizedBox(height: 36),
      ],
    );
  }

  Widget _videoLayout(BuildContext context, AppL10n l, CallService svc) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Colors.black, child: _RemoteVideoView()),
        // Scrims so the white text/controls stay legible over any frame.
        const _Scrim(top: true),
        const _Scrim(top: false),
        Positioned(
          top: 16,
          left: 16,
          right: 16,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(call.peer.short,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(color: Colors.white),
                  overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Row(
                children: [
                  Text(_statusLabel(l, call.status),
                      style: const TextStyle(color: Colors.white70, fontSize: 13)),
                  if (call.transport != null) ...[
                    const SizedBox(width: 12),
                    _TransportBadge(call.transport!),
                  ],
                ],
              ),
            ],
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 36,
          child: _Controls(call: call, svc: svc, l: l),
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
  const _TransportBadge(this.kind);
  final CallTransportKind kind;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final (IconData icon, String label, Color color) = switch (kind) {
      CallTransportKind.onion => (Icons.shield, l.callPathOnion, Colors.tealAccent),
      CallTransportKind.relay => (Icons.alt_route, l.callPathRelay, Colors.amberAccent),
      CallTransportKind.p2p => (Icons.bolt, l.callPathP2P, Colors.lightBlueAccent),
      CallTransportKind.unknown => (Icons.lock, l.callPathRelay, Colors.white54),
    };
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(color: color, fontSize: 13)),
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
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _RoundButton(
              icon: Icons.call_end,
              color: Colors.red,
              label: l.callDecline,
              onTap: svc.reject,
            ),
            _RoundButton(
              icon: Icons.call,
              color: Colors.green,
              label: l.callAccept,
              onTap: svc.accept,
            ),
          ],
        );
      case CallStatus.dialing:
        return _RoundButton(
          icon: Icons.call_end,
          color: Colors.red,
          label: l.callCancel,
          onTap: svc.cancel,
        );
      default:
        // connecting / active — live media toggles wired to the engine.
        return Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _MiniToggle(
                  call.micOn ? Icons.mic : Icons.mic_off,
                  call.micOn ? l.callMicOn : l.callMicOff,
                  enabled: true,
                  onTap: () => svc.setMicEnabled(!call.micOn),
                ),
                if (call.media.video)
                  _MiniToggle(
                    call.cameraOn ? Icons.videocam : Icons.videocam_off,
                    call.cameraOn ? l.callCameraOn : l.callCameraOff,
                    enabled: true,
                    onTap: () => svc.setCameraEnabled(!call.cameraOn),
                  ),
                if (call.media.screen)
                  _MiniToggle(Icons.screen_share, l.callScreenOn, enabled: false),
              ],
            ),
            const SizedBox(height: 20),
            _RoundButton(
              icon: Icons.call_end,
              color: Colors.red,
              label: l.callEnd,
              onTap: svc.hangup,
            ),
          ],
        );
    }
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final Color color;
  final String label;
  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: color,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () => onTap(),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Icon(icon, color: Colors.white, size: 30),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(color: Colors.white70)),
      ],
    );
  }
}

/// Renders the decoded remote video frames from [remoteVideoFrame]. Each new
/// RGBA frame is turned into a `ui.Image` off the widget tree; decodes are
/// coalesced (only the latest pending frame is decoded) so a slow decode drops
/// frames instead of queuing stale ones.
class _RemoteVideoView extends StatefulWidget {
  const _RemoteVideoView();

  @override
  State<_RemoteVideoView> createState() => _RemoteVideoViewState();
}

class _RemoteVideoViewState extends State<_RemoteVideoView> {
  ui.Image? _image;
  VeilVideoFrame? _pending; // newest frame awaiting decode
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    remoteVideoFrame.addListener(_onFrame);
    _onFrame();
  }

  @override
  void dispose() {
    remoteVideoFrame.removeListener(_onFrame);
    _image?.dispose();
    super.dispose();
  }

  void _onFrame() {
    final f = remoteVideoFrame.value;
    if (f == null) {
      _pending = null;
      if (_image != null && mounted) {
        setState(() {
          _image?.dispose();
          _image = null;
        });
      }
      return;
    }
    _pending = f;
    if (!_busy) _drain();
  }

  void _drain() {
    final f = _pending;
    if (f == null) {
      _busy = false;
      return;
    }
    _pending = null;
    _busy = true;
    ui.decodeImageFromPixels(
      f.rgba,
      f.width,
      f.height,
      ui.PixelFormat.rgba8888,
      (img) {
        if (!mounted) {
          img.dispose();
          return;
        }
        setState(() {
          _image?.dispose();
          _image = img;
        });
        _drain(); // pick up whatever arrived while decoding
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final img = _image;
    if (img == null) {
      return Center(
        child: Text(
          '…',
          style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 40),
        ),
      );
    }
    return RawImage(image: img, fit: BoxFit.contain);
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

class _MiniToggle extends StatelessWidget {
  const _MiniToggle(this.icon, this.label, {required this.enabled, this.onTap});
  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = enabled ? Colors.white : Colors.white38;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        behavior: HitTestBehavior.opaque,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: Colors.white12,
              child: Icon(icon, color: color),
            ),
            const SizedBox(height: 6),
            Text(label, style: TextStyle(color: color, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}
