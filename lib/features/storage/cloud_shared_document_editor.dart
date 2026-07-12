import 'dart:async';

import 'package:flutter/material.dart';

import '../../domain/cloud_rich_text_crdt.dart';
import '../../l10n/app_localizations.dart';
import '../../state/cloud_document_replication_service.dart';

class CloudSharedDocumentEditor extends StatefulWidget {
  const CloudSharedDocumentEditor({
    super.key,
    required this.service,
    required this.documentId,
    this.onManage,
    this.onClose,
  });

  final CloudDocumentReplicationService service;
  final String documentId;
  final VoidCallback? onManage;
  final VoidCallback? onClose;

  @override
  State<CloudSharedDocumentEditor> createState() =>
      _CloudSharedDocumentEditorState();
}

class _CloudSharedDocumentEditorState extends State<CloudSharedDocumentEditor> {
  StreamSubscription<void>? _subscription;
  _CloudRichTextController? _controller;
  CloudRichTextDocumentState? _state;
  CloudRichTextStyle _typingStyle = const CloudRichTextStyle();
  bool _loading = true;
  bool _busy = false;
  bool _dirty = false;
  bool _remoteChanged = false;

  @override
  void initState() {
    super.initState();
    _subscription = widget.service.changes.listen((_) {
      if (_dirty || _busy) {
        if (mounted) setState(() => _remoteChanged = true);
      } else {
        unawaited(_load());
      }
    });
    unawaited(_load());
  }

  Future<void> _load() async {
    final state = await widget.service.loadRichText(widget.documentId);
    if (!mounted) return;
    final next = state == null
        ? null
        : _CloudRichTextController(state.snapshot);
    final prior = _controller;
    setState(() {
      _state = state;
      _controller = next;
      _typingStyle = const CloudRichTextStyle();
      _loading = false;
      _dirty = false;
      _remoteChanged = false;
    });
    prior?.dispose();
  }

  void _changed(String _) {
    final controller = _controller;
    if (controller == null) return;
    controller.reconcile(_typingStyle);
    setState(() => _dirty = true);
  }

