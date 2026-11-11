import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/document_export.dart';
import '../../core/diagnostic_journal.dart';
import '../../core/format.dart';
import '../../data/folder_saved_versions.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_controller.dart';
import '../../state/folder_saved_export.dart';
import '../../state/identity_guard.dart';
import '../common/help_label.dart';

final folderSavedVersionAccessProvider = Provider<FolderSavedVersionAccess>(
  (ref) => const NativeFolderSavedVersions(),
);
final folderSavedExportPickerProvider = Provider<ExportDocumentPicker>(
  (ref) => openExportDocument,
);

class FolderSavedVersionsDialog extends ConsumerStatefulWidget {
  const FolderSavedVersionsDialog({super.key, required this.root});
  final String root;

  @override
  ConsumerState<FolderSavedVersionsDialog> createState() =>
      _FolderSavedVersionsDialogState();
}

class _FolderSavedVersionsDialogState
    extends ConsumerState<FolderSavedVersionsDialog> {
  late final IdentityLease _lease;
  late final String _root;
  late final FolderSavedVersionAccess _access;
  FolderSavedVersionPage? _page;
  bool _loading = true;
  bool _failed = false;
  String? _exporting;
  FolderSavedExportCancellation? _cancellation;

  bool _current() =>
      mounted && widget.root == _root && ref.holdsIdentity(_lease);

  void _cancelExport() {
    final cancellation = _cancellation;
    if (cancellation != null) {
      unawaited(cancellation.cancel().catchError((_) {}));
    }
  }

  void _recordError(Object error, FolderSavedDiagnosticAction action) {
    if (_current()) {
      diagnosticJournal.recordFolderSavedFailure(
        action: action,
        failure: folderSavedFailureCode(error),
      );
    }
  }

  @override
  void initState() {
    super.initState();
    _root = widget.root;
    _lease = ref.leaseIdentity();
    _access = ref.read(folderSavedVersionAccessProvider);
    ref.listenManual(appControllerProvider, (_, next) {
      if (!_current()) {
        _cancelExport();
        if (mounted) setState(() => _page = null);
      }
    });
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant FolderSavedVersionsDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_current()) {
      _cancelExport();
      _page = null;
    }
  }

  @override
  void dispose() {
    _cancelExport();
    super.dispose();
  }

  Future<void> _load({String? after}) async {
    if (!_current()) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final page = await _access.list(
        widget.root,
        after: after,
        stillCurrent: _current,
      );
      if (_current()) setState(() => _page = page);
    } on FolderSavedOperationCancelled {
      // A locked/switched identity cannot populate the old modal.
    } catch (error) {
      _recordError(error, FolderSavedDiagnosticAction.listing);
      if (_current()) {
        setState(() {
          _failed = true;
          _page = null;
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _export(FolderSavedVersion version) async {
    if (!_current() || _exporting != null || !version.readable) return;
    final l = AppL10n.of(context);
    final picker = ref.read(folderSavedExportPickerProvider);
    final cancellation = FolderSavedExportCancellation();
    _cancellation = cancellation;
    setState(() => _exporting = version.relativePath);
    String? message;
    try {
      final saved = await exportFolderSavedVersion(
        access: _access,
        root: widget.root,
        version: version,
        stillCurrent: _current,
        cancellation: cancellation,
        pick: picker,
      );
      if (saved) message = l.chatFileSavedToChosenFolder;
    } on FolderSavedOperationCancelled {
      // No success/failure notice leaks into the replacement identity.
    } on FolderSavedVersionChanged catch (error) {
      _recordError(error, FolderSavedDiagnosticAction.exporting);
      message = l.folderSyncSavedChanged;
    } on DocumentExportException catch (error) {
      _recordError(error, FolderSavedDiagnosticAction.exporting);
      message = error.permissionDenied
          ? l.chatFileSavePermissionDenied
          : l.chatFileSaveFailed;
    } catch (error) {
      _recordError(error, FolderSavedDiagnosticAction.exporting);
      message = l.chatFileSaveFailed;
    } finally {
      _cancellation = null;
      if (mounted) setState(() => _exporting = null);
    }
    if (mounted && _current() && message != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final current = _current();
    final enabled = current && !_loading && _exporting == null;
    return AlertDialog(
      title: HelpLabel(
        title: l.folderSyncSavedTitle,
        help: l.folderSyncSavedHint,
      ),
      content: SizedBox(
        width: 640,
        height: min(420, MediaQuery.sizeOf(context).height * 0.55),
        child: !current
            ? Text(l.folderSyncSavedSessionChanged)
            : _loading
            ? const Center(child: CircularProgressIndicator())
            : _failed
            ? Text(l.folderSyncSavedLoadFailed)
            : (_page?.entries.isEmpty ?? true)
            ? Text(l.folderSyncSavedEmpty)
            : ListView.builder(
                itemCount: _page!.entries.length,
                itemBuilder: (context, index) {
                  final version = _page!.entries[index];
                  final stamp = version.version;
                  final details = <String>[
                    version.previous
                        ? l.folderSyncSavedPrevious
                        : l.folderSyncSavedIncoming,
                    if (!version.readable) l.folderSyncSavedUnreadable,
                    if (stamp != null) formatBytes(stamp.size),
                    if (stamp != null &&
                        stamp.modifiedAtMs.abs() <= 8640000000000000)
                      formatDateTime(
                        DateTime.fromMillisecondsSinceEpoch(stamp.modifiedAtMs),
                      ),
                  ];
                  return ListTile(
                    leading: Icon(
                      version.previous
                          ? Icons.history
                          : Icons.move_to_inbox_outlined,
                    ),
                    title: Text(
                      version.originalPath ?? l.folderSyncSavedUnknown,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(details.join(' · ')),
                    trailing: _exporting == version.relativePath
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(),
                          )
                        : IconButton(
                            tooltip: l.chatFileSaveAs,
                            icon: const Icon(Icons.save_alt),
                            onPressed: enabled && version.readable
                                ? () => _export(version)
                                : null,
                          ),
                  );
                },
              ),
      ),
      actions: [
        IconButton(
          tooltip: l.folderSyncSavedRefresh,
          icon: const Icon(Icons.refresh),
          onPressed: enabled ? () => _load() : null,
        ),
        if (_page?.nextAfter case final String after)
          TextButton(
            onPressed: enabled ? () => _load(after: after) : null,
            child: Text(l.folderSyncSavedNext),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.actionDone),
        ),
      ],
    );
  }
}
