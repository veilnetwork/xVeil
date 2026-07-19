// Sticker panel (stickers epic, brick 2 + pack-management polish): a bottom
// sheet showing the user's sticker packs as SECTIONS with a per-pack manage
// menu (share / rename / delete) and an import button. Picking a sticker
// returns its item id; the composer loads the bytes and sends it. Import
// reads images through the file picker, normalizes them, and lands them in a
// pack the user chooses (existing or freshly created).

import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../state/providers.dart';
import '../../state/sticker_store.dart';

/// Opens the sticker sheet; resolves to either a sticker item id (send that
/// sticker), `pack:<packId>` (share that pack to the chat), or null.
Future<String?> showStickerPanel(BuildContext context) =>
    showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (sheetContext) => StickerPicker(
        onSelected: (itemId) => Navigator.of(sheetContext).pop(itemId),
      ),
    );

/// Reusable sticker library used by the standalone sheet and the unified
/// composer expression hub.
class StickerPicker extends ConsumerStatefulWidget {
  const StickerPicker({
    super.key,
    required this.onSelected,
    this.allowPackShare = true,
    this.allowCustomEmoji = false,
  });

  final ValueChanged<String> onSelected;
  final bool allowPackShare;
  final bool allowCustomEmoji;

  @override
  ConsumerState<StickerPicker> createState() => _StickerPickerState();
}

class _StickerPickerState extends ConsumerState<StickerPicker> {
  bool _importing = false;
  bool _emojiMode = false;

  Future<void> _import() async {
    setState(() => _importing = true);
    try {
      final picked = await FilePicker.pickFiles(
        type: FileType.image,
        allowMultiple: true,
        withData: true,
      );
      final files = picked?.files ?? const [];
      final images = <Uint8List>[];
      for (final f in files) {
        Uint8List? bytes = f.bytes;
        if (bytes == null && f.path != null) {
          try {
            bytes = await File(f.path!).readAsBytes();
          } catch (_) {}
        }
        if (bytes != null && bytes.isNotEmpty) images.add(bytes);
      }
      if (images.isEmpty || !mounted) return;
      // Which pack the import lands in: with an existing library the user
      // picks (or creates) the target; an empty library skips the question.
      final ctrl = ref.read(stickerControllerProvider.notifier);
      final packs = ref.read(stickerControllerProvider).valueOrNull ?? const [];
      String? packId;
      if (packs.isNotEmpty) {
        packId = await _pickTargetPack(packs);
        if (packId == null) return; // cancelled
        if (packId == _newPackSentinel) {
          if (!mounted) return;
          final name = await _promptPackName(initial: '');
          if (name == null || name.isEmpty) return;
          packId = await ctrl.createPack(name);
        }
      }
      final n = await ctrl.importImages(images, packId: packId);
      if (mounted && n > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppL10n.of(context).stickerImported(n))),
        );
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  static const String _newPackSentinel = '__new__';

  /// Existing pack ids + a "new pack" sentinel; null when dismissed.
  Future<String?> _pickTargetPack(List<StickerPack> packs) {
    final l = AppL10n.of(context);
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(l.stickerPackChooseTarget),
        children: [
          for (final p in packs)
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(p.id),
              child: Text(_packLabel(l, p)),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop(_newPackSentinel),
            child: Row(
              children: [
                const Icon(Icons.add, size: 18),
                const SizedBox(width: 8),
                Text(l.stickerPackNew),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<String?> _promptPackName({required String initial}) async {
    final l = AppL10n.of(context);
    final field = TextEditingController(text: initial);
    try {
      return await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(l.stickerPackNameHint),
          content: TextField(
            controller: field,
            autofocus: true,
            maxLength: 64,
            decoration: InputDecoration(hintText: l.stickerPackNameHint),
            onSubmitted: (v) => Navigator.of(dialogContext).pop(v.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l.actionCancel),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(field.text.trim()),
              child: Text(l.actionDone),
            ),
          ],
        ),
      );
    } finally {
      field.dispose();
    }
  }

  Future<void> _renamePack(StickerPack pack) async {
    final name = await _promptPackName(initial: pack.name);
    if (name == null || name.isEmpty || name == pack.name) return;
    await ref
        .read(stickerControllerProvider.notifier)
        .renamePack(pack.id, name);
  }

  Future<void> _deletePack(StickerPack pack) async {
    final l = AppL10n.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l.stickerPackDelete),
        content: Text(l.stickerPackDeleteConfirm(_packLabel(l, pack))),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l.chatDeleteConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(stickerControllerProvider.notifier).deletePack(pack.id);
  }

