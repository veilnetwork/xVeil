import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../chat/message_markdown.dart';
import 'space_post_body.dart';

enum SpacePostBlockStyle {
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

final _existingSpacePostBlockPrefix = RegExp(
  r'^(?:#{1,3}[ \t]+|>[ \t]?|[-+*][ \t]+|\d+[.)][ \t]+)',
);

String _withoutSpacePostBlockPrefix(String line) {
  if (const {'---', '***', '___'}.contains(line.trim())) return '';
  return line.replaceFirst(_existingSpacePostBlockPrefix, '');
}

/// Replaces the structural style of every selected line. The returned text is
/// ordinary Markdown and therefore remains readable by older peers.
({String text, TextSelection selection}) applySpacePostBlockStyle(
  String text,
  TextSelection selection,
  SpacePostBlockStyle style,
) {
  final rawStart = selection.isValid ? selection.start : text.length;
  final rawEnd = selection.isValid ? selection.end : text.length;
  final start = rawStart.clamp(0, text.length);
  final end = rawEnd.clamp(start, text.length);
  final lineStart = start == 0 ? 0 : text.lastIndexOf('\n', start - 1) + 1;
  var lineEnd = text.indexOf('\n', end);
  if (lineEnd < 0) lineEnd = text.length;
  if (end > start && end <= text.length && text[end - 1] == '\n') {
    lineEnd = end - 1;
  }
  final region = text.substring(lineStart, lineEnd);

  if (style == SpacePostBlockStyle.code) {
    final fenced = '```\n$region\n```';
    final updated = text.replaceRange(lineStart, lineEnd, fenced);
    final contentStart = lineStart + 4;
    return (
      text: updated,
      selection: region.isEmpty
          ? TextSelection.collapsed(offset: contentStart)
          : TextSelection(
              baseOffset: contentStart,
              extentOffset: contentStart + region.length,
            ),
    );
  }

  final lines = region.split('\n');
  final plain = lines.map(_withoutSpacePostBlockPrefix).toList();
  final transformed = switch (style) {
    SpacePostBlockStyle.paragraph => plain.join('\n'),
    SpacePostBlockStyle.heading1 => plain.map((line) => '# $line').join('\n'),
    SpacePostBlockStyle.heading2 => plain.map((line) => '## $line').join('\n'),
    SpacePostBlockStyle.heading3 => plain.map((line) => '### $line').join('\n'),
    SpacePostBlockStyle.quote => plain.map((line) => '> $line').join('\n'),
    SpacePostBlockStyle.bulletList => plain.map((line) => '- $line').join('\n'),
    SpacePostBlockStyle.orderedList => [
      for (var index = 0; index < plain.length; index++)
        '${index + 1}. ${plain[index]}',
    ].join('\n'),
    SpacePostBlockStyle.divider => '---',
    SpacePostBlockStyle.code => throw StateError('handled above'),
  };
  final updated = text.replaceRange(lineStart, lineEnd, transformed);
  return (
    text: updated,
    selection: TextSelection.collapsed(offset: lineStart + transformed.length),
  );
}

class SpacePostBodyEditor extends StatefulWidget {
  const SpacePostBodyEditor({
    super.key,
    required this.controller,
    required this.maxLength,
    required this.hintText,
    this.onChanged,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final int maxLength;
  final String hintText;
  final ValueChanged<String>? onChanged;
  final bool autofocus;

  @override
  State<SpacePostBodyEditor> createState() => _SpacePostBodyEditorState();
}

class _SpacePostBodyEditorState extends State<SpacePostBodyEditor> {
  final FocusNode _focusNode = FocusNode();
  bool _preview = false;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _setValue(({String text, TextSelection selection}) result) {
    if (result.text.length > widget.maxLength) return;
    widget.controller.value = widget.controller.value.copyWith(
      text: result.text,
      selection: result.selection,
      composing: TextRange.empty,
    );
    widget.onChanged?.call(result.text);
    _focusNode.requestFocus();
    setState(() {});
  }

  void _applyBlock(SpacePostBlockStyle style) => _setValue(
    applySpacePostBlockStyle(
      widget.controller.text,
      widget.controller.selection,
      style,
    ),
  );

  void _applyInline(String marker) {
    final value = widget.controller.value;
    _setValue(applyMarker(value.text, value.selection, marker));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: colors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Wrap(
              spacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                PopupMenuButton<SpacePostBlockStyle>(
                  key: const ValueKey('space-post-block-menu'),
                  tooltip: l.spacePostBlocks,
                  enabled: !_preview,
                  onSelected: _applyBlock,
                  itemBuilder: (_) => [
                    for (final style in SpacePostBlockStyle.values)
                      PopupMenuItem(
                        value: style,
                        child: Row(
                          children: [
                            Icon(_blockIcon(style), size: 18),
                            const SizedBox(width: 10),
                            Text(_blockLabel(l, style)),
                          ],
                        ),
                      ),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.view_agenda_outlined, size: 19),
                        const SizedBox(width: 6),
                        Text(l.spacePostBlocks),
                        const Icon(Icons.arrow_drop_down, size: 18),
                      ],
                    ),
                  ),
                ),
                PopupMenuButton<String>(
                  key: const ValueKey('space-post-inline-format-menu'),
                  tooltip: l.chatFormatTooltip,
                  enabled: !_preview,
                  onSelected: _applyInline,
                  icon: const Icon(Icons.text_format),
                  itemBuilder: (_) => [
                    PopupMenuItem(value: '**', child: Text(l.chatFormatBold)),
                    PopupMenuItem(value: '*', child: Text(l.chatFormatItalic)),
                    PopupMenuItem(
                      value: '__',
                      child: Text(l.chatFormatUnderline),
                    ),
                    PopupMenuItem(value: '~~', child: Text(l.chatFormatStrike)),
                    PopupMenuItem(value: '`', child: Text(l.chatFormatCode)),
                    PopupMenuItem(
                      value: '||',
                      child: Text(l.chatFormatSpoiler),
                    ),
                  ],
                ),
                IconButton(
                  key: const ValueKey('space-post-preview-toggle'),
                  tooltip: _preview
                      ? l.spacePostContinueEditing
                      : l.spacePostPreview,
                  isSelected: _preview,
                  onPressed: () => setState(() => _preview = !_preview),
                  selectedIcon: const Icon(Icons.edit_outlined),
                  icon: const Icon(Icons.visibility_outlined),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        if (_preview)
          Container(
            key: const ValueKey('space-post-body-preview'),
            constraints: const BoxConstraints(minHeight: 132),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border.all(color: colors.outlineVariant),
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.topLeft,
            child: widget.controller.text.trim().isEmpty
                ? Text(
                    widget.hintText,
                    style: TextStyle(color: colors.onSurfaceVariant),
                  )
                : SpacePostBody(widget.controller.text),
          )
        else
          TextField(
            key: const ValueKey('space-post-body-field'),
            controller: widget.controller,
            focusNode: _focusNode,
            autofocus: widget.autofocus,
            minLines: 5,
            maxLines: 12,
            maxLength: widget.maxLength,
            onChanged: widget.onChanged,
            decoration: InputDecoration(
              hintText: widget.hintText,
              counterText: '',
              border: const OutlineInputBorder(),
            ),
          ),
      ],
    );
  }
}

