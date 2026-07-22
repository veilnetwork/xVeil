import 'package:flutter/material.dart';

import '../chat/message_markdown.dart';

enum SpacePostTextBlockKind {
  paragraph,
  heading1,
  heading2,
  heading3,
  quote,
  bulletList,
  orderedList,
  code,
  divider,
}

class SpacePostTextBlock {
  const SpacePostTextBlock(
    this.kind, {
    this.text = '',
    this.items = const [],
    this.startOrdinal = 1,
  });

  final SpacePostTextBlockKind kind;
  final String text;
  final List<String> items;
  final int startOrdinal;
}

final _spacePostHeadingPattern = RegExp(r'^(#{1,3})[ \t]+(.*)$');
final _spacePostBulletPattern = RegExp(r'^[-+*][ \t]+(.*)$');
final _spacePostOrderedPattern = RegExp(r'^(\d+)[.)][ \t]+(.*)$');

bool _opensSpacePostFence(String line) {
  final trimmed = line.trimLeft();
  return trimmed.startsWith('```') && !trimmed.substring(3).contains('```');
}

String _trimBlockNewlines(String value) =>
    value.replaceFirst(RegExp(r'^\n+'), '').replaceFirst(RegExp(r'\n+$'), '');

/// Parses the publication body's compatible Markdown representation into
/// structural blocks. The signed/wire value stays a single readable string,
/// so older peers keep displaying the content even without the rich renderer.
List<SpacePostTextBlock> parseSpacePostTextBlocks(String body) {
  final lines = body.split('\n');
  final blocks = <SpacePostTextBlock>[];
  final paragraph = <String>[];

  void flushParagraph() {
    final text = _trimBlockNewlines(paragraph.join('\n'));
    paragraph.clear();
    if (text.isNotEmpty) {
      blocks.add(
        SpacePostTextBlock(SpacePostTextBlockKind.paragraph, text: text),
      );
    }
  }

  var index = 0;
  while (index < lines.length) {
    final line = lines[index];
    final trimmed = line.trimLeft();

    if (_opensSpacePostFence(line)) {
      var closing = index + 1;
      while (closing < lines.length &&
          !lines[closing].trimLeft().startsWith('```')) {
        closing++;
      }
      if (closing < lines.length) {
        flushParagraph();
        blocks.add(
          SpacePostTextBlock(
            SpacePostTextBlockKind.code,
            text: lines.sublist(index + 1, closing).join('\n'),
          ),
        );
        index = closing + 1;
        continue;
      }
    }

    final heading = _spacePostHeadingPattern.firstMatch(trimmed);
    if (heading != null) {
      flushParagraph();
      final level = heading.group(1)!.length;
      blocks.add(
        SpacePostTextBlock(switch (level) {
          1 => SpacePostTextBlockKind.heading1,
          2 => SpacePostTextBlockKind.heading2,
          _ => SpacePostTextBlockKind.heading3,
        }, text: heading.group(2)!),
      );
      index++;
      continue;
    }

    if (trimmed == '---' || trimmed == '***' || trimmed == '___') {
      flushParagraph();
      blocks.add(const SpacePostTextBlock(SpacePostTextBlockKind.divider));
      index++;
      continue;
    }

    if (trimmed.startsWith('>')) {
      flushParagraph();
      final quoted = <String>[];
      while (index < lines.length) {
        final candidate = lines[index].trimLeft();
        if (!candidate.startsWith('>')) break;
        var content = candidate.substring(1);
        if (content.startsWith(' ')) content = content.substring(1);
        quoted.add(content);
        index++;
      }
      blocks.add(
        SpacePostTextBlock(
          SpacePostTextBlockKind.quote,
          text: quoted.join('\n'),
        ),
      );
      continue;
    }

    final bullet = _spacePostBulletPattern.firstMatch(trimmed);
    if (bullet != null) {
      flushParagraph();
      final items = <String>[];
      while (index < lines.length) {
        final match = _spacePostBulletPattern.firstMatch(
          lines[index].trimLeft(),
        );
        if (match == null) break;
        items.add(match.group(1)!);
        index++;
      }
      blocks.add(
        SpacePostTextBlock(
          SpacePostTextBlockKind.bulletList,
          items: List.unmodifiable(items),
        ),
      );
      continue;
    }

    final ordered = _spacePostOrderedPattern.firstMatch(trimmed);
    if (ordered != null) {
      flushParagraph();
      final items = <String>[];
      final start = int.tryParse(ordered.group(1)!) ?? 1;
      while (index < lines.length) {
        final match = _spacePostOrderedPattern.firstMatch(
          lines[index].trimLeft(),
        );
        if (match == null) break;
        items.add(match.group(2)!);
        index++;
      }
      blocks.add(
        SpacePostTextBlock(
          SpacePostTextBlockKind.orderedList,
          items: List.unmodifiable(items),
          startOrdinal: start,
        ),
      );
      continue;
    }

    paragraph.add(line);
    index++;
  }
  flushParagraph();
  return blocks;
}

