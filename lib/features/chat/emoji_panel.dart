// Emoji picker panel (user remark #2, 2026-07-10): a bottom sheet with a
// search field and the grouped grid, opened from the composer's emoji button
// (desktop finally gets a way to insert emoji; on mobile it complements the
// system keyboard). Returns the picked emoji char, or null when dismissed.

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import 'emoji_data.dart';

Future<String?> showEmojiPanel(BuildContext context) =>
    showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      // Cap the sheet: a grid wants height, but the chat must stay visible.
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (_) => const _EmojiSheet(),
    );

class _EmojiSheet extends StatefulWidget {
  const _EmojiSheet();

  @override
  State<_EmojiSheet> createState() => _EmojiSheetState();
}

class _EmojiSheetState extends State<_EmojiSheet> {
  String _query = '';
  int _group = 0;
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Widget _grid(List<EmojiEntry> entries) => GridView.builder(
        controller: _scroll,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 44,
        ),
        itemCount: entries.length,
        itemBuilder: (context, i) {
          final e = entries[i];
          return InkWell(
            key: ValueKey('emoji:${e.char}'),
            borderRadius: BorderRadius.circular(8),
            onTap: () => Navigator.of(context).pop(e.char),
            child: Tooltip(
              message: e.name,
              waitDuration: const Duration(milliseconds: 600),
              child: Center(
                child: Text(e.char, style: const TextStyle(fontSize: 24)),
              ),
            ),
          );
        },
      );

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final searching = _query.trim().isNotEmpty;
    final hits = searchEmoji(_query);
    return SizedBox(
      height: 420,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              autofocus: true,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search, size: 20),
                hintText: l.emojiSearchHint,
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          if (!searching)
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (var i = 0; i < emojiGroups.length; i++)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: ChoiceChip(
                        key: ValueKey('emoji-group:${emojiGroups[i].name}'),
                        label: Text(emojiGroups[i].tab),
                        tooltip: emojiGroups[i].name,
                        selected: _group == i,
                        showCheckmark: false,
                        selectedColor: scheme.primaryContainer,
                        onSelected: (_) => setState(() {
                          _group = i;
                          if (_scroll.hasClients) _scroll.jumpTo(0);
                        }),
                      ),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 4),
          Expanded(
            child: searching
                ? (hits.isEmpty
                    ? Center(child: Text(l.searchNoResults))
                    : _grid(hits))
                : _grid(emojiGroups[_group].entries),
          ),
        ],
      ),
    );
  }
}
