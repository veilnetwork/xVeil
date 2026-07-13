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
}) {
  Widget hub() => _ExpressionHub(
    enableStickers: enableStickers,
    enableGif: enableGif,
    allowStickerPackShare: allowStickerPackShare,
  );

  // Keep one spatial contract on every form factor: the hub floats above the
  // composer instead of growing out of the physical bottom edge. On phones the
  // SafeArea + horizontal inset make it a compact near-full-width card; on
  // desktop it caps at 560 px. This also leaves Android's gesture/navigation
  // area and the message field visually separate from the expression grid.
  return showGeneralDialog<ComposerExpressionResult>(
    context: context,
    useRootNavigator: false,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withValues(alpha: 0.28),
    transitionDuration: const Duration(milliseconds: 160),
    pageBuilder: (dialogContext, _, _) {
      final available = MediaQuery.sizeOf(dialogContext).height;
      final viewPadding = MediaQuery.viewPaddingOf(dialogContext);
      final bottomPadding = kExpressionPanelBottomGap + viewPadding.bottom;
      final height =
          (available -
                  viewPadding.top -
                  bottomPadding -
                  kExpressionPanelOuterTopGap)
              .clamp(240.0, 480.0);
      return SafeArea(
        bottom: false,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              kExpressionPanelOuterTopGap,
              16,
              bottomPadding,
            ),
            child: Material(
              key: const ValueKey('composer-expression-panel'),
              color: Theme.of(dialogContext).colorScheme.surface,
              elevation: 12,
              borderRadius: BorderRadius.circular(24),
              clipBehavior: Clip.antiAlias,
              child: SizedBox(width: 560, height: height, child: hub()),
            ),
          ),
        ),
      );
    },
    transitionBuilder: (_, animation, _, child) => FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
      child: SlideTransition(
        position: Tween<Offset>(begin: const Offset(0, 0.04), end: Offset.zero)
            .animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
            ),
        child: child,
      ),
    ),
  );
}

const double kExpressionPanelBottomGap = 88;
const double kExpressionPanelOuterTopGap = 16;

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
      child: Column(
        children: [
          TabBar(tabs: tabs),
          Expanded(child: TabBarView(children: views)),
        ],
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