  String _packLabel(AppL10n l, StickerPack p) =>
      p.name.isEmpty ? l.stickerPackTitle : p.name;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final packs = ref.watch(stickerControllerProvider);
    return SizedBox(
      height: 420,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    l.stickerTitle,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                _importing
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : IconButton(
                        icon: const Icon(Icons.add_photo_alternate_outlined),
                        tooltip: l.stickerImport,
                        onPressed: _import,
                      ),
              ],
            ),
          ),
          if (widget.allowCustomEmoji)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: SegmentedButton<bool>(
                key: const ValueKey('sticker-inline-mode'),
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(
                    value: false,
                    icon: const Icon(Icons.sticky_note_2_outlined, size: 18),
                    label: Text(l.stickerTitle),
                  ),
                  ButtonSegment(
                    value: true,
                    icon: const Icon(Icons.emoji_emotions_outlined, size: 18),
                    label: Text(l.chatEmojiTooltip),
                  ),
                ],
                selected: {_emojiMode},
                onSelectionChanged: (value) {
                  setState(() => _emojiMode = value.first);
                },
              ),
            ),
          Expanded(
            child: packs.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, _) => Center(child: Text(l.stickerEmpty)),
              data: (list) {
                // Empty packs still render (they're manageable); only a bare
                // library gets the import call-to-action.
                if (list.isEmpty) return _empty(context, l);
                return ListView(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  children: [
                    for (final p in list) ..._packSection(context, l, p),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// One pack: a header row (name + count + manage menu) and its grid.
  List<Widget> _packSection(BuildContext context, AppL10n l, StickerPack p) => [
    Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 0, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${_packLabel(l, p)} · ${p.items.length}',
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          PopupMenuButton<String>(
            key: ValueKey('pack-menu:${p.id}'),
            icon: const Icon(Icons.more_horiz, size: 20),
            onSelected: (action) {
              switch (action) {
                case 'share':
                  widget.onSelected('pack:${p.id}');
                case 'rename':
                  _renamePack(p);
                case 'delete':
                  _deletePack(p);
              }
            },
            itemBuilder: (context) => [
              if (widget.allowPackShare && p.items.isNotEmpty)
                PopupMenuItem(value: 'share', child: Text(l.stickerSharePack)),
              PopupMenuItem(value: 'rename', child: Text(l.stickerPackRename)),
              PopupMenuItem(value: 'delete', child: Text(l.stickerPackDelete)),
            ],
          ),
        ],
      ),
    ),
    GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 96,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemCount: p.items.length,
      itemBuilder: (context, i) => _StickerCell(
        itemId: p.items[i],
        onSelected: (itemId) =>
            widget.onSelected(_emojiMode ? 'emoji:$itemId' : itemId),
      ),
    ),
  ];

  Widget _empty(BuildContext context, AppL10n l) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.emoji_emotions_outlined,
          size: 48,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(height: 12),
        Text(l.stickerEmpty),
        const SizedBox(height: 12),
        FilledButton.tonalIcon(
          onPressed: _importing ? null : _import,
          icon: const Icon(Icons.add_photo_alternate_outlined),
          label: Text(l.stickerImport),
        ),
      ],
    ),
  );
}

class _StickerCell extends ConsumerWidget {
  const _StickerCell({required this.itemId, required this.onSelected});
  final String itemId;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return InkWell(
      key: ValueKey('sticker:$itemId'),
      borderRadius: BorderRadius.circular(8),
      onTap: () => onSelected(itemId),
      child: FutureBuilder<Uint8List?>(
        future: ref.read(storageProvider).loadFile(stickerFileKey(itemId)),
        builder: (context, snap) {
          final bytes = snap.data;
          if (bytes == null) {
            return const ColoredBox(color: Colors.transparent);
          }
          return Image.memory(
            bytes,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
          );
        },
      ),
    );
  }
}
