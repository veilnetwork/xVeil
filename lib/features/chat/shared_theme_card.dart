// A theme that arrived in a chat.
//
// Sharing a look is a chat action before it is a settings action — somebody
// makes one, sends it to a friend, and the friend is looking at sixty
// characters of base64. So a message carrying a theme is drawn as the theme:
// a miniature of this app in the colours it would take, built through the same
// `AppTheme.of` the app itself uses, so what the card shows is what accepting
// it does rather than an impression of it.
//
// The preview deliberately includes a WARNING line. A theme comes from another
// person, and the one thing a person needs to know before wearing a stranger's
// colours is that the sentences this app cannot afford to have missed are
// still legible in them. Showing it is stronger than promising it — and the
// promise is kept by `AppTheme`, which repairs foregrounds against every
// surface a theme chose (see theme_contrast_test.dart).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/inline_custom_emoji.dart';
import '../../domain/theme_spec.dart';
import '../../l10n/app_localizations.dart';
import '../../state/theme_controller.dart';
import '../../theme/app_theme.dart';
import 'message_markdown.dart';

/// The bubble content for a message that carries a theme.
class SharedThemeCard extends ConsumerWidget {
  const SharedThemeCard({
    super.key,
    required this.found,
    this.highlight,
    this.customEmoji = const [],
  });

  /// The theme, and whatever the sender wrote around it.
  final ThemeInText found;

  final String? highlight;
  final List<InlineCustomEmoji> customEmoji;

  Future<void> _use(WidgetRef ref) async {
    final spec = found.spec;
    final notifier = ref.read(themeProvider.notifier);
    // A built-in that came back from a friend is the one this app already
    // ships, not a copy of it — keeping it as "yours" would leave two
    // identical rows in the picker and no way to tell them apart.
    if (kBuiltInThemes.contains(spec)) {
      await notifier.choose(spec);
    } else {
      await notifier.addCustom(spec);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final spec = found.spec;
    final wearing = ref.watch(themeProvider.select((c) => c.chosen == spec));
    final words = found.words;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Whatever the sender actually wrote. The encoded part is theirs to
        // send and nobody's to read, so it is taken out — but the sentence it
        // came with is a message like any other.
        if (words.isNotEmpty) ...[
          FormattedText(words, highlight: highlight, customEmoji: customEmoji),
          const SizedBox(height: 8),
        ],
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 280),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.palette_outlined,
                    size: 15,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    l.themeInChat,
                    style: text.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              SharedThemePreview(spec: spec),
              const SizedBox(height: 6),
              Text(
                spec.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: text.titleSmall,
              ),
              const SizedBox(height: 2),
              // Said before the tap, not after it: what a stranger's theme can
              // and cannot do is only useful while there is still a decision.
              Text(
                l.themeInChatSafety,
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              if (wearing)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check, size: 16, color: scheme.primary),
                    const SizedBox(width: 6),
                    Text(
                      l.themeInChatInUse,
                      style: text.labelLarge?.copyWith(color: scheme.primary),
                    ),
                  ],
                )
              else
                FilledButton.tonalIcon(
                  onPressed: () => _use(ref),
                  icon: const Icon(Icons.brush_outlined, size: 18),
                  label: Text(l.themeInChatUse),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// This app, in miniature, wearing [spec].
///
/// Built from `AppTheme.of` rather than from the spec's fields, so a theme
/// whose colours had to be repaired to stay readable is previewed AS REPAIRED.
/// A preview that showed the raw request would be advertising something the
/// app will not do.
class SharedThemePreview extends StatelessWidget {
  const SharedThemePreview({super.key, required this.spec});

  final ThemeSpec spec;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final s = AppTheme.of(spec).colorScheme;
    final small = Theme.of(context).textTheme.bodySmall;
    return Container(
      decoration: BoxDecoration(
        color: s.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: s.onSurfaceVariant.withValues(alpha: 0.25)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // A title bar, so the surface colour is shown carrying something
          // rather than as a swatch.
          Container(
            color: s.surfaceContainerHigh,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              children: [
                Icon(Icons.shield_outlined, size: 13, color: s.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    spec.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: small?.copyWith(
                      color: s.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // The two bubbles, painted the way the chat paints them — an
                // incoming one on the raised surface, an outgoing one on the
                // primary container with its own ink.
                _MiniBubble(
                  text: l.themeInChatSampleTheirs,
                  fill: s.surfaceContainerHighest,
                  ink: s.onSurface,
                  mine: false,
                  style: small,
                ),
                const SizedBox(height: 5),
                _MiniBubble(
                  text: l.themeInChatSampleMine,
                  fill: s.primaryContainer,
                  ink: s.onPrimaryContainer,
                  mine: true,
                  style: small,
                ),
                const SizedBox(height: 8),
                // The line that matters. If a theme could hide this, no
                // preview of it would be worth showing.
                Row(
                  children: [
                    Icon(Icons.warning_amber_rounded, size: 14, color: s.error),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        l.themeInChatSampleWarning,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: small?.copyWith(color: s.error),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniBubble extends StatelessWidget {
  const _MiniBubble({
    required this.text,
    required this.fill,
    required this.ink,
    required this.mine,
    required this.style,
  });

  final String text;
  final Color fill;
  final Color ink;
  final bool mine;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => Align(
    alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(10),
          topRight: const Radius.circular(10),
          bottomLeft: Radius.circular(mine ? 10 : 2),
          bottomRight: Radius.circular(mine ? 2 : 10),
        ),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style?.copyWith(color: ink),
      ),
    ),
  );
}
