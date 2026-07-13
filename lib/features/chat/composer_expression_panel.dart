import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import 'emoji_panel.dart';
import 'sticker_panel.dart';

enum ComposerExpressionKind { emoji, sticker, gif }

class ComposerExpressionResult {
  const ComposerExpressionResult(this.kind, [this.value]);

  final ComposerExpressionKind kind;
  final String? value;
}

/// One expression hub for every composer. It deliberately offers local GIF
/// import instead of a third-party search endpoint: a clear-web search would
/// disclose chat-adjacent intent outside the veil overlay.
Future<ComposerExpressionResult?> showComposerExpressionPanel(
  BuildContext context, {
  bool enableStickers = true,
  bool enableGif = true,
  bool allowStickerPackShare = true,
}) => showModalBottomSheet<ComposerExpressionResult>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  constraints: const BoxConstraints(maxWidth: 560),
  builder: (_) => _ExpressionHub(
    enableStickers: enableStickers,
    enableGif: enableGif,
    allowStickerPackShare: allowStickerPackShare,
  ),
);

class _ExpressionHub extends StatelessWidget {
  const _ExpressionHub({
    required this.enableStickers,
    required this.enableGif,
    required this.allowStickerPackShare,
  });

  final bool enableStickers;
  final bool enableGif;
  final bool allowStickerPackShare;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final tabs = <Widget>[
      Tab(
        icon: const Icon(Icons.emoji_emotions_outlined),
        text: l.chatEmojiTooltip,
      ),
      if (enableStickers)
        Tab(
          icon: const Icon(Icons.sticky_note_2_outlined),
          text: l.stickerTitle,
        ),
      if (enableGif)
        Tab(icon: const Icon(Icons.gif_box_outlined), text: l.composerGif),
    ];
    final views = <Widget>[
      EmojiPicker(
        autofocus: false,
        onSelected: (value) => Navigator.of(
          context,
        ).pop(ComposerExpressionResult(ComposerExpressionKind.emoji, value)),
      ),
      if (enableStickers)
        StickerPicker(
          allowPackShare: allowStickerPackShare,
          onSelected: (value) => Navigator.of(context).pop(
            ComposerExpressionResult(ComposerExpressionKind.sticker, value),
          ),
        ),
      if (enableGif)
        _GifPicker(
          onPick: () => Navigator.of(
            context,
          ).pop(const ComposerExpressionResult(ComposerExpressionKind.gif)),
        ),
    ];
    return DefaultTabController(
      length: tabs.length,
      child: SizedBox(
        height: 480,
        child: Column(
          children: [
            TabBar(tabs: tabs),
            Expanded(child: TabBarView(children: views)),
          ],
        ),
      ),
    );
  }
}

class _GifPicker extends StatelessWidget {
  const _GifPicker({required this.onPick});

  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.gif_box_outlined, size: 56, color: scheme.primary),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              key: const ValueKey('composer-pick-gif'),
              onPressed: onPick,
              icon: const Icon(Icons.folder_open_outlined),
              label: Text(l.composerGifLocal),
            ),
            const SizedBox(height: 12),
            Text(
              l.composerGifPrivacy,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
