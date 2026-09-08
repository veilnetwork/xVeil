// Settings → Transfer data: write everything to a file, or read a file back.
//
// Three things this screen is careful about, because each of them is a way a
// person loses something without being told:
//
//  * SIZE. The question "should the files come too" is unanswerable without
//    the two numbers, so both are on screen before it is asked — and they are
//    counted from the space, not guessed.
//  * WHAT AN OPEN ARCHIVE IS. With the identity inside, the file is the
//    identity: whoever holds it is this person. That sentence is on the button
//    that writes it, not in a manual.
//  * WHOSE ARCHIVE IT IS. An import states the identity, the date and the
//    counts before it touches anything, and refuses an archive from another
//    identity outright.

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/log.dart';
import '../../data/storage/storage.dart';
import '../../domain/data_transfer.dart';
import '../../l10n/app_localizations.dart';
import '../../routing/back_affordance.dart';
import '../common/shown_cause.dart';
import '../../state/data_export.dart';
import '../../state/data_import.dart';
import '../../state/device_settings_sync.dart';
import '../../state/device_sync_appliers.dart';
import '../../state/messaging.dart';
import '../../state/providers.dart';

class DataTransferScreen extends ConsumerStatefulWidget {
  const DataTransferScreen({super.key});

  @override
  ConsumerState<DataTransferScreen> createState() => _DataTransferScreenState();
}

