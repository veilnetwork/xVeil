import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/veil_bundle.dart';
import '../../l10n/app_localizations.dart';
import '../../state/model_import.dart';
import '../../state/model_message.dart';
import '../../state/translation_model_controller.dart' show translationBundlePickerProvider;
import 'model_provenance_dialog.dart';
import '../../state/providers.dart';

/// A model that arrived in a chat: what it claims to be, and a way to install
/// it.
///
/// Shaped after the sticker pack card, which solves the same problem — a file
/// that is not content but an OFFER, and which needs downloading before it can
/// even be described. The order is deliberate: nothing is claimed about a
/// bundle until its bytes are here and its manifest has been read.
///
/// The trust line is not decoration. A translation model decides what this app
/// says another person wrote, and its hashes prove only that the bytes match
/// the manifest that travelled with them — a substituted model carrying its
/// own manifest passes every check. So the card says so, every time, rather
/// than leaving the person to infer it from a green tick.
class ModelBundleCard extends ConsumerStatefulWidget {
  const ModelBundleCard({
    super.key,
    required this.fileKey,
    required this.fileName,
    required this.downloaded,
    this.sizeBytes,
    this.progress,
    this.onDownload,
  });

  final String fileKey;
  final String? fileName;
  final bool downloaded;
  final int? sizeBytes;
  final double? progress;
  final VoidCallback? onDownload;

  @override
  ConsumerState<ModelBundleCard> createState() => _ModelBundleCardState();
}

class _ModelBundleCardState extends ConsumerState<ModelBundleCard> {
  bool _installing = false;
  bool _installed = false;
  String? _error;

  Future<void> _install() async {
    setState(() {
      _installing = true;
      _error = null;
    });
    File? staged;
    try {
      final bytes = await ref.read(storageProvider).loadFile(widget.fileKey);
      if (bytes == null) {
        // Silence here was a defect: tapping Install did nothing at all, with
        // no error and no change, which reads as a dead button. It happens
        // when the blob is gone — a cleared history, a store that never
        // finished the download.
        if (mounted) {
          setState(() => _error = AppL10n.of(context).modelBundleMissing);
        }
        return;
      }
      staged = await materialiseBundle(
        bytes,
        name: widget.fileName ?? 'received.veiltranslate',
      );
      var result = await installReceivedModel(
        staged,
        into: targetsFromWidgetRef(ref),
      );
      if (!mounted) return;
      if (result.needsDecision) {
        // Nothing has been installed at this point. The bundle's own hashes
        // check out — what is unsettled is whether it is the PUBLISHED model,
        // which the manifest cannot answer because the sender wrote it.
        final choice = await askAboutProvenance(context, result.verdict!);
        if (!mounted) return;
        switch (choice) {
          case ProvenanceChoice.installAnyway:
            result = await installReceivedModel(
              staged,
              into: targetsFromWidgetRef(ref),
              acceptUnverified: true,
            );
            if (!mounted) return;
          case ProvenanceChoice.loadManually:
            final path = await ref.read(translationBundlePickerProvider)();
            if (!mounted) return;
            if (path == null) return;
            // A file the person chose themselves, from wherever they trust.
            // Held to the same standard: choosing it says where it came from,
            // not that it is the published artifact.
            result = await installReceivedModel(
              File(path),
              into: targetsFromWidgetRef(ref),
            );
            if (!mounted) return;
            if (result.needsDecision) {
              final again = await askAboutProvenance(context, result.verdict!);
              if (!mounted) return;
              if (again != ProvenanceChoice.installAnyway) return;
              result = await installReceivedModel(
                File(path),
                into: targetsFromWidgetRef(ref),
                acceptUnverified: true,
              );
              if (!mounted) return;
            }
          case ProvenanceChoice.cancel:
            return;
        }
      }
      setState(() {
        _installed = result.succeeded;
        _error = result.error;
      });
    } finally {
      // The staged copy is a second full copy of a model; leaving it behind
      // would double what a phone spends on every install.
      if (staged != null && staged.parent.existsSync()) {
        staged.parent.deleteSync(recursive: true);
      }
      if (mounted) setState(() => _installing = false);
    }
  }

  /// What the NAME claims. The manifest decides what installs, and the two can
  /// disagree — so this is a label, and the card never states more than it has
  /// read.
  String _title(AppL10n l) =>
      modelBundleKind(widget.fileName) == kBundleSpeech
          ? l.modelBundleSpeech
          : l.modelBundleTranslate;

  String? _subtitle() {
    final hint = pairHintFromFileName(widget.fileName);
    final size = widget.sizeBytes;
    final mb = size == null ? null : '${(size / (1024 * 1024)).round()} MB';
    if (hint == null) return mb;
    final pretty = hint.replaceFirst('-', ' → ');
    return mb == null ? pretty : '$pretty, $mb';
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final subtitle = _subtitle();

    return Container(
      constraints: const BoxConstraints(maxWidth: 320),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.translate, size: 20, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _title(l),
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
            ],
          ),
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                subtitle,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            ),
          const SizedBox(height: 8),
          Text(
            l.modelBundleTrust,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 8),
          if (_installed)
            Row(
              children: [
                Icon(Icons.check, size: 16, color: scheme.primary),
                const SizedBox(width: 6),
                Text(l.modelBundleInstalled),
              ],
            )
          else if (_installing)
            Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Text(l.modelBundleInstalling),
              ],
            )
          else if (!widget.downloaded)
            // Nothing can be said about a bundle whose bytes are not here, so
            // the only offer is to fetch them.
            FilledButton.tonalIcon(
              onPressed: widget.onDownload,
              icon: widget.progress != null
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        value: widget.progress,
                      ),
                    )
                  : const Icon(Icons.download_outlined, size: 18),
              label: Text(l.modelBundleDownload),
            )
          else
            FilledButton.tonalIcon(
              onPressed: _install,
              icon: const Icon(Icons.download_done, size: 18),
              label: Text(l.modelBundleInstall),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                // The reason, not just the verdict: a truncated transfer and a
                // file that was never a bundle call for different actions.
                '${l.modelBundleFailed}: $_error',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.error,
                    ),
              ),
            ),
        ],
      ),
    );
  }
}
