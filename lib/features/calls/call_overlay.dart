import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/call.dart';
import '../../domain/call_signal.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_controller.dart';
import '../../state/call_service.dart';

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
        // connecting / active — media toggles are inert stubs until Phases 3–5.
        return Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _MiniToggle(Icons.mic, l.callMicOn, enabled: false),
                if (call.media.video)
                  _MiniToggle(Icons.videocam, l.callCameraOn, enabled: false),
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

class _MiniToggle extends StatelessWidget {
  const _MiniToggle(this.icon, this.label, {required this.enabled});
  final IconData icon;
  final String label;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final color = enabled ? Colors.white : Colors.white38;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
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
    );
  }
}
