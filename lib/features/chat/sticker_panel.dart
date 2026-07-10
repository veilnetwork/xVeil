// Sticker panel (stickers epic, brick 2): a bottom sheet showing the user's
// sticker packs with an import button. Picking a sticker returns its item id;
// the composer loads the bytes and sends it. Import reads images through the
// file picker, normalizes them, and adds them to the default pack.

import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../state/providers.dart';
import '../../state/sticker_store.dart';

/// The default pack shared by the header share button (v1: the single
/// import pack). Kept in sync with the store's default pack id.
const String _defaultSharePackId = 'my';

/// Opens the sticker sheet; resolves to either a sticker item id (send that
/// sticker), `pack:<packId>` (share that pack to the chat), or null.
Future<String?> showStickerPanel(BuildContext context) =>
    showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (_) => const _StickerSheet(),
    );

class _StickerSheet extends ConsumerStatefulWidget {
  const _StickerSheet();

  @override
  ConsumerState<_StickerSheet> createState() => _StickerSheetState();
}

class _StickerSheetState extends ConsumerState<_StickerSheet> {
  bool _importing = false;

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
      if (images.isEmpty) return;
      final n = await ref
          .read(stickerControllerProvider.notifier)
          .importImages(images);
      if (mounted && n > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppL10n.of(context).stickerImported(n))),
        );
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

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
                  child: Text(l.stickerTitle,
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                // Share the whole library as a pack to this chat.
                if ((packs.valueOrNull ?? const []).any((p) => p.items.isNotEmpty))
                  IconButton(
                    icon: const Icon(Icons.ios_share),
                    tooltip: l.stickerSharePack,
                    onPressed: () => Navigator.of(context).pop('pack:$_defaultSharePackId'),
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
          Expanded(
            child: packs.when(
              loading: () =>
                  const Center(child: CircularProgressIndicator()),
              error: (_, _) => Center(child: Text(l.stickerEmpty)),
              data: (list) {
                final items = [
                  for (final p in list)
                    for (final id in p.items) id,
                ];
                if (items.isEmpty) {
                  return _empty(context, l);
                }
                return GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate:
                      const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 96,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                  ),
                  itemCount: items.length,
                  itemBuilder: (context, i) => _StickerCell(itemId: items[i]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _empty(BuildContext context, AppL10n l) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.emoji_emotions_outlined,
                size: 48,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
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
  const _StickerCell({required this.itemId});
  final String itemId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return InkWell(
      key: ValueKey('sticker:$itemId'),
      borderRadius: BorderRadius.circular(8),
      onTap: () => Navigator.of(context).pop(itemId),
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
