import 'dart:async' show Timer, unawaited;
import 'dart:io' show Platform;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veil_media/veil_media.dart' show VeilVideoFrame;

import '../../core/ids.dart';
import '../../domain/call_signal.dart';
import '../../domain/group.dart';
import '../../domain/group_call.dart';
import '../../domain/group_policy.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_controller.dart';
import '../../state/group_call_service.dart';
import '../../state/group_service_providers.dart';
import '../../state/veil_group_call_media.dart';

/// Global room surface for the signed group-call control plane.
///
/// It is mounted above every route, just like the 1:1 call overlay, so an
/// incoming announce can ring while the user is outside the group chat. The
/// surface deliberately renders the actual participant projection maintained
/// by [GroupCallService]; no synthetic roster is inferred from group members.
class GroupCallOverlay extends ConsumerStatefulWidget {
  const GroupCallOverlay({super.key});

  @override
  ConsumerState<GroupCallOverlay> createState() => _GroupCallOverlayState();
}

class _GroupCallOverlayState extends ConsumerState<GroupCallOverlay> {
  String? _callId;
  bool _minimized = false;

  @override
  Widget build(BuildContext context) {
    final ready = ref.watch(
      appControllerProvider.select((s) => s.phase == AppPhase.ready),
    );
    if (!ready) return const SizedBox.shrink();
    final call = ref.watch(currentGroupCallProvider).valueOrNull;
    final calls = ref.watch(groupCallServiceProvider);
    final groups = ref.watch(groupServiceProvider);
    if (call == null || !call.isLive || calls == null || groups == null) {
      _callId = null;
      _minimized = false;
      return const SizedBox.shrink();
    }
    if (_callId != call.callId) {
      _callId = call.callId;
      _minimized = false;
    }

    // Bound the room before the asynchronous group metadata resolves. This
    // overlay is a sibling of the router's Navigator, so controls below must
    // not rely on Navigator-owned Tooltip/Overlay infrastructure.
    return Positioned.fill(
      child: FutureBuilder<GroupState?>(
        future: groups.stateOf(call.groupId),
        builder: (context, snapshot) {
          final state = snapshot.data;
          final name = state?.name.trim();
          final title = name == null || name.isEmpty
              ? call.groupId.short
              : name;
          final role = state?.roleOf(groups.selfId);
          final isAdmin = role != null && role.rank >= GroupRole.admin.rank;
          final media = calls.mediaController;
          final nativeMedia = media is VeilGroupCallMediaController
              ? media
              : null;
          if (_minimized && call.status != GroupCallStatus.ringing) {
            return GroupCallMiniView(
              call: call,
              title: title,
              onExpand: () => setState(() => _minimized = false),
              onLeave: () => unawaited(calls.leave()),
            );
          }
          return Material(
            color: const Color(0xF20E1116),
            child: SafeArea(
              child: GroupCallRoomView(
                call: call,
                title: title,
                selfId: groups.selfId,
                isAdmin: isAdmin,
                onMinimize: call.status == GroupCallStatus.ringing
                    ? null
                    : () => setState(() => _minimized = true),
                onAccept: () => unawaited(calls.join()),
                onDecline: () => unawaited(calls.decline()),
                onLeave: () => unawaited(calls.leave()),
                onEndEveryone: () => unawaited(calls.endForEveryone()),
                onMic: () => unawaited(calls.setMicEnabled(!call.micOn)),
                onCamera: () =>
                    unawaited(calls.setCameraEnabled(!call.cameraOn)),
                onScreen: () =>
                    unawaited(calls.setScreenShareEnabled(!call.screenOn)),
                localVideoFrame: nativeMedia?.localVideoFrame,
                videoFrameFor: nativeMedia?.videoFrameFor,
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Pure room widget kept separate from provider wiring so layout and all
/// destructive controls can be covered by widget tests.
class GroupCallRoomView extends StatelessWidget {
  const GroupCallRoomView({
    super.key,
    required this.call,
    required this.title,
    required this.selfId,
    required this.isAdmin,
    required this.onAccept,
    required this.onDecline,
    required this.onLeave,
    required this.onEndEveryone,
    required this.onMic,
    required this.onCamera,
    required this.onScreen,
    this.onMinimize,
    this.localVideoFrame,
    this.videoFrameFor,
  });

  final GroupCall call;
  final String title;
  final NodeId selfId;
  final bool isAdmin;
  final VoidCallback? onMinimize;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final VoidCallback onLeave;
  final VoidCallback onEndEveryone;
  final VoidCallback onMic;
  final VoidCallback onCamera;
  final VoidCallback onScreen;
  final ValueListenable<VeilVideoFrame?>? localVideoFrame;
  final ValueListenable<VeilVideoFrame?>? Function(NodeId)? videoFrameFor;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final participants = call.participants.values.toList()
      ..sort((a, b) {
        if (a.nodeId == selfId) return -1;
        if (b.nodeId == selfId) return 1;
        return a.joinedAt.compareTo(b.joinedAt);
      });
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 8, 8),
          child: Row(
            children: [
              const Icon(Icons.groups_rounded, color: Colors.white70),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      key: const ValueKey('group-call-title'),
                      style: Theme.of(
                        context,
                      ).textTheme.titleLarge?.copyWith(color: Colors.white),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      call.status == GroupCallStatus.ringing
                          ? l.groupCallIncoming
                          : _statusLabel(l, call.status),
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ],
                ),
              ),
              if (onMinimize != null)
                Semantics(
                  container: true,
                  label: l.groupCallMinimize,
                  button: true,
                  child: IconButton(
                    key: const ValueKey('group-call-minimize'),
                    color: Colors.white,
                    onPressed: onMinimize,
                    icon: const Icon(Icons.keyboard_arrow_down),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              l.groupMembers(participants.length),
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(color: Colors.white60),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 720 ? 3 : 2;
              return GridView.builder(
                key: const ValueKey('group-call-participants'),
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  childAspectRatio: constraints.maxWidth < 420 ? 0.95 : 1.35,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                ),
                itemCount: participants.length,
                itemBuilder: (context, index) {
                  final participant = participants[index];
                  final isSelf = participant.nodeId == selfId;
                  final media = isSelf
                      ? CallMedia(
                          audio: call.micOn,
                          video: call.cameraOn && call.media.video,
                          screen: call.screenOn,
                        )
                      : participant.media;
                  return _ParticipantCard(
                    participant: participant,
                    label: isSelf ? l.reactorsYou : participant.nodeId.short,
                    media: media,
                    videoFrame: isSelf
                        ? localVideoFrame
                        : videoFrameFor?.call(participant.nodeId),
                  );
                },
              );
            },
          ),
        ),
        if (call.status == GroupCallStatus.ringing)
          _RingingControls(onAccept: onAccept, onDecline: onDecline)
        else
          _ActiveControls(
            call: call,
            isAdmin: isAdmin,
            onMic: onMic,
            onCamera: onCamera,
            onScreen: onScreen,
            onLeave: onLeave,
            onEndEveryone: onEndEveryone,
          ),
        const SizedBox(height: 24),
      ],
    );
  }

  static String _statusLabel(AppL10n l, GroupCallStatus status) =>
      switch (status) {
        GroupCallStatus.ringing => l.groupCallIncoming,
        GroupCallStatus.connecting => l.callConnecting,
        GroupCallStatus.active => l.callActive,
        GroupCallStatus.ended => l.callEnded,
      };
}

class _ParticipantCard extends StatelessWidget {
  const _ParticipantCard({
    required this.participant,
    required this.label,
    required this.media,
    this.videoFrame,
  });

