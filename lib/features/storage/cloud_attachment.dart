import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/cloud.dart';
import '../../l10n/app_localizations.dart';
import '../../state/cloud_service.dart';
import 'cloud_item_actions.dart';

/// Put `veil-cloud:<itemId>` at [selection], replacing it when it spans text.
///
/// Padded with spaces unless a line edge or a space is already there: the
/// item-id charset covers letters, digits, `_` and `-`, so a reference typed
/// against a neighbouring word would swallow it. Returns the new text and a
/// collapsed caret past the reference. Pure — unit-tested.
({String text, TextSelection selection}) insertCloudAttachment(
  String text,
  TextSelection selection,
  String itemId,
) {
  final start = selection.isValid ? selection.start : text.length;
  final end = selection.isValid ? selection.end : text.length;
  final before = text.substring(0, start);
  final after = text.substring(end);
  final lead = before.isEmpty || before.endsWith('\n') || before.endsWith(' ')
      ? ''
      : ' ';
  final trail = after.startsWith('\n') || after.startsWith(' ') ? '' : ' ';
  final inserted = '$lead${cloudAttachmentRef(itemId)}$trail';
  return (
    text: '$before$inserted$after',
    selection: TextSelection.collapsed(offset: start + inserted.length),
  );
}

/// The sheet's "upload" row, which is not an item and cannot be one.
const _uploadChoice = 'upload';

/// Ask which cloud item to attach: an existing one, or a new file imported
/// through the ordinary cloud import. Returns null when nothing was chosen.
///
/// [excludeItemId] drops the note doing the attaching — a note referencing
/// itself renders a chip that reopens the thing already open.
Future<CloudItem?> pickCloudAttachment(
  BuildContext context,
  CloudService service, {
  String? excludeItemId,
}) async {
  final l = AppL10n.of(context);
  final items = [
    for (final item in await service.listItems())
      if (item.id != excludeItemId) item,
  ];
  if (!context.mounted) return null;
  final choice = await showModalBottomSheet<Object>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheet).height * 0.7,
        ),
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(title: Text(l.cloudAttachmentPick)),
            ListTile(
              key: const ValueKey('cloud-attachment-upload'),
              leading: const Icon(Icons.upload_file_outlined),
              title: Text(l.cloudAttachmentUpload),
              onTap: () => Navigator.pop(sheet, _uploadChoice),
            ),
            if (items.isEmpty)
              ListTile(enabled: false, title: Text(l.cloudAttachmentEmpty)),
            for (final item in items)
              ListTile(
                key: ValueKey('cloud-attachment-pick-${item.id}'),
                leading: Icon(
                  item.kind == CloudItemKind.note
                      ? Icons.note_outlined
                      : Icons.insert_drive_file_outlined,
                ),
                title: Text(
                  item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(formatCloudBytes(item.size)),
                onTap: () => Navigator.pop(sheet, item),
              ),
          ],
        ),
      ),
    ),
  );
  if (choice is CloudItem) return choice;
  if (choice != _uploadChoice) return null;
  try {
    return await importPickedCloudFile(service);
  } catch (_) {
    return null;
  }
}

/// One `veil-cloud:<itemId>` reference, drawn as an attachment.
///
/// The reference lives in the note body and the item lives in the index, so the
/// two can disagree — the item may be deleted, or it may belong to a device
/// whose index this one has not seen. Whatever the reason, the chip renders:
/// the unavailable state is the point of the design, not an error path. It is
/// never raw text and never nothing, because either would leave the reader
/// with a note that quietly lost a file.
class CloudAttachmentChip extends ConsumerStatefulWidget {
  const CloudAttachmentChip({super.key, required this.itemId});

  final String itemId;

  @override
  ConsumerState<CloudAttachmentChip> createState() =>
      _CloudAttachmentChipState();
}

class _CloudAttachmentChipState extends ConsumerState<CloudAttachmentChip> {
  bool _working = false;

  Future<void> _onTap(CloudItem? item) async {
    if (_working) return;
    final l = AppL10n.of(context);
    final messenger = ScaffoldMessenger.of(context);
    void say(String message) => messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
    final service = ref.read(cloudServiceProvider);
    if (item == null || service == null) {
      say(l.cloudAttachmentGone);
      return;
    }
    setState(() => _working = true);
    try {
      // Two taps, because they are two different things: the first brings the
      // bytes to this device, the second hands them to the rest of the machine.
      if (!await service.isLocal(item)) {
        final ok = await service.ensureLocal(item);
        if (!mounted) return;
        say(ok ? l.cloudAttachmentFetched : l.cloudAttachmentFetchFailed);
        return;
      }
      final result = await exportCloudItem(service, item);
      if (!mounted || result == CloudExportResult.cancelled) return;
      say(
        result == CloudExportResult.done
            ? l.cloudExportDone
            : l.cloudExportFailed,
      );
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final items = ref.watch(cloudItemsProvider);
    final item = items.value
        ?.where((row) => row.id == widget.itemId)
        .firstOrNull;
    // Until the index has answered, "not in the index" is not yet a fact, and
    // accusing a perfectly good attachment of being gone is worse than waiting.
    final resolved = items.hasValue;
    final missing = resolved && item == null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
      child: Material(
        color: missing ? scheme.errorContainer : scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          key: ValueKey('cloud-attachment-${widget.itemId}'),
          borderRadius: BorderRadius.circular(14),
          onTap: () => unawaited(_onTap(item)),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: missing ? Border.all(color: scheme.error) : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_working)
                  const Padding(
                    padding: EdgeInsets.only(right: 6),
                    child: SizedBox.square(
                      dimension: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Icon(
                      missing
                          ? Icons.link_off
                          : item?.kind == CloudItemKind.note
                          ? Icons.note_outlined
                          : Icons.attach_file,
                      size: 16,
                      color: missing
                          ? scheme.onErrorContainer
                          : scheme.onSecondaryContainer,
                    ),
                  ),
                Flexible(
                  child: Text(
                    missing
                        ? l.cloudAttachmentMissing
                        : item?.name ?? l.cloudAttachment,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: missing
                          ? scheme.onErrorContainer
                          : scheme.onSecondaryContainer,
                      decoration: missing ? TextDecoration.lineThrough : null,
                      decorationColor: scheme.onErrorContainer,
                    ),
                  ),
                ),
                if (item != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Text(
                      formatCloudBytes(item.size),
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSecondaryContainer,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
