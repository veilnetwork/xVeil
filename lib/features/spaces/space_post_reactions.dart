import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/ids.dart';
import '../../domain/group_reaction.dart';
import '../../l10n/app_localizations.dart';

const _quickSpacePostReactions = ['👍', '❤', '😂', '😮', '😢', '🙏'];

/// Compact reaction controls shared by a Space's own publication list and the
/// merged user feed. Existing reactions remain visible; the add button keeps
/// an empty post from reserving a full row of emoji controls.
class SpacePostReactionBar extends StatelessWidget {
  const SpacePostReactionBar({
    super.key,
    required this.postId,
    required this.reactions,
    required this.selfId,
    required this.onReact,
    this.onPublicReact,
  });

  final String postId;
  final MessageReactions reactions;
  final NodeId selfId;
  final Future<bool> Function(String emoji)? onReact;
  final Future<bool> Function(String emoji)? onPublicReact;

  @override
  Widget build(BuildContext context) {
    final entries = reactions.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final entry in entries)
          FilterChip(
            key: ValueKey('space-post-reaction-$postId-${entry.key}'),
            selected: entry.value.contains(selfId),
            showCheckmark: false,
            visualDensity: VisualDensity.compact,
            label: Text('${entry.key} ${entry.value.length}'),
            onSelected: onReact == null
                ? null
                : (_) => unawaited(onReact!(entry.key)),
          ),
        if (onReact != null)
          PopupMenuButton<String>(
            key: ValueKey('space-post-add-reaction-$postId'),
            icon: const Icon(Icons.add_reaction_outlined, size: 20),
            padding: EdgeInsets.zero,
            onSelected: (emoji) => unawaited(onReact!(emoji)),
            itemBuilder: (_) => [
              for (final emoji in _quickSpacePostReactions)
                PopupMenuItem(value: emoji, child: Text(emoji)),
            ],
          ),
        if (onPublicReact != null)
          PopupMenuButton<String>(
            key: ValueKey('space-post-add-public-reaction-$postId'),
            tooltip: AppL10n.of(context).spacePostPublicReaction,
            icon: const Icon(Icons.public, size: 20),
            padding: EdgeInsets.zero,
            onSelected: (emoji) => unawaited(onPublicReact!(emoji)),
            itemBuilder: (_) => [
              for (final emoji in _quickSpacePostReactions)
                PopupMenuItem(value: emoji, child: Text(emoji)),
            ],
          ),
      ],
    );
  }
}