  final GroupCallParticipant participant;
  final String label;
  final CallMedia media;
  final ValueListenable<VeilVideoFrame?>? videoFrame;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: label,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.78),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white12),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if ((media.video || media.screen) && videoFrame != null)
                _GroupVideoFrameView(
                  key: ValueKey('group-call-video-${participant.nodeId.short}'),
                  frameListenable: videoFrame!,
                )
              else
                Center(
                  child: CircleAvatar(
                    radius: 28,
                    child: Text(
                      label.characters.first.toUpperCase(),
                      style: const TextStyle(fontSize: 22),
                    ),
                  ),
                ),
              Align(
                alignment: Alignment.bottomCenter,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(10, 20, 10, 9),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Colors.black54],
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _MediaDot(
                            icon: media.audio ? Icons.mic : Icons.mic_off,
                            enabled: media.audio,
                          ),
                          if (media.video)
                            const _MediaDot(
                              icon: Icons.videocam,
                              enabled: true,
                            ),
                          if (media.screen)
                            const _MediaDot(
                              icon: Icons.screen_share,
                              enabled: true,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Coalescing raw-RGBA renderer. At most one ui decode is in flight and the
/// newest pending frame replaces stale ones, so an N-party grid cannot build
/// an unbounded decode queue when the UI thread is busy.
class _GroupVideoFrameView extends StatefulWidget {
  const _GroupVideoFrameView({super.key, required this.frameListenable});

  final ValueListenable<VeilVideoFrame?> frameListenable;

  @override
  State<_GroupVideoFrameView> createState() => _GroupVideoFrameViewState();
}

class _GroupVideoFrameViewState extends State<_GroupVideoFrameView> {
  static const _minDecodeInterval = Duration(milliseconds: 66);

  ui.Image? _image;
  VeilVideoFrame? _pending;
  bool _busy = false;
  Timer? _decodeTimer;
  DateTime? _lastDecodeAt;

  @override
  void initState() {
    super.initState();
    widget.frameListenable.addListener(_onFrame);
    _onFrame();
  }

  @override
  void didUpdateWidget(covariant _GroupVideoFrameView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.frameListenable == widget.frameListenable) return;
    oldWidget.frameListenable.removeListener(_onFrame);
    widget.frameListenable.addListener(_onFrame);
    _onFrame();
  }

  @override
  void dispose() {
    widget.frameListenable.removeListener(_onFrame);
    _decodeTimer?.cancel();
    _image?.dispose();
    super.dispose();
  }

  void _onFrame() {
    final frame = widget.frameListenable.value;
    if (frame == null) {
      _pending = null;
      if (_image != null && mounted) {
        setState(() {
          _image?.dispose();
          _image = null;
        });
      }
      return;
    }
    _pending = frame;
    _scheduleDrain();
  }

  void _scheduleDrain() {
    if (_busy || _decodeTimer != null) return;
    final last = _lastDecodeAt;
    if (last == null) {
      _drain();
      return;
    }
    final elapsed = DateTime.now().difference(last);
    if (elapsed >= _minDecodeInterval) {
      _drain();
      return;
    }
    _decodeTimer = Timer(_minDecodeInterval - elapsed, () {
      _decodeTimer = null;
      if (mounted) _drain();
    });
  }

  void _drain() {
    final frame = _pending;
    if (frame == null) {
      _busy = false;
      return;
    }
    _pending = null;
    _busy = true;
    _lastDecodeAt = DateTime.now();
    ui.decodeImageFromPixels(
      frame.rgba,
      frame.width,
      frame.height,
      ui.PixelFormat.rgba8888,
      (image) {
        if (!mounted) {
          image.dispose();
          return;
        }
        setState(() {
          _image?.dispose();
          _image = image;
        });
        _busy = false;
        if (_pending != null) _scheduleDrain();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image == null) {
      return Center(
        child: Icon(
          Icons.videocam_outlined,
          color: Colors.white.withValues(alpha: 0.35),
          size: 38,
        ),
      );
    }
    return ColoredBox(
      color: Colors.black,
      child: RawImage(image: image, fit: BoxFit.cover),
    );
  }
}

class _MediaDot extends StatelessWidget {
  const _MediaDot({required this.icon, required this.enabled});
  final IconData icon;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 3),
    child: Icon(
      icon,
      size: 17,
      color: enabled ? Colors.tealAccent : Colors.white38,
    ),
  );
}

