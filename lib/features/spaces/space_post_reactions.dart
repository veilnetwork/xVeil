import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/ids.dart';
import '../../domain/group_reaction.dart';

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
  });

  final String postId;
  final MessageReactions reactions;
  final NodeId selfId;
  final Future<bool> Function(String emoji) onReact;

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
            onSelected: (_) => unawaited(onReact(entry.key)),
          ),
        PopupMenuButton<String>(
          key: ValueKey('space-post-add-reaction-$postId'),
          icon: const Icon(Icons.add_reaction_outlined, size: 20),
          padding: EdgeInsets.zero,
          onSelected: (emoji) => unawaited(onReact(emoji)),
          itemBuilder: (_) => [
            for (final emoji in _quickSpacePostReactions)
              PopupMenuItem(value: emoji, child: Text(emoji)),
          ],
        ),
      ],
    );
  }
}
