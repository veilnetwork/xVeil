import 'dart:async' show unawaited;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../state/call_audio_route.dart';

/// Shared Element-style chrome for direct and group call surfaces.
class CallSurfaceHeader extends StatelessWidget {
  const CallSurfaceHeader({
    super.key,
    required this.title,
    required this.subtitle,
    this.group = false,
    this.onMinimize,
    this.onSettings,
    this.minimizeKey,
    this.minimizeLabel,
  });

  final String title;
  final String subtitle;
  final bool group;
  final VoidCallback? onMinimize;
  final VoidCallback? onSettings;
  final Key? minimizeKey;
  final String? minimizeLabel;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
    child: SizedBox(
      height: 54,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: onMinimize == null
                ? const SizedBox(width: 48)
                : Semantics(
                    container: true,
                    label: minimizeLabel,
                    button: true,
                    child: ExcludeSemantics(
                      child: IconButton(
                        key:
                            minimizeKey ??
                            const ValueKey('call-surface-minimize'),
                        onPressed: onMinimize,
                        color: Colors.white,
                        icon: const Icon(
                          Icons.keyboard_arrow_down_rounded,
                          size: 30,
                        ),
                      ),
                    ),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 54),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      group ? Icons.groups_rounded : Icons.lock_outline_rounded,
                      size: 15,
                      color: Colors.white54,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        title,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white60, fontSize: 12),
                ),
              ],
            ),
          ),
          if (onSettings != null)
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                key: const ValueKey('call-surface-settings'),
                onPressed: onSettings,
                color: Colors.white,
                icon: const Icon(Icons.more_vert),
              ),
            ),
        ],
      ),
    ),
  );
}

class CallControlDock extends StatelessWidget {
  const CallControlDock({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: ConstrainedBox(
        constraints: BoxConstraints(minWidth: constraints.maxWidth - 24),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const SizedBox(width: 12),
              children[i],
            ],
          ],
        ),
      ),
    ),
  );
}

class CallControlAction extends StatelessWidget {
  const CallControlAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.selected = false,
    this.destructive = false,
    this.positive = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool selected;
  final bool destructive;
  final bool positive;

  @override
  Widget build(BuildContext context) {
    final background = destructive
        ? const Color(0xFFFF3B4E)
        : positive
        ? const Color(0xFF24B47E)
        : selected
        ? Colors.white
        : const Color(0xFF20252D);
    final foreground = selected && !destructive && !positive
        ? const Color(0xFF151920)
        : Colors.white;
    return Semantics(
      button: true,
      label: label,
      selected: selected,
      child: Material(
        color: background,
        shape: CircleBorder(side: BorderSide(color: Colors.white24)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox.square(
            dimension: 54,
            child: Icon(icon, color: foreground, size: 25),
          ),
        ),
      ),
    );
  }
}

class CallAudioRouteAction extends StatelessWidget {
  const CallAudioRouteAction({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return ValueListenableBuilder<CallAudioRoute>(
      valueListenable: callAudioRouter.route,
      builder: (context, route, _) {
        final speaker = route == CallAudioRoute.speaker;
        return CallControlAction(
          key: const ValueKey('call-audio-route'),
          icon: speaker ? Icons.volume_up_rounded : Icons.phone_in_talk_rounded,
          label: speaker ? l.callSpeaker : l.callEarpiece,
          selected: speaker,
          onPressed: () => unawaited(callAudioRouter.toggle()),
        );
      },
    );
  }
}