String _blockLabel(AppL10n l, SpacePostBlockStyle style) => switch (style) {
  SpacePostBlockStyle.paragraph => l.spacePostBlockParagraph,
  SpacePostBlockStyle.heading1 => l.spacePostBlockHeading1,
  SpacePostBlockStyle.heading2 => l.spacePostBlockHeading2,
  SpacePostBlockStyle.heading3 => l.spacePostBlockHeading3,
  SpacePostBlockStyle.quote => l.chatFormatQuote,
  SpacePostBlockStyle.bulletList => l.spacePostBlockBulletList,
  SpacePostBlockStyle.orderedList => l.spacePostBlockOrderedList,
  SpacePostBlockStyle.code => l.spacePostBlockCode,
  SpacePostBlockStyle.divider => l.spacePostBlockDivider,
};

IconData _blockIcon(SpacePostBlockStyle style) => switch (style) {
  SpacePostBlockStyle.paragraph => Icons.notes,
  SpacePostBlockStyle.heading1 ||
  SpacePostBlockStyle.heading2 ||
  SpacePostBlockStyle.heading3 => Icons.title,
  SpacePostBlockStyle.quote => Icons.format_quote,
  SpacePostBlockStyle.bulletList => Icons.format_list_bulleted,
  SpacePostBlockStyle.orderedList => Icons.format_list_numbered,
  SpacePostBlockStyle.code => Icons.code,
  SpacePostBlockStyle.divider => Icons.horizontal_rule,
};