class _RingingControls extends StatelessWidget {
  const _RingingControls({required this.onAccept, required this.onDecline});
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _CallButton(
          key: const ValueKey('group-call-decline'),
          icon: Icons.call_end,
          label: l.callDecline,
          color: Colors.redAccent,
          onPressed: onDecline,
        ),
        const SizedBox(width: 32),
        _CallButton(
          key: const ValueKey('group-call-accept'),
          icon: Icons.call,
          label: l.callAccept,
          color: Colors.green,
          onPressed: onAccept,
        ),
      ],
    );
  }
}

class _ActiveControls extends StatelessWidget {
  const _ActiveControls({
    required this.call,
    required this.isAdmin,
    required this.onMic,
    required this.onCamera,
    required this.onScreen,
    required this.onLeave,
    required this.onEndEveryone,
  });

  final GroupCall call;
  final bool isAdmin;
  final VoidCallback onMic;
  final VoidCallback onCamera;
  final VoidCallback onScreen;
  final VoidCallback onLeave;
  final VoidCallback onEndEveryone;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _CallButton(
            key: const ValueKey('group-call-mic'),
            icon: call.micOn ? Icons.mic : Icons.mic_off,
            label: call.micOn ? l.callMicOn : l.callMicOff,
            onPressed: onMic,
          ),
          if (call.media.video) ...[
            const SizedBox(width: 12),
            _CallButton(
              key: const ValueKey('group-call-camera'),
              icon: call.cameraOn ? Icons.videocam : Icons.videocam_off,
              label: call.cameraOn ? l.callCameraOn : l.callCameraOff,
              onPressed: onCamera,
            ),
            if (Platform.isMacOS) ...[
              const SizedBox(width: 12),
              _CallButton(
                key: const ValueKey('group-call-screen'),
                icon: call.screenOn
                    ? Icons.stop_screen_share
                    : Icons.screen_share,
                label: call.screenOn ? l.callScreenOn : l.callScreenOff,
                onPressed: onScreen,
              ),
            ],
          ],
          const SizedBox(width: 12),
          _CallButton(
            key: const ValueKey('group-call-leave'),
            icon: Icons.call_end,
            label: l.groupCallLeave,
            color: Colors.redAccent,
            onPressed: onLeave,
          ),
          if (isAdmin) ...[
            const SizedBox(width: 12),
            _CallButton(
              key: const ValueKey('group-call-end-everyone'),
              icon: Icons.group_off_outlined,
              label: l.groupCallEndEveryone,
              color: Colors.deepOrange,
              onPressed: onEndEveryone,
            ),
          ],
        ],
      ),
    );
  }
}