  void _notice(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _save() async {
    final state = _state;
    final controller = _controller;
    if (state == null || controller == null || !state.canEdit || _busy) return;
    setState(() => _busy = true);
    CloudDocumentMutationResult? result;
    try {
      result = await widget.service.saveRichText(
        widget.documentId,
        base: state.snapshot,
        text: controller.text,
        styles: controller.styles,
      );
    } catch (_) {
      result = null;
    }
    if (!mounted) return;
    final l = AppL10n.of(context);
    _notice(
      result == null
          ? l.cloudRichFailed
          : result.fullyQueued
          ? l.cloudRichSaved
          : l.cloudSharedPartial,
    );
    setState(() => _busy = false);
    if (result != null) await _load();
  }

  Future<void> _deleteVisible() async {
    final state = _state;
    if (state == null || !state.canEdit || _busy) return;
    final l = AppL10n.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.cloudRichDeleteTitle),
        content: Text(l.cloudRichDeleteBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l.cloudRichDelete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    CloudDocumentMutationResult? result;
    try {
      result = await widget.service.deleteRichTextDocument(
        widget.documentId,
        parentOperationIds: state.snapshot.headOperationIds,
      );
    } catch (_) {
      result = null;
    }
    if (!mounted) return;
    _notice(result == null ? l.cloudRichFailed : l.cloudRichDeleted);
    setState(() => _busy = false);
    if (result != null) await _load();
  }

  void _toggle(CloudRichTextStyle Function(CloudRichTextStyle) transform) {
    final controller = _controller;
    if (controller == null || _state?.canEdit != true) return;
    final range = controller.graphemeSelection;
    if (range.$1 == range.$2) {
      setState(() => _typingStyle = transform(_typingStyle));
      return;
    }
    controller.formatRange(range.$1, range.$2, transform);
    setState(() => _dirty = true);
  }

  void _setBlock(CloudRichTextBlock block) {
    final controller = _controller;
    if (controller == null || _state?.canEdit != true) return;
    final range = controller.lineGraphemeSelection;
    if (range.$1 == range.$2) {
      setState(() => _typingStyle = _typingStyle.copyWith(block: block));
      return;
    }
    controller.formatRange(
      range.$1,
      range.$2,
      (style) => style.copyWith(block: block),
    );
    setState(() {
      _typingStyle = _typingStyle.copyWith(block: block);
      _dirty = true;
    });
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final state = _state;
    final controller = _controller;
    if (_loading) {
      return const SafeArea(child: Center(child: CircularProgressIndicator()));
    }
    if (state == null || controller == null) {
      return SafeArea(child: Center(child: Text(l.cloudRichFailed)));
    }
    final editable = state.canEdit;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.9,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      if (widget.onClose != null)
                        IconButton(
                          key: const ValueKey('cloud-rich-close'),
                          tooltip: MaterialLocalizations.of(
                            context,
                          ).backButtonTooltip,
                          onPressed: _busy ? null : widget.onClose,
                          icon: const Icon(Icons.arrow_back),
                        )
                      else ...[
                        const Icon(Icons.edit_note_outlined),
                        const SizedBox(width: 12),
                      ],
                      Expanded(child: Text(l.cloudRichTitle)),
                      if (widget.onManage != null)
                        IconButton(
                          key: const ValueKey('cloud-rich-manage'),
                          tooltip: l.cloudRichManage,
                          onPressed: _busy ? null : widget.onManage,
                          icon: const Icon(Icons.group_outlined),
                        ),
                      if (_busy)
                        const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      else if (editable)
                        IconButton(
                          key: const ValueKey('cloud-rich-save'),
                          tooltip: l.cloudRichSave,
                          onPressed: _dirty ? _save : null,
                          icon: const Icon(Icons.save_outlined),
                        ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 36, right: 8),
                    child: Text(
                      editable ? l.cloudRichCollaborative : l.cloudRichReadOnly,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
            if (state.snapshot.hasConcurrentRecovery)
              _NoticeBanner(
                icon: Icons.call_split_outlined,
                text: l.cloudRichRecovered,
                color: Theme.of(context).colorScheme.tertiaryContainer,
              ),
            if (_remoteChanged)
              _NoticeBanner(
                icon: Icons.sync_problem_outlined,
                text: l.cloudRichRemotePending,
                color: Theme.of(context).colorScheme.secondaryContainer,
              ),
            if (state.snapshot.invalidOperationIds.isNotEmpty)
              _NoticeBanner(
                icon: Icons.gpp_bad_outlined,
                text: l.cloudRichInvalid,
                color: Theme.of(context).colorScheme.errorContainer,
              ),
            const Divider(height: 1),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: TextField(
                  key: const ValueKey('cloud-rich-editor'),
                  controller: controller,
                  readOnly: !editable,
                  expands: true,
                  minLines: null,
                  maxLines: null,
                  textAlignVertical: TextAlignVertical.top,
                  decoration: InputDecoration(
                    hintText: l.cloudRichHint,
                    border: InputBorder.none,
                  ),
                  onChanged: _changed,
                ),
              ),
            ),
            if (editable) ...[
              const Divider(height: 1),
              SizedBox(height: 48, child: _toolbar(l)),
            ],
            if (editable)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
                child: Row(
                  children: [
                    IconButton(
                      key: const ValueKey('cloud-rich-delete'),
                      tooltip: l.cloudRichDelete,
                      onPressed: _busy ? null : _deleteVisible,
                      icon: const Icon(Icons.delete_sweep_outlined),
                    ),
                    const Spacer(),
                    FilledButton.icon(
                      onPressed: _busy || !_dirty ? null : _save,
                      icon: const Icon(Icons.save_outlined),
                      label: Text(l.cloudRichSave),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _toolbar(AppL10n l) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    padding: const EdgeInsets.symmetric(horizontal: 8),
    child: Row(
      children: [
        _formatButton(
          key: 'bold',
          tooltip: l.cloudRichBold,
          icon: Icons.format_bold,
          onPressed: () =>
              _toggle((style) => style.copyWith(bold: !style.bold)),
        ),
        _formatButton(
          key: 'italic',
          tooltip: l.cloudRichItalic,
          icon: Icons.format_italic,
          onPressed: () =>
              _toggle((style) => style.copyWith(italic: !style.italic)),
        ),
        _formatButton(
          key: 'underline',
          tooltip: l.cloudRichUnderline,
          icon: Icons.format_underline,
          onPressed: () =>
              _toggle((style) => style.copyWith(underline: !style.underline)),
        ),
        _formatButton(
          key: 'strike',
          tooltip: l.cloudRichStrike,
          icon: Icons.format_strikethrough,
          onPressed: () =>
              _toggle((style) => style.copyWith(strike: !style.strike)),
        ),
        _formatButton(
          key: 'code',
          tooltip: l.cloudRichCode,
          icon: Icons.code,
          onPressed: () =>
              _toggle((style) => style.copyWith(inlineCode: !style.inlineCode)),
        ),
        const SizedBox(width: 4),
        DropdownButton<CloudRichTextBlock>(
          key: const ValueKey('cloud-rich-block'),
          value: _typingStyle.block,
          underline: const SizedBox.shrink(),
          onChanged: (value) {
            if (value != null) _setBlock(value);
          },
          items: [
            DropdownMenuItem(
              value: CloudRichTextBlock.paragraph,
              child: Text(l.cloudRichParagraph),
            ),
            DropdownMenuItem(
              value: CloudRichTextBlock.heading1,
              child: Text(l.cloudRichHeading1),
            ),
            DropdownMenuItem(
              value: CloudRichTextBlock.heading2,
              child: Text(l.cloudRichHeading2),
            ),
            DropdownMenuItem(
              value: CloudRichTextBlock.quote,
              child: Text(l.cloudRichQuote),
            ),
            DropdownMenuItem(
              value: CloudRichTextBlock.bullet,
              child: Text(l.cloudRichBullet),
            ),
            DropdownMenuItem(
              value: CloudRichTextBlock.code,
              child: Text(l.cloudRichCodeBlock),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _formatButton({
    required String key,
    required String tooltip,
    required IconData icon,
    required VoidCallback onPressed,
  }) => IconButton(
    key: ValueKey('cloud-rich-$key'),
    tooltip: tooltip,
    onPressed: onPressed,
    icon: Icon(icon),
  );
}

class _NoticeBanner extends StatelessWidget {
  const _NoticeBanner({
    required this.icon,
    required this.text,
    required this.color,
  });

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: color,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(text)),
        ],
      ),
    ),
  );
}

class _CloudRichTextController extends TextEditingController {
  _CloudRichTextController(CloudRichTextSnapshot snapshot)
    : styles = snapshot.atoms.map((atom) => atom.style).toList(),
      _graphemes = snapshot.atoms.map((atom) => atom.value).toList(),
      super(text: snapshot.text);

  List<CloudRichTextStyle> styles;
  List<String> _graphemes;

  (int, int) get graphemeSelection {
    if (!selection.isValid) return (0, 0);
    final start = _graphemeIndexAtOffset(text, selection.start);
    final end = _graphemeIndexAtOffset(text, selection.end);
    return (start < end ? start : end, start < end ? end : start);
  }

  (int, int) get lineGraphemeSelection {
    if (!selection.isValid) return (0, 0);
    final low = selection.start < selection.end
        ? selection.start
        : selection.end;
    final high = selection.start < selection.end
        ? selection.end
        : selection.start;
    final priorBreak = low <= 0 ? -1 : text.lastIndexOf('\n', low - 1);
    final lineStart = priorBreak + 1;
    final nextBreak = text.indexOf('\n', high);
    final lineEnd = nextBreak < 0 ? text.length : nextBreak + 1;
    return (
      _graphemeIndexAtOffset(text, lineStart),
      _graphemeIndexAtOffset(text, lineEnd),
    );
  }

  void reconcile(CloudRichTextStyle insertionStyle) {
    final next = text.characters.toList();
    var prefix = 0;
    while (prefix < _graphemes.length &&
        prefix < next.length &&
        _graphemes[prefix] == next[prefix]) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < _graphemes.length - prefix &&
        suffix < next.length - prefix &&
        _graphemes[_graphemes.length - 1 - suffix] ==
            next[next.length - 1 - suffix]) {
      suffix++;
    }
    styles = [
      ...styles.take(prefix),
      ...List.filled(next.length - prefix - suffix, insertionStyle),
      ...styles.skip(styles.length - suffix),
    ];
    _graphemes = next;
    notifyListeners();
  }

  void formatRange(
    int start,
    int end,
    CloudRichTextStyle Function(CloudRichTextStyle) transform,
  ) {
    for (var index = start; index < end && index < styles.length; index++) {
      styles[index] = transform(styles[index]);
    }
    notifyListeners();
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final theme = Theme.of(context);
    final effectiveStyle =
        (style ?? theme.textTheme.bodyLarge ?? const TextStyle()).copyWith(
          color: style?.color ?? theme.colorScheme.onSurface,
        );
    final children = <InlineSpan>[];
    for (var index = 0; index < _graphemes.length; index++) {
      final mark = index < styles.length
          ? styles[index]
          : const CloudRichTextStyle();
      children.add(
        TextSpan(
          text: _graphemes[index],
          style: _textStyle(context, effectiveStyle, mark),
        ),
      );
    }
    return TextSpan(style: effectiveStyle, children: children);
  }
}

int _graphemeIndexAtOffset(String text, int offset) {
  if (offset <= 0) return 0;
  var units = 0;
  var index = 0;
  for (final grapheme in text.characters) {
    units += grapheme.length;
    if (units >= offset) return index + 1;
    index++;
  }
  return index;
}

TextStyle _textStyle(
  BuildContext context,
  TextStyle base,
  CloudRichTextStyle mark,
) {
  final theme = Theme.of(context);
  final decoration = TextDecoration.combine([
    if (mark.underline) TextDecoration.underline,
    if (mark.strike) TextDecoration.lineThrough,
  ]);
  final blockStyle = switch (mark.block) {
    CloudRichTextBlock.heading1 => theme.textTheme.headlineSmall,
    CloudRichTextBlock.heading2 => theme.textTheme.titleLarge,
    CloudRichTextBlock.quote => theme.textTheme.bodyLarge?.copyWith(
      color: theme.colorScheme.secondary,
    ),
    CloudRichTextBlock.code => theme.textTheme.bodyMedium?.copyWith(
      fontFamily: 'monospace',
      backgroundColor: theme.colorScheme.surfaceContainerHighest,
    ),
    CloudRichTextBlock.bullet => theme.textTheme.bodyLarge?.copyWith(
      color: theme.colorScheme.primary,
    ),
    CloudRichTextBlock.paragraph => null,
  };
  return base
      .merge(blockStyle)
      .copyWith(
        fontWeight: mark.bold ? FontWeight.bold : null,
        fontStyle: mark.italic ? FontStyle.italic : null,
        fontFamily: mark.inlineCode ? 'monospace' : blockStyle?.fontFamily,
        backgroundColor: mark.inlineCode
            ? theme.colorScheme.surfaceContainerHighest
            : blockStyle?.backgroundColor,
        decoration: decoration == TextDecoration.none ? null : decoration,
      );
}