/// Rich publication renderer. Inline formatting and privacy-preserving links
/// stay delegated to [FormattedText]; this widget only supplies the structural
/// layer that publications need on top.
class SpacePostBody extends StatelessWidget {
  const SpacePostBody(
    this.body, {
    super.key,
    this.style,
    this.selectable = true,
  });

  final String body;
  final TextStyle? style;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final blocks = parseSpacePostTextBlocks(body);
    final content =
        blocks.length == 1 &&
            blocks.single.kind == SpacePostTextBlockKind.paragraph
        ? FormattedText(blocks.single.text, style: style)
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var index = 0; index < blocks.length; index++) ...[
                if (index > 0) const SizedBox(height: 8),
                _SpacePostTextBlockView(block: blocks[index], style: style),
              ],
            ],
          );
    return selectable ? SelectionArea(child: content) : content;
  }
}

class _SpacePostTextBlockView extends StatelessWidget {
  const _SpacePostTextBlockView({required this.block, this.style});

  final SpacePostTextBlock block;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = style ?? DefaultTextStyle.of(context).style;
    return switch (block.kind) {
      SpacePostTextBlockKind.paragraph => FormattedText(
        block.text,
        style: style,
      ),
      SpacePostTextBlockKind.heading1 => FormattedText(
        block.text,
        style: base
            .merge(theme.textTheme.titleLarge)
            .copyWith(color: base.color, fontWeight: FontWeight.w700),
      ),
      SpacePostTextBlockKind.heading2 => FormattedText(
        block.text,
        style: base
            .merge(theme.textTheme.titleMedium)
            .copyWith(color: base.color, fontWeight: FontWeight.w700),
      ),
      SpacePostTextBlockKind.heading3 => FormattedText(
        block.text,
        style: base
            .merge(theme.textTheme.titleSmall)
            .copyWith(color: base.color, fontWeight: FontWeight.w700),
      ),
      SpacePostTextBlockKind.quote => Container(
        width: double.infinity,
        padding: const EdgeInsets.only(left: 10, top: 2, bottom: 2),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: theme.colorScheme.primary, width: 3),
          ),
        ),
        child: FormattedText(
          block.text,
          style: base.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
      SpacePostTextBlockKind.bulletList => _SpacePostList(
        items: block.items,
        style: style,
      ),
      SpacePostTextBlockKind.orderedList => _SpacePostList(
        items: block.items,
        style: style,
        startOrdinal: block.startOrdinal,
      ),
      SpacePostTextBlockKind.code => FormattedText(
        '```\n${block.text}\n```',
        style: style,
      ),
      SpacePostTextBlockKind.divider => const Divider(height: 12),
    };
  }
}

class _SpacePostList extends StatelessWidget {
  const _SpacePostList({required this.items, this.style, this.startOrdinal});

  final List<String> items;
  final TextStyle? style;
  final int? startOrdinal;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      for (var index = 0; index < items.length; index++)
        Padding(
          padding: EdgeInsets.only(top: index == 0 ? 0 : 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 30,
                child: Text(
                  startOrdinal == null ? '•' : '${startOrdinal! + index}.',
                  textAlign: TextAlign.right,
                  style: style,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(child: FormattedText(items[index], style: style)),
            ],
          ),
        ),
    ],
  );
}
