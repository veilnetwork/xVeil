import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/file_download_policy.dart';
import '../../l10n/app_localizations.dart';
import '../../state/messaging.dart';

/// Per-identity incoming-file policy editor (Phase A1): the auto-download size
/// cap and the list of types that are always offered, never silently fetched.
/// Reads/writes the ACTIVE identity's [MessagingService.fileDownloadPolicy], so a
/// switch to another identity (or a decoy) edits that identity's own policy.
/// Changes persist immediately (no Save button) — the next offer is judged anew.
class FileSettingsScreen extends ConsumerStatefulWidget {
  const FileSettingsScreen({super.key});

  @override
  ConsumerState<FileSettingsScreen> createState() => _FileSettingsScreenState();
}

class _FileSettingsScreenState extends ConsumerState<FileSettingsScreen> {
  late FileDownloadPolicy _policy =
      ref.read(messagingServiceProvider).fileDownloadPolicy;
  final _addCtl = TextEditingController();

  /// Auto-download size presets. 0 ⇒ "always ask" (offer everything).
  static const _presets = <int>[
    0,
    512 * 1024,
    2 * 1024 * 1024,
    8 * 1024 * 1024,
    50 * 1024 * 1024,
  ];

  @override
  void dispose() {
    _addCtl.dispose();
    super.dispose();
  }

  Future<void> _save(FileDownloadPolicy next) async {
    setState(() => _policy = next);
    await ref.read(messagingServiceProvider).setFileDownloadPolicy(next);
  }

  String _limitLabel(AppL10n l, int bytes) =>
      bytes == 0 ? l.fileAlwaysAsk : _fmtBytes(bytes);

  static String _fmtBytes(int b) {
    if (b >= 1 << 20) {
      final mb = b / (1 << 20);
      return '${mb == mb.roundToDouble() ? mb.toStringAsFixed(0) : mb.toStringAsFixed(1)} MB';
    }
    if (b >= 1 << 10) return '${(b / (1 << 10)).toStringAsFixed(0)} KB';
    return '$b B';
  }

  Future<void> _pickLimit(AppL10n l) async {
    final choice = await showDialog<int>(
      context: context,
      builder: (d) => SimpleDialog(
        title: Text(l.fileAutoLimit),
        children: [
          for (final p in _presets)
            ListTile(
              title: Text(_limitLabel(l, p)),
              trailing:
                  _policy.autoMaxBytes == p ? const Icon(Icons.check) : null,
              onTap: () => Navigator.of(d).pop(p),
            ),
        ],
      ),
    );
    if (choice == null) return;
    await _save(_policy.copyWith(autoMaxBytes: choice));
  }

  Future<void> _addType() async {
    final ext = FileDownloadPolicy.normalizeExt(_addCtl.text);
    _addCtl.clear();
    if (ext == null || _policy.blockedExts.contains(ext)) {
      setState(() {}); // clear the field even on a no-op
      return;
    }
    await _save(_policy.copyWith(blockedExts: {..._policy.blockedExts, ext}));
  }

  Future<void> _removeType(String ext) async => _save(_policy.copyWith(
      blockedExts: _policy.blockedExts.where((e) => e != ext).toSet()));

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final exts = _policy.blockedExts.toList()..sort();
    return Scaffold(
      appBar: AppBar(title: Text(l.fileSettingsTitle)),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.download_outlined),
            title: Text(l.fileAutoLimit),
            subtitle: Text(l.fileAutoLimitHint),
            trailing: Text(
              _limitLabel(l, _policy.autoMaxBytes),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            isThreeLine: true,
            onTap: () => _pickLimit(l),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.fileBlockedTitle,
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(l.fileBlockedHint,
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final e in exts)
                      InputChip(
                        label: Text(e),
                        onDeleted: () => _removeType(e),
                      ),
                  ],
                ),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _addCtl,
                        autocorrect: false,
                        decoration: InputDecoration(
                          hintText: l.fileTypeHint,
                          prefixText: '.',
                        ),
                        onSubmitted: (_) => _addType(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonal(
                      onPressed: _addType,
                      child: Text(l.fileAddType),
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
