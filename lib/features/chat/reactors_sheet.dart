// "Who reacted" sheet, shared by 1:1 chats and groups: one section per emoji
// (most-used first), one tile per reactor with their resolved display name.
// The callers resolve names themselves (their reactor types differ: NodeId in
// groups, reactor-hex in 1:1) and hand the sheet plain strings.

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

/// Invert a 1:1 reactions record `{reactorHex: emoji}` into
/// `{emoji: [reactorHex, …]}` — the shape the group fold already produces and
/// [showReactorsSheet] renders. Reactor order within an emoji is preserved.
Map<String, List<String>> invertReactions(Map<String, String> byReactor) {
  final out = <String, List<String>>{};
  for (final e in byReactor.entries) {
    if (e.value.isEmpty) continue;
    (out[e.value] ??= []).add(e.key);
  }
  return out;
}

/// Show the reactor list for one message: [namesByEmoji] maps each emoji to the
/// display names of everyone who set it (already resolved by the caller).
Future<void> showReactorsSheet(
  BuildContext context, {
  required Map<String, List<String>> namesByEmoji,
}) {
  final sections =
      namesByEmoji.entries.where((e) => e.value.isNotEmpty).toList()
        ..sort((a, b) => b.value.length.compareTo(a.value.length));
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) {
      final l = AppL10n.of(context);
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.6,
          ),
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(
                  l.reactorsTitle,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              for (final s in sections) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
                  child: Text(
                    '${s.key} ${s.value.length}',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
                for (final name in s.value)
                  ListTile(
                    dense: true,
                    leading: CircleAvatar(
                      child: Text(
                        name.isEmpty
                            ? '?'
                            : name.characters.first.toUpperCase(),
                      ),
                    ),
                    title: Text(name),
                    trailing: Text(s.key, style: const TextStyle(fontSize: 18)),
                  ),
              ],
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
    },
  );
}