class _CallButton extends StatelessWidget {
  const _CallButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.color = const Color(0xFF38404B),
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final Color color;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: color,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: SizedBox.square(
              dimension: 52,
              child: Icon(icon, color: Colors.white),
            ),
          ),
        ),
        const SizedBox(height: 6),
        SizedBox(
          width: 82,
          child: Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
        ),
      ],
    ),
  );
}

class GroupCallMiniView extends StatelessWidget {
  const GroupCallMiniView({
    super.key,
    required this.call,
    required this.title,
    required this.onExpand,
    required this.onLeave,
  });

  final GroupCall call;
  final String title;
  final VoidCallback onExpand;
  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Align(
      alignment: Alignment.bottomRight,
      child: Padding(
        padding: const EdgeInsets.only(right: 12, bottom: 92),
        child: SizedBox(
          width: 270,
          height: 76,
          child: Material(
            key: const ValueKey('group-call-mini'),
            color: Colors.black.withValues(alpha: 0.9),
            elevation: 10,
            borderRadius: BorderRadius.circular(16),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onExpand,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                child: Row(
                  children: [
                    const CircleAvatar(
                      radius: 20,
                      child: Icon(Icons.groups_rounded),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white),
                          ),
                          Text(
                            l.groupMembers(call.participants.length),
                            style: const TextStyle(
                              color: Colors.white60,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Semantics(
                      container: true,
                      label: l.groupCallExpand,
                      button: true,
                      child: IconButton(
                        color: Colors.white,
                        onPressed: onExpand,
                        icon: const Icon(Icons.open_in_full, size: 19),
                      ),
                    ),
                    Semantics(
                      container: true,
                      label: l.groupCallLeave,
                      button: true,
                      child: IconButton(
                        key: const ValueKey('group-call-mini-leave'),
                        color: Colors.redAccent,
                        onPressed: onLeave,
                        icon: const Icon(Icons.call_end, size: 20),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