class _DataTransferScreenState extends ConsumerState<DataTransferScreen> {
  DataExportPlan? _plan;
  bool _includeFiles = true;
  bool _includeIdentity = false;
  String? _busy;
  String? _result;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_loadPlan());
  }

  Storage get _storage => ref.read(storageProvider);

  Future<String> _selfHex() =>
      ref.read(messagingServiceProvider).savedSelfHex();

  Future<void> _loadPlan() async {
    try {
      final plan = await DataExporter(
        storage: _storage,
        nodeIdHex: await _selfHex(),
        syncedSettingKeys:
            ref.read(deviceSettingsSyncHubProvider).syncedKeys.toSet(),
      ).plan();
      if (mounted) setState(() => _plan = plan);
    } catch (e) {
      if (mounted) setState(() => _error = shownCause(e, kind: 'transfer'));
    }
  }

  Future<void> _export({required bool sealed}) async {
    final l = AppL10n.of(context);
    String? password;
    if (sealed) {
      password = await _askPassword(title: l.transferExportPasswordTitle);
      if (password == null || password.isEmpty) return;
    }
    final name =
        'xveil-${DateTime.now().toIso8601String().split('T').first}.xveilbk';
    final dest = await FilePicker.saveFile(fileName: name);
    if (dest == null) return;

    setState(() {
      _busy = l.transferWorking;
      _result = null;
      _error = null;
    });
    try {
      final file = File(dest);
      final handle = file.openWrite();
      final report = await DataExporter(
        storage: _storage,
        nodeIdHex: await _selfHex(),
        syncedSettingKeys:
            ref.read(deviceSettingsSyncHubProvider).syncedKeys.toSet(),
      ).run(
        sink: (bytes) async => handle.add(bytes),
        password: password,
        includeIdentity: _includeIdentity,
        includeFiles: _includeFiles,
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() => _busy = l.transferProgress(done, total));
        },
      );
      await handle.flush();
      await handle.close();
      if (!mounted) return;
      setState(() {
        _busy = null;
        _result = l.transferExportDone(
          report.records,
          report.files,
          _mb(report.bytes),
        );
      });
    } catch (e) {
      devLog(() => 'transfer: export failed: $e');
      if (mounted) {
        setState(() {
          _busy = null;
          _error = shownCause(e, kind: 'transfer');
        });
      }
    }
  }

  Future<void> _import() async {
    final l = AppL10n.of(context);
    final picked = await FilePicker.pickFiles(withReadStream: false);
    final path = picked?.files.single.path;
    if (path == null) return;
    final file = File(path);

    TransferHeader header;
    try {
      header = await DataImporter.inspect(file.openRead());
    } catch (e) {
      setState(() => _error = shownCause(e, kind: 'transfer'));
      return;
    }

    String? password;
    if (header.isSealed) {
      if (!mounted) return;
      password = await _askPassword(title: l.transferImportPasswordTitle);
      if (password == null || password.isEmpty) return;
    }

    if (!mounted) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.transferImportConfirmTitle),
        content: Text(
          l.transferImportConfirmBody(
            header.nodeIdHex.substring(0, 8),
            DateTime.fromMillisecondsSinceEpoch(
              header.createdMs,
            ).toLocal().toString().split('.').first,
            header.counts['messages'] ?? 0,
            header.counts['files'] ?? 0,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l.transferImportAction),
          ),
        ],
      ),
    );
    if (go != true) return;

    setState(() {
      _busy = l.transferWorking;
      _result = null;
      _error = null;
    });
    try {
      final report = await DataImporter(
        storage: _storage,
        appliers: ref.read(deviceSyncAppliersProvider),
        selfNodeIdHex: await _selfHex(),
      ).run(
        bytes: file.openRead(),
        password: password,
        onProgress: (records) {
          if (!mounted) return;
          setState(() => _busy = l.transferProgress(records, 0));
        },
      );
      if (!mounted) return;
      setState(() {
        _busy = null;
        _result = l.transferImportDone(
          report.syncEvents,
          report.filesAdded,
          report.settingsFilled,
        );
      });
    } on ImportRefused catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = null;
        _error = switch (e.reason) {
          ImportRefusal.otherIdentity => l.transferRefusedOtherIdentity,
          ImportRefusal.identityWouldBeReplaced => l.transferRefusedHasIdentity,
          ImportRefusal.noAppliers => l.transferRefusedNotReady,
        };
      });
    } on TransferException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = null;
        _error = switch (e.failure) {
          TransferFailure.badPassword => l.transferBadPassword,
          TransferFailure.truncated => l.transferTruncated,
          TransferFailure.notAnArchive ||
          TransferFailure.unsupportedVersion => l.transferNotAnArchive,
          TransferFailure.corrupt => l.transferCorrupt,
        };
      });
    } catch (e) {
      devLog(() => 'transfer: import failed: $e');
      if (mounted) {
        setState(() {
          _busy = null;
          _error = shownCause(e, kind: 'transfer');
        });
      }
    }
  }

  Future<String?> _askPassword({required String title}) => showDialog<String>(
    context: context,
    builder: (context) => _PasswordDialog(title: title),
  );

  static String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final theme = Theme.of(context);
    final plan = _plan;

    return Scaffold(
      appBar: AppBar(
        leading: const RootedBackButton(),
        title: Text(l.transferTitle),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(l.transferIntro, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 24),

          Text(l.transferExportTitle, style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          if (plan == null)
            const LinearProgressIndicator()
          else ...[
            Text(
              l.transferContents(
                plan.contacts,
                plan.messages,
                plan.callLogEntries,
              ),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _includeFiles,
              onChanged: (v) => setState(() => _includeFiles = v),
              title: Text(l.transferIncludeFiles),
              // The two sizes, side by side: this is the question being asked.
              subtitle: Text(
                l.transferSizes(
                  _mb(plan.estimatedBytesWithoutFiles),
                  _mb(plan.estimatedBytesWithFiles),
                  plan.files,
                ),
              ),
            ),
            if (plan.oversizeFiles > 0)
              Text(
                l.transferOversizeFiles(plan.oversizeFiles),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _includeIdentity,
              onChanged: (v) => setState(() => _includeIdentity = v),
              title: Text(l.transferIncludeIdentity),
              subtitle: Text(l.transferIncludeIdentityHint),
            ),
            if (_includeIdentity)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  l.transferIdentityWarning,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
              ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _busy != null ? null : () => _export(sealed: false),
                  icon: const Icon(Icons.lock_open_outlined),
                  label: Text(l.transferExportOpen),
                ),
                FilledButton.icon(
                  onPressed: _busy != null ? null : () => _export(sealed: true),
                  icon: const Icon(Icons.lock_outline),
                  label: Text(l.transferExportSealed),
                ),
              ],
            ),
          ],

          const Divider(height: 40),
          Text(l.transferImportTitle, style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(l.transferImportBody, style: theme.textTheme.bodySmall),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _busy != null ? null : _import,
            icon: const Icon(Icons.file_open_outlined),
            label: Text(l.transferImportPick),
          ),

          if (_busy != null) ...[
            const SizedBox(height: 24),
            const LinearProgressIndicator(),
            const SizedBox(height: 8),
            Text(_busy!, style: theme.textTheme.bodySmall),
          ],
          if (_result != null) ...[
            const SizedBox(height: 24),
            Text(
              _result!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 24),
            Text(
              _error!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The password prompt, owning its own controller.
///
/// A `TextEditingController` created by the caller and disposed when
/// `showDialog` resolves is disposed too early: the route keeps its subtree
/// mounted through the exit transition, and the field it left behind reads a
/// dead controller. The widget that renders it is the one that can dispose it
/// at the right moment.
class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog({required this.title});

  final String title;

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        obscureText: true,
        autofocus: true,
        decoration: InputDecoration(labelText: l.transferPasswordLabel),
        onSubmitted: (v) => Navigator.of(context).pop(v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.actionCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(l.actionContinue),
        ),
      ],
    );
  }
}
